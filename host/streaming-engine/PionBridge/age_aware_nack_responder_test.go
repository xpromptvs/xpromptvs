package main

import (
	"bytes"
	"errors"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

func TestAgeAwareResponderSnapshotsRTTThresholdPerNACK(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(900, 0)}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(80 * time.Millisecond)
	policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeRTT, Floor: 30 * time.Millisecond,
		Cap: 500 * time.Millisecond, MultiplierMilli: 1_250,
	}, estimator)
	if err != nil {
		t.Fatal(err)
	}
	counters := &RecoveryCounters{}
	recorder := newIncrementingRecoveryTraceRecorder(32)
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		AgePolicy: policy, Now: clock.Now, Counters: counters, Trace: recorder,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)

	harness.writePrimary(t, 7, []byte{7}, nil)
	clock.Advance(75 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 7}},
	})
	select {
	case <-harness.written:
	case <-time.After(time.Second):
		t.Fatal("75ms packet was not repaired under a 100ms RTT threshold")
	}

	estimator.Observe(20 * time.Millisecond)
	harness.writePrimary(t, 8, []byte{8}, nil)
	clock.Advance(30 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 8}},
	})
	select {
	case <-harness.written:
	case <-time.After(time.Second):
		t.Fatal("packet at the exact 30ms threshold was not repaired")
	}

	harness.writePrimary(t, 9, []byte{9}, nil)
	clock.Advance(30*time.Millisecond + time.Nanosecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 9}},
	})
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 999}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("stale dynamic-age NACK requested %d keyframes, want 1", keyframes.Load())
	}

	recoverySnapshot := counters.Snapshot()
	snapshot := recoverySnapshot.RTXAgeDecisions
	if snapshot.FreshRequests != 2 || snapshot.StaleRequests != 1 ||
		snapshot.CacheMisses != 1 || snapshot.PacketAgeBuckets.LE30 != 1 ||
		snapshot.PacketAgeBuckets.LE75 != 2 ||
		snapshot.PacketAgeBuckets.LE500 != 0 {
		t.Fatalf("dynamic age decisions = %#v", snapshot)
	}
	if recoverySnapshot.ResponderCacheEvictions != 1 ||
		recoverySnapshot.ResponderCacheMisses != 1 {
		t.Fatalf("dynamic cache evidence = %#v", recoverySnapshot)
	}
	classified := make([]recoveryTraceEvent, 0, 3)
	for _, event := range recoveryTraceEvents(recorder) {
		if event.Kind == traceNACKClassifiedFresh || event.Kind == traceNACKClassifiedStale {
			classified = append(classified, event)
		}
	}
	if len(classified) != 3 {
		t.Fatalf("classified trace count = %d, want 3", len(classified))
	}
	wantAges := []int64{int64(75 * time.Millisecond), int64(30 * time.Millisecond), int64(30*time.Millisecond + time.Nanosecond)}
	wantThresholds := []int64{int64(100 * time.Millisecond), int64(30 * time.Millisecond), int64(30 * time.Millisecond)}
	for index, event := range classified {
		if event.PacketAgeNanoseconds == nil || *event.PacketAgeNanoseconds != wantAges[index] ||
			event.RTXAgeThresholdNanoseconds == nil ||
			*event.RTXAgeThresholdNanoseconds != wantThresholds[index] {
			t.Fatalf("classified trace %d = %#v", index, event)
		}
	}
}

func TestAgeAwareResponderEvictsBoundedPayloadButRetainsAgeLedger(t *testing.T) {
	for _, test := range []struct {
		name       string
		maxPackets int
		maxBytes   int
		payload    []byte
	}{
		{name: "packet bound", maxPackets: 2, maxBytes: 1 << 20, payload: []byte{1}},
		{name: "byte bound", maxPackets: 100, maxBytes: 2, payload: []byte{1, 2}},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := &responderFakeClock{now: time.Unix(1_000, 0)}
			counters := &RecoveryCounters{}
			keyframes := make(chan struct{}, 2)
			harness := newResponderHarness(t, AgeAwareResponderConfig{
				MaxAge: 30 * time.Millisecond, MaxPackets: test.maxPackets, MaxBytes: test.maxBytes,
				Now: clock.Now, Counters: counters,
				RequestKeyframe: func(uint32) { keyframes <- struct{}{} },
			}, nil)
			harness.writePrimary(t, 1, test.payload, nil)
			harness.writePrimary(t, 2, test.payload, nil)
			harness.writePrimary(t, 3, test.payload, nil)

			readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
				MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
			})
			select {
			case packet := <-harness.written:
				t.Fatalf("evicted original unexpectedly repaired: %#v", packet.header)
			case <-time.After(20 * time.Millisecond):
			}
			select {
			case <-keyframes:
			case <-time.After(time.Second):
				t.Fatal("young cache miss did not request keyframe")
			}
			snapshot := counters.Snapshot()
			if snapshot.ResponderCacheEvictions == 0 || snapshot.ResponderCacheMisses != 1 ||
				snapshot.StaleRTXRequestsSuppressed != 0 {
				t.Fatalf("young eviction snapshot = %#v", snapshot)
			}
		})
	}

	clock := &responderFakeClock{now: time.Unix(2_000, 0)}
	counters := &RecoveryCounters{}
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, MaxPackets: 1, MaxBytes: 1 << 20,
		Now: clock.Now, Counters: counters,
	}, nil)
	harness.writePrimary(t, 10, []byte{10}, nil)
	harness.writePrimary(t, 11, []byte{11}, nil)
	clock.Advance(30*time.Millisecond + time.Nanosecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 10}},
	})
	snapshot := counters.Snapshot()
	if snapshot.StaleRTXRequestsSuppressed != 1 || snapshot.ResponderCacheMisses != 0 {
		t.Fatalf("evicted stale packet lost its timestamp ledger: %#v", snapshot)
	}

	ageClock := &responderFakeClock{now: time.Unix(2_500, 0)}
	ageCounters := &RecoveryCounters{}
	ageHarness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, MaxPackets: 10, MaxBytes: 1 << 20,
		Now: ageClock.Now, Counters: ageCounters,
	}, nil)
	ageHarness.writePrimary(t, 20, []byte{20}, nil)
	ageClock.Advance(30*time.Millisecond + time.Nanosecond)
	ageHarness.writePrimary(t, 21, []byte{21}, nil)
	if got := ageCounters.Snapshot().ResponderCacheEvictions; got != 1 {
		t.Fatalf("aged payload evictions = %d, want 1", got)
	}
}

func TestAgeAwareResponderTraceStaleLossAndCoalescedPLI(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(4_000, 0)}
	recorder := newIncrementingRecoveryTraceRecorder(32)
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond,
		Now:    clock.Now, Trace: recorder,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 77, []byte{1}, nil)
	clock.Advance(31 * time.Millisecond)
	nack := &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 77}},
	}
	readNACK(t, harness.interceptor, nack)
	readNACK(t, harness.interceptor, nack)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})

	want := []recoveryTraceKind{
		traceNACKParsed, traceNACKClassifiedStale, traceKeyframeGateOpened,
		traceNACKParsed, traceNACKClassifiedStale, traceKeyframeGateCoalesced,
		tracePLIParsed, traceKeyframeGateCoalesced,
	}
	if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("stale recovery trace = %v, want %v", got, want)
	}
	if keyframes.Load() != 1 {
		t.Fatalf("coalesced requests invoked %d callbacks", keyframes.Load())
	}
	events := recoveryTraceEvents(recorder)
	if events[2].Reason == nil || *events[2].Reason != "generic-nack-stale" ||
		events[7].Reason == nil || *events[7].Reason != "pli" {
		t.Fatalf("gate reasons = %#v, %#v", events[2], events[7])
	}
}

func TestAgeAwareResponderTraceFreshRTXDoesNotOpenGate(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(16)
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Trace: recorder,
	}, nil)
	harness.writePrimary(t, 77, []byte{1}, nil)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 77}},
	})
	select {
	case <-harness.written:
	case <-time.After(time.Second):
		t.Fatal("fresh NACK did not emit RTX")
	}
	want := []recoveryTraceKind{
		traceNACKParsed, traceNACKClassifiedFresh, traceRTXEmitted,
	}
	if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("fresh recovery trace = %v, want %v", got, want)
	}
}

func TestAgeAwareResponderTraceCacheMissOpensOneGate(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(16)
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Trace: recorder,
	}, nil)
	harness.writePrimary(t, 77, []byte{1}, nil)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 78}},
	})
	want := []recoveryTraceKind{
		traceNACKParsed, traceNACKClassifiedCacheMiss, traceKeyframeGateOpened,
	}
	if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("cache-miss trace = %v, want %v", got, want)
	}
	event := recoveryTraceEvents(recorder)[2]
	if event.Reason == nil || *event.Reason != "generic-nack-cache-miss" {
		t.Fatalf("cache-miss gate = %#v", event)
	}
}

func TestAgeAwareResponderHandlesOriginalAndRTXSequenceWrap(t *testing.T) {
	harness := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond}, nil)
	harness.stream.mutex.Lock()
	harness.stream.sequencer = rtp.NewFixedSequencer(65_535)
	harness.stream.mutex.Unlock()
	harness.writePrimary(t, 65_535, []byte{0xaa}, nil)
	harness.writePrimary(t, 0, []byte{0xbb}, nil)

	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10,
		Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{65_535, 0}),
	})
	first := <-harness.written
	second := <-harness.written
	if first.header.SequenceNumber != 65_535 || second.header.SequenceNumber != 0 {
		t.Fatalf("RTX sequence wrap = %d, %d", first.header.SequenceNumber, second.header.SequenceNumber)
	}
	if !bytes.Equal(first.payload, []byte{0xff, 0xff, 0xaa}) ||
		!bytes.Equal(second.payload, []byte{0, 0, 0xbb}) {
		t.Fatalf("original sequence prefixes = %x, %x", first.payload, second.payload)
	}
}

func TestAgeAwareResponderObservesOnlyActualGenericNACKFeedback(t *testing.T) {
	var observations atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge:      30 * time.Millisecond,
		ObserveNACK: func() { observations.Add(1) },
	}, nil)
	harness.writePrimary(t, 1, []byte{1}, nil)

	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.ReceiverReport{},
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	if got := observations.Load(); got != 0 {
		t.Fatalf("non-NACK RTCP observations = %d, want 0", got)
	}

	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10,
		Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{1, 2, 3}),
	})
	if got := observations.Load(); got != 1 {
		t.Fatalf("generic NACK observations = %d, want 1", got)
	}

	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 99,
		Nacks:     []rtcp.NackPair{{PacketID: 1}},
	})
	if got := observations.Load(); got != 1 {
		t.Fatalf("unknown-stream NACK observations = %d, want 1", got)
	}
}

func TestAgeAwareResponderCoalescesKeyframesUntilOutgoingKeyframe(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_000, 0)}
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 1, []byte{1}, nil)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("coalesced keyframes = %d", keyframes.Load())
	}

	metadata, err := (FrameMetadata{
		Version: frameMetadataVersion, Keyframe: true, StreamID: 1, FrameID: 2,
		PacketCount: 1, OriginalAccessUnitBytes: 1,
	}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	keyframeHeader := &rtp.Header{
		Version: 2, PayloadType: 45, SequenceNumber: 2, Timestamp: 180_000, SSRC: 10,
	}
	if err := keyframeHeader.SetExtension(3, metadata); err != nil {
		t.Fatal(err)
	}
	harness.writePrimary(t, 2, []byte{2}, keyframeHeader)
	harness.factory.MarkKeyframeSent(10, 2)
	harness.writePrimary(t, 3, []byte{3}, nil)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 3}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("outgoing keyframe did not reset coalescing latch: %d", keyframes.Load())
	}
}

func TestAgeAwareResponderExplicitKeyframeBoundaryResetsLatchWithoutMetadataExtension(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_050, 0)}
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 1, []byte{1}, nil)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("initial stale loss requested %d keyframes", keyframes.Load())
	}

	harness.writePrimary(t, 2, []byte{2}, nil)
	harness.factory.MarkKeyframeSent(10, 2)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("pre-keyframe loss reopened the latch: %d", keyframes.Load())
	}

	harness.writePrimary(t, 3, []byte{3}, nil)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 3}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("post-keyframe stale loss requested %d keyframes, want 2", keyframes.Load())
	}
}

func TestAgeAwareResponderRetriesOnlyForLossAtOrAfterLatestKeyframe(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_100, 0)}
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 65_535, []byte{1}, nil)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 65_535}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("initial stale loss requested %d keyframes", keyframes.Load())
	}

	metadata, err := (FrameMetadata{
		Version: frameMetadataVersion, Keyframe: true, StreamID: 1, FrameID: 2,
		PacketCount: 1, OriginalAccessUnitBytes: 1,
	}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	keyframeHeader := &rtp.Header{
		Version: 2, PayloadType: 45, SequenceNumber: 0, Timestamp: 180_000,
		SSRC: 10, Marker: true,
	}
	if err := keyframeHeader.SetExtension(3, metadata); err != nil {
		t.Fatal(err)
	}
	harness.writePrimary(t, 0, []byte{2}, keyframeHeader)
	harness.factory.MarkKeyframeSent(10, 0)

	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 65_535}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("pre-keyframe stale loss requested another keyframe: %d", keyframes.Load())
	}

	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 0}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("lost recovery keyframe requests = %d, want 2", keyframes.Load())
	}
}

func TestAgeAwareResponderPLIRequestsOneCoalescedKeyframe(t *testing.T) {
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge:          30 * time.Millisecond,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	for range 2 {
		readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
			&rtcp.PictureLossIndication{MediaSSRC: 10},
		})
	}
	if keyframes.Load() != 1 {
		t.Fatalf("PLI keyframe requests = %d, want 1", keyframes.Load())
	}
}

func TestAgeAwareResponderCoalescesPLIWhileResponseOutstandingUsingMediaRTT(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_200, 0)}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(200 * time.Millisecond)
	counters := &RecoveryCounters{}
	recorder := newIncrementingRecoveryTraceRecorder(16)
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now,
		MediaRTT: estimator, Counters: counters, Trace: recorder,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)

	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	harness.writePrimary(t, 10, []byte{1}, nil)
	harness.factory.MarkKeyframeSent(10, 10)
	clock.Advance(399 * time.Millisecond)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("PLI inside media-RTT response wait requested %d keyframes", keyframes.Load())
	}
	if got := counters.Snapshot().PLIResponsesCoalesced; got != 1 {
		t.Fatalf("outstanding-response PLI coalescing count = %d, want 1", got)
	}
	events := recoveryTraceEvents(recorder)
	coalesced := events[len(events)-1]
	wantWait := int64(400 * time.Millisecond)
	if coalesced.Kind != traceKeyframeGateCoalesced ||
		coalesced.NumericValue == nil || *coalesced.NumericValue != wantWait {
		t.Fatalf("coalesced PLI trace = %#v, want wait %d", coalesced, wantWait)
	}

	clock.Advance(time.Millisecond)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("PLI at media-RTT response deadline requested %d keyframes, want 2", keyframes.Load())
	}
}

func TestAgeAwareResponderResponseWaitUsesRTXFloorAndNoRTTFallback(t *testing.T) {
	for _, test := range []struct {
		name     string
		rtt      time.Duration
		wantWait time.Duration
	}{
		{name: "healthy RTT uses RTX floor", rtt: time.Millisecond, wantWait: 30 * time.Millisecond},
		{name: "no RTT uses fallback", wantWait: 500 * time.Millisecond},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := &responderFakeClock{now: time.Unix(3_300, 0)}
			estimator := &mediaRTTEstimator{}
			if test.rtt > 0 {
				estimator.Observe(test.rtt)
			}
			var keyframes atomic.Uint64
			harness := newResponderHarness(t, AgeAwareResponderConfig{
				MaxAge: 30 * time.Millisecond, Now: clock.Now, MediaRTT: estimator,
				RequestKeyframe: func(uint32) { keyframes.Add(1) },
			}, nil)
			readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
				&rtcp.PictureLossIndication{MediaSSRC: 10},
			})
			harness.writePrimary(t, 20, []byte{1}, nil)
			harness.factory.MarkKeyframeSent(10, 20)
			clock.Advance(test.wantWait - time.Nanosecond)
			readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
				&rtcp.PictureLossIndication{MediaSSRC: 10},
			})
			if keyframes.Load() != 1 {
				t.Fatalf("PLI before %v wait requested %d keyframes", test.wantWait, keyframes.Load())
			}
			clock.Advance(time.Nanosecond)
			readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
				&rtcp.PictureLossIndication{MediaSSRC: 10},
			})
			if keyframes.Load() != 2 {
				t.Fatalf("PLI at %v wait requested %d keyframes, want 2", test.wantWait, keyframes.Load())
			}
		})
	}
}

func TestAgeAwareResponderNACKProvesOutstandingKeyframeDamageImmediately(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_400, 0)}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(400 * time.Millisecond)
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now, MediaRTT: estimator,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	harness.writePrimary(t, 30, []byte{1}, nil)
	harness.factory.MarkKeyframeSent(10, 30)
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 30}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("NACK-proven keyframe damage requested %d keyframes, want 2", keyframes.Load())
	}
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 30}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("duplicate NACK while replacement pending requested %d keyframes", keyframes.Load())
	}
}

func TestAgeAwareResponderUnprovenNACKDoesNotReplaceOutstandingKeyframe(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_500, 0)}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(200 * time.Millisecond)
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now, MediaRTT: estimator,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	harness.writePrimary(t, 40, []byte{1}, nil)
	harness.factory.MarkKeyframeSent(10, 40)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 999}},
	})
	if keyframes.Load() != 1 {
		t.Fatalf("unproven NACK inside response wait requested %d keyframes", keyframes.Load())
	}
	clock.Advance(400 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 999}},
	})
	if keyframes.Load() != 2 {
		t.Fatalf("unproven NACK after response wait requested %d keyframes, want 2", keyframes.Load())
	}
}

func TestAgeAwareResponderIgnoresRTXNACKAndPassesUnrelatedRTCP(t *testing.T) {
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge:          30 * time.Millisecond,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 1, []byte{1}, nil)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 20, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	if keyframes.Load() != 0 {
		t.Fatalf("RTX SSRC NACK requested %d keyframes", keyframes.Load())
	}
	select {
	case packet := <-harness.written:
		t.Fatalf("RTX SSRC NACK emitted packet %#v", packet.header)
	default:
	}

	report := &rtcp.ReceiverReport{SSRC: 77}
	returned := readRTCPPackets(t, harness.interceptor, []rtcp.Packet{report})
	if len(returned) != 1 {
		t.Fatalf("returned RTCP packets = %d", len(returned))
	}
	if got, ok := returned[0].(*rtcp.ReceiverReport); !ok || got.SSRC != 77 {
		t.Fatalf("unrelated RTCP changed: %#v", returned[0])
	}
}

func TestAgeAwareResponderReportsRepairWriterFailureOnce(t *testing.T) {
	writeFailure := errors.New("repair writer failed")
	var reports atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond,
		ReportError: func(err error) {
			if !errors.Is(err, writeFailure) {
				t.Errorf("reported error = %v", err)
			}
			reports.Add(1)
		},
	}, func(header *rtp.Header) error {
		if header.SSRC == 20 {
			return writeFailure
		}
		return nil
	})
	harness.writePrimary(t, 1, []byte{1}, nil)
	for range 2 {
		readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
			MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
		})
	}
	if reports.Load() != 1 {
		t.Fatalf("writer failure reports = %d", reports.Load())
	}
}

func TestAgeAwareResponderTreatsBudgetSuppressionAsNonfatalSkippedRTX(t *testing.T) {
	var reports atomic.Uint64
	counters := &RecoveryCounters{}
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Counters: counters,
		ReportError: func(error) { reports.Add(1) },
	}, func(header *rtp.Header) error {
		if header.SSRC == 20 {
			return errRecoveryFrameClockSuppressed
		}
		return nil
	})
	harness.writePrimary(t, 1, []byte{1}, nil)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	if reports.Load() != 0 {
		t.Fatalf("suppression reported %d fatal errors", reports.Load())
	}
	if snapshot := counters.Snapshot(); snapshot.RTXPacketsSent != 0 {
		t.Fatalf("suppressed RTX counted as sent: %#v", snapshot)
	}
}

func TestAgeAwareResponderUnbindAndCloseReleasePayloadAndSuppressWork(t *testing.T) {
	var keyframes atomic.Uint64
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge:          30 * time.Millisecond,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	harness.writePrimary(t, 1, []byte{1}, nil)
	harness.interceptor.UnbindLocalStream(&harness.stream.info)
	harness.stream.mutex.Lock()
	retainedAfterUnbind := len(harness.stream.packets)
	harness.stream.mutex.Unlock()
	if retainedAfterUnbind != 0 {
		t.Fatalf("retained packets after unbind = %d", retainedAfterUnbind)
	}
	if err := harness.interceptor.Close(); err != nil {
		t.Fatal(err)
	}
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 1}},
	})
	if keyframes.Load() != 0 {
		t.Fatalf("closed responder invoked %d callbacks", keyframes.Load())
	}
	select {
	case packet := <-harness.written:
		t.Fatalf("closed responder emitted packet %#v", packet.header)
	default:
	}
}

func TestAgeAwareResponderCacheStatsDrainOnUnbindAndClose(t *testing.T) {
	for _, test := range []struct {
		name    string
		release func(*responderHarness)
	}{
		{
			name: "unbind",
			release: func(harness *responderHarness) {
				harness.interceptor.UnbindLocalStream(&harness.stream.info)
			},
		},
		{
			name: "close",
			release: func(harness *responderHarness) {
				if err := harness.interceptor.Close(); err != nil {
					t.Fatalf("close responder: %v", err)
				}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			cache := &ResponderCacheCounters{}
			harness := newResponderHarness(t, AgeAwareResponderConfig{
				MaxAge: 30 * time.Millisecond, MaxPackets: 2,
				CacheCounters: cache,
			}, nil)
			harness.writePrimary(t, 1, []byte{1}, nil)
			harness.writePrimary(t, 2, []byte{2}, nil)
			before := cache.Snapshot()
			if before.PacketsCurrent != 2 || before.PacketsPeak != 2 ||
				before.BytesCurrent == 0 || before.BytesPeak != before.BytesCurrent {
				t.Fatalf("cache before release = %#v", before)
			}

			test.release(harness)
			after := cache.Snapshot()
			if after.PacketsCurrent != 0 || after.BytesCurrent != 0 ||
				after.PacketsPeak != before.PacketsPeak || after.BytesPeak != before.BytesPeak {
				t.Fatalf("cache after release = %#v, before %#v", after, before)
			}
		})
	}
}

func TestAgeAwareResponderUsesInclusiveRTXAgeBoundary(t *testing.T) {
	for _, test := range []struct {
		name         string
		age          time.Duration
		wantRTX      bool
		wantKeyframe bool
	}{
		{name: "one nanosecond inside", age: 29_999_999 * time.Nanosecond, wantRTX: true},
		{name: "exactly at boundary", age: 30 * time.Millisecond, wantRTX: true},
		{name: "one nanosecond stale", age: 30*time.Millisecond + time.Nanosecond, wantKeyframe: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := &responderFakeClock{now: time.Unix(1_000, 0)}
			keyframes := make(chan struct{}, 2)
			factory, err := NewAgeAwareNACKResponder(AgeAwareResponderConfig{
				MaxAge: 30 * time.Millisecond,
				Now:    clock.Now,
				RequestKeyframe: func(uint32) {
					keyframes <- struct{}{}
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			responder, err := factory.NewInterceptor("age-boundary")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if err := responder.Close(); err != nil {
					t.Errorf("close responder: %v", err)
				}
			})

			written := make(chan responderWrittenPacket, 4)
			writer := responder.BindLocalStream(
				&interceptor.StreamInfo{
					SSRC:                      10,
					SSRCRetransmission:        20,
					PayloadType:               45,
					PayloadTypeRetransmission: 46,
					RTCPFeedback:              []interceptor.RTCPFeedback{{Type: "nack"}},
				},
				interceptor.RTPWriterFunc(func(
					header *rtp.Header,
					payload []byte,
					_ interceptor.Attributes,
				) (int, error) {
					written <- responderWrittenPacket{
						header:  header.Clone(),
						payload: append([]byte(nil), payload...),
					}
					return len(payload), nil
				}),
			)
			originalPayload := []byte{0x11, 0x22, 0x33}
			if _, err := writer.Write(&rtp.Header{
				Version: 2, PayloadType: 45, SequenceNumber: 65_535,
				Timestamp: 90_000, SSRC: 10,
			}, originalPayload, nil); err != nil {
				t.Fatal(err)
			}
			<-written // The primary packet always passes through unchanged.

			clock.Advance(test.age)
			readNACK(t, responder, &rtcp.TransportLayerNack{
				SenderSSRC: 99,
				MediaSSRC:  10,
				Nacks:      []rtcp.NackPair{{PacketID: 65_535}},
			})

			if test.wantRTX {
				select {
				case repair := <-written:
					if repair.header.SSRC != 20 || repair.header.PayloadType != 46 {
						t.Fatalf("repair header = %#v", repair.header)
					}
					if repair.header.SequenceNumber == 65_535 {
						t.Fatalf("repair reused original sequence %d", repair.header.SequenceNumber)
					}
					wantPayload := append([]byte{0xff, 0xff}, originalPayload...)
					if !bytes.Equal(repair.payload, wantPayload) {
						t.Fatalf("repair payload = %x, want %x", repair.payload, wantPayload)
					}
				case <-time.After(time.Second):
					t.Fatal("timely NACK produced no RTX packet")
				}
				select {
				case <-keyframes:
					t.Fatal("timely NACK requested a keyframe")
				default:
				}
				return
			}

			select {
			case repair := <-written:
				t.Fatalf("stale NACK produced RTX packet %#v", repair.header)
			case <-time.After(20 * time.Millisecond):
			}
			select {
			case <-keyframes:
			case <-time.After(time.Second):
				t.Fatal("stale NACK did not request a keyframe")
			}
		})
	}
}

type responderFakeClock struct {
	mutex sync.Mutex
	now   time.Time
}

func (clock *responderFakeClock) Now() time.Time {
	clock.mutex.Lock()
	defer clock.mutex.Unlock()
	return clock.now
}

func (clock *responderFakeClock) Advance(duration time.Duration) {
	clock.mutex.Lock()
	clock.now = clock.now.Add(duration)
	clock.mutex.Unlock()
}

type responderWrittenPacket struct {
	header  rtp.Header
	payload []byte
}

type responderHarness struct {
	factory     *ageAwareNACKResponderFactory
	interceptor interceptor.Interceptor
	writer      interceptor.RTPWriter
	written     chan responderWrittenPacket
	stream      *ageAwareLocalStream
}

func newResponderHarness(
	t *testing.T,
	config AgeAwareResponderConfig,
	writeError func(*rtp.Header) error,
) *responderHarness {
	t.Helper()
	factory, err := NewAgeAwareNACKResponder(config)
	if err != nil {
		t.Fatal(err)
	}
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	written := make(chan responderWrittenPacket, 32)
	info := &interceptor.StreamInfo{
		SSRC:                      10,
		SSRCRetransmission:        20,
		PayloadType:               45,
		PayloadTypeRetransmission: 46,
		RTCPFeedback:              []interceptor.RTCPFeedback{{Type: "nack"}},
		RTPHeaderExtensions: []interceptor.RTPHeaderExtension{
			{URI: frameMetadataURI, ID: 3},
		},
	}
	writer := bound.BindLocalStream(info, interceptor.RTPWriterFunc(func(
		header *rtp.Header,
		payload []byte,
		_ interceptor.Attributes,
	) (int, error) {
		if writeError != nil {
			if err := writeError(header); err != nil {
				return 0, err
			}
		}
		written <- responderWrittenPacket{
			header: header.Clone(), payload: append([]byte(nil), payload...),
		}
		return len(payload), nil
	}))
	concrete, ok := bound.(*ageAwareNACKResponder)
	if !ok {
		t.Fatalf("responder type = %T", bound)
	}
	concrete.mutex.Lock()
	stream := concrete.streams[10]
	concrete.mutex.Unlock()
	if stream == nil {
		t.Fatal("primary stream did not bind")
	}
	t.Cleanup(func() {
		if err := bound.Close(); err != nil {
			t.Errorf("close responder: %v", err)
		}
	})
	return &responderHarness{
		factory: factory, interceptor: bound, writer: writer, written: written, stream: stream,
	}
}

func TestAgeAwareResponderFactoryDrainClearsBoundCaches(t *testing.T) {
	cache := &ResponderCacheCounters{}
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, CacheCounters: cache,
	}, nil)
	harness.writePrimary(t, 1, []byte{1, 2, 3}, nil)
	before := cache.Snapshot()
	if before.PacketsCurrent != 1 || before.BytesCurrent == 0 {
		t.Fatalf("cache before drain = %#v", before)
	}
	harness.factory.DrainCache()
	after := cache.Snapshot()
	if after.PacketsCurrent != 0 || after.BytesCurrent != 0 ||
		after.PacketsPeak != before.PacketsPeak || after.BytesPeak != before.BytesPeak {
		t.Fatalf("cache after drain = %#v, before %#v", after, before)
	}
}

func TestRecoveryDrainWithoutImpairmentClearsResponderCache(t *testing.T) {
	cache := &ResponderCacheCounters{}
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, CacheCounters: cache,
	}, nil)
	harness.writePrimary(t, 1, []byte{1, 2, 3}, nil)
	resources := &peerAPIResources{
		responderCache: cache, responderFactory: harness.factory,
	}

	if err := resources.DrainImpairment(time.Second); err != nil {
		t.Fatalf("drain recovery state without impairment: %v", err)
	}
	if snapshot := cache.Snapshot(); snapshot.PacketsCurrent != 0 ||
		snapshot.BytesCurrent != 0 {
		t.Fatalf("cache after recovery drain = %#v", snapshot)
	}
}

func (harness *responderHarness) writePrimary(
	t *testing.T,
	sequence uint16,
	payload []byte,
	header *rtp.Header,
) {
	t.Helper()
	if header == nil {
		header = &rtp.Header{
			Version: 2, PayloadType: 45, SequenceNumber: sequence,
			Timestamp: uint32(sequence) * 3_000, SSRC: 10,
		}
	}
	if _, err := harness.writer.Write(header, payload, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case primary := <-harness.written:
		if primary.header.SSRC != 10 || primary.header.SequenceNumber != sequence {
			t.Fatalf("primary pass-through = %#v", primary.header)
		}
	case <-time.After(time.Second):
		t.Fatal("primary packet did not pass through")
	}
}

func readNACK(t *testing.T, responder interceptor.Interceptor, nack *rtcp.TransportLayerNack) {
	t.Helper()
	readRTCPPackets(t, responder, []rtcp.Packet{nack})
}

func readRTCPPackets(
	t *testing.T,
	responder interceptor.Interceptor,
	packets []rtcp.Packet,
) []rtcp.Packet {
	t.Helper()
	raw, err := rtcp.Marshal(packets)
	if err != nil {
		t.Fatal(err)
	}
	reader := responder.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		copy(buffer, raw)
		return len(raw), attributes, nil
	}))
	buffer := make([]byte, len(raw))
	count, attributes, err := reader.Read(buffer, nil)
	if err != nil {
		t.Fatal(err)
	}
	if attributes == nil {
		t.Fatal("RTCP reader returned nil attributes")
	}
	returned, err := attributes.GetRTCPPackets(buffer[:count])
	if err != nil {
		t.Fatal(err)
	}
	return returned
}
