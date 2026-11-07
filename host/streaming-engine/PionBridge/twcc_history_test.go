package main

import (
	"testing"
	"time"

	"github.com/pion/rtcp"
)

type twccTestClock struct{ now time.Time }

func (clock *twccTestClock) Now() time.Time { return clock.now }

func mustTWCCPacketHistory(t *testing.T, config TWCCPacketHistoryConfig) *TWCCPacketHistory {
	t.Helper()
	history, err := NewTWCCPacketHistory(config)
	if err != nil {
		t.Fatal(err)
	}
	return history
}

func twccFeedback(base uint16, statuses []uint16, deltas ...int64) *rtcp.TransportLayerCC {
	receiveDeltas := make([]*rtcp.RecvDelta, 0, len(deltas))
	for _, delta := range deltas {
		receiveDeltas = append(receiveDeltas, &rtcp.RecvDelta{
			Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: delta,
		})
	}
	return &rtcp.TransportLayerCC{
		BaseSequenceNumber: base,
		PacketStatusCount:  uint16(len(statuses)),
		ReferenceTime:      10,
		PacketChunks: []rtcp.PacketStatusChunk{&rtcp.StatusVectorChunk{
			Type: rtcp.TypeTCCStatusVectorChunk, SymbolSize: rtcp.TypeTCCSymbolSizeTwoBit,
			SymbolList: statuses,
		}},
		RecvDeltas: receiveDeltas,
	}
}

func TestTWCCProvisionalLossCanBeReversed(t *testing.T) {
	clock := &twccTestClock{now: time.Unix(100, 0)}
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{
		Now: clock.Now, ReorderingGrace: 20 * time.Millisecond,
	})
	history.RecordSent(TWCCSentPacket{
		SSRC: 1, RTPSequence: 2, TransportSequence: 10,
		Class: TWCCMedia, Bytes: 100, Departure: clock.now.Add(-10 * time.Millisecond),
	})
	if err := history.ApplyFeedback(twccFeedback(10, []uint16{rtcp.TypeTCCPacketNotReceived})); err != nil {
		t.Fatal(err)
	}
	snapshot := history.Snapshot()
	if snapshot.ProvisionalPackets != 1 || snapshot.FinalizedLostPackets != 0 {
		t.Fatalf("first feedback snapshot = %+v", snapshot)
	}
	clock.now = clock.now.Add(5 * time.Millisecond)
	if err := history.ApplyFeedback(twccFeedback(10, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta}, 1_000)); err != nil {
		t.Fatal(err)
	}
	snapshot = history.Snapshot()
	if snapshot.ProvisionalPackets != 0 || snapshot.DeliveredPackets != 1 || snapshot.FinalizedLostPackets != 0 {
		t.Fatalf("reordered feedback snapshot = %+v", snapshot)
	}
}

func TestTWCCFinalizesOnlyAfterFrontierAndGrace(t *testing.T) {
	clock := &twccTestClock{now: time.Unix(200, 0)}
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{
		Now: clock.Now, ReorderingGrace: 20 * time.Millisecond,
	})
	for sequence := uint16(10); sequence <= 11; sequence++ {
		history.RecordSent(TWCCSentPacket{
			TransportSequence: sequence, Class: TWCCMedia, Bytes: 80,
			Departure: clock.now.Add(-10 * time.Millisecond),
		})
	}
	if err := history.ApplyFeedback(twccFeedback(10, []uint16{rtcp.TypeTCCPacketNotReceived})); err != nil {
		t.Fatal(err)
	}
	clock.now = clock.now.Add(25 * time.Millisecond)
	history.Finalize()
	if got := history.Snapshot().FinalizedLostPackets; got != 0 {
		t.Fatalf("loss finalized without a later frontier: %d", got)
	}
	if err := history.ApplyFeedback(twccFeedback(11, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta}, 1_000)); err != nil {
		t.Fatal(err)
	}
	history.Finalize()
	snapshot := history.Snapshot()
	if snapshot.FinalizedLostPackets != 1 || snapshot.ProvisionalPackets != 0 {
		t.Fatalf("finalized snapshot = %+v", snapshot)
	}
	if err := history.ApplyFeedback(twccFeedback(10, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta}, 1_000)); err != nil {
		t.Fatal(err)
	}
	if got := history.Snapshot().FinalizedLostPackets; got != 1 {
		t.Fatalf("late feedback reversed finalized loss: %d", got)
	}
}

func TestTWCCFeedbackIsIdempotentAndMalformedIsRejected(t *testing.T) {
	clock := &twccTestClock{now: time.Unix(300, 0)}
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{Now: clock.Now})
	history.RecordSent(TWCCSentPacket{TransportSequence: 7, Class: TWCCFEC, Bytes: 50, Departure: clock.now})
	feedback := twccFeedback(7, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta}, 1_000)
	if err := history.ApplyFeedback(feedback); err != nil {
		t.Fatal(err)
	}
	if err := history.ApplyFeedback(feedback); err != nil {
		t.Fatal(err)
	}
	snapshot := history.Snapshot()
	if snapshot.DeliveredPackets != 1 || snapshot.ByClass[TWCCFEC].DeliveredPackets != 1 {
		t.Fatalf("duplicate feedback snapshot = %+v", snapshot)
	}
	malformed := twccFeedback(7, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta})
	if err := history.ApplyFeedback(malformed); err == nil {
		t.Fatal("malformed feedback unexpectedly accepted")
	}
	if got := history.Snapshot().MalformedFeedbackPackets; got != 1 {
		t.Fatalf("malformed feedback count = %d", got)
	}
}

func TestTWCCFeedbackObserverRunsOnlyAfterValidFeedback(t *testing.T) {
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{})
	history.RecordSent(TWCCSentPacket{
		TransportSequence: 7, Class: TWCCMedia, Bytes: 50,
	})
	observations := 0
	history.SetFeedbackObserver(func() {
		observations++
		if snapshot := history.Snapshot(); snapshot.FeedbackPackets != 1 {
			t.Fatalf("observer ran before feedback publication: %#v", snapshot)
		}
	})
	if err := history.ApplyFeedback(twccFeedback(
		7, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta}, 1_000,
	)); err != nil {
		t.Fatal(err)
	}
	if observations != 1 {
		t.Fatalf("valid feedback observations = %d, want 1", observations)
	}
	if err := history.ApplyFeedback(twccFeedback(
		7, []uint16{rtcp.TypeTCCPacketReceivedSmallDelta},
	)); err == nil {
		t.Fatal("malformed feedback unexpectedly accepted")
	}
	if observations != 1 {
		t.Fatalf("malformed feedback observations = %d, want 1", observations)
	}
}

func TestTWCCWrapCapacityAndQueueTrend(t *testing.T) {
	clock := &twccTestClock{now: time.Unix(400, 0)}
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{
		Now: clock.Now, MaxPackets: 2, MaxAge: time.Second,
	})
	departures := []time.Time{clock.now, clock.now.Add(time.Millisecond), clock.now.Add(2 * time.Millisecond)}
	classes := []TWCCPacketClass{TWCCMedia, TWCCFEC, TWCCRTX}
	for index, sequence := range []uint16{65_535, 0, 1} {
		history.RecordSent(TWCCSentPacket{
			TransportSequence: sequence, Class: classes[index], Bytes: 10,
			Departure: departures[index],
		})
	}
	if got := history.Snapshot().EvictedPackets; got != 1 {
		t.Fatalf("evictions = %d, want 1", got)
	}
	feedback := twccFeedback(0, []uint16{
		rtcp.TypeTCCPacketReceivedSmallDelta,
		rtcp.TypeTCCPacketReceivedSmallDelta,
	}, 1_000, 3_000)
	if err := history.ApplyFeedback(feedback); err != nil {
		t.Fatal(err)
	}
	// Receiver spacing is 3 ms while sender spacing is 1 ms.
	if got := history.Snapshot().QueueTrend; got != 2*time.Millisecond {
		t.Fatalf("queue trend = %s, want 2ms", got)
	}
}

func TestTWCCResetAndClose(t *testing.T) {
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{})
	history.RecordSent(TWCCSentPacket{TransportSequence: 1, Class: TWCCMedia, Bytes: 1})
	history.Reset()
	if got := history.Snapshot().ByClass[TWCCMedia].SentPackets; got != 0 {
		t.Fatalf("sent after reset = %d", got)
	}
	if err := history.Close(); err != nil {
		t.Fatal(err)
	}
	history.RecordSent(TWCCSentPacket{TransportSequence: 2, Class: TWCCMedia, Bytes: 1})
	if got := history.Snapshot().ByClass[TWCCMedia].SentPackets; got != 0 {
		t.Fatalf("sent after close = %d", got)
	}
}
