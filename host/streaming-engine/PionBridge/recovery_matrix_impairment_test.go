package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

func TestRecoveryMatrixPacketClassifierSeparatesOriginalRTXNACKAndOther(t *testing.T) {
	cases := []struct {
		name      string
		endpoint  recoveryMatrixEndpoint
		packet    []byte
		want      recoveryPacketClass
		sequence  *uint16
		timestamp *uint32
	}{
		{
			name: "original", endpoint: matrixHost,
			packet: marshalMatrixRTP(t, av1PayloadType, 10),
			want:   matrixPacketOriginal, sequence: matrixSequencePointer(10),
			timestamp: matrixUint32Pointer(90_000),
		},
		{
			name: "RTX", endpoint: matrixHost,
			packet: marshalMatrixRTP(t, rtxPayloadType, 11),
			want:   matrixPacketRTX, sequence: matrixSequencePointer(11),
			timestamp: matrixUint32Pointer(90_000),
		},
		{
			name: "NACK", endpoint: matrixViewer,
			packet: marshalMatrixNACK(t, 10),
			want:   matrixPacketNACK,
		},
		{
			name: "TWCC", endpoint: matrixViewer,
			packet: []byte{0x8f, 205, 0, 1, 0, 0, 0, 1},
			want:   matrixPacketTWCC,
		},
		{
			name: "PLI", endpoint: matrixViewer,
			packet: []byte{0x81, 206, 0, 1, 0, 0, 0, 1},
			want:   matrixPacketPLIFIR,
		},
		{
			name: "short", endpoint: matrixViewer,
			packet: []byte{22, 205, 0, 1},
			want:   matrixPacketOther,
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			got := classifyRecoveryDatagram(test.endpoint, test.packet)
			if got.Endpoint != test.endpoint || got.Class != test.want || got.Bytes != len(test.packet) {
				t.Fatalf("classification = %#v", got)
			}
			if !matrixEqualSequence(got.RTPSequence, test.sequence) {
				t.Fatalf("sequence = %v, want %v", got.RTPSequence, test.sequence)
			}
			if !matrixEqualTimestamp(got.RTPTimestamp, test.timestamp) {
				t.Fatalf("timestamp = %v, want %v", got.RTPTimestamp, test.timestamp)
			}
			if test.want == matrixPacketNACK {
				if got.WireFingerprint != recoveryWireFingerprint(test.packet) {
					t.Fatalf("NACK fingerprint = %q", got.WireFingerprint)
				}
			} else if got.WireFingerprint != "" {
				t.Fatalf("%s packet unexpectedly fingerprinted as %q", test.want, got.WireFingerprint)
			}
		})
	}
}

func TestRecoveryImpairmentClassifiesNegotiatedFlexFECByPayloadAndSSRC(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{})
	t.Cleanup(func() { _ = controller.Close() })
	controller.observePassthrough(matrixHost, marshalMatrixRTP(t, av1PayloadType, 1))
	controller.SetFlexFECIdentity(flexfecPayloadType, 88)
	packet := marshalMatrixRTP(t, flexfecPayloadType, 2)
	binary.BigEndian.PutUint32(packet[8:12], 88)
	if got := controller.classifyDatagram(matrixHost, packet).Class; got != matrixPacketFEC {
		t.Fatalf("class=%q, want %q", got, matrixPacketFEC)
	}
}

func TestRecoveryImpairmentFECAndTWCCUseIndependentLossStreams(t *testing.T) {
	profile := recoveryMatrixProfile{
		Seed: matrixInt64Pointer(8191), MediaLossBasisPoints: 4_000,
		FECLossBasisPoints: 4_000, TWCCLossBasisPoints: 4_000,
	}
	baseline := newRecoveryImpairmentController(profile)
	interleaved := newRecoveryImpairmentController(profile)
	t.Cleanup(func() { _ = baseline.Close() })
	t.Cleanup(func() { _ = interleaved.Close() })
	baseline.Activate()
	interleaved.Activate()
	for ordinal := uint16(1); ordinal <= 64; ordinal++ {
		want := baseline.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
		interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketFEC, Bytes: 1200,
		})
		interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixViewer, Class: matrixPacketTWCC, Bytes: 80,
		})
		got := interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
		if want.Action != got.Action || want.DelayMicroseconds != got.DelayMicroseconds {
			t.Fatalf("media ordinal %d shifted: %#v versus %#v", ordinal, want, got)
		}
	}
}

func TestRecoveryImpairmentFirstFECAndTWCCRulesFireOnce(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		DropFirstFEC: true, DropFirstTWCC: true,
	})
	t.Cleanup(func() { _ = controller.Close() })
	controller.Activate()
	for _, class := range []recoveryPacketClass{matrixPacketFEC, matrixPacketTWCC} {
		first := controller.decide(recoveryDatagramClassification{Class: class, Bytes: 16})
		second := controller.decide(recoveryDatagramClassification{Class: class, Bytes: 16})
		if first.Action != matrixActionDrop || second.Action != matrixActionAdmit {
			t.Fatalf("%s actions = %q, %q", class, first.Action, second.Action)
		}
	}
	for _, totals := range []map[recoveryPacketClass]recoveryPacketTotals{
		controller.Snapshot().Attempted,
		controller.Snapshot().ControllerDropped,
	} {
		for _, class := range recoveryPacketClasses() {
			if _, exists := totals[class]; !exists {
				t.Fatalf("snapshot omitted class %q: %#v", class, totals)
			}
		}
	}
}

func TestRecoveryImpairmentDecisionsRepeatForSameSeed(t *testing.T) {
	profile := recoveryMatrixProfile{
		Seed: matrixInt64Pointer(1741), OneWayDelayMicroseconds: 2_000,
		MaxJitterMicroseconds: 3_000, MediaLossBasisPoints: 3_500,
	}
	first := replayRecoveryDecisions(t, profile, 48)
	second := replayRecoveryDecisions(t, profile, 48)
	if !reflect.DeepEqual(first.decisions, second.decisions) {
		t.Fatalf("same seeded replay produced different decisions")
	}
	if first.digest != second.digest || first.digest == "" {
		t.Fatalf("digests = %q and %q", first.digest, second.digest)
	}
}

func TestRecoveryOriginalRandomDecisionsUseStableSourceCoordinates(t *testing.T) {
	profile := recoveryMatrixProfile{
		Seed: matrixInt64Pointer(8191), MaxJitterMicroseconds: 20_000,
		MediaLossBasisPoints:            2_000,
		ImmediateDuplicationBasisPoints: 1_000,
		DelayedDuplicationBasisPoints:   1_000,
		DuplicationDelayMinMicroseconds: 1_000,
		DuplicationDelayMaxMicroseconds: 5_000,
	}
	baseline := newRecoveryImpairmentController(profile)
	divergent := newRecoveryImpairmentController(profile)
	t.Cleanup(func() { _ = baseline.Close() })
	t.Cleanup(func() { _ = divergent.Close() })
	baseline.Activate()
	divergent.Activate()

	for range 4 {
		_ = decideMatrixOriginal(baseline, 90_000)
		_ = decideMatrixOriginal(divergent, 90_000)
	}
	for range 4 {
		_ = decideMatrixOriginal(baseline, 91_500)
	}
	for range 18 {
		_ = decideMatrixOriginal(divergent, 91_500)
	}
	for index := range 32 {
		want := decideMatrixOriginal(baseline, 93_000)
		got := decideMatrixOriginal(divergent, 93_000)
		if want.Action != got.Action ||
			want.DelayMicroseconds != got.DelayMicroseconds ||
			want.duplicateDelayMicroseconds != got.duplicateDelayMicroseconds {
			t.Fatalf("frame 3 packet %d shifted: %#v versus %#v", index+1, want, got)
		}
	}
}

func TestRecoveryImpairmentPacketClassesUseIndependentRandomStreams(t *testing.T) {
	profile := recoveryMatrixProfile{
		Seed: matrixInt64Pointer(8191), MediaLossBasisPoints: 4_000,
		NACKLossBasisPoints: 4_000,
	}
	baseline := newRecoveryImpairmentController(profile)
	interleaved := newRecoveryImpairmentController(profile)
	t.Cleanup(func() { _ = baseline.Close() })
	t.Cleanup(func() { _ = interleaved.Close() })
	baseline.Activate()
	interleaved.Activate()
	for ordinal := uint16(1); ordinal <= 64; ordinal++ {
		want := baseline.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
		interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixViewer, Class: matrixPacketNACK, Bytes: 16,
		})
		got := interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
		if want.Action != got.Action || want.DelayMicroseconds != got.DelayMicroseconds {
			t.Fatalf("original ordinal %d changed after NACK interleave: %#v versus %#v", ordinal, want, got)
		}
	}
}

func TestRecoveryImpairmentBurstDropsExactlyRequestedOriginalOrdinals(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		Bursts: []recoveryMatrixBurst{{StartOriginalOrdinal: 2, Length: 4}},
	})
	t.Cleanup(func() { _ = controller.Close() })
	controller.Activate()
	for ordinal := uint16(1); ordinal <= 7; ordinal++ {
		decision := controller.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
		wantDrop := ordinal >= 2 && ordinal <= 5
		if (decision.Action == matrixActionDrop) != wantDrop {
			t.Fatalf("ordinal %d action = %q, want drop %t", ordinal, decision.Action, wantDrop)
		}
	}
}

func TestRecoveryImpairmentSourceCoordinatesSelectExactOriginalPackets(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		Bursts: []recoveryMatrixBurst{{
			SelectorType: matrixBurstSourceCoordinates,
			SourceCoordinates: []recoveryMatrixSourceCoordinate{
				{FrameOrdinal: 2, PacketIndex: 2},
				{FrameOrdinal: 3, PacketIndex: 1},
				{FrameOrdinal: 3, PacketIndex: 2},
			},
		}},
	})
	t.Cleanup(func() { _ = controller.Close() })
	controller.Activate()

	timestamps := []uint32{90_000, 90_000, 91_500, 91_500, 91_500, 93_000, 93_000}
	wantDrops := []bool{false, false, false, true, false, true, true}
	for index, timestamp := range timestamps {
		decision := decideMatrixOriginal(controller, timestamp)
		if got := decision.Action == matrixActionDrop; got != wantDrops[index] {
			t.Fatalf("packet %d coordinate (%d,%d) drop = %t, want %t",
				index+1, decision.OriginalFrameOrdinal,
				decision.OriginalFramePacketIndex, got, wantDrops[index])
		}
	}
	wantCoordinates := []recoveryMatrixSourceCoordinate{
		{FrameOrdinal: 2, PacketIndex: 2},
		{FrameOrdinal: 3, PacketIndex: 1},
		{FrameOrdinal: 3, PacketIndex: 2},
	}
	if got := controller.Snapshot().SourceCoordinateDrops; !reflect.DeepEqual(got, wantCoordinates) {
		t.Fatalf("reported source-coordinate drops = %#v, want %#v", got, wantCoordinates)
	}
}

func TestRecoveryImpairmentSourceCoordinatesAreUnaffectedByRTXInterleaving(t *testing.T) {
	profile := recoveryMatrixProfile{Bursts: []recoveryMatrixBurst{{
		SelectorType:      matrixBurstSourceCoordinates,
		SourceCoordinates: []recoveryMatrixSourceCoordinate{{FrameOrdinal: 2, PacketIndex: 1}},
	}}}
	baseline := newRecoveryImpairmentController(profile)
	interleaved := newRecoveryImpairmentController(profile)
	t.Cleanup(func() { _ = baseline.Close() })
	t.Cleanup(func() { _ = interleaved.Close() })
	baseline.Activate()
	interleaved.Activate()

	_ = decideMatrixOriginal(baseline, 90_000)
	_ = decideMatrixOriginal(interleaved, 90_000)
	for ordinal := uint16(1); ordinal <= 8; ordinal++ {
		_ = interleaved.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketRTX,
			RTPSequence: matrixSequencePointer(ordinal), Bytes: 1200,
		})
	}
	want := decideMatrixOriginal(baseline, 91_500)
	got := decideMatrixOriginal(interleaved, 91_500)
	if want.Action != matrixActionDrop || got.Action != want.Action ||
		got.OriginalFrameOrdinal != 2 || got.OriginalFramePacketIndex != 1 {
		t.Fatalf("source-coordinate decisions = %#v and %#v", want, got)
	}
}

func TestRecoveryImpairmentFirstNACKAndRTXRulesFireOnce(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		DropFirstNACK: true, DropFirstRTX: true,
	})
	t.Cleanup(func() { _ = controller.Close() })
	controller.Activate()
	for _, class := range []recoveryPacketClass{matrixPacketNACK, matrixPacketRTX} {
		first := controller.decide(recoveryDatagramClassification{Endpoint: matrixHost, Class: class, Bytes: 16})
		second := controller.decide(recoveryDatagramClassification{Endpoint: matrixHost, Class: class, Bytes: 16})
		if first.Action != matrixActionDrop || second.Action != matrixActionAdmit {
			t.Fatalf("%s actions = %q, %q", class, first.Action, second.Action)
		}
	}
}

func TestRecoveryImpairmentJitterIsBoundedAndRepeatable(t *testing.T) {
	profile := recoveryMatrixProfile{
		Seed: matrixInt64Pointer(65537), OneWayDelayMicroseconds: 1_500,
		MaxJitterMicroseconds: 2_500,
	}
	first := replayRecoveryDecisions(t, profile, 64)
	second := replayRecoveryDecisions(t, profile, 64)
	for index, decision := range first.decisions {
		if decision.DelayMicroseconds < 1_500 || decision.DelayMicroseconds > 4_000 {
			t.Fatalf("decision %d delay = %d", index, decision.DelayMicroseconds)
		}
		if decision.DelayMicroseconds != second.decisions[index].DelayMicroseconds {
			t.Fatalf("decision %d jitter differs", index)
		}
	}
}

func TestRecoveryImpairmentPacketConnPassesThroughBeforeActivation(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		Bursts: []recoveryMatrixBurst{{StartOriginalOrdinal: 1, Length: 1}},
	})
	t.Cleanup(func() { _ = controller.Close() })
	connection := newMatrixPacketConn()
	payload := marshalMatrixRTP(t, av1PayloadType, 1)
	n, err := controller.SchedulePacketConnWrite(matrixHost, connection, payload, matrixTestAddr("viewer"))
	if err != nil || n != len(payload) {
		t.Fatalf("write = %d, %v", n, err)
	}
	if got := receiveMatrixWrite(t, connection.writes); !reflect.DeepEqual(got, payload) {
		t.Fatalf("payload = %x, want %x", got, payload)
	}
	if snapshot := controller.Snapshot(); snapshot.DecisionCount != 0 {
		t.Fatalf("pre-activation decision count = %d", snapshot.DecisionCount)
	}
}

func TestRecoveryImpairmentPacketConnDropsAndDelaysWithoutBlockingWriter(t *testing.T) {
	dropper := newRecoveryImpairmentController(recoveryMatrixProfile{
		Bursts: []recoveryMatrixBurst{{StartOriginalOrdinal: 1, Length: 1}},
	})
	t.Cleanup(func() { _ = dropper.Close() })
	droppedConn := newMatrixPacketConn()
	dropper.Activate()
	payload := marshalMatrixRTP(t, av1PayloadType, 1)
	n, err := dropper.SchedulePacketConnWrite(matrixHost, droppedConn, payload, matrixTestAddr("viewer"))
	if err != nil || n != len(payload) {
		t.Fatalf("drop write = %d, %v", n, err)
	}
	select {
	case <-droppedConn.writes:
		t.Fatal("intentionally dropped packet reached underlying connection")
	default:
	}

	delayer := newRecoveryImpairmentController(recoveryMatrixProfile{OneWayDelayMicroseconds: 20_000})
	t.Cleanup(func() { _ = delayer.Close() })
	delayedConn := newMatrixPacketConn()
	delayer.Activate()
	started := time.Now()
	n, err = delayer.SchedulePacketConnWrite(matrixHost, delayedConn, payload, matrixTestAddr("viewer"))
	if err != nil || n != len(payload) || time.Since(started) > 10*time.Millisecond {
		t.Fatalf("delayed enqueue = %d, %v after %s", n, err, time.Since(started))
	}
	select {
	case <-delayedConn.writes:
		t.Fatal("delayed packet was written before its deadline")
	case <-time.After(5 * time.Millisecond):
	}
	if got := receiveMatrixWrite(t, delayedConn.writes); !reflect.DeepEqual(got, payload) {
		t.Fatalf("delayed payload = %x", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := delayer.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	if current := delayer.Snapshot().ScheduledBytesCurrent; current != 0 {
		t.Fatalf("scheduled bytes after drain = %d", current)
	}
}

func TestRecoveryImpairmentDeactivateDrainKeepsLaterTrafficOutOfEvidence(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		OneWayDelayMicroseconds: 5_000,
	})
	controller.meterWrites = true
	t.Cleanup(func() { _ = controller.Close() })
	connection := newMatrixPacketConn()
	payload := marshalMatrixRTP(t, av1PayloadType, 1)
	if _, err := controller.SchedulePacketConnWrite(
		matrixHost, connection, payload, matrixTestAddr("viewer"),
	); err != nil {
		t.Fatal(err)
	}
	receiveMatrixWrite(t, connection.writes)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	if _, err := controller.SchedulePacketConnWrite(
		matrixHost, connection, payload, matrixTestAddr("viewer"),
	); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.DeactivateAndWaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	before := controller.Snapshot()
	if before.ScheduledBytesCurrent != 0 ||
		before.AdmittedToVNet[matrixPacketOriginal].Packets != 1 ||
		before.Delivered[matrixPacketOriginal].Packets != 1 {
		t.Fatalf("snapshot before passthrough = %#v", before)
	}
	if _, err := controller.SchedulePacketConnWrite(
		matrixHost, connection, payload, matrixTestAddr("viewer"),
	); err != nil {
		t.Fatal(err)
	}
	after := controller.Snapshot()
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("post-drain traffic changed evidence: before=%#v after=%#v", before, after)
	}
}

func TestRecoveryImpairmentPacketConnDuplicatesAndSurfacesAsyncWriteErrors(t *testing.T) {
	duplicator := newRecoveryImpairmentController(recoveryMatrixProfile{
		Seed: matrixInt64Pointer(1741), ImmediateDuplicationBasisPoints: 10_000,
	})
	t.Cleanup(func() { _ = duplicator.Close() })
	connection := newMatrixPacketConn()
	duplicator.Activate()
	payload := marshalMatrixRTP(t, av1PayloadType, 1)
	if _, err := duplicator.SchedulePacketConnWrite(matrixHost, connection, payload, matrixTestAddr("viewer")); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := duplicator.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	if len(connection.writes) != 2 {
		t.Fatalf("underlying writes = %d, want 2", len(connection.writes))
	}
	snapshot := duplicator.Snapshot()
	if snapshot.DuplicatesScheduled.Packets != 1 || snapshot.AdmittedToVNet[matrixPacketOriginal].Packets != 2 {
		t.Fatalf("duplicate accounting = %#v", snapshot)
	}

	failing := newRecoveryImpairmentController(recoveryMatrixProfile{})
	t.Cleanup(func() { _ = failing.Close() })
	failingConnection := newMatrixPacketConn()
	failingConnection.writeError = errors.New("synthetic write failure")
	failing.Activate()
	if _, err := failing.SchedulePacketConnWrite(matrixHost, failingConnection, payload, matrixTestAddr("viewer")); err != nil {
		t.Fatalf("enqueue unexpectedly returned async error: %v", err)
	}
	context2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if err := failing.WaitForDrain(context2); !errors.Is(err, failingConnection.writeError) {
		t.Fatalf("drain error = %v", err)
	}
}

func TestRecoveryImpairmentPacketConnMetersDeliveryAndQueueLoss(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{})
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := &recoveryImpairmentPacketConn{
		PacketConn: underlying, endpoint: matrixViewer, controller: controller,
	}
	controller.Activate()
	payload := marshalMatrixRTP(t, av1PayloadType, 88)
	controller.recordAdmitted(classifyRecoveryDatagram(matrixHost, payload))
	underlying.reads <- matrixPacketRead{payload: payload, source: matrixTestAddr("host")}
	buffer := make([]byte, 1500)
	n, _, err := wrapped.ReadFrom(buffer)
	if err != nil || n != len(payload) {
		t.Fatalf("read = %d, %v", n, err)
	}
	snapshot := controller.Snapshot()
	if snapshot.Delivered[matrixPacketOriginal].Packets != 1 ||
		snapshot.EffectiveQueueDropped[matrixPacketOriginal].Packets != 0 {
		t.Fatalf("delivery accounting = %#v", snapshot)
	}
}

type matrixPacketRead struct {
	payload []byte
	source  net.Addr
}

type matrixPacketConn struct {
	writes        chan []byte
	reads         chan matrixPacketRead
	writeError    error
	closed        chan struct{}
	closeOnce     sync.Once
	deadlineMutex sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time
}

func newMatrixPacketConn() *matrixPacketConn {
	return &matrixPacketConn{
		writes: make(chan []byte, 8), reads: make(chan matrixPacketRead, 8),
		closed: make(chan struct{}),
	}
}

func (connection *matrixPacketConn) ReadFrom(buffer []byte) (int, net.Addr, error) {
	select {
	case packet := <-connection.reads:
		return copy(buffer, packet.payload), packet.source, nil
	case <-connection.closed:
		return 0, nil, net.ErrClosed
	}
}

func (connection *matrixPacketConn) WriteTo(payload []byte, _ net.Addr) (int, error) {
	if connection.writeError != nil {
		return 0, connection.writeError
	}
	copyOfPayload := append([]byte(nil), payload...)
	connection.writes <- copyOfPayload
	return len(payload), nil
}

func (connection *matrixPacketConn) Close() error {
	connection.closeOnce.Do(func() { close(connection.closed) })
	return nil
}

func (connection *matrixPacketConn) LocalAddr() net.Addr { return matrixTestAddr("local") }
func (connection *matrixPacketConn) SetDeadline(deadline time.Time) error {
	connection.deadlineMutex.Lock()
	connection.readDeadline = deadline
	connection.writeDeadline = deadline
	connection.deadlineMutex.Unlock()
	return nil
}
func (connection *matrixPacketConn) SetReadDeadline(deadline time.Time) error {
	connection.deadlineMutex.Lock()
	connection.readDeadline = deadline
	connection.deadlineMutex.Unlock()
	return nil
}
func (connection *matrixPacketConn) SetWriteDeadline(deadline time.Time) error {
	connection.deadlineMutex.Lock()
	connection.writeDeadline = deadline
	connection.deadlineMutex.Unlock()
	return nil
}

func (connection *matrixPacketConn) deadlines() (time.Time, time.Time) {
	connection.deadlineMutex.Lock()
	defer connection.deadlineMutex.Unlock()
	return connection.readDeadline, connection.writeDeadline
}

type matrixTestAddr string

func (address matrixTestAddr) Network() string { return "matrix" }
func (address matrixTestAddr) String() string  { return string(address) }

func receiveMatrixWrite(t *testing.T, writes <-chan []byte) []byte {
	t.Helper()
	select {
	case payload := <-writes:
		return payload
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for underlying write")
		return nil
	}
}

type matrixDecisionReplay struct {
	decisions []recoveryImpairmentDecision
	digest    string
}

func replayRecoveryDecisions(t *testing.T, profile recoveryMatrixProfile, count int) matrixDecisionReplay {
	t.Helper()
	controller := newRecoveryImpairmentController(profile)
	defer func() { _ = controller.Close() }()
	controller.Activate()
	decisions := make([]recoveryImpairmentDecision, 0, count)
	for ordinal := 1; ordinal <= count; ordinal++ {
		decision := controller.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: matrixSequencePointer(uint16(ordinal)), Bytes: 1200,
		})
		decision.ElapsedMicroseconds = 0
		decisions = append(decisions, decision)
	}
	return matrixDecisionReplay{decisions: decisions, digest: controller.Snapshot().DecisionSHA256}
}

func decideMatrixOriginal(
	controller *RecoveryImpairmentController,
	timestamp uint32,
) recoveryImpairmentDecision {
	return controller.decide(recoveryDatagramClassification{
		Endpoint: matrixHost, Class: matrixPacketOriginal,
		RTPTimestamp: matrixUint32Pointer(timestamp), Bytes: 1200,
	})
}

func matrixInt64Pointer(value int64) *int64 {
	return &value
}

func matrixUint32Pointer(value uint32) *uint32 {
	return &value
}

func matrixEqualTimestamp(left, right *uint32) bool {
	return (left == nil && right == nil) ||
		(left != nil && right != nil && *left == *right)
}

func marshalMatrixRTP(t *testing.T, payloadType uint8, sequence uint16) []byte {
	t.Helper()
	encoded, err := (&rtp.Packet{
		Header: rtp.Header{
			Version: 2, PayloadType: payloadType, SequenceNumber: sequence,
			Timestamp: 90_000, SSRC: 77,
		},
		Payload: []byte{0xcd, 0x01, 0x02},
	}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func marshalMatrixNACK(t *testing.T, sequence uint16) []byte {
	t.Helper()
	encoded, err := (&rtcp.TransportLayerNack{
		SenderSSRC: 91, MediaSSRC: 77,
		Nacks: []rtcp.NackPair{{PacketID: sequence}},
	}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func matrixSequencePointer(value uint16) *uint16 {
	return &value
}

func matrixEqualSequence(left, right *uint16) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}
