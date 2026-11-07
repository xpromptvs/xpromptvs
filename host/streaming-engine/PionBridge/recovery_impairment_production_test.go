package main

import (
	"container/heap"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestRecoveryBandwidthQueueUsesVirtualFluidDepartureTimes(t *testing.T) {
	queue, err := newRecoveryBandwidthQueue(8_000, 2_000)
	if err != nil {
		t.Fatal(err)
	}
	epoch := time.Unix(1_000, 0)

	departure, admitted, err := queue.reserve(epoch, 1_000)
	if err != nil || !admitted || !departure.Equal(epoch.Add(time.Second)) {
		t.Fatalf("first reserve = %v, %t, %v; want +1s, true, nil", departure, admitted, err)
	}
	secondArrival := epoch.Add(500 * time.Millisecond)
	departure, admitted, err = queue.reserve(secondArrival, 1_000)
	if err != nil || !admitted || !departure.Equal(epoch.Add(2*time.Second)) {
		t.Fatalf("second reserve = %v, %t, %v; want epoch+2s, true, nil", departure, admitted, err)
	}
	departure, admitted, err = queue.reserve(secondArrival, 501)
	if err != nil || admitted || !departure.IsZero() {
		t.Fatalf("overflow reserve = %v, %t, %v; want zero, false, nil", departure, admitted, err)
	}
	if queue.queuedBits != 12_000 || !queue.updatedAt.Equal(secondArrival) {
		t.Fatalf("rejected reserve changed queue = %#v", queue)
	}
}

func TestRecoveryBandwidthQueueAdmitsExactCapacityAndDrainsWhileIdle(t *testing.T) {
	queue, err := newRecoveryBandwidthQueue(8_000, 2_000)
	if err != nil {
		t.Fatal(err)
	}
	epoch := time.Unix(2_000, 0)
	departure, admitted, err := queue.reserve(epoch, 2_000)
	if err != nil || !admitted || !departure.Equal(epoch.Add(2*time.Second)) {
		t.Fatalf("capacity reserve = %v, %t, %v", departure, admitted, err)
	}
	arrival := epoch.Add(3 * time.Second)
	departure, admitted, err = queue.reserve(arrival, 500)
	if err != nil || !admitted || !departure.Equal(arrival.Add(500*time.Millisecond)) {
		t.Fatalf("idle-drained reserve = %v, %t, %v", departure, admitted, err)
	}
}

func TestRecoveryBandwidthQueueRejectsInvalidInputs(t *testing.T) {
	for _, test := range []struct {
		name          string
		rate          int64
		capacityBytes uint64
	}{
		{name: "zero rate", rate: 0, capacityBytes: 1},
		{name: "negative rate", rate: -1, capacityBytes: 1},
		{name: "zero capacity", rate: 1, capacityBytes: 0},
		{name: "capacity overflow", rate: 1, capacityBytes: math.MaxUint64/8 + 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := newRecoveryBandwidthQueue(test.rate, test.capacityBytes); err == nil {
				t.Fatal("invalid queue configuration unexpectedly accepted")
			}
		})
	}

	queue, err := newRecoveryBandwidthQueue(8_000, 2_000)
	if err != nil {
		t.Fatal(err)
	}
	epoch := time.Unix(3_000, 0)
	if _, _, err := queue.reserve(epoch, 0); err == nil {
		t.Fatal("zero-byte packet unexpectedly accepted")
	}
	if _, admitted, err := queue.reserve(epoch, 1_000); err != nil || !admitted {
		t.Fatalf("initial reserve = admitted %t, error %v", admitted, err)
	}
	before := queue
	if _, _, err := queue.reserve(epoch.Add(-time.Nanosecond), 1); err == nil {
		t.Fatal("non-monotonic arrival unexpectedly accepted")
	}
	if queue != before {
		t.Fatalf("invalid arrival changed queue: before=%#v after=%#v", before, queue)
	}
	if _, _, err := queue.reserve(epoch, math.MaxUint64); err == nil {
		t.Fatal("packet bit-size overflow unexpectedly accepted")
	}
}

func TestRecoveryBandwidthQueueResetPreservesConfiguration(t *testing.T) {
	queue, err := newRecoveryBandwidthQueue(8_000, 2_000)
	if err != nil {
		t.Fatal(err)
	}
	epoch := time.Unix(4_000, 0)
	if _, admitted, err := queue.reserve(epoch, 1_000); err != nil || !admitted {
		t.Fatalf("reserve = admitted %t, error %v", admitted, err)
	}
	queue.reset()
	if queue.rateBitsPerSecond != 8_000 || queue.capacityBits != 16_000 ||
		queue.queuedBits != 0 || !queue.updatedAt.IsZero() {
		t.Fatalf("reset queue = %#v", queue)
	}
	departure, admitted, err := queue.reserve(epoch.Add(time.Hour), 1_000)
	if err != nil || !admitted || !departure.Equal(epoch.Add(time.Hour+time.Second)) {
		t.Fatalf("post-reset reserve = %v, %t, %v", departure, admitted, err)
	}
}

func TestRecoveryBandwidthQueueHandlesLargeIntegerArithmetic(t *testing.T) {
	queue, err := newRecoveryBandwidthQueue(math.MaxInt64, math.MaxUint64/8)
	if err != nil {
		t.Fatal(err)
	}
	epoch := time.Unix(5_000, 0)
	departure, admitted, err := queue.reserve(epoch, math.MaxInt64/8)
	if err != nil || !admitted || !departure.After(epoch) {
		t.Fatalf("large reserve = %v, %t, %v", departure, admitted, err)
	}
	arrival := epoch.Add(time.Second)
	if _, _, err := queue.reserve(arrival, 1); err != nil {
		t.Fatalf("large drain arithmetic: %v", err)
	}
}

func TestRecoveryBandwidthQueueTraceIsStableAcrossTwentyWorkers(t *testing.T) {
	type event struct {
		offset time.Duration
		bytes  uint64
	}
	trace := []event{
		{offset: 0, bytes: 1_000},
		{offset: 200 * time.Millisecond, bytes: 600},
		{offset: 200 * time.Millisecond, bytes: 700},
		{offset: 900 * time.Millisecond, bytes: 400},
		{offset: 3 * time.Second, bytes: 2_000},
	}
	replay := func() []string {
		queue, err := newRecoveryBandwidthQueue(8_000, 2_000)
		if err != nil {
			return []string{"constructor: " + err.Error()}
		}
		epoch := time.Unix(6_000, 0)
		result := make([]string, 0, len(trace))
		for _, item := range trace {
			departure, admitted, err := queue.reserve(epoch.Add(item.offset), item.bytes)
			result = append(result, fmt.Sprintf("%d/%t/%v/%v", departure.Sub(epoch), admitted, err, queue.queuedBits))
		}
		return result
	}
	want := replay()
	results := make(chan []string, 20)
	var workers sync.WaitGroup
	for index := 0; index < 20; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			results <- replay()
		}()
	}
	workers.Wait()
	close(results)
	for got := range results {
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("concurrent trace = %#v; want %#v", got, want)
		}
	}
}

func TestProductionRecoveryImpairmentLifecycleIsExplicitAndIdempotent(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1741,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	if err := controller.Activate(); err != nil {
		t.Fatalf("second activation: %v", err)
	}
	if err := controller.Close(); err != nil {
		t.Fatal(err)
	}
	if err := controller.Close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
	if err := controller.Activate(); err == nil {
		t.Fatal("activation after close unexpectedly succeeded")
	}
}

func TestRecoveryTraceHooksImpairmentDropAttemptAndDelivery(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(16)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "single-original-loss"),
		Seed:    1_741,
		Trace:   recorder,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	for sequence := uint16(10); sequence <= 11; sequence++ {
		timestamp := uint32(sequence) * 1_500
		controller.decide(recoveryDatagramClassification{
			Endpoint: matrixHost, Class: matrixPacketOriginal,
			RTPSequence: uint16Pointer(sequence), RTPTimestamp: &timestamp,
			Bytes: 1_200,
		})
	}
	originalTimestamp := uint32(18_000)
	original := recoveryDatagramClassification{
		Endpoint: matrixHost, Class: matrixPacketOriginal,
		RTPSequence: uint16Pointer(12), RTPTimestamp: &originalTimestamp,
		Bytes: 1_200,
	}
	controller.recordAdmitted(original)
	controller.recordDelivered(original)
	nack := recoveryDatagramClassification{
		Endpoint: matrixViewer, Class: matrixPacketNACK, Bytes: 32,
	}
	decision := controller.decide(nack)
	nack.traceOrdinal = decision.ClassOrdinal
	controller.recordAdmitted(nack)
	controller.recordDelivered(nack)

	want := []recoveryTraceKind{
		traceOriginalDropped,
		traceOriginalSocketDelivered,
		traceNACKSocketAttempted,
		traceNACKSocketDelivered,
	}
	if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("impairment trace = %v, want %v", got, want)
	}
	events := recoveryTraceEvents(recorder)
	if events[0].RTPSequence == nil || *events[0].RTPSequence != 11 ||
		events[0].RTPTimestamp == nil || *events[0].RTPTimestamp != 16_500 {
		t.Fatalf("dropped original event = %#v", events[0])
	}
	if events[1].RTPSequence == nil || *events[1].RTPSequence != 12 ||
		events[1].RTPTimestamp == nil || *events[1].RTPTimestamp != 18_000 {
		t.Fatalf("delivered original event = %#v", events[1])
	}
	if events[2].RTPSequence != nil || events[3].RTPSequence != nil {
		t.Fatalf("encrypted NACK unexpectedly exposed a sequence: %#v", events[2:])
	}
	if events[2].NumericValue == nil || events[3].NumericValue == nil ||
		*events[2].NumericValue != *events[3].NumericValue {
		t.Fatalf("NACK attempt/delivery trace tokens differ: %#v", events[2:])
	}
}

func TestRecoveryTraceNACKWireIdentitySurvivesDelayAndOmitsDropDelivery(t *testing.T) {
	packet := marshalMatrixNACK(t, 77)
	wantFingerprint := recoveryWireFingerprint(packet)
	wantSize := len(packet)

	delayedProfile := mustRecoveryMatrixProfile(t, "clean")
	delayedProfile.OneWayDelayMicroseconds = 2_000
	delayedTrace := newIncrementingRecoveryTraceRecorder(8)
	delayed, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: delayedProfile, Seed: 1_741, Trace: delayedTrace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = delayed.Close() })
	connection := newMatrixPacketConn()
	if err := delayed.Activate(); err != nil {
		t.Fatal(err)
	}
	if _, err := delayed.SchedulePacketConnWrite(
		matrixViewer, connection, packet, matrixTestAddr("host"),
	); err != nil {
		t.Fatal(err)
	}
	packet[len(packet)-1] ^= 1
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := delayed.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	events := recoveryTraceEvents(delayedTrace)
	if len(events) != 2 || events[0].Kind != traceNACKSocketAttempted ||
		events[1].Kind != traceNACKSocketDelivered {
		t.Fatalf("delayed NACK events = %#v", events)
	}
	for _, event := range events {
		if event.WireFingerprint == nil || *event.WireFingerprint != wantFingerprint ||
			event.PacketSize == nil || *event.PacketSize != wantSize {
			t.Fatalf("delayed NACK identity = %#v, want %s/%d", event, wantFingerprint, wantSize)
		}
	}
	if events[0].NumericValue == nil || events[1].NumericValue == nil ||
		*events[0].NumericValue != 1 || *events[1].NumericValue != 1 {
		t.Fatalf("delayed NACK class ordinals = %#v", events)
	}

	droppedProfile := mustRecoveryMatrixProfile(t, "clean")
	droppedProfile.DropFirstNACK = true
	droppedTrace := newIncrementingRecoveryTraceRecorder(8)
	dropped, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: droppedProfile, Seed: 1_741, Trace: droppedTrace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = dropped.Close() })
	if err := dropped.Activate(); err != nil {
		t.Fatal(err)
	}
	droppedPacket := marshalMatrixNACK(t, 78)
	if _, err := dropped.SchedulePacketConnWrite(
		matrixViewer, newMatrixPacketConn(), droppedPacket, matrixTestAddr("host"),
	); err != nil {
		t.Fatal(err)
	}
	droppedEvents := recoveryTraceEvents(droppedTrace)
	if len(droppedEvents) != 1 || droppedEvents[0].Kind != traceNACKSocketAttempted {
		t.Fatalf("dropped NACK events = %#v, want attempted only", droppedEvents)
	}
	if droppedEvents[0].WireFingerprint == nil ||
		*droppedEvents[0].WireFingerprint != recoveryWireFingerprint(droppedPacket) ||
		droppedEvents[0].PacketSize == nil || *droppedEvents[0].PacketSize != len(droppedPacket) {
		t.Fatalf("dropped NACK identity = %#v", droppedEvents[0])
	}
}

func TestProductionRecoveryImpairmentResetStartsFreshActiveEpoch(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "loss-jitter")
	trace := newIncrementingRecoveryTraceRecorder(8)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1741,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}

	classification := recoveryDatagramClassification{
		Endpoint:     matrixHost,
		Class:        matrixPacketOriginal,
		RTPTimestamp: matrixUint32Pointer(90_000),
		Bytes:        1_200,
	}
	_ = controller.decide(classification)
	_ = controller.decide(classification)
	trace.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: traceOriginalDropped,
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.ResetMeasurement(ctx); err != nil {
		t.Fatal(err)
	}
	if snapshot := controller.Snapshot(); snapshot.DecisionCount != 0 ||
		snapshot.Attempted[matrixPacketOriginal].Packets != 0 ||
		snapshot.ScheduledBytesCurrent != 0 || snapshot.ScheduledBytesPeak != 0 ||
		snapshot.OutstandingMediaBytesCurrent != 0 || snapshot.OutstandingMediaBytesPeak != 0 {
		t.Fatalf("reset snapshot = %#v, want empty measurement epoch", snapshot)
	}
	if events := recoveryTraceEvents(trace); len(events) != 0 {
		t.Fatalf("reset retained pre-measurement trace events: %#v", events)
	}

	decision := controller.decide(classification)
	if decision.ClassOrdinal != 1 {
		t.Fatalf("first post-reset original ordinal = %d, want 1", decision.ClassOrdinal)
	}
	fresh, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1741,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fresh.Close() })
	if err := fresh.Activate(); err != nil {
		t.Fatal(err)
	}
	if want := fresh.decide(classification); decision.Action != want.Action ||
		decision.DelayMicroseconds != want.DelayMicroseconds {
		t.Fatalf("post-reset decision = %#v, want fresh %#v", decision, want)
	}
}

func TestProductionNACKCallbackDoesNotFillHarnessObservationBuffer(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1741,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	callbacks := 0
	controller.SetNACKAttemptCallback(func() { callbacks++ })
	for ordinal := 0; ordinal < 300; ordinal++ {
		controller.decide(recoveryDatagramClassification{
			Endpoint: matrixViewer,
			Class:    matrixPacketNACK,
			Bytes:    16,
		})
	}
	if callbacks != 300 {
		t.Fatalf("NACK callbacks = %d, want 300", callbacks)
	}
	if buffered := len(controller.nackAttempts); buffered != 0 {
		t.Fatalf("buffered harness NACK attempts = %d, want 0", buffered)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.WaitForDrain(ctx); err != nil {
		t.Fatalf("callback-only NACK observation poisoned drain: %v", err)
	}
}

func TestHostPacketConnShapesReverseNACKBeforePionReadsIt(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "first-nack-loss")
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1741,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	first := marshalMatrixNACK(t, 10)
	second := marshalMatrixNACK(t, 11)
	underlying.reads <- matrixPacketRead{payload: first, source: matrixTestAddr("viewer")}
	underlying.reads <- matrixPacketRead{payload: second, source: matrixTestAddr("viewer")}
	buffer := make([]byte, 1500)
	n, _, err := wrapped.ReadFrom(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(buffer[:n], second) {
		t.Fatalf("read payload = %x, want second NACK %x", buffer[:n], second)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	snapshot := controller.Snapshot()
	if snapshot.Attempted[matrixPacketNACK].Packets != 2 ||
		snapshot.ControllerDropped[matrixPacketNACK].Packets != 1 ||
		snapshot.Delivered[matrixPacketNACK].Packets != 1 {
		t.Fatalf("reverse NACK accounting = %#v", snapshot)
	}
}

func TestHostPacketConnDrainsNACKWhileEarlierDeliveryWaits(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	profile.OneWayDelayMicroseconds = 200_000
	trace := newIncrementingRecoveryTraceRecorder(64)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1_741,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	first := []byte{0x01, 0x02, 0x03}
	nack := marshalMatrixNACK(t, 77)
	underlying.reads <- matrixPacketRead{
		payload: first, source: matrixTestAddr("viewer"),
	}
	underlying.reads <- matrixPacketRead{
		payload: nack, source: matrixTestAddr("viewer"),
	}
	readResult := make(chan error, 1)
	go func() {
		_, _, err := wrapped.ReadFrom(make([]byte, 1_500))
		readResult <- err
	}()

	deadline := time.Now().Add(50 * time.Millisecond)
	for time.Now().Before(deadline) {
		events := recoveryTraceEvents(trace)
		returns := 0
		decisionCalled := false
		for _, event := range events {
			if event.Kind == tracePacketConnReadReturned {
				returns++
			}
			if event.Kind == traceNACKImpairmentDecisionCalled {
				decisionCalled = true
			}
		}
		if returns >= 2 && decisionCalled {
			select {
			case err := <-readResult:
				t.Fatalf("delivery returned before its shaped deadline: %v", err)
			default:
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("read pump did not drain the queued NACK before the first deadline: %#v",
		recoveryTraceEvents(trace))
}

func TestHostPacketConnOwnsConsumerReadDeadline(t *testing.T) {
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"), Seed: 1_741,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	readDeadline := time.Now().Add(10 * time.Millisecond)
	if err := wrapped.SetReadDeadline(readDeadline); err != nil {
		t.Fatal(err)
	}
	underlyingRead, underlyingWrite := underlying.deadlines()
	if !underlyingRead.IsZero() || !underlyingWrite.IsZero() {
		t.Fatalf("consumer read deadline leaked to underlying = %v, %v",
			underlyingRead, underlyingWrite)
	}
	_, _, err = wrapped.ReadFrom(make([]byte, 16))
	var networkError net.Error
	if !errors.As(err, &networkError) || !networkError.Timeout() {
		t.Fatalf("consumer read deadline error = %T %v", err, err)
	}
	combinedDeadline := time.Now().Add(time.Second)
	if err := wrapped.SetDeadline(combinedDeadline); err != nil {
		t.Fatal(err)
	}
	underlyingRead, underlyingWrite = underlying.deadlines()
	if !underlyingRead.IsZero() || !underlyingWrite.Equal(combinedDeadline) {
		t.Fatalf("combined deadline delegation = %v, %v", underlyingRead, underlyingWrite)
	}
}

func TestHostPacketConnControllerCloseUnblocksAndForgetsPump(t *testing.T) {
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"), Seed: 1_741,
	})
	if err != nil {
		t.Fatal(err)
	}
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	pump := wrapped.(*recoveryImpairmentPacketConn).readPump
	readResult := make(chan error, 1)
	go func() {
		_, _, err := wrapped.ReadFrom(make([]byte, 16))
		readResult <- err
	}()
	if err := controller.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readResult:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("consumer close error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("controller close did not unblock consumer")
	}
	select {
	case <-pump.done:
	default:
		t.Fatal("controller close returned before pump termination")
	}
	controller.mu.Lock()
	remaining := len(controller.readPumps)
	controller.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("controller retained %d closed read pumps", remaining)
	}
	if err := wrapped.Close(); err != nil {
		t.Fatalf("wrapper close after controller close = %v", err)
	}
}

func TestHostPacketConnTracesRawReadAndNACKDecision(t *testing.T) {
	trace := newIncrementingRecoveryTraceRecorder(32)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"),
		Seed:    1_741,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	nack := marshalMatrixNACK(t, 77)
	underlying.reads <- matrixPacketRead{payload: nack, source: matrixTestAddr("viewer")}
	buffer := make([]byte, 1_500)
	n, _, err := wrapped.ReadFrom(buffer)
	if err != nil || !reflect.DeepEqual(buffer[:n], nack) {
		t.Fatalf("read = %d, %v, %x; want NACK %x", n, err, buffer[:n], nack)
	}

	events := recoveryTraceEvents(trace)
	wantKinds := []recoveryTraceKind{
		tracePacketConnReadStarted,
		tracePacketConnReadReturned,
		traceNACKImpairmentDecisionCalled,
		traceNACKSocketAttempted,
		traceNACKImpairmentDecisionReturned,
		tracePacketConnReadStarted,
		traceNACKSocketDelivered,
	}
	if got := recoveryTraceKinds(trace); !reflect.DeepEqual(got, wantKinds) {
		t.Fatalf("read handoff kinds = %v, want %v", got, wantKinds)
	}
	readID := events[0].NumericValue
	if readID == nil || *readID <= 0 {
		t.Fatalf("read start lacks a positive ID: %#v", events[0])
	}
	wantFingerprint := recoveryWireFingerprint(nack)
	for _, index := range []int{1, 2, 4} {
		if events[index].NumericValue == nil || *events[index].NumericValue != *readID ||
			events[index].WireFingerprint == nil ||
			*events[index].WireFingerprint != wantFingerprint ||
			events[index].PacketSize == nil || *events[index].PacketSize != len(nack) {
			t.Fatalf("read-correlated event %d = %#v", index, events[index])
		}
	}
	for _, index := range []int{3, 6} {
		if events[index].WireFingerprint == nil ||
			*events[index].WireFingerprint != wantFingerprint ||
			events[index].PacketSize == nil || *events[index].PacketSize != len(nack) {
			t.Fatalf("impairment event %d = %#v", index, events[index])
		}
	}
}

func TestHostPacketConnTracesDecisionReturnForDroppedNACK(t *testing.T) {
	trace := newIncrementingRecoveryTraceRecorder(64)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "first-nack-loss"),
		Seed:    1_741,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	underlying := newMatrixPacketConn()
	wrapped := controller.wrapHostPacketConn(underlying)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	first := marshalMatrixNACK(t, 77)
	second := marshalMatrixNACK(t, 78)
	underlying.reads <- matrixPacketRead{payload: first, source: matrixTestAddr("viewer")}
	underlying.reads <- matrixPacketRead{payload: second, source: matrixTestAddr("viewer")}
	buffer := make([]byte, 1_500)
	if _, _, err := wrapped.ReadFrom(buffer); err != nil {
		t.Fatal(err)
	}

	firstFingerprint := recoveryWireFingerprint(first)
	events := recoveryTraceEvents(trace)
	var firstKinds []recoveryTraceKind
	for _, event := range events {
		if event.WireFingerprint != nil && *event.WireFingerprint == firstFingerprint {
			firstKinds = append(firstKinds, event.Kind)
		}
	}
	want := []recoveryTraceKind{
		tracePacketConnReadReturned,
		traceNACKImpairmentDecisionCalled,
		traceNACKSocketAttempted,
		traceNACKImpairmentDecisionReturned,
	}
	if !reflect.DeepEqual(firstKinds, want) {
		t.Fatalf("dropped NACK trace = %v, want %v; all events %#v", firstKinds, want, events)
	}
}

func TestProductionHostWriteAccountsSuccessfulSocketDelivery(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	trace := newIncrementingRecoveryTraceRecorder(16)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	connection := newMatrixPacketConn()
	connection.writes = make(chan []byte, 200)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	payload := marshalMatrixRTP(t, av1PayloadType, 1)
	if _, err := controller.SchedulePacketConnWrite(
		matrixHost, connection, payload, matrixTestAddr("viewer"),
	); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	snapshot := controller.Snapshot()
	if snapshot.Delivered[matrixPacketOriginal].Packets != 1 ||
		snapshot.EffectiveQueueDropped[matrixPacketOriginal].Packets != 0 {
		t.Fatalf("forward delivery accounting = %#v", snapshot)
	}
	events := recoveryTraceEvents(trace)
	if len(events) != 2 || events[0].Kind != traceOriginalQueueAdmitted ||
		events[1].Kind != traceOriginalSocketDelivered {
		t.Fatalf("successful queue trace = %#v", events)
	}
	for _, event := range events {
		if event.RTPSequence == nil || *event.RTPSequence != 1 ||
			event.RTPTimestamp == nil || *event.RTPTimestamp != 90_000 {
			t.Fatalf("successful queue identity = %#v", event)
		}
	}
}

func TestProductionBandwidthQueueDropsExcessAndDrains(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "bandwidth-0.9x-q1")
	trace := newIncrementingRecoveryTraceRecorder(512)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	connection := newMatrixPacketConn()
	connection.writes = make(chan []byte, 200)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	for sequence := uint16(1); sequence <= 100; sequence++ {
		payload := marshalMatrixRTP(t, av1PayloadType, sequence)
		payload = append(payload, make([]byte, 1_100)...)
		if _, err := controller.SchedulePacketConnWrite(
			matrixHost, connection, payload, matrixTestAddr("viewer"),
		); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.WaitForDrain(ctx); err != nil {
		t.Fatal(err)
	}
	controller.ReconcileQueueLossAfterDrain()
	snapshot := controller.Snapshot()
	if snapshot.EffectiveQueueDropped[matrixPacketOriginal].Packets == 0 ||
		snapshot.ScheduledBytesCurrent != 0 ||
		snapshot.OutstandingMediaBytesCurrent != 0 {
		t.Fatalf("bandwidth queue accounting = %#v", snapshot)
	}
	var admitted, rejected, delivered int
	for _, event := range recoveryTraceEvents(trace) {
		if event.RTPSequence == nil || event.RTPTimestamp == nil {
			t.Fatalf("queue event lacks RTP identity: %#v", event)
		}
		switch event.Kind {
		case traceOriginalQueueAdmitted:
			admitted++
		case traceOriginalQueueRejected:
			rejected++
		case traceOriginalSocketDelivered:
			delivered++
		default:
			t.Fatalf("unexpected bandwidth queue event: %#v", event)
		}
	}
	if admitted+rejected != 100 || rejected == 0 || delivered != admitted {
		t.Fatalf("queue events admitted/rejected/delivered = %d/%d/%d", admitted, rejected, delivered)
	}
}

func TestProductionFiniteBandwidthEpisodeStopsPacingNewPackets(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	profile.BandwidthPermille = 750
	profile.QueueFrames = 4
	profile.BandwidthDurationMilliseconds = 100
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}

	classification := recoveryDatagramClassification{
		Endpoint: matrixHost,
		Class:    matrixPacketOriginal,
		Bytes:    1_200,
	}
	arrival := time.Now()
	activeDeadline, admitted, reserveErr := controller.reserveScheduledDeadline(
		classification, false, arrival, 0,
	)
	if reserveErr != nil || !admitted || !activeDeadline.After(arrival) {
		t.Fatalf("active episode deadline = %v, admitted=%t, error=%v; want paced", activeDeadline, admitted, reserveErr)
	}
	controller.finishScheduled(classification, nil)

	controller.mu.Lock()
	controller.activatedAt = time.Now().Add(-200 * time.Millisecond)
	controller.mu.Unlock()
	arrival = time.Now()
	expiredDeadline, admitted, reserveErr := controller.reserveScheduledDeadline(
		classification, false, arrival, 7*time.Millisecond,
	)
	want := arrival.Add(7 * time.Millisecond)
	if reserveErr != nil || !admitted || !expiredDeadline.Equal(want) {
		t.Fatalf("expired episode deadline = %v, admitted=%t, error=%v; want %v", expiredDeadline, admitted, reserveErr, want)
	}
	controller.finishScheduled(classification, nil)
}

func TestProductionBandwidthQueuesAreDirectionalAndExcludePropagation(t *testing.T) {
	controller := newTestVirtualBandwidthController(t, 8_000, 2_000)
	epoch := time.Unix(7_000, 0)
	controller.activatedAt = epoch
	classification := recoveryDatagramClassification{
		Endpoint: matrixHost,
		Class:    matrixPacketOriginal,
		Bytes:    1_000,
	}
	deadline, admitted, err := controller.reserveScheduledDeadline(
		classification, false, epoch, 100*time.Millisecond,
	)
	if err != nil || !admitted || !deadline.Equal(epoch.Add(1_100*time.Millisecond)) {
		t.Fatalf("host deadline = %v, %t, %v", deadline, admitted, err)
	}
	controller.finishScheduled(classification, nil)

	classification.Endpoint = matrixViewer
	deadline, admitted, err = controller.reserveScheduledDeadline(
		classification, false, epoch, 250*time.Millisecond,
	)
	if err != nil || !admitted || !deadline.Equal(epoch.Add(1_250*time.Millisecond)) {
		t.Fatalf("viewer deadline = %v, %t, %v; queue directions are coupled", deadline, admitted, err)
	}
	controller.finishScheduled(classification, nil)

	classification.Endpoint = matrixHost
	deadline, admitted, err = controller.reserveScheduledDeadline(
		classification, false, epoch.Add(500*time.Millisecond), 10*time.Millisecond,
	)
	if err != nil || !admitted || !deadline.Equal(epoch.Add(2_010*time.Millisecond)) {
		t.Fatalf("second host deadline = %v, %t, %v; propagation entered queue state", deadline, admitted, err)
	}
	controller.finishScheduled(classification, nil)
}

func TestProductionBandwidthAdmissionDoesNotDependOnDeliveryProgress(t *testing.T) {
	controller := newTestVirtualBandwidthController(t, 8_000, 2_000)
	epoch := time.Unix(8_000, 0)
	controller.activatedAt = epoch
	classification := recoveryDatagramClassification{
		Endpoint: matrixHost,
		Class:    matrixPacketOriginal,
		Bytes:    1_000,
	}
	first, admitted, err := controller.reserveScheduledDeadline(classification, false, epoch, 0)
	if err != nil || !admitted || !first.Equal(epoch.Add(time.Second)) {
		t.Fatalf("first deadline = %v, %t, %v", first, admitted, err)
	}
	second, admitted, err := controller.reserveScheduledDeadline(
		classification, false, epoch.Add(500*time.Millisecond), 0,
	)
	if err != nil || !admitted || !second.Equal(epoch.Add(2*time.Second)) {
		t.Fatalf("second deadline with first undelivered = %v, %t, %v", second, admitted, err)
	}
	if controller.scheduledNow != 2_000 {
		t.Fatalf("lifecycle gauge = %d; want 2000 without influencing admission", controller.scheduledNow)
	}
	controller.finishScheduled(classification, nil)
	controller.finishScheduled(classification, nil)
}

func TestProductionBandwidthQueueModelAndResetLifecycle(t *testing.T) {
	controller := newTestVirtualBandwidthController(t, 8_000, 2_000)
	epoch := time.Unix(9_000, 0)
	controller.activatedAt = epoch
	classification := recoveryDatagramClassification{
		Endpoint: matrixHost,
		Class:    matrixPacketOriginal,
		Bytes:    1_000,
	}
	if _, admitted, err := controller.reserveScheduledDeadline(classification, false, epoch, 0); err != nil || !admitted {
		t.Fatalf("reserve before activation = %t, %v", admitted, err)
	}
	controller.finishScheduled(classification, nil)
	if controller.bandwidthQueues[matrixHost].queuedBits == 0 {
		t.Fatal("test did not prime host queue")
	}
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	if controller.bandwidthQueues[matrixHost].queuedBits != 0 ||
		!controller.bandwidthQueues[matrixHost].updatedAt.IsZero() {
		t.Fatalf("activation did not reset host queue: %#v", controller.bandwidthQueues[matrixHost])
	}
	if got := controller.Snapshot().BandwidthQueueModel; got != recoveryBandwidthQueueModelVirtualFluid {
		t.Fatalf("bandwidth queue model = %q", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.ResetMeasurement(ctx); err != nil {
		t.Fatal(err)
	}
	for endpoint, queue := range controller.bandwidthQueues {
		if queue.queuedBits != 0 || !queue.updatedAt.IsZero() {
			t.Fatalf("measurement reset left %s queue dirty: %#v", endpoint, queue)
		}
	}

	clean, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"),
		Seed:    1,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = clean.Close() })
	if got := clean.Snapshot().BandwidthQueueModel; got != "" {
		t.Fatalf("clean profile queue model = %q; want absent", got)
	}
}

func newTestVirtualBandwidthController(
	t *testing.T,
	rateBitsPerSecond int64,
	capacityBytes uint64,
) *RecoveryImpairmentController {
	t.Helper()
	controller := newRecoveryImpairmentController(mustRecoveryMatrixProfile(t, "clean"))
	t.Cleanup(func() { _ = controller.Close() })
	controller.bandwidthRateBitsPerSecond = rateBitsPerSecond
	controller.bandwidthQueueBytes = capacityBytes
	controller.bandwidthQueues = make(map[recoveryMatrixEndpoint]*recoveryBandwidthQueue, 2)
	for _, endpoint := range []recoveryMatrixEndpoint{matrixHost, matrixViewer} {
		queue, err := newRecoveryBandwidthQueue(rateBitsPerSecond, capacityBytes)
		if err != nil {
			t.Fatal(err)
		}
		controller.bandwidthQueues[endpoint] = &queue
	}
	return controller
}

func TestProductionRecoveryImpairmentRejectsInvalidConfiguration(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	profile.OneWayDelayMicroseconds = -1
	if _, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
	}); err == nil {
		t.Fatal("negative delay unexpectedly accepted")
	}
}

func TestProductionClassifierLearnsNegotiatedPayloadTypesDuringWarmup(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	original := marshalMatrixRTP(t, 35, 10)
	controller.observePassthrough(matrixHost, original)
	controller.SetFlexFECIdentity(37, 99)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	if got := controller.classifyDatagram(matrixHost, original); got.Class != matrixPacketOriginal ||
		got.RTPSequence == nil || *got.RTPSequence != 10 ||
		got.RTPTimestamp == nil || *got.RTPTimestamp != 90_000 {
		t.Fatalf("learned original classification identity = %#v", got)
	}
	rtx := marshalMatrixRTP(t, 36, 11)
	binary.BigEndian.PutUint32(rtx[8:12], 88)
	if got := controller.classifyDatagram(matrixHost, rtx); got.Class != matrixPacketRTX ||
		got.RTPSequence == nil || *got.RTPSequence != 11 ||
		got.RTPTimestamp == nil || *got.RTPTimestamp != 90_000 {
		t.Fatalf("learned RTX classification identity = %#v", got)
	}
	fec := marshalMatrixRTP(t, 37, 12)
	binary.BigEndian.PutUint32(fec[8:12], 99)
	if got := controller.classifyDatagram(matrixHost, fec); got.Class != matrixPacketFEC || got.RTPSequence == nil || *got.RTPSequence != 12 {
		t.Fatalf("learned FEC classification identity = %#v", got)
	}
}

func TestProductionClassifierDoesNotMisclassifyReceiverReportDuringRecovery(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "single-original-loss")
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    1,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	original := marshalMatrixRTP(t, 35, 10)
	controller.observePassthrough(matrixHost, original)
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	_ = controller.decide(controller.classifyDatagram(matrixHost, original))
	second := marshalMatrixRTP(t, 35, 11)
	if decision := controller.decide(controller.classifyDatagram(matrixHost, second)); decision.Action != matrixActionDrop {
		t.Fatalf("second original action = %q", decision.Action)
	}
	compoundSRTCP := []byte{0x81, 0xc9, 0x00, 0x07, 0, 0, 0, 1}
	classification := controller.classifyDatagram(matrixViewer, compoundSRTCP)
	if classification.Class != matrixPacketOtherRTCP {
		t.Fatalf("compound SRTCP classification = %#v", classification)
	}
	if classification.WireFingerprint != "" {
		t.Fatalf("compound SRTCP fingerprint = %q", classification.WireFingerprint)
	}
}

func TestProductionDirectionalRandomSeedsAreIndependent(t *testing.T) {
	host := deriveRecoveryMatrixSeed(1_741, matrixHost, matrixPacketOther, "jitter")
	viewer := deriveRecoveryMatrixSeed(1_741, matrixViewer, matrixPacketOther, "jitter")
	if host == viewer {
		t.Fatalf("directional seeds unexpectedly match: %d", host)
	}
}

func TestRecoverySchedulerStableEqualDeadlineOrder(t *testing.T) {
	deadline := time.Unix(1, 0)
	entries := recoveryScheduledHeap{
		&recoveryScheduledDatagram{deadline: deadline, enqueueOrdinal: 2},
		&recoveryScheduledDatagram{deadline: deadline, enqueueOrdinal: 1},
	}
	heap.Init(&entries)
	first := heap.Pop(&entries).(*recoveryScheduledDatagram)
	second := heap.Pop(&entries).(*recoveryScheduledDatagram)
	if first.enqueueOrdinal != 1 || second.enqueueOrdinal != 2 {
		t.Fatalf("equal-deadline order = %d, %d; want 1, 2",
			first.enqueueOrdinal, second.enqueueOrdinal)
	}
}

func TestRecoverySchedulerPublishesAfterAccounting(t *testing.T) {
	trace := newIncrementingRecoveryTraceRecorder(16)
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"),
		Seed:    1_741,
		Trace:   trace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	nack := marshalMatrixNACK(t, 77)
	classification := controller.classifyDatagram(matrixViewer, nack)
	decision := controller.decide(classification)
	classification.traceOrdinal = decision.ClassOrdinal
	deadline, admitted, reserveErr := controller.reserveScheduledDeadline(
		classification, false, time.Now(), 0,
	)
	if reserveErr != nil {
		t.Fatal(reserveErr)
	}
	if !admitted {
		t.Fatal("test NACK was not scheduled")
	}
	published := make(chan error, 1)
	entry := &recoveryScheduledDatagram{
		deadline: deadline, payload: append([]byte(nil), nack...),
		classification: classification,
		write:          func(payload []byte) (int, error) { return len(payload), nil },
		prepareDelivery: func() (func(), error) {
			return func() {
				snapshot := controller.Snapshot()
				if snapshot.Delivered[matrixPacketNACK].Packets != 1 ||
					snapshot.ScheduledBytesCurrent != 0 {
					published <- fmt.Errorf("publication accounting = %#v", snapshot)
					return
				}
				events := recoveryTraceEvents(trace)
				if len(events) == 0 || events[len(events)-1].Kind != traceNACKSocketDelivered {
					published <- fmt.Errorf("publication trace = %#v", events)
					return
				}
				published <- nil
			}, nil
		},
	}
	if err := controller.schedulers[matrixViewer].enqueue(entry); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-published:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for scheduled publication")
	}
}
