package main

import "testing"

// A SOURCE INDEX MUST NOT BE REUSED WHILE THE OLD SOURCE'S SYMBOLS MAY STILL BE IN FLIGHT. Reusing
// it would let a late symbol from the retired source decode into the new one — the multiplexed form
// of the SSRC-reuse hazard. Release therefore RETIRES the index rather than freeing it.
func TestReleasedSourceIndexIsNotReused(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	delivery.setDelivery(0, true, "win:test")
	first := delivery.streams[0].sourceIndex
	delivery.release(0)
	delivery.setDelivery(0, true, "win:test")
	second := delivery.streams[0].sourceIndex
	if first == second {
		t.Fatalf("source index %d was reused after release", first)
	}
}

// Delivery defaults to RTP, and setting it back to RTP must not leave a stream behind: a stale
// stream would keep an encoder window alive for a source nobody is delivering over the channel.
func TestDeliveryDefaultsToRTPAndClearsOnRevert(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	if delivery.deliversOverDC(0) {
		t.Fatal("delivery defaulted to the DataChannel, want RTP")
	}
	delivery.setDelivery(0, true, "win:test")
	if !delivery.deliversOverDC(0) {
		t.Fatal("setDelivery(true) did not take")
	}
	delivery.setDelivery(0, false, "")
	if delivery.deliversOverDC(0) || delivery.streams[0] != nil {
		t.Fatal("reverting to RTP left a stream behind")
	}
}

// bumpAll marks a discontinuity on every live source at once — what a peer rebuild needs.
func TestBumpAllAdvancesEveryGeneration(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	delivery.setDelivery(0, true, "win:test")
	delivery.setDelivery(1, true, "win:other")
	delivery.bumpAll()
	for slot, stream := range delivery.streams {
		if stream != nil && stream.generation != 1 {
			t.Fatalf("slot %d generation = %d, want 1", slot, stream.generation)
		}
	}
}

// The routing decision is the ONE place RTP and DataChannel delivery diverge. write() returning
// false is what tells the caller to packetise as RTP, so a slot that was never routed must return
// false and a routed one must return true even when the channel is not open — otherwise a transient
// channel state would silently duplicate the frame onto BOTH paths.
func TestWriteReportsRoutingRatherThanChannelHealth(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	if delivery.write(0, []byte{1, 2, 3}, 0, false, 45) {
		t.Fatal("an unrouted slot claimed the DataChannel")
	}
	delivery.setDelivery(0, true, "win:test")
	if !delivery.write(0, []byte{1, 2, 3}, 0, false, 45) {
		t.Fatal("a routed slot fell back to RTP because the channel was nil")
	}
	if delivery.notOpen.Load() == 0 {
		t.Fatal("a send with no open channel was not counted")
	}
}

// Hidden means STOP EMITTING, not stop routing. Repair for a source nobody is watching is pure
// waste, and the routing must survive so the tab coming back does not renegotiate.
func TestHiddenStopsSymbolsWithoutUnrouting(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	delivery.setDelivery(0, true, "win:test")
	delivery.setHidden(true)
	before := delivery.sourceSym.Load()
	if !delivery.write(0, []byte{1, 2, 3}, 0, false, 45) {
		t.Fatal("hidden unrouted the slot; it must still claim the DataChannel")
	}
	if delivery.sourceSym.Load() != before {
		t.Fatal("hidden still emitted symbols")
	}
	delivery.setHidden(false)
	delivery.write(0, []byte{1, 2, 3}, 0, false, 45)
	if delivery.sourceSym.Load() == before {
		t.Fatal("visible did not resume")
	}
}

// A HIDDEN SOURCE MUST NOT ADVANCE THE ESI SPACE EITHER. If it did, the client would come back to a
// gap it can never fill and would sit waiting for symbols that were never sent — indistinguishable
// from heavy loss, and permanent.
func TestHiddenDoesNotAdvanceTheSymbolSpace(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	delivery.setDelivery(0, true, "win:test")
	delivery.write(0, make([]byte, 100), 0, false, 45)
	delivery.setHidden(true)
	delivery.write(0, make([]byte, 100), 0, false, 45)
	delivery.setHidden(false)
	delivery.write(0, make([]byte, 100), 0, false, 45)
	if got := delivery.streams[0].nextESI; got != 2 {
		t.Fatalf("nextESI = %d after one hidden frame, want 2", got)
	}
}

// sourceIndexFor is what the caller reports as `dcIndex`. It must answer -1 rather than 0 for an
// unrouted slot: 0 is a VALID index, so returning it would bind a client's symbols to a source that
// is not being delivered over the channel at all.
func TestSourceIndexForDistinguishesUnroutedFromIndexZero(t *testing.T) {
	delivery := newDCDelivery(nil, nil)
	if got := delivery.sourceIndexFor(0); got != -1 {
		t.Fatalf("unrouted slot reported index %d, want -1", got)
	}
	delivery.setDelivery(0, true, "win:test")
	if got := delivery.sourceIndexFor(0); got != 0 {
		t.Fatalf("first routed slot reported index %d, want 0", got)
	}
}
