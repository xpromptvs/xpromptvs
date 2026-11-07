package main

import (
	"sync"
	"testing"
	"time"
)

func TestFlexFECStatsAreConcurrentBoundedCopies(t *testing.T) {
	clock := &twccTestClock{now: time.Unix(500, 0)}
	counters := NewFlexFECCounters(clock.Now)
	tiers := NewFlexFECTierStore(FlexFECTierOff, counters)
	tiers.Set(FlexFECTierLow)

	var workers sync.WaitGroup
	for index := 0; index < 100; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			counters.recordSelectedFrame(2)
			counters.recordGroup(109, 3, 300)
		}()
	}
	workers.Wait()
	clock.now = clock.now.Add(25 * time.Millisecond)
	snapshot := counters.Snapshot(tiers.Load())
	if snapshot.CurrentTier != FlexFECTierLow || snapshot.TimeInCurrentTier != 25*time.Millisecond {
		t.Fatalf("tier snapshot = %+v", snapshot)
	}
	if snapshot.SelectedFramesByTemporalID[2] != 100 || snapshot.ProtectedMediaPackets != 10_900 ||
		snapshot.FECPackets != 300 || snapshot.FECBytes != 30_000 || snapshot.GroupSizeHistogram[109] != 100 {
		t.Fatalf("counter snapshot = %+v", snapshot)
	}
	snapshot.SelectedFramesByTemporalID[2] = 0
	if counters.Snapshot(tiers.Load()).SelectedFramesByTemporalID[2] != 100 {
		t.Fatal("snapshot exposed mutable selected-frame map")
	}
}

func TestFlexFECStatsRetainFirstDisableReason(t *testing.T) {
	counters := NewFlexFECCounters(nil)
	counters.recordFailure(assertionError("first"))
	counters.recordFailure(assertionError("second"))
	snapshot := counters.Snapshot(FlexFECTierOff)
	if snapshot.Failures != 2 || snapshot.DisableReason != "first" {
		t.Fatalf("failure snapshot = %+v", snapshot)
	}
}

type assertionError string

func (value assertionError) Error() string { return string(value) }
