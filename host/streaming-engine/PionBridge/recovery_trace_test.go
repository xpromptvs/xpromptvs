package main

import (
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

type recoveryTraceTestClock struct {
	mutex  sync.Mutex
	values []uint64
	index  int
}

func (clock *recoveryTraceTestClock) next() uint64 {
	clock.mutex.Lock()
	defer clock.mutex.Unlock()
	if clock.index >= len(clock.values) {
		panic("recovery trace test clock exhausted")
	}
	value := clock.values[clock.index]
	clock.index++
	return value
}

func TestRecoveryTraceRecorderDisabledDoesNothing(t *testing.T) {
	called := false
	recorder := newRecoveryTraceRecorder(false, 2, func() uint64 {
		called = true
		return 1
	})
	recorder.Record(recoveryTraceEvent{Layer: traceLayerPionResponder, Kind: traceNACKParsed})
	if called || recorder.Snapshot("pion-host") != nil {
		t.Fatal("disabled recorder performed diagnostic work")
	}
}

func TestRecoveryTraceReadIDsAreDisabledOrPositiveAndMonotonic(t *testing.T) {
	disabledTrace := newRecoveryTraceRecorder(false, 8, func() uint64 {
		t.Fatal("disabled read tracing sampled the clock")
		return 0
	})
	disabled, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"),
		Seed:    1_741,
		Trace:   disabledTrace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = disabled.Close() })
	if readID := disabled.beginPacketConnRead(); readID != 0 {
		t.Fatalf("disabled trace allocated read ID %d", readID)
	}

	enabledTrace := newIncrementingRecoveryTraceRecorder(8)
	enabled, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: mustRecoveryMatrixProfile(t, "clean"),
		Seed:    1_741,
		Trace:   enabledTrace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = enabled.Close() })
	if first, second := enabled.beginPacketConnRead(), enabled.beginPacketConnRead(); first != 1 || second != 2 {
		t.Fatalf("read IDs = %d, %d; want 1, 2", first, second)
	}
	events := recoveryTraceEvents(enabledTrace)
	if len(events) != 2 || events[0].Kind != tracePacketConnReadStarted ||
		events[1].Kind != tracePacketConnReadStarted ||
		events[0].NumericValue == nil || *events[0].NumericValue != 1 ||
		events[1].NumericValue == nil || *events[1].NumericValue != 2 {
		t.Fatalf("read start trace = %#v", events)
	}
}

func TestRecoveryTraceReadHandoffJSONRetainsNoPayload(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110, 120, 130, 140}}
	recorder := newRecoveryTraceRecorder(true, 4, clock.next)
	readID := int64(19)
	fingerprint := "0123456789abcdef"
	packetSize := 92
	for _, event := range []recoveryTraceEvent{
		{Layer: traceLayerImpairment, Kind: tracePacketConnReadStarted,
			NumericValue: &readID},
		{Layer: traceLayerImpairment, Kind: tracePacketConnReadReturned,
			NumericValue: &readID, WireFingerprint: &fingerprint, PacketSize: &packetSize},
		{Layer: traceLayerImpairment, Kind: traceNACKImpairmentDecisionCalled,
			NumericValue: &readID, WireFingerprint: &fingerprint, PacketSize: &packetSize},
		{Layer: traceLayerImpairment, Kind: traceNACKImpairmentDecisionReturned,
			NumericValue: &readID, WireFingerprint: &fingerprint, PacketSize: &packetSize},
	} {
		recorder.Record(event)
	}
	encoded, err := json.Marshal(recorder.Snapshot("pion-host"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "payload") {
		t.Fatalf("read handoff trace retained payload bytes: %s", encoded)
	}
	for _, kind := range []string{
		"packetConnReadStarted", "packetConnReadReturned",
		"nackImpairmentDecisionCalled", "nackImpairmentDecisionReturned",
	} {
		if !strings.Contains(string(encoded), `"kind":"`+kind+`"`) {
			t.Fatalf("read handoff trace omitted %s: %s", kind, encoded)
		}
	}
}

func TestRecoveryTraceRecorderIsBoundedAndOrdered(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110, 120, 130}}
	recorder := newRecoveryTraceRecorder(true, 2, clock.next)
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: traceNACKParsed,
		RTPSequence: uint16Pointer(77),
	})
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: traceKeyframeGateOpened,
	})
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerPionSender, Kind: traceKeyframeSubmitted,
	})

	snapshot := recorder.Snapshot("pion-host")
	if snapshot.Buffer.RetainedCount != 2 || snapshot.Buffer.DroppedCount != 1 || snapshot.Complete {
		t.Fatalf("invalid bounded snapshot: %#v", snapshot)
	}
	if snapshot.Events[0].Ordinal != 0 || snapshot.Events[1].Ordinal != 1 {
		t.Fatalf("invalid ordinals: %#v", snapshot.Events)
	}
	if snapshot.Events[0].MonotonicNanoseconds != 100 ||
		snapshot.Events[1].MonotonicNanoseconds != 110 {
		t.Fatalf("invalid timestamps: %#v", snapshot.Events)
	}
	if snapshot.CapturedNanoseconds != 130 {
		t.Fatalf("captured timestamp = %d; want 130", snapshot.CapturedNanoseconds)
	}
}

func TestRecoveryTraceRecorderResetStartsFreshEpoch(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110, 120, 130}}
	recorder := newRecoveryTraceRecorder(true, 1, clock.next)
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: traceOriginalDropped,
	})
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: traceNACKSocketAttempted,
	})
	recorder.Reset()
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: traceOriginalDropped,
	})

	snapshot := recorder.Snapshot("pion-host")
	if len(snapshot.Events) != 1 || snapshot.Events[0].Ordinal != 0 ||
		snapshot.Events[0].MonotonicNanoseconds != 120 ||
		snapshot.Buffer.DroppedCount != 0 || !snapshot.Complete {
		t.Fatalf("post-reset trace = %#v", snapshot)
	}
}

func TestRecoveryTraceRecorderResetPreservesInFlightReadStart(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110, 120, 130}}
	recorder := newRecoveryTraceRecorder(true, 4, clock.next)
	readID := int64(7)
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: tracePacketConnReadStarted,
		NumericValue: &readID,
	})
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: traceOriginalDropped,
	})

	recorder.Reset()
	fingerprint := "0123456789abcdef"
	packetSize := 130
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: tracePacketConnReadReturned,
		NumericValue: &readID, WireFingerprint: &fingerprint,
		PacketSize: &packetSize,
	})

	snapshot := recorder.Snapshot("pion-host")
	if len(snapshot.Events) != 2 ||
		snapshot.Events[0].Kind != tracePacketConnReadStarted ||
		snapshot.Events[0].Ordinal != 0 ||
		snapshot.Events[0].MonotonicNanoseconds != 100 ||
		snapshot.Events[1].Kind != tracePacketConnReadReturned ||
		snapshot.Events[1].Ordinal != 1 ||
		snapshot.Events[1].MonotonicNanoseconds != 120 ||
		snapshot.Buffer.DroppedCount != 0 || !snapshot.Complete {
		t.Fatalf("post-reset in-flight read trace = %#v", snapshot)
	}
}

func TestRecoveryTraceSnapshotUsesExactSchema(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110}}
	recorder := newRecoveryTraceRecorder(true, 1, clock.next)
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: traceNACKParsed,
		MediaSSRC: uint32Pointer(1_234), RTPSequence: uint16Pointer(77),
		RTPTimestamp: uint32Pointer(90_000),
		Retry:        uint32Pointer(2), Trigger: stringPointer("timer"),
		Reason: stringPointer("stale"), NumericValue: int64Pointer(-3),
		PacketID:        int64Pointer(41),
		WireFingerprint: stringPointer("0123456789abcdef"),
		PacketSize:      intPointer(92),
	})
	encoded, err := json.Marshal(recorder.Snapshot("pion-host"))
	if err != nil {
		t.Fatal(err)
	}
	want := `{"schemaVersion":3,"source":"pion-host","clockDomain":"macos-uptime-raw",` +
		`"capturedNanoseconds":110,"buffer":{"capacity":1,"retainedCount":1,"droppedCount":0},` +
		`"events":[{"ordinal":0,"monotonicNanoseconds":100,"layer":"pionResponder",` +
		`"kind":"nackParsed","mediaSSRC":1234,"rtpSequence":77,"rtpTimestamp":90000,"retry":2,` +
		`"trigger":"timer","reason":"stale","numericValue":-3,"packetID":41,` +
		`"wireFingerprint":"0123456789abcdef","packetSize":92}],"complete":true}`
	if string(encoded) != want {
		t.Fatalf("snapshot JSON:\n%s\nwant:\n%s", encoded, want)
	}
}

func TestRecoveryTracePacketSetFieldsRoundTrip(t *testing.T) {
	clock := &recoveryTraceTestClock{values: []uint64{100, 110}}
	recorder := newRecoveryTraceRecorder(true, 1, clock.next)
	recorder.Record(recoveryTraceEvent{
		Layer: traceLayerPionSender, Kind: traceKeyframePacketPacketized,
		RTPSequence: uint16Pointer(99), RTPTimestamp: uint32Pointer(90_000),
		FrameID: uint64Pointer(41), PayloadType: uint8Pointer(35),
		PacketIndex: uint16Pointer(1), PacketCount: uint16Pointer(3),
		Marker: boolPointer(false), Recovered: boolPointer(false),
		IsFirstPacketInFrame: boolPointer(true),
		IsLastPacketInFrame:  boolPointer(false),
	})

	encoded, err := json.Marshal(recorder.Snapshot("pion-host"))
	if err != nil {
		t.Fatal(err)
	}
	want := `{"schemaVersion":3,"source":"pion-host","clockDomain":"macos-uptime-raw",` +
		`"capturedNanoseconds":110,"buffer":{"capacity":1,"retainedCount":1,"droppedCount":0},` +
		`"events":[{"ordinal":0,"monotonicNanoseconds":100,"layer":"pionSender",` +
		`"kind":"keyframePacketPacketized","rtpSequence":99,"rtpTimestamp":90000,"frameID":41,` +
		`"payloadType":35,"packetIndex":1,"packetCount":3,"marker":false,"recovered":false,` +
		`"isFirstPacketInFrame":true,"isLastPacketInFrame":false}],"complete":true}`
	if string(encoded) != want {
		t.Fatalf("packet-set snapshot JSON:\n%s\nwant:\n%s", encoded, want)
	}

	var decoded recoveryTraceSnapshot
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	event := decoded.Events[0]
	if event.PayloadType == nil || *event.PayloadType != 35 ||
		event.PacketIndex == nil || *event.PacketIndex != 1 ||
		event.PacketCount == nil || *event.PacketCount != 3 ||
		event.Marker == nil || *event.Marker ||
		event.Recovered == nil || *event.Recovered ||
		event.IsFirstPacketInFrame == nil || !*event.IsFirstPacketInFrame ||
		event.IsLastPacketInFrame == nil || *event.IsLastPacketInFrame {
		t.Fatalf("packet-set event did not round trip: %#v", event)
	}

	var old recoveryTraceEvent
	if err := json.Unmarshal([]byte(`{"ordinal":0,"monotonicNanoseconds":1,"layer":"libwebrtc","kind":"rtpGapObserved"}`), &old); err != nil {
		t.Fatal(err)
	}
	if old.PayloadType != nil || old.PacketIndex != nil || old.PacketCount != nil ||
		old.Marker != nil || old.Recovered != nil || old.IsFirstPacketInFrame != nil ||
		old.IsLastPacketInFrame != nil {
		t.Fatalf("old schema-3 event gained packet fields: %#v", old)
	}
}

func TestRecoveryTraceSnapshotEncodesEmptyEventsAsArray(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(8)
	data, err := json.Marshal(recorder.Snapshot("pion-viewer"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"events":[]`) {
		t.Fatalf("empty recovery trace events are not an array: %s", data)
	}
}

func TestRecoveryTraceRecorderSerializesConcurrentProducers(t *testing.T) {
	const producerCount = 8
	const recordsPerProducer = 64
	clockValues := make([]uint64, producerCount*recordsPerProducer+1)
	for index := range clockValues {
		clockValues[index] = uint64(1_000 + index)
	}
	clock := &recoveryTraceTestClock{values: clockValues}
	recorder := newRecoveryTraceRecorder(true, producerCount*recordsPerProducer, clock.next)

	var wait sync.WaitGroup
	for producer := 0; producer < producerCount; producer++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for record := 0; record < recordsPerProducer; record++ {
				recorder.Record(recoveryTraceEvent{
					Layer: traceLayerPionSender, Kind: traceKeyframeFirstPacketEmitted,
				})
			}
		}()
	}
	wait.Wait()

	snapshot := recorder.Snapshot("pion-host")
	if len(snapshot.Events) != producerCount*recordsPerProducer || !snapshot.Complete {
		t.Fatalf("invalid concurrent snapshot: %#v", snapshot.Buffer)
	}
	for index, event := range snapshot.Events {
		if event.Ordinal != uint64(index) || event.MonotonicNanoseconds != uint64(1_000+index) {
			t.Fatalf("event %d = %#v", index, event)
		}
	}
}

func TestRecoveryTraceSessionStatsOmitDisabledAndEncodeEnabled(t *testing.T) {
	ordinary, err := json.Marshal(SessionStats{})
	if err != nil {
		t.Fatal(err)
	}
	if jsonContainsKey(ordinary, "recoveryTrace") {
		t.Fatalf("ordinary stats contain recoveryTrace: %s", ordinary)
	}

	clock := &recoveryTraceTestClock{values: []uint64{100}}
	recorder := newRecoveryTraceRecorder(true, 1, clock.next)
	diagnostic, err := json.Marshal(SessionStats{RecoveryTrace: recorder.Snapshot("pion-host")})
	if err != nil {
		t.Fatal(err)
	}
	if !jsonContainsKey(diagnostic, "recoveryTrace") {
		t.Fatalf("diagnostic stats omit recoveryTrace: %s", diagnostic)
	}
}

func jsonContainsKey(data []byte, key string) bool {
	var object map[string]json.RawMessage
	return json.Unmarshal(data, &object) == nil && object[key] != nil
}

func uint16Pointer(value uint16) *uint16 { return &value }
func uint8Pointer(value uint8) *uint8    { return &value }
func uint32Pointer(value uint32) *uint32 { return &value }
func uint64Pointer(value uint64) *uint64 { return &value }
func boolPointer(value bool) *bool       { return &value }
func int64Pointer(value int64) *int64    { return &value }
func intPointer(value int) *int          { return &value }
func stringPointer(value string) *string { return &value }

func newIncrementingRecoveryTraceRecorder(capacity int) *recoveryTraceRecorder {
	var tick atomic.Uint64
	tick.Store(99)
	return newRecoveryTraceRecorder(true, capacity, func() uint64 { return tick.Add(1) })
}

func recoveryTraceEvents(recorder *recoveryTraceRecorder) []recoveryTraceEvent {
	return recorder.Snapshot("test").Events
}

func recoveryTraceKinds(recorder *recoveryTraceRecorder) []recoveryTraceKind {
	events := recoveryTraceEvents(recorder)
	kinds := make([]recoveryTraceKind, len(events))
	for index, event := range events {
		kinds[index] = event.Kind
	}
	return kinds
}
