package main

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtp"
)

type recordingFlexEncoder struct {
	mutex        sync.Mutex
	groups       [][]rtp.Packet
	repairCounts []uint32
	returnNone   bool
	nextFEC      uint16
	ssrc         uint32
	payloadType  uint8
}

func (encoder *recordingFlexEncoder) EncodeFec(media []rtp.Packet, repairCount uint32) []rtp.Packet {
	encoder.mutex.Lock()
	defer encoder.mutex.Unlock()
	group := make([]rtp.Packet, len(media))
	copy(group, media)
	encoder.groups = append(encoder.groups, group)
	encoder.repairCounts = append(encoder.repairCounts, repairCount)
	if encoder.returnNone {
		return nil
	}
	result := make([]rtp.Packet, repairCount)
	for index := range result {
		result[index] = rtp.Packet{Header: rtp.Header{
			Version: 2, PayloadType: encoder.payloadType,
			SequenceNumber: encoder.nextFEC, Timestamp: 0xdeadbeef, SSRC: encoder.ssrc,
		}, Payload: []byte{byte(index)}}
		encoder.nextFEC++
	}
	return result
}

type recordingFlexEncoderFactory struct{ encoder *recordingFlexEncoder }

func (factory recordingFlexEncoderFactory) NewEncoder(payloadType uint8, ssrc uint32) flexfec.FlexEncoder {
	factory.encoder.payloadType = payloadType
	factory.encoder.ssrc = ssrc
	return factory.encoder
}

type frameAwareHarness struct {
	t             *testing.T
	tier          *FlexFECTierStore
	counters      *FlexFECCounters
	history       *TWCCPacketHistory
	budget        *RecoveryFrameClockBudget
	allocator     *TransportSequenceAllocator
	encoder       *recordingFlexEncoder
	written       []rtp.Packet
	disableErrors []error
	writer        interceptor.RTPWriter
	info          interceptor.StreamInfo
}

func newFrameAwareHarness(t *testing.T, tier FlexFECTier, transportSeed uint16) *frameAwareHarness {
	return newFrameAwareHarnessWithBudget(t, tier, transportSeed, nil)
}

func newFrameAwareHarnessWithBudget(
	t *testing.T,
	tier FlexFECTier,
	transportSeed uint16,
	budget *RecoveryFrameClockBudget,
) *frameAwareHarness {
	t.Helper()
	counters := NewFlexFECCounters(nil)
	allocator := newTransportSequenceAllocator(transportSeed)
	harness := &frameAwareHarness{
		t: t, counters: counters, tier: NewFlexFECTierStore(tier, counters),
		history: mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{}),
		budget:  budget, allocator: allocator,
		encoder: &recordingFlexEncoder{nextFEC: 700},
		info: interceptor.StreamInfo{
			SSRC: 100, SSRCForwardErrorCorrection: 200,
			PayloadType: 45, PayloadTypeForwardErrorCorrection: 47,
			RTPHeaderExtensions: []interceptor.RTPHeaderExtension{
				{URI: frameMetadataURI, ID: 3},
				{URI: dependencyDescriptorURI, ID: 4},
				{URI: twccURI, ID: 5},
			},
		},
	}
	factory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
		Tier: harness.tier, Override: NewFlexFECOverrideStore(), Allocator: allocator,
		History: harness.history, Counters: counters, EgressBudget: budget,
		EncoderFactory: recordingFlexEncoderFactory{encoder: harness.encoder},
		Disable:        func(err error) { harness.disableErrors = append(harness.disableErrors, err) },
	})
	if err != nil {
		t.Fatal(err)
	}
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	child := interceptor.RTPWriterFunc(func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
		harness.written = append(harness.written, rtp.Packet{Header: *header, Payload: append([]byte(nil), payload...)})
		return header.MarshalSize() + len(payload), nil
	})
	harness.writer = bound.BindLocalStream(&harness.info, child)
	return harness
}

func TestFrameAwareFlexFECSuppressesRepairBeforeAllocatingTWCC(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000, FramesPerSecond: 60,
		BurstDuration: 20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(40_000); err != nil {
		t.Fatal(err)
	}
	harness := newFrameAwareHarnessWithBudget(t, FlexFECTierHigh, 25, budget)
	harness.writeFrame(1, 10, 123_456, 1, true, 0)
	if len(harness.written) != 1 {
		t.Fatalf("written packets = %d, want media only", len(harness.written))
	}
	if got := harness.history.Snapshot().ByClass[TWCCFEC].SentPackets; got != 0 {
		t.Fatalf("FEC history packets = %d", got)
	}
	if next := harness.allocator.Next(); next != 25 {
		t.Fatalf("next sequence = %d, suppressed FEC consumed a sequence", next)
	}
	snapshot := budget.Snapshot()
	if snapshot.FECSuppressedPackets != 1 || snapshot.FECAdmittedPackets != 0 {
		t.Fatalf("egress snapshot = %#v", snapshot)
	}
}

func (harness *frameAwareHarness) writeFrame(
	frameID uint64,
	startSequence uint16,
	timestamp uint32,
	packetCount int,
	keyframe bool,
	templateID uint8,
) {
	harness.t.Helper()
	for index := 0; index < packetCount; index++ {
		packet := frameAwarePacket(
			frameID, startSequence+uint16(index), timestamp, index, packetCount, keyframe, templateID,
		)
		if _, err := harness.writer.Write(&packet.Header, packet.Payload, nil); err != nil {
			harness.t.Fatalf("write packet %d: %v", index, err)
		}
	}
}

func frameAwarePacket(
	frameID uint64,
	sequence uint16,
	timestamp uint32,
	packetIndex int,
	packetCount int,
	keyframe bool,
	templateID uint8,
) rtp.Packet {
	metadata, err := (FrameMetadata{
		Version: frameMetadataVersion, Keyframe: keyframe,
		StreamID: 1, FrameID: frameID,
		PacketIndex: uint16(packetIndex), PacketCount: uint16(packetCount),
		OriginalAccessUnitBytes: uint32(packetCount),
	}).MarshalBinary()
	if err != nil {
		panic(err)
	}
	descriptor, err := marshalDependencyDescriptor(
		AV1Dependency{Mode: AV1ScalabilityL1T3, TemporalID: []uint8{0, 0, 1, 2, 2}[templateID], TemplateID: templateID},
		frameID, packetIndex == 0, packetIndex == packetCount-1, false,
	)
	if err != nil {
		panic(err)
	}
	packet := rtp.Packet{Header: rtp.Header{
		Version: 2, Marker: packetIndex == packetCount-1,
		PayloadType: 45, SequenceNumber: sequence, Timestamp: timestamp, SSRC: 100,
	}, Payload: []byte{byte(packetIndex)}}
	if err := packet.SetExtensionWithProfile(3, metadata, rtp.ExtensionProfileTwoByte); err != nil {
		panic(err)
	}
	if err := packet.SetExtensionWithProfile(4, descriptor, rtp.ExtensionProfileTwoByte); err != nil {
		panic(err)
	}
	return packet
}

func TestFrameAwareFlexFECTemporalSelectionAndRatios(t *testing.T) {
	for _, test := range []struct {
		name       string
		tier       FlexFECTier
		templateID uint8
		keyframe   bool
		wantRepair uint32
	}{
		{name: "off keyframe", tier: FlexFECTierOff, keyframe: true},
		{name: "low T0", tier: FlexFECTierLow, templateID: 1, wantRepair: 1},
		{name: "low rejects T1", tier: FlexFECTierLow, templateID: 2},
		{name: "medium T1", tier: FlexFECTierMedium, templateID: 2, wantRepair: 1},
		{name: "medium rejects T2", tier: FlexFECTierMedium, templateID: 3},
		{name: "high T2", tier: FlexFECTierHigh, templateID: 4, wantRepair: 2},
		{name: "active keyframe strongest", tier: FlexFECTierLow, keyframe: true, wantRepair: 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			harness := newFrameAwareHarness(t, test.tier, 1)
			harness.writeFrame(1, 10, 90_000, 5, test.keyframe, test.templateID)
			if test.wantRepair == 0 {
				if len(harness.encoder.groups) != 0 || len(harness.written) != 5 {
					t.Fatalf("groups=%d written=%d", len(harness.encoder.groups), len(harness.written))
				}
				return
			}
			if len(harness.encoder.repairCounts) != 1 || harness.encoder.repairCounts[0] != test.wantRepair {
				t.Fatalf("repair counts = %v, want %d", harness.encoder.repairCounts, test.wantRepair)
			}
			if len(harness.written) != 5+int(test.wantRepair) {
				t.Fatalf("written = %d", len(harness.written))
			}
		})
	}
}

func TestFrameAwareFlexFECGroupsWithinOneFrameAt109Packets(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierMedium, 1)
	harness.writeFrame(1, 1_000, 90_000, 109, false, 1)
	harness.writeFrame(2, 2_000, 91_500, 110, false, 1)
	groupSizes := make([]int, len(harness.encoder.groups))
	for index, group := range harness.encoder.groups {
		groupSizes[index] = len(group)
		for packetIndex := 1; packetIndex < len(group); packetIndex++ {
			if group[packetIndex].SequenceNumber != group[packetIndex-1].SequenceNumber+1 {
				t.Fatalf("group %d is not consecutive", index)
			}
			if group[packetIndex].Timestamp != group[0].Timestamp {
				t.Fatalf("group %d crosses a timestamp", index)
			}
		}
	}
	if fmt.Sprint(groupSizes) != "[109 109 1]" {
		t.Fatalf("group sizes = %v", groupSizes)
	}
	if fmt.Sprint(harness.encoder.repairCounts) != "[22 22 1]" {
		t.Fatalf("repair counts = %v", harness.encoder.repairCounts)
	}
}

func TestFrameAwareFlexFECRepairTimestampTWCCAndHistory(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierHigh, 65_535)
	harness.writeFrame(1, 10, 123_456, 1, true, 0)
	if len(harness.written) != 2 {
		t.Fatalf("written = %d, want media + repair", len(harness.written))
	}
	repair := harness.written[1]
	if repair.Timestamp != 123_456 || repair.SSRC != 200 || repair.SequenceNumber != 700 {
		t.Fatalf("repair header = %+v", repair.Header)
	}
	var extension rtp.TransportCCExtension
	if err := extension.Unmarshal(repair.GetExtension(5)); err != nil {
		t.Fatal(err)
	}
	if extension.TransportSequence != 65_535 {
		t.Fatalf("repair TWCC = %d", extension.TransportSequence)
	}
	class := harness.history.Snapshot().ByClass[TWCCFEC]
	if class.SentPackets != 1 || class.SentBytes == 0 {
		t.Fatalf("FEC history = %+v", class)
	}
}

func TestFrameAwareFlexFECUsesDependencyDescriptorWhenCustomMetadataIsNotNegotiated(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierHigh, 1)
	harness.info.RTPHeaderExtensions = harness.info.RTPHeaderExtensions[1:]
	factory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
		Tier: harness.tier, Override: NewFlexFECOverrideStore(), Allocator: newTransportSequenceAllocator(1),
		History: harness.history, Counters: harness.counters,
		EncoderFactory: recordingFlexEncoderFactory{encoder: harness.encoder},
		Disable:        func(err error) { harness.disableErrors = append(harness.disableErrors, err) },
	})
	if err != nil {
		t.Fatal(err)
	}
	bound, err := factory.NewInterceptor("browser-compatible")
	if err != nil {
		t.Fatal(err)
	}
	child := interceptor.RTPWriterFunc(func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
		harness.written = append(harness.written, rtp.Packet{Header: *header, Payload: append([]byte(nil), payload...)})
		return header.MarshalSize() + len(payload), nil
	})
	harness.writer = bound.BindLocalStream(&harness.info, child)
	for index := 0; index < 3; index++ {
		packet := frameAwarePacket(1, 20+uint16(index), 91_500, index, 3, false, 1)
		if err := packet.DelExtension(3); err != nil {
			t.Fatal(err)
		}
		if _, err := harness.writer.Write(&packet.Header, packet.Payload, nil); err != nil {
			t.Fatal(err)
		}
	}
	if len(harness.disableErrors) != 0 || len(harness.encoder.groups) != 1 || len(harness.written) != 5 {
		t.Fatalf("disables=%v groups=%d written=%d", harness.disableErrors, len(harness.encoder.groups), len(harness.written))
	}
}

func TestFrameAwareFlexFECMalformedFrameForwardsMediaAndDisables(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierHigh, 1)
	first := frameAwarePacket(1, 10, 90_000, 0, 2, false, 1)
	if _, err := harness.writer.Write(&first.Header, first.Payload, nil); err != nil {
		t.Fatal(err)
	}
	// Starting a new frame proves the old one was incomplete.
	next := frameAwarePacket(2, 20, 91_500, 0, 1, false, 1)
	if _, err := harness.writer.Write(&next.Header, next.Payload, nil); err != nil {
		t.Fatal(err)
	}
	harness.writeFrame(3, 30, 93_000, 1, false, 1)
	if len(harness.written) != 3 || len(harness.encoder.groups) != 0 || len(harness.disableErrors) != 1 {
		t.Fatalf("written=%d groups=%d disables=%v", len(harness.written), len(harness.encoder.groups), harness.disableErrors)
	}
	if snapshot := harness.counters.Snapshot(harness.tier.Load()); snapshot.Failures != 1 || snapshot.DisableReason == "" {
		t.Fatalf("failure snapshot = %+v", snapshot)
	}
}

func TestFrameAwareFlexFECRejectsBoundaryDisagreementAndEmptyEncoder(t *testing.T) {
	for _, test := range []struct {
		name       string
		mutate     func(*rtp.Packet)
		returnNone bool
	}{
		{name: "descriptor disagreement", mutate: func(packet *rtp.Packet) {
			descriptor := append([]byte(nil), packet.GetExtension(4)...)
			descriptor[0] &^= 0x40
			if err := packet.SetExtensionWithProfile(4, descriptor, rtp.ExtensionProfileTwoByte); err != nil {
				panic(err)
			}
		}},
		{name: "encoder returned no repair", returnNone: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			harness := newFrameAwareHarness(t, FlexFECTierHigh, 1)
			harness.encoder.returnNone = test.returnNone
			packet := frameAwarePacket(1, 10, 90_000, 0, 1, false, 1)
			if test.mutate != nil {
				test.mutate(&packet)
			}
			if _, err := harness.writer.Write(&packet.Header, packet.Payload, nil); err != nil {
				t.Fatal(err)
			}
			if len(harness.written) != 1 || len(harness.disableErrors) != 1 {
				t.Fatalf("written=%d disables=%v", len(harness.written), harness.disableErrors)
			}
		})
	}
}

func TestFrameAwareFlexFECRejectsNonConsecutiveSequences(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierHigh, 1)
	for index, sequence := range []uint16{10, 12} {
		packet := frameAwarePacket(1, sequence, 90_000, index, 2, false, 1)
		if _, err := harness.writer.Write(&packet.Header, packet.Payload, nil); err != nil {
			t.Fatal(err)
		}
	}
	if len(harness.written) != 2 || len(harness.encoder.groups) != 0 || len(harness.disableErrors) != 1 {
		t.Fatalf("written=%d groups=%d disables=%v", len(harness.written), len(harness.encoder.groups), harness.disableErrors)
	}
}

func TestFrameAwareFlexFECUnbindRejectsIncompleteFrame(t *testing.T) {
	harness := newFrameAwareHarness(t, FlexFECTierHigh, 1)
	packet := frameAwarePacket(1, 10, 90_000, 0, 2, false, 1)
	if _, err := harness.writer.Write(&packet.Header, packet.Payload, nil); err != nil {
		t.Fatal(err)
	}
	// Recover the interceptor through a dedicated harness because BindLocalStream
	// intentionally exposes only the writer in production.
	factory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
		Tier:      NewFlexFECTierStore(FlexFECTierHigh, harness.counters),
		Override:  NewFlexFECOverrideStore(),
		Allocator: NewTransportSequenceAllocator(), History: harness.history,
		Counters: harness.counters, EncoderFactory: recordingFlexEncoderFactory{encoder: harness.encoder},
		Disable: func(err error) { harness.disableErrors = append(harness.disableErrors, err) },
	})
	if err != nil {
		t.Fatal(err)
	}
	bound, err := factory.NewInterceptor("unbind")
	if err != nil {
		t.Fatal(err)
	}
	writer := bound.BindLocalStream(&harness.info, interceptor.RTPWriterFunc(
		func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
			return header.MarshalSize() + len(payload), nil
		},
	))
	packet = frameAwarePacket(2, 20, 91_500, 0, 2, false, 1)
	if _, err := writer.Write(&packet.Header, packet.Payload, nil); err != nil {
		t.Fatal(err)
	}
	bound.UnbindLocalStream(&harness.info)
	if len(harness.disableErrors) != 1 {
		t.Fatalf("disable errors = %v", harness.disableErrors)
	}
}

func TestFrameAwareFlexFECTierStoreConcurrent(t *testing.T) {
	counters := NewFlexFECCounters(nil)
	store := NewFlexFECTierStore(FlexFECTierOff, counters)
	var workers sync.WaitGroup
	for index := 0; index < 100; index++ {
		workers.Add(1)
		go func(value int) {
			defer workers.Done()
			store.Set(FlexFECTier(value % 4))
			_ = store.Load()
		}(index)
	}
	workers.Wait()
	if store.Load() > FlexFECTierHigh {
		t.Fatalf("invalid final tier %d", store.Load())
	}
}

// THE DESCRIPTOR SOURCE MUST BE BYTE-FOR-BYTE TODAY'S ARITHMETIC. AV1 browser sessions, RdevViewer
// and `llv capture-view` all negotiate the dependency descriptor, so they take this path and must be
// unaffected by an increment whose entire purpose is the OTHER path. Asserted against
// parseOutboundDependencyDescriptor directly rather than against a fixture, so the two cannot drift.
func TestBoundaryFromDescriptorMatchesTodaysArithmetic(t *testing.T) {
	for _, templateID := range []byte{0, 1, 2, 3, 4} {
		for _, flags := range []byte{0x00, 0x80, 0x40, 0xc0} {
			data := []byte{templateID, flags, 0x00}
			want, wantErr := parseOutboundDependencyDescriptor(data)
			got, gotErr := boundaryFromDescriptor(data)
			if (wantErr == nil) != (gotErr == nil) {
				t.Fatalf("template %d flags %#x: err mismatch: %v vs %v",
					templateID, flags, wantErr, gotErr)
			}
			if wantErr != nil {
				continue
			}
			if got.first != want.FirstPacket || got.last != want.LastPacket ||
				got.keyframe != (want.TemplateID == 0) || got.temporalID != want.TemporalID {
				t.Fatalf("template %d flags %#x: boundary %+v disagrees with descriptor %+v",
					templateID, flags, got, want)
			}
			if got.descriptor == nil || *got.descriptor != want {
				t.Fatalf("template %d flags %#x: descriptor not retained", templateID, flags)
			}
		}
	}
}

// THE FIRST PACKET OF AN H.264 KEYFRAME NEVER CONTAINS TYPE 5, and that is why 7/8 are the primary
// detection path rather than a defensive extra. Verified against the vendored pion v1.10.2
// H264Payloader: DisableStapA defaults to false, and it buffers SPS and PPS into a STAP-A carrying
// ONLY those two, with the IDR following in a SEPARATE packet. A rule keyed on type 5 would
// misclassify every H.264 keyframe as a delta frame, silently, on every session.
func TestH264KeyframeFromPayload(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH264)
	if !ok {
		t.Fatal("no H.264 profile registered")
	}
	// STAP-A (type 24) carrying SPS (7) then PPS (8), which is what the payloader actually emits.
	stapA := []byte{24, 0x00, 0x02, 0x67, 0x42, 0x00, 0x02, 0x68, 0xce}
	tests := []struct {
		name    string
		payload []byte
		want    bool
	}{
		{"idr", []byte{0x65, 0x88}, true},
		{"sps", []byte{0x67, 0x42}, true},
		{"pps", []byte{0x68, 0xce}, true},
		{"stap-a of sps+pps", stapA, true},
		{"fu-a starting an idr", []byte{0x7c, 0x85, 0x00}, true},
		{"non-idr slice", []byte{0x61, 0x9a}, false},
		{"fu-a starting a non-idr", []byte{0x7c, 0x81, 0x00}, false},
		{"stap-a of non-idr only", []byte{24, 0x00, 0x02, 0x61, 0x9a}, false},
		{"too short", []byte{}, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := profile.keyframeFromPayload(test.payload); got != test.want {
				t.Fatalf("keyframeFromPayload(%#v) = %v, want %v", test.payload, got, test.want)
			}
		})
	}
}

// H.265 puts the type in bits 1-6 of the first byte. 16-21 are BLA/IDR/CRA; 32/33/34 are VPS/SPS/PPS
// and count for the same reason 7/8 do on H.264 — they lead the keyframe. Type 49 is a fragmentation
// unit whose real type is in payload[2].
func TestH265KeyframeFromPayload(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH265)
	if !ok {
		t.Fatal("no H.265 profile registered")
	}
	nal := func(t byte) []byte { return []byte{t << 1, 0x01, 0x00} }
	tests := []struct {
		name    string
		payload []byte
		want    bool
	}{
		{"idr_w_radl 19", nal(19), true},
		{"idr_n_lp 20", nal(20), true},
		{"bla 16", nal(16), true},
		{"cra 21", nal(21), true},
		{"vps 32", nal(32), true},
		{"sps 33", nal(33), true},
		{"pps 34", nal(34), true},
		{"trail_r 1", nal(1), false},
		{"fu starting an idr", []byte{49 << 1, 0x01, 0x80 | 19}, true},
		{"fu starting a trail", []byte{49 << 1, 0x01, 0x80 | 1}, false},
		// AGGREGATION PACKETS. The real case — a keyframe's parameter sets, bundled — is asserted
		// against pion's own payloader in TestARealKeyframeIsClassifiedFromItsFirstPacket, because a
		// hand-written one would only assert what its author believed pion emits. These rows are the
		// DEGENERATE shapes that payloader will never produce, and they exist to pin the degrade
		// rule: an aggregate this function cannot walk is not a keyframe, and never an error.
		{
			// The keyframe unit is SECOND, so this fails if the walk does not advance correctly:
			// header, then size 3 + trail unit, then size 3 + VPS unit.
			"aggregate reaching a parameter set in its second unit",
			[]byte{48 << 1, 0x01, 0x00, 0x03, 0x02, 0x01, 0x00, 0x00, 0x03, 0x40, 0x01, 0x0c},
			true,
		},
		{
			"aggregate of trail slices only",
			[]byte{48 << 1, 0x01, 0x00, 0x03, 0x02, 0x01, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00},
			false,
		},
		{
			// A size running past the end of the payload.
			"aggregate truncated mid-unit",
			[]byte{48 << 1, 0x01, 0x00, 0x09, 0x40, 0x01},
			false,
		},
		{
			// A unit too small to carry its own 2-byte NAL header.
			"aggregate with a unit size below a NAL header",
			[]byte{48 << 1, 0x01, 0x00, 0x01, 0x40},
			false,
		},
		{"aggregate header alone", []byte{48 << 1, 0x01}, false},
		{"too short", []byte{0x00}, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := profile.keyframeFromPayload(test.payload); got != test.want {
				t.Fatalf("keyframeFromPayload(%#v) = %v, want %v", test.payload, got, test.want)
			}
		})
	}
}

// A REAL KEYFRAME'S FIRST PACKET CARRIES NO SLICE AT ALL, and that is why this test packetizes with
// pion's own payloader instead of hand-authoring bytes.
//
// rdev's encoder prepends parameter sets to every keyframe (LLVCore.VideoEncoder.annexBData) and
// both payloaders bundle them ahead of the slice: H.264 into a STAP-A carrying only SPS and PPS,
// H.265 into an AGGREGATION PACKET carrying VPS, SPS and PPS. `keyframeFromPayload` is asked only of
// a frame's FIRST packet, so a classifier that recognised only slice and fragmentation types would
// call every keyframe a delta frame — silently, since a wrong verdict here cannot fail anything. It
// would simply earn the tier ratio instead of the pinned 2/5.
//
// THE HAND-AUTHORED TABLES ABOVE COULD NOT SEE THAT. Each case in them asserts what the author
// BELIEVED the payloader emits, which is the failure this repo has already recorded once — a
// fixture that encoded a wrong belief about pion, and was wrong in exactly the belief it was written
// to check. Driving the real payloader is what makes this independent of any such belief.
func TestARealKeyframeIsClassifiedFromItsFirstPacket(t *testing.T) {
	h265NAL := func(nalType byte) []byte { return []byte{nalType << 1, 0x01} }
	for _, test := range []struct {
		name       string
		codec      codecID
		accessUnit []byte
	}{
		{
			name:  "h264",
			codec: rdevNegotiatedCodecH264,
			accessUnit: annexB(
				[]byte{0x67, 0x42, 0xe0, 0x1f}, // SPS
				[]byte{0x68, 0xce, 0x3c, 0x80}, // PPS
				filler([]byte{0x65}, 3000),     // IDR
			),
		},
		{
			name:  "h265",
			codec: rdevNegotiatedCodecH265,
			accessUnit: annexB(
				append(h265NAL(32), 0x0c, 0x01, 0xff), // VPS
				append(h265NAL(33), 0x01, 0x02, 0x03), // SPS
				append(h265NAL(34), 0x04, 0x05),       // PPS
				filler(h265NAL(19), 3000),             // IDR
			),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			profile, ok := profileForCodecID(test.codec)
			if !ok {
				t.Fatal("codec not registered")
			}
			packets := newPayloaderFor(profile).Payload(1200, test.accessUnit)
			if len(packets) < 2 {
				t.Fatalf("a 3000-byte IDR at MTU 1200 must fragment, got %d packet(s)", len(packets))
			}
			if !profile.keyframeFromPayload(packets[0]) {
				t.Fatalf("the first packet of a real keyframe was not classified as one: % x", packets[0])
			}
		})
	}
}

// AND THE VERDICT HAS TO SURVIVE `accept`, which is the layer that actually decides the ratio.
//
// An aggregation packet followed by fragmentation units is a packet-shape sequence no test had ever
// put through `accept`: the frame OPENS on one NAL type and continues on another, sharing only a
// timestamp. This asserts the whole frame is collected and still earns the keyframe count —
// ceil(2n/5) rather than tier Low's ceil(n/10), which is the difference the misclassification cost.
func TestAcceptRecordsARealH265KeyframeAndItsRepairCount(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH265)
	if !ok {
		t.Fatal("no H.265 profile registered")
	}
	h265NAL := func(nalType byte) []byte { return []byte{nalType << 1, 0x01} }
	accessUnit := annexB(
		append(h265NAL(32), 0x0c, 0x01, 0xff),
		append(h265NAL(33), 0x01, 0x02, 0x03),
		append(h265NAL(34), 0x04, 0x05),
		filler(h265NAL(19), 3000),
	)
	packets := newPayloaderFor(profile).Payload(1200, accessUnit)
	if len(packets) < 3 {
		t.Fatalf("want an aggregate plus fragments, got %d packet(s)", len(packets))
	}

	stream := &frameAwareFlexFECStream{mediaSSRC: 1, profile: profile}
	shape := flexFECShape{tier: FlexFECTierLow}
	var complete *frameAwareFlexFECFrame
	for index, payload := range packets {
		last := index == len(packets)-1
		frame, err := stream.accept(&rtp.Header{
			SSRC:           1,
			SequenceNumber: uint16(10 + index), //nolint:gosec
			Timestamp:      90,
			Marker:         last,
		}, payload, shape)
		if err != nil {
			t.Fatalf("packet %d rejected: %v", index, err)
		}
		if frame != nil && !last {
			t.Fatalf("the frame completed early, at packet %d", index)
		}
		complete = frame
	}
	if complete == nil {
		t.Fatal("the frame never completed")
	}
	if !complete.keyframe {
		t.Fatal("a real H.265 keyframe was recorded as a delta frame — it loses the 2/5 ratio")
	}
	if len(complete.packets) != len(packets) {
		t.Fatalf("collected %d packets, want %d", len(complete.packets), len(packets))
	}
	media := len(complete.packets)
	want := uint32((media*2 + 4) / 5)
	if got := flexFECRepairCount(shape, complete.keyframe, media); got != want {
		t.Fatalf("repair count = %d, want %d (2/5 of %d media packets)", got, want, media)
	}
	if asDelta := flexFECRepairCount(shape, false, media); asDelta >= want {
		t.Fatalf("the test cannot see the defect: delta count %d is not below keyframe count %d",
			asDelta, want)
	}
}

// AV1 takes the descriptor path and must never be asked this question. Returning false rather than
// guessing is what makes a wrong call at the SELECTION site loud instead of silent.
func TestAV1KeyframeFromPayloadIsNeverConsulted(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecAV1)
	if !ok {
		t.Fatal("no AV1 profile registered")
	}
	if profile.keyframeFromPayload([]byte{0x0a, 0x00}) {
		t.Fatal("AV1 must not claim a keyframe from the payload — it uses the dependency descriptor")
	}
}

// THE SEND PATH IS WHAT MAKES `first` EXACT. This interceptor sits on the OUTGOING side, where
// packets arrive complete and in order by construction, so "no frame in progress" is a sound
// derivation of "this packet starts a frame". The same derivation on a RECEIVE path would be wrong,
// which is why it is asserted here rather than assumed.
func TestBoundaryFromRTPUsesMarkerAndFrameState(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH264)
	if !ok {
		t.Fatal("no H.264 profile registered")
	}
	idr := []byte{0x65, 0x88}
	delta := []byte{0x61, 0x9a}

	start := boundaryFromRTP(&rtp.Header{Marker: false}, idr, profile, false)
	if !start.first || start.last || !start.keyframe || start.descriptor != nil {
		t.Fatalf("frame start = %+v", start)
	}

	// A CONTINUATION MUST NOT RE-DERIVE `keyframe`: an FU-A continuation carries no NAL type, so the
	// value is meaningless here and `accept` must never compare it against the frame in progress.
	mid := boundaryFromRTP(&rtp.Header{Marker: false}, idr, profile, true)
	if mid.first || mid.last {
		t.Fatalf("continuation = %+v", mid)
	}
	if mid.keyframe {
		t.Fatal("a continuation must not claim to start a keyframe")
	}

	// The marker bit is the frame's last packet — already trusted, because today's code cross-checks
	// it against the descriptor and errors on disagreement.
	end := boundaryFromRTP(&rtp.Header{Marker: true}, delta, profile, true)
	if end.first || !end.last {
		t.Fatalf("frame end = %+v", end)
	}

	// L1T1: there is one temporal layer, so selectFlexFECFrame's tier test is inert and 0 is exactly
	// correct rather than a placeholder.
	if start.temporalID != 0 {
		t.Fatalf("temporalID = %d, want 0", start.temporalID)
	}
}

// A FRAGMENTED H.264 KEYFRAME MUST SURVIVE `accept` WHOLE. This is the case the design detail exists
// for: re-deriving `keyframe` from an FU-A continuation yields false, and comparing that against the
// frame in progress would reject the frame — silently costing protection on exactly the frames that
// matter most.
func TestAcceptCollectsAFragmentedH264Keyframe(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH264)
	if !ok {
		t.Fatal("no H.264 profile registered")
	}
	stream := &frameAwareFlexFECStream{mediaSSRC: 1, profile: profile}
	shape := flexFECShape{tier: FlexFECTierLow}

	fuStart := []byte{0x7c, 0x85, 0x00}
	fuEnd := []byte{0x7c, 0x45, 0x00}

	if complete, err := stream.accept(
		&rtp.Header{SSRC: 1, SequenceNumber: 10, Timestamp: 90, Marker: false}, fuStart, shape,
	); err != nil || complete != nil {
		t.Fatalf("first fragment: complete=%v err=%v", complete, err)
	}
	complete, err := stream.accept(
		&rtp.Header{SSRC: 1, SequenceNumber: 11, Timestamp: 90, Marker: true}, fuEnd, shape,
	)
	if err != nil {
		t.Fatalf("second fragment rejected: %v", err)
	}
	if complete == nil {
		t.Fatal("the frame never completed")
	}
	if !complete.keyframe {
		t.Fatal("a fragmented IDR must be recorded as a keyframe — it is what gets the 2/5 ratio")
	}
	if len(complete.packets) != 2 {
		t.Fatalf("packets = %d, want 2", len(complete.packets))
	}
}

// THE TIER TRANSITION USED TO KILL FlexFEC OUTRIGHT, and this is the test for it.
//
// While the controller sits at tier 0 the interceptor short-circuits — `shape.silent() &&
// stream.frame == nil` returns before `accept` is ever called — so NO packet enters frame tracking
// and `stream.frame` stays nil. The moment the controller decides to protect something, the next
// packet reaches `accept` as a CONTINUATION, `stream.frame` is still nil, and the guard read that as
// corruption and disabled FlexFEC for the rest of the session.
//
// MEASURED: `[bridge] recovery policy seq=2 tier=1` followed immediately by `[bridge] recovery:
// FlexFEC disabled — frame begins after packet zero`. FEC died the first time it was asked to do
// anything — the same signature as the inert-FlexFEC incident already on record, from a different
// cause. At rdev's two or three packets per frame the transition lands mid-frame about half the
// time, so adaptive FlexFEC was close to a coin flip.
//
// THE GUARD'S PREMISE WAS WRONG RATHER THAN ITS LOGIC: it assumed `accept` sees every packet, which
// the tier-0 bypass violates by design. Resyncing at the next frame start is the correct response,
// and it is bounded — one skipped partial frame per activation.
func TestAcceptResyncsWhenTheTierRisesMidFrame(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecAV1)
	if !ok {
		t.Fatal("no AV1 profile registered")
	}
	const extensionID = 4
	stream := &frameAwareFlexFECStream{mediaSSRC: 1, profile: profile, dependencyExtensionID: extensionID}
	shape := flexFECShape{tier: FlexFECTierLow}

	// A descriptor is 3 bytes: bit 7 is first-packet, bit 6 is last-packet, the low bits the template.
	packet := func(seq uint16, first, last bool) *rtp.Header {
		descriptor := byte(0)
		if first {
			descriptor |= 0x80
		}
		if last {
			descriptor |= 0x40
		}
		header := &rtp.Header{Version: 2, SSRC: 1, SequenceNumber: seq, Timestamp: 90, Marker: last}
		if err := header.SetExtension(extensionID, []byte{descriptor, 0, 0}); err != nil {
			t.Fatalf("could not attach the descriptor: %v", err)
		}
		return header
	}

	// The tier has just risen and this frame started while the interceptor was still bypassed.
	complete, err := stream.accept(packet(10, false, false), []byte{0x0a}, shape)
	if err != nil {
		t.Fatalf("a mid-frame arrival after the tier rose must resync, not fail FlexFEC: %v", err)
	}
	if complete != nil {
		t.Fatal("a partial frame must not be reported as complete")
	}

	// And the NEXT frame must be tracked normally — a resync that never resyncs is just a mute.
	if complete, err = stream.accept(packet(11, true, false), []byte{0x0a}, shape); err != nil || complete != nil {
		t.Fatalf("frame start after the resync: complete=%v err=%v", complete, err)
	}
	complete, err = stream.accept(packet(12, false, true), []byte{0x0a}, shape)
	if err != nil {
		t.Fatalf("frame end after the resync: %v", err)
	}
	if complete == nil {
		t.Fatal("the frame after the resync never completed — FlexFEC would protect nothing")
	}
	if len(complete.packets) != 2 {
		t.Fatalf("collected %d packets, want the 2 of the resynced frame only", len(complete.packets))
	}
}
