package main

import "testing"

// THE BOUND THAT KEEPS THE CHANNEL ALIVE.
//
// SCTP queues and will not let us withdraw what we have handed it — verified in pion/sctp, where the
// only abandonment check runs at transmission and never for a chunk still pending, and where
// maxPacketLifeTime's clock is likewise started at first transmission. So a frame handed over during a
// stall WILL be sent, however stale, and the queue grows without bound: measured 39kB -> 1.1MB inside
// one five-second window, ending in "PeerConnection disconnected".
//
// These tests drive the state machine directly rather than a real DataChannel, because the property is
// the DECISION — refuse while deep, resume when drained — and that is what has to hold.

/// THE REAL DECISION, not a copy of it. An earlier version of this file asserted against its own
/// reimplementation of the state machine, and mutating the production branch away left every test
/// green — proving only that the test agreed with itself.
func admit(delivery *dcDelivery, depth uint64) bool {
	return delivery.admitFrame(depth, 4)
}

func TestAdmitsWhileTheQueueIsShallow(t *testing.T) {
	delivery := &dcDelivery{}
	for _, depth := range []uint64{0, 1024, 40 * 1024, dcSendHighWaterBytes - 1} {
		if !admit(delivery, depth) {
			t.Fatalf("refused at %d bytes, which is inside normal operation — a healthy relayed "+
				"session's high-water sat at 29-40kB", depth)
		}
	}
}

func TestRefusesOnceTheQueueIsDeep(t *testing.T) {
	delivery := &dcDelivery{}
	if admit(delivery, dcSendHighWaterBytes) {
		t.Fatal("accepted a frame at the high-water mark: the queue is what kills the connection")
	}
}

// HYSTERESIS. A single threshold at the drain rate oscillates — one frame in, one refused, forever —
// and the queue never actually clears. Shedding continues until the queue is genuinely low.
func TestKeepsSheddingUntilTheQueueIsGenuinelyClear(t *testing.T) {
	delivery := &dcDelivery{}
	admit(delivery, dcSendHighWaterBytes) // enter shedding
	if admit(delivery, dcSendHighWaterBytes-1) {
		t.Fatal("resumed one byte below the high-water mark — that is the oscillation the low-water "+
			"mark exists to prevent")
	}
	if admit(delivery, dcSendLowWaterBytes+1) {
		t.Fatal("resumed just above the low-water mark")
	}
}

func TestResumesOnceDrained(t *testing.T) {
	delivery := &dcDelivery{}
	admit(delivery, dcSendHighWaterBytes)
	if !admit(delivery, dcSendLowWaterBytes) {
		t.Fatal("did not resume at the low-water mark: shedding must end, or one stall silences the "+
			"source for good")
	}
	if delivery.shedding.Load() {
		t.Fatal("still in the shedding state after resuming")
	}
}

// THE MARKS MUST BE ORDERED AND BOTH BELOW FATAL. Measured: normal operation 29-40kB, fatal 1.1MB.
func TestWaterMarksSitBetweenNormalAndFatal(t *testing.T) {
	if dcSendLowWaterBytes >= dcSendHighWaterBytes {
		t.Fatal("the low-water mark must be below the high-water mark, or there is no hysteresis")
	}
	if dcSendHighWaterBytes <= 40*1024 {
		t.Fatal("the high-water mark is inside normal operation and would shed a healthy session")
	}
	if dcSendHighWaterBytes >= 1024*1024 {
		t.Fatal("the high-water mark is at the depth that already killed a connection")
	}
}
