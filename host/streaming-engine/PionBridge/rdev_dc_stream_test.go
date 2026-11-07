package main

import (
	"encoding/binary"
	"testing"
)

// A 3000-byte access unit is three symbols, and the third is SHORT ON THE WIRE — v5. The algebra
// still runs at the full symbol width; `addSource` and the receiver both supply the padding, so it
// never travels.
func TestPacketsForFragmentsAndPads(t *testing.T) {
	stream := newDCVideoStream(7, 16, 1, 2)
	// One repair over this frame's three symbols: this test is about fragmentation, and the repair
	// rate is now a fraction of symbols rather than a count per frame.
	stream.setRepairRate(1.0 / 3.0)
	packets := stream.packetsFor(make([]byte, 3000), 0, false, 45, 1)
	if len(packets) != 4 { // 3 source + 1 repair
		t.Fatalf("packet count = %d, want 4", len(packets))
	}
	// 3000 bytes is two full symbols and a 600-byte tail; the repair stays dense.
	wantLen := []int{
		dcHeaderBytes + dcSymbolBytes,
		dcHeaderBytes + dcSymbolBytes,
		dcHeaderBytes + 600,
		dcHeaderBytes + dcSymbolBytes,
	}
	for i, packet := range packets {
		if len(packet) != wantLen[i] {
			t.Fatalf("packet %d is %d bytes, want %d", i, len(packet), wantLen[i])
		}
		if binary.LittleEndian.Uint32(packet[0:]) != dcMagic || packet[4] != dcVersion {
			t.Fatalf("packet %d has a bad prefix", i)
		}
		if binary.LittleEndian.Uint16(packet[30:]) != 7 {
			t.Fatalf("packet %d sourceIndex = %d, want 7", i, binary.LittleEndian.Uint16(packet[30:]))
		}
	}
	if packets[0][5] != dcKindSource || packets[3][5] != dcKindRepair {
		t.Fatal("expected three source symbols then one repair")
	}
	if got := binary.LittleEndian.Uint32(packets[0][24:]); got != 3000 {
		t.Fatalf("frameBytes = %d, want 3000", got)
	}
	if got := binary.LittleEndian.Uint16(packets[0][22:]); got != 3 {
		t.Fatalf("fragCount = %d, want 3", got)
	}
}

// ESIs are CONTIGUOUS AND GLOBAL PER SOURCE, which is what lets the client derive a frame's whole
// symbol range from any one surviving symbol (firstESI = esi - fragIndex). A repeated or reset ESI
// makes the decoder overwrite one slot and silently assemble nothing.
func TestESIsAreContiguousAcrossFrames(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	var seen []uint32
	for frame := 0; frame < 3; frame++ {
		for _, packet := range stream.packetsFor(make([]byte, 2000), 0, false, 45, 1) {
			seen = append(seen, binary.LittleEndian.Uint32(packet[8:]))
		}
	}
	if len(seen) != 6 {
		t.Fatalf("symbol count = %d, want 6", len(seen))
	}
	for i, esi := range seen {
		if esi != uint32(i) {
			t.Fatalf("esi[%d] = %d, want %d (full: %v)", i, esi, i, seen)
		}
	}
}

// A KEYFRAME GETS MORE REPAIR THAN A DELTA. Loss probability scales with frame size, so the largest
// frame is both the likeliest to be lost and the one whose loss costs every later frame until the
// next IDR.
func TestKeyframesGetMoreRepair(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 3)
	stream.setRepairRate(1.0)   // one repair per symbol, so the keyframe's extra protection is visible
	delta := stream.packetsFor(make([]byte, 1200), 0, false, 45, 1)
	key := stream.packetsFor(make([]byte, 1200), 0, true, 45, 1)
	if got := len(delta) - 1; got != 1 {
		t.Fatalf("delta repair symbols = %d, want 1", got)
	}
	if got := len(key) - 1; got != 3 {
		t.Fatalf("keyframe repair symbols = %d, want 3", got)
	}
}

// THE MEDIA CLOCK IS REAL CAPTURE TIME, ANCHORED TO THE FIRST FRAME — never summed from rounded
// per-frame deltas. Summing is the obvious shape and it is wrong: a constant interval rounds the same
// way every time so the residual never cancels, measured at +82 ticks over 300 frames on the RTP
// path. Anchoring holds the error at one tick for the life of the stream.
func TestMediaTimestampIsAnchoredToTheFirstFrame(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	const oneSecond = 1_000_000_000
	first := stream.packetsFor(make([]byte, 100), 5*oneSecond, false, 45, 1)
	second := stream.packetsFor(make([]byte, 100), 6*oneSecond, false, 45, 1)
	third := stream.packetsFor(make([]byte, 100), 7*oneSecond, false, 45, 1)
	if got := binary.LittleEndian.Uint32(first[0][16:]); got != 0 {
		t.Fatalf("first timestamp = %d, want 0 (the epoch is the first frame, not the clock)", got)
	}
	if got := binary.LittleEndian.Uint32(second[0][16:]); got != 90_000 {
		t.Fatalf("second timestamp = %d, want 90000 (one second at 90kHz)", got)
	}
	if got := binary.LittleEndian.Uint32(third[0][16:]); got != 180_000 {
		t.Fatalf("third timestamp = %d, want 180000", got)
	}
}

// ABSENT PRESENTATION TIME KEEPS THE FIXED 60fps STEP, exactly as FrameTrack does — a source that
// reports no capture time must still produce a monotonic media clock, or the pacer has nothing.
func TestMediaTimestampFallsBackToTheFixedStep(t *testing.T) {
	stream := newDCVideoStream(0, 16, 0, 0)
	a := stream.packetsFor(make([]byte, 100), 0, false, 45, 1)
	b := stream.packetsFor(make([]byte, 100), 0, false, 45, 1)
	if binary.LittleEndian.Uint32(a[0][16:]) != 0 {
		t.Fatal("first timestamp is not the epoch")
	}
	if got := binary.LittleEndian.Uint32(b[0][16:]); got != dcClockStep {
		t.Fatalf("second timestamp = %d, want %d", got, dcClockStep)
	}
}

// A GENERATION BUMP RESTARTS THE STREAM. A codec change or peer rebuild starts a new ESI space and a
// new window; without the epoch the decoder would mix two streams' symbols into one linear system
// and produce plausible garbage rather than an error.
func TestBumpGenerationRestartsTheStream(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 1)
	stream.packetsFor(make([]byte, 2000), 0, false, 45, 1)
	stream.bumpGeneration()
	packets := stream.packetsFor(make([]byte, 1200), 0, false, 45, 1)
	if got := binary.LittleEndian.Uint32(packets[0][8:]); got != 0 {
		t.Fatalf("esi after bump = %d, want 0", got)
	}
	if got := packets[0][32]; got != 1 {
		t.Fatalf("generation = %d, want 1", got)
	}
}

// A SOURCE SYMBOL IS NOT PADDED ON THE WIRE; A REPAIR SYMBOL IS DENSE. The encoder still combines
// full-width symbols — the receiver zero-extends before it solves — so this is purely about what the
// link is charged for.
//
// Measured over a relayed WAN link before this: a near-static window produced ~27-byte frames and
// sent them as 1236-byte messages, about 1.18 Mbit/s of wire for 13 kbit/s of video. The symbol
// COUNTERS could not see it (`src=299 repair=299` reads as a balanced 100% overhead either way),
// which is why the report now carries bytes.
func TestSourceSymbolsAreNotPaddedOnTheWire(t *testing.T) {
	stream := newDCVideoStream(1, 16, 1, 2)
	stream.setRepairRate(1.0)
	packets := stream.packetsFor(make([]byte, 27), 0, false, 45, 1)
	if len(packets) != 2 { // 1 source + 1 repair
		t.Fatalf("packet count = %d, want 2", len(packets))
	}
	if got, want := len(packets[0]), dcHeaderBytes+27; got != want {
		t.Fatalf("source packet is %d bytes, want %d (a padded one would be %d)",
			got, want, dcHeaderBytes+dcSymbolBytes)
	}
	if got, want := len(packets[1]), dcHeaderBytes+dcSymbolBytes; got != want {
		t.Fatalf("repair packet is %d bytes, want %d — a repair symbol is dense", got, want)
	}
	// The header still declares the ALGEBRAIC length, which is what the receiver extends back to.
	if got := binary.LittleEndian.Uint16(packets[0][6:]); got != dcSymbolBytes {
		t.Fatalf("declared symbolBytes = %d, want %d", got, dcSymbolBytes)
	}
	if got := binary.LittleEndian.Uint32(packets[0][24:]); got != 27 {
		t.Fatalf("frameBytes = %d, want 27", got)
	}
}

// THE ENCODER PADS WHAT IT IS GIVEN, and that is what lets the wire carry a short symbol at all.
//
// ASSERTED ON THE STORED SYMBOL, NOT ON THE REPAIR BODY. Two earlier versions of this test drove the
// repair and checked its shape, and NEITHER could fail: `buildRepair` allocates a full-width output
// and combines into it, so a short stored symbol still yields a 1200-byte body whose tail is zero —
// the assertions held while the invariant was broken. Falsified by shortening the buffer `addSource`
// allocates to `len(symbol)`.
func TestAddSourcePadsAShortSymbol(t *testing.T) {
	encoder := newRLCEncoder(dcSymbolBytes, 16, 0x1234)
	encoder.addSource([]byte{1, 2, 3, 4, 5}, 0)
	if len(encoder.symbols) != 1 {
		t.Fatalf("window holds %d symbols, want 1", len(encoder.symbols))
	}
	stored := encoder.symbols[0]
	if len(stored) != dcSymbolBytes {
		t.Fatalf("stored symbol is %d bytes, want %d — a short symbol reached the linear system, and "+
			"the receiver zero-extends to the full width, so the two sides would combine different bytes",
			len(stored), dcSymbolBytes)
	}
	for i, b := range stored[5:] {
		if b != 0 {
			t.Fatalf("stored byte %d is %d, want 0", i+5, b)
		}
	}
}
