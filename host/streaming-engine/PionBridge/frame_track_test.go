package main

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestFrameTrackAdvancesBudgetOnceBeforeWritingAccessUnit(t *testing.T) {
	writer := &recordingTrackWriter{}
	track := NewFrameTrack("video", "desktop")
	context := &fakeTrackLocalContext{
		id: "binding", ssrc: 41, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	var callbackIDs []uint64
	callbackFinished := false
	track.SetOnFrameStart(func(_, frameID uint64) error {
		callbackIDs = append(callbackIDs, frameID)
		callbackFinished = true
		return nil
	})
	writer.onWrite = func() {
		if !callbackFinished {
			t.Error("RTP write preceded frame-start callback")
		}
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 77, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
	}); err != nil {
		t.Fatal(err)
	}
	if len(writer.takePackets()) < 2 || len(callbackIDs) != 1 || callbackIDs[0] != 77 {
		t.Fatalf("frame-start callbacks = %v", callbackIDs)
	}
}

func TestFrameTrackFrameStartFailureDoesNotMutatePacketState(t *testing.T) {
	writer := &recordingTrackWriter{}
	track := NewFrameTrack("video", "desktop")
	context := &fakeTrackLocalContext{
		id: "binding", ssrc: 41, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("ledger rejected frame")
	track.SetOnFrameStart(func(uint64, uint64) error { return wantErr })
	timestamp := track.timestamp
	dependencyFrameNumber := track.dependencyFrameNumber
	sequence := track.bindings["binding"].sequence
	err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 77, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(100),
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if len(writer.takePackets()) != 0 || track.timestamp != timestamp ||
		track.dependencyFrameNumber != dependencyFrameNumber ||
		track.bindings["binding"].sequence != sequence {
		t.Fatal("failed frame-start callback mutated packet state")
	}
}

func TestFrameTrackWritesNegotiatedAV1RTPWithExactMetadata(t *testing.T) {
	writer := &recordingTrackWriter{}
	context := &fakeTrackLocalContext{
		id: "binding-1", ssrc: 0x11223344, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7},
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	track := NewFrameTrack("video", "desktop")
	track.dependencyFrameNumber = 0x1234
	bound, err := track.Bind(context)
	if err != nil {
		t.Fatal(err)
	}
	if bound.PayloadType != 45 {
		t.Fatalf("bound codec = %#v", bound)
	}

	firstData := testAV1AccessUnit(4_000)
	first := OutboundFrame{
		StreamID: 5, FrameID: 9, InputSequence: 11,
		HostProcessingNanos: 13, EncodeNanos: 7,
		Keyframe: true, Dependency: l1t1Dependency(true), Data: firstData,
	}
	if err := track.WriteAccessUnit(first); err != nil {
		t.Fatal(err)
	}
	firstPackets := writer.takePackets()
	if len(firstPackets) < 2 {
		t.Fatalf("large access unit wrote %d RTP packets", len(firstPackets))
	}
	firstTimestamp := firstPackets[0].Timestamp
	for index, packet := range firstPackets {
		if packet.PayloadType != 45 || packet.SSRC != 0x11223344 {
			t.Fatalf("packet %d negotiated fields = %#v", index, packet.Header)
		}
		if packet.Timestamp != firstTimestamp {
			t.Fatalf("packet %d timestamp = %d, want %d", index, packet.Timestamp, firstTimestamp)
		}
		if packet.Marker != (index == len(firstPackets)-1) {
			t.Fatalf("packet %d marker = %v", index, packet.Marker)
		}
		if packet.ExtensionProfile != rtp.ExtensionProfileTwoByte {
			t.Fatalf("packet %d extension profile = 0x%x", index, packet.ExtensionProfile)
		}
		playout := packet.GetExtension(8)
		if index == 0 {
			// MINIMUM ZERO, CEILING NON-ZERO. The minimum governs steady-state latency and must
			// stay 0; the maximum is a PERMISSION, and the 0 it used to carry told the receiver a
			// late frame could only be DISCARDED — which breaks the reference chain and costs a
			// keyframe round trip, far worse for latency than rendering that frame late. Encoded as
			// two 12-bit counts of 10ms: [min>>4, min<<4|max>>8, max].
			if len(playout) != 3 {
				t.Fatalf("first packet playout delay = %v, want 3 bytes", playout)
			}
			minDelay := uint16(playout[0])<<4 | uint16(playout[1])>>4
			maxDelay := uint16(playout[1]&0x0f)<<8 | uint16(playout[2])
			if minDelay != 0 {
				t.Fatalf("playout delay minimum = %d, want 0 — the minimum is what costs latency", minDelay)
			}
			if maxDelay == 0 {
				t.Fatalf("playout delay maximum = 0 — a late frame may then only be discarded")
			}
		} else if len(playout) != 0 {
			t.Fatalf("packet %d unexpectedly repeated playout delay = %v", index, playout)
		}
		metadata, err := ParseFrameMetadata(packet.GetExtension(7))
		if err != nil {
			t.Fatal(err)
		}
		if metadata.StreamID != first.StreamID || metadata.FrameID != first.FrameID ||
			metadata.InputSequence != first.InputSequence ||
			metadata.HostProcessingNanos != first.HostProcessingNanos ||
			metadata.EncodeNanos != first.EncodeNanos || !metadata.Keyframe ||
			metadata.PacketIndex != uint16(index) ||
			metadata.PacketCount != uint16(len(firstPackets)) ||
			metadata.OriginalAccessUnitBytes != uint32(len(first.Data)) {
			t.Fatalf("packet %d metadata = %#v", index, metadata)
		}
		descriptor := packet.GetExtension(9)
		wantFlags := byte(0)
		if index == 0 {
			wantFlags |= 0x80
		}
		if index == len(firstPackets)-1 {
			wantFlags |= 0x40
		}
		wantDescriptor := []byte{wantFlags, 0x12, 0x34}
		if index == 0 {
			wantDescriptor = append(wantDescriptor, 0x80, 0x00, 0x3a, 0x41, 0x01, 0x00)
		}
		if !bytes.Equal(descriptor, wantDescriptor) {
			t.Fatalf("packet %d dependency descriptor = %x, want %x", index, descriptor, wantDescriptor)
		}
		encoded, err := packet.Marshal()
		if err != nil {
			t.Fatal(err)
		}
		if len(encoded) > 1_200 {
			t.Fatalf("packet %d marshaled size = %d", index, len(encoded))
		}
		if index > 0 && packet.SequenceNumber != firstPackets[index-1].SequenceNumber+1 {
			t.Fatalf("packet %d sequence did not increment", index)
		}
	}

	second := OutboundFrame{
		StreamID: 5, FrameID: 10, InputSequence: 12,
		HostProcessingNanos: 14, EncodeNanos: 8,
		Dependency: l1t1Dependency(false), Data: testAV1AccessUnit(12),
	}
	if err := track.WriteAccessUnit(second); err != nil {
		t.Fatal(err)
	}
	secondPackets := writer.takePackets()
	if len(secondPackets) == 0 {
		t.Fatal("second access unit wrote no packets")
	}
	if secondPackets[0].Timestamp != firstTimestamp+1_500 {
		t.Fatalf("second timestamp = %d, want %d", secondPackets[0].Timestamp, firstTimestamp+1_500)
	}
	if secondPackets[0].SequenceNumber != firstPackets[len(firstPackets)-1].SequenceNumber+1 {
		t.Fatal("sequence did not continue across access units")
	}
	// Every frame's first packet repeats the playout delay: minimum 0, ceiling non-zero.
	if got := secondPackets[0].GetExtension(8); len(got) != 3 || got[0] != 0 || got[1]>>4 != 0 || got[2] == 0 {
		t.Fatalf("second frame playout delay = %v, want min 0 with a non-zero ceiling", got)
	}
	metadata, err := ParseFrameMetadata(secondPackets[0].GetExtension(7))
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Keyframe {
		t.Fatal("delta frame metadata was marked keyframe")
	}
	if got := secondPackets[0].GetExtension(9); !bytes.Equal(got, []byte{0xc1, 0x12, 0x35}) {
		t.Fatalf("delta dependency descriptor = %x", got)
	}

	if err := track.Unbind(context); err != nil {
		t.Fatal(err)
	}
	if err := track.WriteAccessUnit(second); err == nil {
		t.Fatal("write without a binding unexpectedly succeeded")
	}
}

func TestFrameTrackWritesLayeredDependencyDescriptorsWithWrapAndMTUBudget(t *testing.T) {
	for _, test := range []struct {
		name      string
		mode      AV1ScalabilityMode
		structure []byte
		delta     AV1Dependency
	}{
		{name: "L1T1", mode: AV1ScalabilityL1T1,
			structure: []byte{0x80, 0x00, 0x3a, 0x41, 0x01, 0x00},
			delta:     l1t1Dependency(false)},
		{name: "L1T2", mode: AV1ScalabilityL1T2,
			structure: []byte{0x80, 0x01, 0x1e, 0xa8, 0x51, 0x41, 0x01, 0x08},
			delta:     AV1Dependency{Mode: AV1ScalabilityL1T2, TemporalID: 1, TemplateID: 2}},
		{name: "L1T3", mode: AV1ScalabilityL1T3,
			structure: []byte{0x80, 0x02, 0x14, 0xea, 0xa8, 0x60, 0x41,
				0x4d, 0x14, 0x10, 0x20, 0x84, 0x26},
			delta: AV1Dependency{Mode: AV1ScalabilityL1T3, TemporalID: 2, TemplateID: 4}},
	} {
		t.Run(test.name, func(t *testing.T) {
			writer := &recordingTrackWriter{}
			context := layeredFrameTrackContext(test.name, writer)
			track := NewFrameTrack("video", "desktop")
			track.dependencyFrameNumber = 0xffff
			if _, err := track.Bind(context); err != nil {
				t.Fatal(err)
			}
			if err := track.WriteAccessUnit(OutboundFrame{
				StreamID: 1, FrameID: 1, Keyframe: true,
				Dependency: AV1Dependency{Mode: test.mode}, Data: testAV1AccessUnit(4_000),
			}); err != nil {
				t.Fatal(err)
			}
			packets := writer.takePackets()
			if len(packets) < 2 {
				t.Fatalf("layered keyframe emitted %d packets", len(packets))
			}
			for index, packet := range packets {
				descriptor := packet.GetExtension(9)
				wantFlags := byte(0)
				if index == 0 {
					wantFlags |= 0x80
				}
				if index == len(packets)-1 {
					wantFlags |= 0x40
				}
				want := []byte{wantFlags, 0xff, 0xff}
				if index == 0 {
					want = append(want, test.structure...)
				}
				if !bytes.Equal(descriptor, want) {
					t.Fatalf("packet %d descriptor = %x, want %x", index, descriptor, want)
				}
				if packet.MarshalSize() > maximumRTPBytes {
					t.Fatalf("packet %d size = %d", index, packet.MarshalSize())
				}
			}
			if err := track.WriteAccessUnit(OutboundFrame{
				StreamID: 1, FrameID: 2, Dependency: test.delta,
				Data: testAV1AccessUnit(16),
			}); err != nil {
				t.Fatal(err)
			}
			delta := writer.takePackets()
			if len(delta) != 1 {
				t.Fatalf("small delta emitted %d packets", len(delta))
			}
			if got := delta[0].GetExtension(9); !bytes.Equal(
				got, []byte{0xc0 | test.delta.TemplateID, 0x00, 0x00},
			) {
				t.Fatalf("wrapped delta descriptor = %x", got)
			}
		})
	}
}

func TestFrameTrackRTXPreservesDependencyDescriptorBytes(t *testing.T) {
	writer := &recordingTrackWriter{}
	context := layeredFrameTrackContext("rtx", writer)
	track := NewFrameTrack("video", "desktop")
	track.dependencyFrameNumber = 0x1234
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 1, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(32),
	}); err != nil {
		t.Fatal(err)
	}
	primary := writer.takePackets()[0]
	want := append([]byte(nil), primary.GetExtension(9)...)
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond,
	}, nil)
	header := primary.Header.Clone()
	header.SSRC = 10
	header.SequenceNumber = 77
	harness.writePrimary(t, 77, primary.Payload, &header)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 77}},
	})
	select {
	case repair := <-harness.written:
		if got := repair.header.GetExtension(9); !bytes.Equal(got, want) {
			t.Fatalf("RTX descriptor = %x, want %x", got, want)
		}
	case <-time.After(time.Second):
		t.Fatal("NACK produced no RTX packet")
	}
}

func TestFrameTrackDescriptorSizeChangesAV1FragmentationWithinMTU(t *testing.T) {
	data := testAV1AccessUnit(2_400)
	packetize := func(mode AV1ScalabilityMode) []*rtp.Packet {
		writer := &recordingTrackWriter{}
		track := NewFrameTrack("video", "desktop")
		track.dependencyFrameNumber = 7
		if _, err := track.Bind(layeredFrameTrackContext("budget", writer)); err != nil {
			t.Fatal(err)
		}
		if err := track.WriteAccessUnit(OutboundFrame{
			StreamID: 1, FrameID: 1, Keyframe: true,
			Dependency: AV1Dependency{Mode: mode}, Data: data,
		}); err != nil {
			t.Fatal(err)
		}
		return writer.takePackets()
	}
	l1t1 := packetize(AV1ScalabilityL1T1)
	l1t3 := packetize(AV1ScalabilityL1T3)
	if len(l1t1) < 2 || len(l1t3) < 2 || len(l1t3[0].Payload) >= len(l1t1[0].Payload) {
		t.Fatalf(
			"first payload bytes L1T1/L1T3 = %d/%d across %d/%d packets",
			len(l1t1[0].Payload), len(l1t3[0].Payload), len(l1t1), len(l1t3),
		)
	}
	for _, packets := range [][]*rtp.Packet{l1t1, l1t3} {
		payloads := make([][]byte, len(packets))
		for index, packet := range packets {
			if packet.MarshalSize() > maximumRTPBytes {
				t.Fatalf("packet %d size = %d", index, packet.MarshalSize())
			}
			payloads[index] = packet.Payload
		}
		if got := normalizedAV1(t, payloads); !bytes.Equal(got, data[2:]) {
			t.Fatal("descriptor-aware fragmentation changed normalized AV1 bytes")
		}
	}
}

func layeredFrameTrackContext(id string, writer webrtc.TrackLocalWriter) *fakeTrackLocalContext {
	return &fakeTrackLocalContext{
		id: id, ssrc: 0x11223344, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7}, {URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
}

func TestFrameTrackTraceRecordsEveryPacketizedKeyframePacket(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(32)
	writer := &recordingTrackWriter{}
	context := &fakeTrackLocalContext{
		id: "trace-binding", ssrc: 0x11223344, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7}, {URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	track := NewFrameTrack("video", "desktop", recorder)
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 41, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
	}); err != nil {
		t.Fatal(err)
	}
	packets := writer.takePackets()
	events := recoveryTraceEvents(recorder)
	var packetized []recoveryTraceEvent
	var firstPackets []recoveryTraceEvent
	for _, event := range events {
		switch event.Kind {
		case traceKeyframePacketPacketized:
			packetized = append(packetized, event)
		case traceKeyframeFirstPacketEmitted:
			firstPackets = append(firstPackets, event)
		}
	}
	if len(packets) < 2 || len(packetized) != len(packets) || len(firstPackets) != 1 ||
		len(events) != len(packets)+1 {
		t.Fatalf("packets/events = %d/%d; events %#v", len(packets), len(events), events)
	}
	for index, packet := range packets {
		event := packetized[index]
		if event.Kind != traceKeyframePacketPacketized ||
			event.MediaSSRC == nil || *event.MediaSSRC != uint32(context.ssrc) ||
			event.RTPSequence == nil || *event.RTPSequence != packet.SequenceNumber ||
			event.RTPTimestamp == nil || *event.RTPTimestamp != packet.Timestamp ||
			event.FrameID == nil || *event.FrameID != 41 ||
			event.PayloadType == nil || *event.PayloadType != uint8(packet.PayloadType) ||
			event.PacketIndex == nil || *event.PacketIndex != uint16(index) ||
			event.PacketCount == nil || *event.PacketCount != uint16(len(packets)) ||
			event.Marker == nil || *event.Marker != packet.Marker {
			t.Fatalf("packetized keyframe event %d = %#v; packet %#v", index, event, packet)
		}
	}
	first := firstPackets[0]
	if first.Kind != traceKeyframeFirstPacketEmitted ||
		first.MediaSSRC == nil || *first.MediaSSRC != uint32(context.ssrc) ||
		first.RTPSequence == nil || *first.RTPSequence != packets[0].SequenceNumber ||
		first.RTPTimestamp == nil || *first.RTPTimestamp != packets[0].Timestamp ||
		first.FrameID == nil || *first.FrameID != 41 {
		t.Fatalf("first keyframe packet trace = %#v", first)
	}
}

func TestFrameTrackAcceptsOptionalMetadataAndRequiresPlayoutDelay(t *testing.T) {
	track := NewFrameTrack("video", "desktop")
	missingCodec := &fakeTrackLocalContext{
		id: "missing-codec", ssrc: 1, writer: &recordingTrackWriter{},
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90_000},
			PayloadType:        96,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 3}, {URI: playoutDelayURI, ID: 4},
			{URI: dependencyDescriptorURI, ID: 5},
		},
	}
	if _, err := track.Bind(missingCodec); err == nil {
		t.Fatal("missing AV1 negotiation unexpectedly bound")
	}
	playoutOnly := *missingCodec
	playoutOnly.id = "playout-only"
	playoutOnly.codecs = []webrtc.RTPCodecParameters{{
		RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000},
		PayloadType:        45,
	}}
	playoutOnly.extensions = []webrtc.RTPHeaderExtensionParameter{
		{URI: playoutDelayURI, ID: 4}, {URI: dependencyDescriptorURI, ID: 5},
	}
	if _, err := track.Bind(&playoutOnly); err != nil {
		t.Fatalf("optional metadata extension prevented binding: %v", err)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 1, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
	}); err != nil {
		t.Fatal(err)
	}
	packets := playoutOnly.writer.(*recordingTrackWriter).takePackets()
	// The playout-delay extension is present with a non-zero CEILING; see the encoding note above.
	if len(packets) == 0 || len(packets[0].GetExtension(3)) != 0 ||
		len(packets[0].GetExtension(4)) != 3 || packets[0].GetExtension(4)[2] == 0 ||
		len(packets[0].GetExtension(5)) == 0 {
		t.Fatalf("playout-only packet extensions = %#v", packets)
	}
	for index, packet := range packets {
		if packet.MarshalSize() > maximumRTPBytes {
			t.Fatalf("playout-only packet %d is %d bytes", index, packet.MarshalSize())
		}
	}

	missingPlayout := playoutOnly
	missingPlayout.id = "missing-playout"
	missingPlayout.writer = &recordingTrackWriter{}
	missingPlayout.extensions = []webrtc.RTPHeaderExtensionParameter{
		{URI: frameMetadataURI, ID: 3}, {URI: dependencyDescriptorURI, ID: 5},
	}
	if _, err := NewFrameTrack("missing", "desktop").Bind(&missingPlayout); err == nil {
		t.Fatal("missing playout-delay extension unexpectedly bound")
	}
	missingDependency := playoutOnly
	missingDependency.id = "missing-dependency"
	missingDependency.writer = &recordingTrackWriter{}
	missingDependency.extensions = []webrtc.RTPHeaderExtensionParameter{{URI: playoutDelayURI, ID: 4}}
	if _, err := NewFrameTrack("missing", "desktop").Bind(&missingDependency); err == nil {
		t.Fatal("missing dependency-descriptor extension unexpectedly bound")
	}
}

func TestFrameTrackReportsFirstSentKeyframePacketWithoutMetadataExtension(t *testing.T) {
	writer := &recordingTrackWriter{}
	context := &fakeTrackLocalContext{
		id: "browser-binding", ssrc: 0x11223344, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 4}, {URI: dependencyDescriptorURI, ID: 5},
		},
	}
	type sentKeyframe struct {
		ssrc     uint32
		sequence uint16
	}
	var sent []sentKeyframe
	track := NewFrameTrack("video", "desktop")
	track.SetOnKeyframeSent(func(ssrc uint32, sequence uint16) {
		sent = append(sent, sentKeyframe{ssrc: ssrc, sequence: sequence})
	})
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 1, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
	}); err != nil {
		t.Fatal(err)
	}
	packets := writer.takePackets()
	if len(packets) < 2 {
		t.Fatalf("keyframe emitted %d packets", len(packets))
	}
	if len(sent) != 1 || sent[0].ssrc != uint32(context.ssrc) ||
		sent[0].sequence != packets[0].SequenceNumber {
		t.Fatalf("sent keyframe boundaries = %#v, first packet = %#v", sent, packets[0].Header)
	}

	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 2,
		Dependency: l1t1Dependency(false), Data: testAV1AccessUnit(32),
	}); err != nil {
		t.Fatal(err)
	}
	if len(sent) != 1 {
		t.Fatalf("delta frame changed keyframe boundaries: %#v", sent)
	}
}

func TestFrameTrackSelectsPrimaryAV1WhenRTXSurroundsIt(t *testing.T) {
	writer := &recordingTrackWriter{}
	context := &fakeTrackLocalContext{
		id: "av1-among-rtx", ssrc: 0x11223344, writer: writer,
		codecs: []webrtc.RTPCodecParameters{
			{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeRTX, ClockRate: 90_000, SDPFmtpLine: "apt=45;rtx-time=30",
				},
				PayloadType: 46,
			},
			{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
				},
				PayloadType: 45,
			},
			{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeRTX, ClockRate: 90_000, SDPFmtpLine: "apt=45;rtx-time=30",
				},
				PayloadType: 47,
			},
		},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7}, {URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	track := NewFrameTrack("video", "desktop")
	bound, err := track.Bind(context)
	if err != nil {
		t.Fatal(err)
	}
	if bound.MimeType != webrtc.MimeTypeAV1 || bound.PayloadType != 45 {
		t.Fatalf("bound associated codec instead of AV1: %#v", bound)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 1, FrameID: 1, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(32),
	}); err != nil {
		t.Fatal(err)
	}
	packets := writer.takePackets()
	if len(packets) == 0 {
		t.Fatal("primary AV1 write emitted no packets")
	}
	for index, packet := range packets {
		if packet.PayloadType != 45 {
			t.Fatalf("packet %d payload type = %d, want primary AV1 PT 45", index, packet.PayloadType)
		}
	}
}

func TestFrameTrackRTCPRequestsOneKeyframeForOwnedPLIOrFIR(t *testing.T) {
	for name, test := range map[string]struct {
		packet    rtcp.Packet
		handlePLI bool
	}{
		"owned PLI": {
			packet:    &rtcp.PictureLossIndication{MediaSSRC: 10},
			handlePLI: true,
		},
		"delegated PLI": {
			packet: &rtcp.PictureLossIndication{MediaSSRC: 10},
		},
		"FIR": {packet: &rtcp.FullIntraRequest{
			MediaSSRC: 10,
			FIR:       []rtcp.FIREntry{{SSRC: 10, SequenceNumber: 1}},
		}},
	} {
		t.Run(name, func(t *testing.T) {
			payload, err := rtcp.Marshal([]rtcp.Packet{test.packet})
			if err != nil {
				t.Fatal(err)
			}
			reads := 0
			requests := 0
			readFrameTrackRTCP(interceptor.RTCPReaderFunc(func(
				buffer []byte, attributes interceptor.Attributes,
			) (int, interceptor.Attributes, error) {
				if reads > 0 {
					return 0, attributes, io.EOF
				}
				reads++
				return copy(buffer, payload), attributes, nil
			}), func() { requests++ }, test.handlePLI)
			want := 1
			if name == "delegated PLI" {
				want = 0
			}
			if requests != want {
				t.Fatalf("keyframe requests = %d, want %d", requests, want)
			}
		})
	}
}

func TestPionHostRTCPPipelineCountsOneKeyframeRequestPerPLI(t *testing.T) {
	counters := &RecoveryCounters{}
	callbacks := 0
	requestKeyframe := func(uint32) {
		callbacks++
		counters.addRecoveryKeyframeRequest()
	}
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge:          30 * time.Millisecond,
		Counters:        counters,
		RequestKeyframe: requestKeyframe,
	}, nil)
	payload, err := rtcp.Marshal([]rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	reader := harness.interceptor.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte, attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		if reads > 0 {
			return 0, attributes, io.EOF
		}
		reads++
		return copy(buffer, payload), attributes, nil
	}))

	// The TRACK's own callback must not fire: handlePLI is false, so this PLI belongs to the
	// interceptor. Passing a distinct func makes that the assertion it always was implicitly --
	// sharing one counter between the two paths could not tell them apart.
	trackRequests := 0
	readFrameTrackRTCP(reader, func() { trackRequests++ }, false)
	if trackRequests != 0 {
		t.Fatalf("track-level keyframe requests = %d, want 0 when the interceptor handles PLI",
			trackRequests)
	}

	if callbacks != 1 || counters.Snapshot().RecoveryKeyframeRequests != 1 {
		t.Fatalf(
			"PLI callbacks=%d recoveryKeyframeRequests=%d, want 1/1",
			callbacks, counters.Snapshot().RecoveryKeyframeRequests,
		)
	}
}

func TestFrameTrackRTCPIgnoresUnrelatedFeedbackAndStopsOnClose(t *testing.T) {
	payload, err := rtcp.Marshal([]rtcp.Packet{
		&rtcp.ReceiverReport{SSRC: 10},
		&rtcp.SenderReport{SSRC: 11},
		&rtcp.ReceiverEstimatedMaximumBitrate{SenderSSRC: 12, Bitrate: 1_000_000},
	})
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	requests := 0
	readFrameTrackRTCP(interceptor.RTCPReaderFunc(func(
		buffer []byte, attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		if reads > 0 {
			return 0, attributes, io.EOF
		}
		reads++
		return copy(buffer, payload), attributes, nil
	}), func() { requests++ }, true)
	if requests != 0 || reads != 1 {
		t.Fatalf("unrelated RTCP requests=%d reads=%d", requests, reads)
	}
}

type recordingTrackWriter struct {
	mutex   sync.Mutex
	packets []*rtp.Packet
	onWrite func()
}

func (writer *recordingTrackWriter) WriteRTP(header *rtp.Header, payload []byte) (int, error) {
	if writer.onWrite != nil {
		writer.onWrite()
	}
	packet := &rtp.Packet{Header: *header, Payload: append([]byte(nil), payload...)}
	encoded, err := packet.Marshal()
	if err != nil {
		return 0, err
	}
	copyPacket := &rtp.Packet{}
	if err := copyPacket.Unmarshal(encoded); err != nil {
		return 0, err
	}
	writer.mutex.Lock()
	writer.packets = append(writer.packets, copyPacket)
	writer.mutex.Unlock()
	return len(encoded), nil
}

func (writer *recordingTrackWriter) Write(data []byte) (int, error) {
	packet := &rtp.Packet{}
	if err := packet.Unmarshal(data); err != nil {
		return 0, err
	}
	return writer.WriteRTP(&packet.Header, packet.Payload)
}

func (writer *recordingTrackWriter) takePackets() []*rtp.Packet {
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	result := writer.packets
	writer.packets = nil
	return result
}

type fakeTrackLocalContext struct {
	id         string
	ssrc       webrtc.SSRC
	writer     webrtc.TrackLocalWriter
	codecs     []webrtc.RTPCodecParameters
	extensions []webrtc.RTPHeaderExtensionParameter
}

func (context *fakeTrackLocalContext) CodecParameters() []webrtc.RTPCodecParameters {
	return context.codecs
}

func (context *fakeTrackLocalContext) HeaderExtensions() []webrtc.RTPHeaderExtensionParameter {
	return context.extensions
}

func (context *fakeTrackLocalContext) SSRC() webrtc.SSRC { return context.ssrc }

func (context *fakeTrackLocalContext) SSRCRetransmission() webrtc.SSRC { return 0 }

func (context *fakeTrackLocalContext) SSRCForwardErrorCorrection() webrtc.SSRC { return 0 }

func (context *fakeTrackLocalContext) WriteStream() webrtc.TrackLocalWriter { return context.writer }

func (context *fakeTrackLocalContext) ID() string { return context.id }

func (context *fakeTrackLocalContext) RTCPReader() interceptor.RTCPReader {
	return interceptor.RTCPReaderFunc(func([]byte, interceptor.Attributes) (int, interceptor.Attributes, error) {
		return 0, nil, io.EOF
	})
}

var _ webrtc.TrackLocalContext = (*fakeTrackLocalContext)(nil)

// frameTrackContextOffering builds a bind context advertising exactly the given mime types, so a
// test can present the negotiated set an H.264-only or H.265-capable receiver would leave behind.
//
// It ALWAYS offers the dependency-descriptor extension, so a test that fails to bind H.264 fails
// for the reason under test — codec selection — rather than for a missing extension.
func frameTrackContextOffering(mimeTypes []string) *fakeTrackLocalContext {
	codecs := make([]webrtc.RTPCodecParameters, 0, len(mimeTypes))
	for _, mime := range mimeTypes {
		payloadType := webrtc.PayloadType(96)
		if profile, ok := profileForMimeType(mime); ok {
			payloadType = webrtc.PayloadType(profile.payloadType)
		}
		codecs = append(codecs, webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: mime, ClockRate: 90_000},
			PayloadType:        payloadType,
		})
	}
	return &fakeTrackLocalContext{
		id: "binding", ssrc: 0x11223344, writer: &recordingTrackWriter{},
		codecs: codecs,
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7}, {URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
}

// BIND SELECTS BY rdev's PREFERENCE, not by the answer's order. A browser accepting AV1 and H.264
// must get AV1 — measurably better per bit on the text and UI rdev streams — and a browser
// accepting only H.264 must still BIND rather than fail, which is the whole point of the increment.
func TestBindSelectsByRdevPreference(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		offered  []string
		expected codecID
	}{
		{"all three", []string{webrtc.MimeTypeH264, webrtc.MimeTypeH265, webrtc.MimeTypeAV1}, rdevNegotiatedCodecAV1},
		{"no AV1", []string{webrtc.MimeTypeH264, webrtc.MimeTypeH265}, rdevNegotiatedCodecH265},
		{"H.264 only", []string{webrtc.MimeTypeH264}, rdevNegotiatedCodecH264},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			track := NewFrameTrack("video", "desktop")
			if _, err := track.Bind(frameTrackContextOffering(testCase.offered)); err != nil {
				t.Fatalf("Bind: %v", err)
			}
			got, ok := track.NegotiatedCodec()
			if !ok || got != testCase.expected {
				t.Fatalf("selected %v (ok=%t), want %v", got, ok, testCase.expected)
			}
		})
	}
}

// A codec rdev does not offer must be refused rather than bound to nothing.
func TestBindRefusesAnUnofferedCodec(t *testing.T) {
	track := NewFrameTrack("video", "desktop")
	if _, err := track.Bind(frameTrackContextOffering([]string{webrtc.MimeTypeVP8})); err == nil {
		t.Fatal("Bind accepted a codec rdev does not offer")
	}
}

// AN H.264 BIND MUST NOT REQUIRE THE DEPENDENCY DESCRIPTOR. Browsers negotiate that extension for
// AV1 and VP9, so demanding it would refuse to bind before packetization was ever reached.
func TestBindWithoutTheDescriptorSucceedsForH264AndFailsForAV1(t *testing.T) {
	withoutDescriptor := func(mime string) *fakeTrackLocalContext {
		context := frameTrackContextOffering([]string{mime})
		context.extensions = []webrtc.RTPHeaderExtensionParameter{
			{URI: frameMetadataURI, ID: 7}, {URI: playoutDelayURI, ID: 8},
		}
		return context
	}
	if _, err := NewFrameTrack("video", "desktop").Bind(withoutDescriptor(webrtc.MimeTypeH264)); err != nil {
		t.Fatalf("H.264 bind refused without a descriptor it does not emit: %v", err)
	}
	if _, err := NewFrameTrack("video", "desktop").Bind(withoutDescriptor(webrtc.MimeTypeAV1)); err == nil {
		t.Fatal("AV1 bound without the dependency descriptor it emits")
	}
}

// WHAT ACTUALLY GOES ON THE WIRE, which the bind tests above do not reach.
//
// An H.264 receiver never negotiated the dependency descriptor, so its packets must not carry one —
// even when the extension WAS offered, which is the case this pins. The bind context here offers
// the descriptor deliberately: a test that withheld it would pass against a build that always
// emits, because there would be no extension id to write.
//
// It also pins that the descriptor is still emitted for AV1, so the guard cannot be satisfied by
// dropping it everywhere.
func TestDependencyDescriptorIsEmittedForAV1AndNotForH264(t *testing.T) {
	for _, testCase := range []struct {
		mime string
		want bool
	}{
		{webrtc.MimeTypeAV1, true},
		{webrtc.MimeTypeH265, false},
		{webrtc.MimeTypeH264, false},
	} {
		t.Run(testCase.mime, func(t *testing.T) {
			context := frameTrackContextOffering([]string{testCase.mime})
			writer, ok := context.writer.(*recordingTrackWriter)
			if !ok {
				t.Fatalf("writer type = %T", context.writer)
			}
			track := NewFrameTrack("video", "desktop")
			if _, err := track.Bind(context); err != nil {
				t.Fatalf("Bind: %v", err)
			}
			if err := track.WriteAccessUnit(OutboundFrame{
				StreamID: 1, FrameID: 1, Keyframe: true,
				Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
			}); err != nil {
				t.Fatalf("WriteAccessUnit: %v", err)
			}
			packets := writer.takePackets()
			if len(packets) == 0 {
				t.Fatal("no packets written")
			}
			for index, packet := range packets {
				got := len(packet.GetExtension(9)) > 0
				if got != testCase.want {
					t.Fatalf("packet %d carries a dependency descriptor = %t, want %t",
						index, got, testCase.want)
				}
			}
		})
	}
}

// A SCREEN SOURCE IS NEVER EXACTLY 60 FPS, so an RTP timeline paced on a fixed step is a claim about
// frame timing that the capture side contradicts. ScreenCaptureKit delivers on CONTENT CHANGE, so
// real intervals are irregular by construction and the average sits below 60 (rdev's own `[encode]`
// line has recorded 58.2). A receiver derives its render schedule from these timestamps, so a fixed
// step makes the media clock run fast against the wall clock and the error accumulates without
// bound. The jitter buffer is the only thing that absorbs it — and rdev caps that buffer at 10 ms on
// purpose, which is why the defect is INVISIBLE on a far path (real network jitter forces a big
// buffer that hides it) and fully exposed on loopback.
//
// The presentation time is honoured only when it is PRESENT: a zero means "no timestamp" and keeps
// the fixed step, which is what leaves LLV's answering path (SendVideo, the certification comparison
// arm) byte-identical.
func TestFrameTrackPacesRTPTimestampsFromPresentationTime(t *testing.T) {
	writer := &recordingTrackWriter{}
	track := NewFrameTrack("video", "desktop")
	context := &fakeTrackLocalContext{
		id: "binding", ssrc: 41, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}

	const epoch = uint64(1_000_000_000)
	write := func(frameID uint64, presentationNanos uint64) uint32 {
		t.Helper()
		if err := track.WriteAccessUnit(OutboundFrame{
			StreamID: 1, FrameID: frameID, Keyframe: frameID == 1,
			PresentationNanos: presentationNanos,
			Dependency:        l1t1Dependency(frameID == 1),
			Data:              testAV1AccessUnit(200),
		}); err != nil {
			t.Fatal(err)
		}
		packets := writer.takePackets()
		if len(packets) == 0 {
			t.Fatalf("frame %d wrote no packets", frameID)
		}
		return packets[0].Timestamp
	}

	base := write(1, epoch)

	// 33 ms — a 30 fps interval. The fixed step would call this 16.667 ms and lose half of it.
	if got, want := write(2, epoch+33_000_000), base+2_970; got != want {
		t.Fatalf("33 ms after the first frame: timestamp = %d, want %d (delta %d, want 2970)",
			got, want, got-base)
	}
	// 8 ms — FASTER than 60 fps. The error runs in both directions, so a fixed step cannot be
	// described as a conservative approximation.
	if got, want := write(3, epoch+41_000_000), base+3_690; got != want {
		t.Fatalf("41 ms after the first frame: timestamp = %d, want %d", got, want)
	}
	// A window nobody is touching stops producing frames entirely. That gap is real elapsed time and
	// the receiver has to be told about it, or every frame after an idle period is scheduled early.
	if got, want := write(4, epoch+2_041_000_000), base+183_690; got != want {
		t.Fatalf("2 s idle gap: timestamp = %d, want %d", got, want)
	}
}

// THE DRIFT IS THE POINT, stated as the property rather than as a per-frame delta: a run of frames at
// a realistic capture rate must span the wall-clock time it actually took. Under the fixed step this
// stream would claim 5.000 s of media time for 5.172 s of real time — a 3.4% fast media clock, which
// exhausts a 10 ms jitter buffer in under a third of a second and then never stops being wrong.
func TestFrameTrackRTPTimelineTracksWallClockAtRealCaptureRates(t *testing.T) {
	writer := &recordingTrackWriter{}
	track := NewFrameTrack("video", "desktop")
	context := &fakeTrackLocalContext{
		id: "binding", ssrc: 41, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}

	const (
		frames        = 300
		intervalNanos = uint64(17_241_379) // 58.0 fps, the rate rdev's own encoder log has recorded
		epoch         = uint64(5_000_000_000)
	)
	var base, last uint32
	for index := 0; index < frames; index++ {
		if err := track.WriteAccessUnit(OutboundFrame{
			StreamID: 1, FrameID: uint64(index + 1), Keyframe: index == 0,
			PresentationNanos: epoch + uint64(index)*intervalNanos,
			Dependency:        l1t1Dependency(index == 0),
			Data:              testAV1AccessUnit(200),
		}); err != nil {
			t.Fatal(err)
		}
		packets := writer.takePackets()
		if len(packets) == 0 {
			t.Fatalf("frame %d wrote no packets", index)
		}
		if index == 0 {
			base = packets[0].Timestamp
		}
		last = packets[0].Timestamp
	}

	elapsedNanos := uint64(frames-1) * intervalNanos
	wantTicks := uint32((elapsedNanos*90_000 + 500_000_000) / 1_000_000_000)
	gotTicks := last - base
	// One tick of slack for per-frame rounding, and no more: the fixed step is off by 5_150 ticks
	// here, so a bound wide enough to admit it would not be measuring anything.
	if diff := int64(gotTicks) - int64(wantTicks); diff > 1 || diff < -1 {
		t.Fatalf("media clock drifted: %d ticks for %d ns of capture, want %d (%.2f%% error)",
			gotTicks, elapsedNanos, wantTicks,
			100*float64(int64(gotTicks)-int64(wantTicks))/float64(wantTicks))
	}
}

// THE PLAYOUT-DELAY FLOOR IS PER TRACK, NOT PER PROCESS. It used to live in a package global behind
// a sync.Once, read from the environment at first use — which is fine for a value nobody changes and
// wrong the moment a client can set it: one viewer's choice would silently retune every other live
// session in the host. rdev runs many sessions in one process by design.
//
// The floor is what FORCES a receiver to buffer, as opposed to the ceiling which merely permits it —
// the distinction that matters on WebKit, which honours the sender's extension over the page's own
// jitterBufferTarget. Measured on an iPhone: ceiling at 200 ms and jitterBufferTarget at 200 left
// jbuf at 1.5 ms; only the floor moved it.
func TestFrameTrackPlayoutDelayMinimumIsPerTrackAndSettable(t *testing.T) {
	newBound := func(t *testing.T, id string, ssrc webrtc.SSRC) (*FrameTrack, *recordingTrackWriter) {
		t.Helper()
		writer := &recordingTrackWriter{}
		track := NewFrameTrack("video", "desktop")
		context := &fakeTrackLocalContext{
			id: id, ssrc: ssrc, writer: writer,
			codecs: []webrtc.RTPCodecParameters{{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
				},
				PayloadType: 45,
			}},
			extensions: []webrtc.RTPHeaderExtensionParameter{
				{URI: playoutDelayURI, ID: 8},
				{URI: dependencyDescriptorURI, ID: 9},
			},
		}
		if _, err := track.Bind(context); err != nil {
			t.Fatal(err)
		}
		return track, writer
	}
	// The extension packs two 12-bit counts of 10 ms into three bytes.
	bounds := func(t *testing.T, raw []byte) (int, int) {
		t.Helper()
		if len(raw) != 3 {
			t.Fatalf("playout delay extension = %v, want 3 bytes", raw)
		}
		return int(raw[0])<<4 | int(raw[1]>>4), int(raw[1]&0x0F)<<8 | int(raw[2])
	}
	write := func(t *testing.T, track *FrameTrack, writer *recordingTrackWriter, id uint64) []byte {
		t.Helper()
		if err := track.WriteAccessUnit(OutboundFrame{
			StreamID: 1, FrameID: id, Keyframe: id == 1,
			Dependency: l1t1Dependency(id == 1), Data: testAV1AccessUnit(200),
		}); err != nil {
			t.Fatal(err)
		}
		packets := writer.takePackets()
		if len(packets) == 0 {
			t.Fatal("no packets")
		}
		return packets[0].GetExtension(8)
	}

	mine, mineWriter := newBound(t, "mine", 41)
	theirs, theirsWriter := newBound(t, "theirs", 42)

	// Default: floor zero, which is the project's whole point and must not move on its own.
	if min, max := bounds(t, write(t, mine, mineWriter, 1)); min != 0 || max == 0 {
		t.Fatalf("default floor/ceiling = %d/%d units, want 0 and non-zero", min, max)
	}

	if err := mine.SetPlayoutDelayMinimumMilliseconds(40); err != nil {
		t.Fatal(err)
	}
	if min, _ := bounds(t, write(t, mine, mineWriter, 2)); min != 4 {
		t.Fatalf("floor after setting 40ms = %d units, want 4", min)
	}
	// THE OTHER SESSION IS UNTOUCHED. This is the assertion the package global could never satisfy.
	if min, _ := bounds(t, write(t, theirs, theirsWriter, 1)); min != 0 {
		t.Fatalf("a second track's floor = %d units, want 0 — the setting leaked across sessions", min)
	}
	// A FLOOR CARRIES ITS OWN CEILING. Asking to hold at least 40 ms while the ceiling still says 10
	// is a contradiction on the wire, and refusing it would make the client's control a silent no-op
	// unless the operator had separately set an environment variable — the exact shape of trap this
	// project keeps finding. The floor raises the ceiling to meet it instead.
	if _, max := bounds(t, write(t, mine, mineWriter, 4)); max < 4 {
		t.Fatalf("ceiling = %d units, want at least the 4-unit floor", max)
	}
	// Out of the extension's 12-bit range is still refused, and the previous value stands.
	if err := mine.SetPlayoutDelayMinimumMilliseconds(100_000); err == nil {
		t.Fatal("an out-of-range floor was accepted")
	}
	if min, _ := bounds(t, write(t, mine, mineWriter, 3)); min != 4 {
		t.Fatalf("floor after a refused set = %d units, want the previous 4", min)
	}

	// RETURNING TO AUTO MUST RETURN TO AUTO — and this goes LAST, because setting the floor to zero
	// changes what "the previous value" means for the refused-set assertion above.
	//
	// Lowering the floor has to put the ceiling back too. Ratcheting it left a session that briefly
	// held a 100ms floor PERMITTING a 100ms receiver buffer forever, so "Auto" quietly meant something
	// different from what it meant a minute earlier — and on WebKit, which honours the sender's
	// extension over its own jitterBufferTarget, that is a real change to how much the far side holds.
	if err := mine.SetPlayoutDelayMinimumMilliseconds(0); err != nil {
		t.Fatal(err)
	}
	minAuto, maxAuto := bounds(t, write(t, mine, mineWriter, 5))
	if minAuto != 0 {
		t.Fatalf("floor after returning to Auto = %d units, want 0", minAuto)
	}
	if uint16(maxAuto) != playoutDelayCeilingUnits() {
		t.Fatalf("ceiling after returning to Auto = %d units, want the default %d — the raise did not undo",
			maxAuto, playoutDelayCeilingUnits())
	}
}

// A WINDOW IS A SETTING OF ITS OWN. min = max = 10 stamps exactly 1/1 units — the fixed offset a
// Chromium receiver measured best on (27 ms glass-to-glass against 57 under min 0 / max 500, every
// frame in phase; docs/latency-campaign/2026-09-04-report.md) — and it is neither the floor-only
// entry (which raises the ceiling to the floor and otherwise keeps the configured one) nor the
// gaming mode. An explicit ceiling below the floor is a contradiction on the wire and is refused
// with the previous pair standing; -1 for the ceiling is the floor-only behaviour, so the old
// entry point and the new one agree by construction.
func TestFrameTrackPlayoutDelayWindowIsStampedAsGiven(t *testing.T) {
	writer := &recordingTrackWriter{}
	track := NewFrameTrack("video", "desktop")
	context := &fakeTrackLocalContext{
		id: "window", ssrc: 43, writer: writer,
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}
	if _, err := track.Bind(context); err != nil {
		t.Fatal(err)
	}
	// The extension packs two 12-bit counts of 10 ms into three bytes.
	bounds := func(t *testing.T, raw []byte) (int, int) {
		t.Helper()
		if len(raw) != 3 {
			t.Fatalf("playout delay extension = %v, want 3 bytes", raw)
		}
		return int(raw[0])<<4 | int(raw[1]>>4), int(raw[1]&0x0F)<<8 | int(raw[2])
	}
	write := func(t *testing.T, id uint64) []byte {
		t.Helper()
		if err := track.WriteAccessUnit(OutboundFrame{
			StreamID: 1, FrameID: id, Keyframe: id == 1,
			Dependency: l1t1Dependency(id == 1), Data: testAV1AccessUnit(200),
		}); err != nil {
			t.Fatal(err)
		}
		packets := writer.takePackets()
		if len(packets) == 0 {
			t.Fatal("no packets")
		}
		return packets[0].GetExtension(8)
	}

	if err := track.SetPlayoutDelayBoundsMilliseconds(10, 10); err != nil {
		t.Fatal(err)
	}
	if min, max := bounds(t, write(t, 1)); min != 1 || max != 1 {
		t.Fatalf("10/10 window = %d/%d units, want 1/1", min, max)
	}
	// The gaming MODE is expressible, and distinct from the window.
	if err := track.SetPlayoutDelayBoundsMilliseconds(0, 0); err != nil {
		t.Fatal(err)
	}
	if min, max := bounds(t, write(t, 2)); min != 0 || max != 0 {
		t.Fatalf("0/0 mode = %d/%d units, want 0/0", min, max)
	}
	// A ceiling below the floor is refused and the previous pair stands.
	if err := track.SetPlayoutDelayBoundsMilliseconds(40, 20); err == nil {
		t.Fatal("a ceiling below the floor was accepted")
	}
	if min, max := bounds(t, write(t, 3)); min != 0 || max != 0 {
		t.Fatalf("after a refused set = %d/%d units, want the previous 0/0", min, max)
	}
	// -1 is the floor-only behaviour: the configured ceiling, raised to the floor.
	if err := track.SetPlayoutDelayBoundsMilliseconds(40, -1); err != nil {
		t.Fatal(err)
	}
	if min, max := bounds(t, write(t, 4)); min != 4 || uint16(max) != playoutDelayCeilingUnits() {
		t.Fatalf("40/ceiling = %d/%d units, want 4/%d", min, max, playoutDelayCeilingUnits())
	}
	if err := track.SetPlayoutDelayBoundsMilliseconds(0, -1); err != nil {
		t.Fatal(err)
	}
	if min, max := bounds(t, write(t, 5)); min != 0 || uint16(max) != playoutDelayCeilingUnits() {
		t.Fatalf("0/ceiling = %d/%d units, want 0/%d", min, max, playoutDelayCeilingUnits())
	}
}

// A CODEC PIN ORDERS THE SURVIVORS; IT MUST NOT ELIMINATE THEM.
//
// `preferredProfiles` used to return ONLY the pinned profile, which made a pin a hard filter on the
// ANSWER as well as a preference. Pinning a codec the receiver cannot negotiate then left Bind with
// nothing to select and it failed with "none of rdev's codecs were negotiated" — the track never
// bound, video stopped for good, and nothing surfaced it but a host log line.
//
// REPORTED FROM macOS SAFARI, whose WebRTC stack answers H.265 and H.264 but not AV1 (hardware AV1
// decode is a separate thing from WebRTC negotiation — this was an M5 Max). Pinning AV1 there killed
// the stream instead of falling back.
//
// It also contradicted the client, which already renders a refused pin as amber `data-unmet` and is
// documented against exactly this case ("an iPad with no AV1 decoder answers H.265 for an AV1 pin").
// That path was unreachable: the refusal took the video down before it could be shown.
func TestFrameTrackPinFallsBackWhenTheAnswerLacksIt(t *testing.T) {
	bindWith := func(t *testing.T, preference []codecID, offered ...webrtc.RTPCodecParameters) (string, error) {
		t.Helper()
		track := NewFrameTrack("video", "desktop")
		if preference != nil {
			track.SetCodecPreference(preference)
		}
		parameters, err := track.Bind(&fakeTrackLocalContext{
			id: "binding", ssrc: 41, writer: &recordingTrackWriter{},
			codecs: offered,
			// AV1 emits the dependency descriptor and Bind requires it to have been negotiated, so
			// the context must offer it or the AV1 arms fail for a reason that is not the one under
			// test. H.264/H.265 carry none and ignore it.
			extensions: []webrtc.RTPHeaderExtensionParameter{
				{URI: playoutDelayURI, ID: 8}, {URI: dependencyDescriptorURI, ID: 9},
			},
		})
		return parameters.MimeType, err
	}
	codec := func(mime string, pt webrtc.PayloadType) webrtc.RTPCodecParameters {
		return webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: mime, ClockRate: 90_000},
			PayloadType:        pt,
		}
	}
	av1 := codec(webrtc.MimeTypeAV1, 45)
	h265 := codec(webrtc.MimeTypeH265, 108)
	h264 := codec(webrtc.MimeTypeH264, 102)

	// THE REPORTED FAILURE: an AV1 pin against a Safari-shaped answer.
	mime, err := bindWith(t, []codecID{rdevNegotiatedCodecAV1}, h265, h264)
	if err != nil {
		t.Fatalf("an AV1 pin against an answer of H.265+H.264 failed to bind: %v", err)
	}
	if !strings.EqualFold(mime, webrtc.MimeTypeH265) {
		t.Fatalf("fell back to %s, want H.265 — rdev's next preference among what was negotiated", mime)
	}

	// THE PIN STILL WINS WHERE IT CAN, which is the whole point of pinning. A fallback that also
	// discarded the preference would pass the check above and make the control meaningless.
	if mime, err := bindWith(t, []codecID{rdevNegotiatedCodecH264}, av1, h265, h264); err != nil ||
		!strings.EqualFold(mime, webrtc.MimeTypeH264) {
		t.Fatalf("H.264 pin with everything on offer = %s (err %v), want H.264", mime, err)
	}

	// Auto is unchanged: rdev's own order, AV1 first.
	if mime, err := bindWith(t, nil, av1, h265, h264); err != nil ||
		!strings.EqualFold(mime, webrtc.MimeTypeAV1) {
		t.Fatalf("auto = %s (err %v), want AV1", mime, err)
	}

	// AND AN EMPTY ANSWER IS STILL AN ERROR. Falling back must not become "bind to anything" — a
	// section that negotiated no codec rdev knows is a real failure and has to stay one.
	if _, err := bindWith(t, []codecID{rdevNegotiatedCodecAV1},
		codec("video/VP9", 98)); err == nil {
		t.Fatal("an answer with no rdev codec bound anyway")
	}
}
