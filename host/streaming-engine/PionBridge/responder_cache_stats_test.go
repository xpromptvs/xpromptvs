package main

import "testing"

func TestResponderCacheCountersTrackCurrentAndPeak(t *testing.T) {
	counters := &ResponderCacheCounters{}
	counters.adjust(2, 2_400)
	counters.adjust(-1, -1_200)

	want := ResponderCacheSnapshot{
		PacketsCurrent: 1,
		PacketsPeak:    2,
		BytesCurrent:   1_200,
		BytesPeak:      2_400,
	}
	if got := counters.Snapshot(); got != want {
		t.Fatalf("snapshot = %#v, want %#v", got, want)
	}
}

func TestResponderCacheCountersRejectUnderflow(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("cache counter underflow did not panic")
		}
	}()
	(&ResponderCacheCounters{}).adjust(-1, -1)
}
