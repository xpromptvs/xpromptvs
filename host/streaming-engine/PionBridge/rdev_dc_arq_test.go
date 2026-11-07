package main

import (
	"encoding/binary"
	"testing"
)

// A RETRANSMISSION IS THE SAME PACKET AGAIN, which is what lets ARQ need no new wire format at all:
// the receiver's decoder cannot tell a resent symbol from a first delivery, and does not need to.
func TestHistoryResendsTheOriginalPacket(t *testing.T) {
	stream := newDCVideoStream(3, 16, 1, 2)
	first := stream.packetsFor(make([]byte, 2400), 0, false, 45, 1)
	original := first[0]
	esi := binary.LittleEndian.Uint32(original[8:])

	found, missing := stream.resend([]uint32{esi})
	if missing != 0 || len(found) != 1 {
		t.Fatalf("resend gave %d packets and %d missing, want 1 and 0", len(found), missing)
	}
	if string(found[0]) != string(original) {
		t.Fatal("the resent packet is not byte-identical to the original")
	}
}

// ONLY SOURCE SYMBOLS ARE KEPT. A repair symbol is a combination over a window that has since moved
// on, so resending one is worth nothing to a decoder that has already pruned its terms — and keeping
// them would spend the history on exactly the symbols least able to help.
func TestHistoryKeepsNoRepairSymbols(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(1.0)
	packets := stream.packetsFor(make([]byte, 1200), 0, false, 45, 1)
	if packets[len(packets)-1][5] != dcKindRepair {
		t.Fatal("expected the last packet to be a repair symbol")
	}
	if got := len(stream.history); got != 1 {
		t.Fatalf("history holds %d packets, want 1 (the single source symbol)", got)
	}
}

// BOUNDED, or a receiver that never asks lets the host grow without limit.
func TestHistoryEvictsTheOldest(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	for i := 0; i < dcHistoryLen+50; i++ {
		stream.packetsFor(make([]byte, 100), 0, false, 45, 1)
	}
	if got := len(stream.history); got != dcHistoryLen {
		t.Fatalf("history holds %d packets, want %d", got, dcHistoryLen)
	}
	if _, missing := stream.resend([]uint32{0}); missing != 1 {
		t.Fatal("the oldest symbol should have been evicted")
	}
	if _, missing := stream.resend([]uint32{uint32(dcHistoryLen + 49)}); missing != 0 {
		t.Fatal("the newest symbol should still be resendable")
	}
}

// THE HISTORY GOES WITH THE ESI SPACE. Numbering restarts on a generation bump, so a retained packet
// would answer a request for esi 5 with the PREVIOUS generation's symbol — the exact ambiguity the
// generation byte exists to prevent, reintroduced through the back door.
func TestHistoryIsDroppedOnGenerationBump(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	stream.packetsFor(make([]byte, 1200), 0, false, 45, 1)
	if _, missing := stream.resend([]uint32{0}); missing != 0 {
		t.Fatal("the symbol should be resendable before the bump")
	}
	stream.bumpGeneration()
	if _, missing := stream.resend([]uint32{0}); missing != 1 {
		t.Fatal("esi 0 from the previous generation must not be resendable")
	}
}

// A REQUEST FOR SOMETHING LONG GONE IS ANSWERED SILENTLY SHORT, and counted. There is nothing useful
// to tell a receiver that has fallen past the history — it needs a keyframe, not an error — but the
// count is what would say the history is too short to cover the round trip.
func TestResendReportsWhatItCouldNotFind(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	stream.packetsFor(make([]byte, 1200), 0, false, 45, 1)
	found, missing := stream.resend([]uint32{0, 9999})
	if len(found) != 1 || missing != 1 {
		t.Fatalf("resend gave %d packets and %d missing, want 1 and 1", len(found), missing)
	}
}

// THE HASH IS MIRRORED IN TYPESCRIPT AND THE MIRRORING IS LOAD-BEARING — the same reason the RLC
// coefficients are derived from a shared generator rather than shipped. A disagreement here does not
// degrade: EVERY frame fails its check and the picture stops entirely. These vectors are asserted in
// both suites; the twin is in web/test/rlc.test.ts.
func TestFNV1aCrossImplementationVectors(t *testing.T) {
	if got := fnv1a([]byte("rdev")); got != 0x472bcbcc {
		t.Fatalf("fnv1a(\"rdev\") = %#x, want 0x472bcbcc", got)
	}
	// High-bit bytes, which is where a signed-vs-unsigned mistake on the TypeScript side would show.
	if got := fnv1a([]byte{0, 1, 2, 255}); got != 0x6fab6075 {
		t.Fatalf("fnv1a([0 1 2 255]) = %#x, want 0x6fab6075", got)
	}
	if got := fnv1a(nil); got != 2166136261 {
		t.Fatalf("fnv1a(empty) = %d, want the offset basis 2166136261", got)
	}
}
