package main

import "testing"

// A REPAIR IS ONLY AS LONG AS THE LONGEST SYMBOL IT COVERS. It is a linear combination over its
// window, and every byte past the longest member is a combination of zeroes — provably zero, and
// provably not worth sending.
//
// Measured on a static window at 95kbps: 310 source symbols of ~470 bytes against 286 repair symbols
// of 1240, so repair was 71% OF THE WIRE while the reported overhead — counted in symbols — read
// 29%. Dropping the bitrate twentyfold barely moved the wire rate, because most of it was padding
// that does not scale with the picture.
func TestRepairIsSizedToItsWindow(t *testing.T) {
	encoder := newRLCEncoder(dcSymbolBytes, 16, 0x1234)
	for esi := 0; esi < 4; esi++ {
		encoder.addSource(make([]byte, 470), uint32(esi))
	}
	payload, _, _, _ := encoder.buildRepair()
	if len(payload) != 470 {
		t.Fatalf("repair is %d bytes, want 470 — the longest symbol in the window", len(payload))
	}
}

// THE LONGEST, NOT THE LAST. A window holding a big symbol and a small one must protect both, so
// trimming to the most recent arrival would silently drop the tail of the larger one.
func TestRepairCoversTheLongestSymbolInTheWindow(t *testing.T) {
	encoder := newRLCEncoder(dcSymbolBytes, 16, 0x99)
	encoder.addSource(make([]byte, 900), 0)
	encoder.addSource(make([]byte, 120), 1)
	payload, _, _, _ := encoder.buildRepair()
	if len(payload) != 900 {
		t.Fatalf("repair is %d bytes, want 900 — the longest symbol, not the newest", len(payload))
	}
}

// AND IT SHRINKS AS THE WINDOW MOVES ON. The long symbol ages out; the repair should stop paying for
// it, or a single large frame would set the price for the next sixteen.
func TestRepairShrinksWhenTheLongSymbolLeavesTheWindow(t *testing.T) {
	encoder := newRLCEncoder(dcSymbolBytes, 2, 0x99)
	encoder.addSource(make([]byte, 900), 0)
	encoder.addSource(make([]byte, 120), 1)
	encoder.addSource(make([]byte, 130), 2) // window is 2, so esi 0 is evicted
	payload, _, _, _ := encoder.buildRepair()
	if len(payload) != 130 {
		t.Fatalf("repair is %d bytes, want 130 — the 900-byte symbol has left the window", len(payload))
	}
}

// THE COMBINATION ITSELF MUST BE UNCHANGED over the bytes it does cover: this is a shorter message,
// not a different one, and a receiver zero-extends it back to the algebraic width before solving.
func TestTrimmingDoesNotChangeTheCombination(t *testing.T) {
	symbols := [][]byte{
		{1, 2, 3, 4, 5, 6, 7, 8},
		{9, 10, 11, 12, 13, 14, 15, 16},
	}
	trimmed := newRLCEncoder(dcSymbolBytes, 16, 0x2024)
	full := newRLCEncoder(8, 16, 0x2024)
	for esi, symbol := range symbols {
		trimmed.addSource(symbol, uint32(esi))
		full.addSource(symbol, uint32(esi))
	}
	got, _, _, _ := trimmed.buildRepair()
	want, _, _, _ := full.buildRepair()
	if len(got) != len(want) {
		t.Fatalf("trimmed repair is %d bytes, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("byte %d differs: %d vs %d — trimming changed the combination", i, got[i], want[i])
		}
	}
}
