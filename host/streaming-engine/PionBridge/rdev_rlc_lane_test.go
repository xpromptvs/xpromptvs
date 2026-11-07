package main

import (
	"bytes"
	"math/rand"
	"testing"
)

// The lane's FEC on the Mac (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §3): a repair over a window of
// any size, and a decoder for the page's repairs. Every payload reaching the decoder is padded to one width.
const testRLCWidth = 32

func padRLC(b []byte) []byte { out := make([]byte, testRLCWidth); copy(out, b); return out }

func patterned(esi, length int) []byte {
	out := make([]byte, length)
	for i := range out {
		out[i] = byte(esi*31 + i*7 + 11)
	}
	return out
}

func TestRLCRepairOverAVariableWindowRecoversOneErasure(t *testing.T) {
	symbols := [][]byte{patterned(0, 3), patterned(1, 9), patterned(2, 5)} // lengths differ, as lane symbols do
	repair := rlcRepair(symbols, 0x12345678)
	if len(repair) != 9 {
		t.Fatalf("repair is %d bytes; it is sized to the longest symbol (9)", len(repair))
	}
	d := newRLCDecoder(1024)
	d.addSource(0, padRLC(symbols[0]))
	d.addSource(2, padRLC(symbols[2]))
	got := d.addRepair(0, 3, 0x12345678, padRLC(repair))
	if len(got) != 1 || got[0] != 1 {
		t.Fatalf("the repair made %v known, want [1]", got)
	}
	if !bytes.Equal(d.get(1), padRLC(symbols[1])) {
		t.Fatalf("recovered %x, want %x", d.get(1), padRLC(symbols[1]))
	}
}

func TestRLCDecoderRecoversKErasuresFromKRepairs(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	const n = 20
	symbols := make([][]byte, n)
	for i := range symbols {
		symbols[i] = patterned(i, 1+rng.Intn(testRLCWidth))
	}
	lost := map[int]bool{2: true, 7: true, 8: true, 13: true, 19: true}
	d := newRLCDecoder(1024)
	for i, s := range symbols {
		if !lost[i] {
			d.addSource(uint64(i), padRLC(s))
		}
	}
	seed := uint32(0xabcdef01)
	for repairs := 0; repairs < 8 && len(lost) > 0; repairs++ { // 5 erasures; 3 spare for a degenerate draw
		for _, esi := range d.addRepair(0, n, seed, padRLC(rlcRepair(symbols, seed))) {
			delete(lost, int(esi))
		}
		seed = rlcNextSeed(seed)
	}
	if len(lost) != 0 {
		t.Fatalf("still missing %v after %d repairs", lost, 8)
	}
	for i, s := range symbols {
		if !bytes.Equal(d.get(uint64(i)), padRLC(s)) {
			t.Fatalf("symbol %d recovered WRONG: %x, want %x", i, d.get(uint64(i)), padRLC(s))
		}
	}
}

// The video decoder's soak, ported: losing two of every seven is far past one repair per window, but each loss is
// the only unknown in the next repair, so it does NOT reach the re-key path (the two tests below do). Whatever it
// recovers must be RIGHT.
func TestRLCDecoderRecoversCorrectlyUnderSustainedLoss(t *testing.T) {
	d := newRLCDecoder(1024)
	const window = 8
	seed := uint32(0x1234567)
	for esi := 0; esi < 400; esi++ {
		if !(esi%7 == 3 || esi%7 == 4) {
			d.addSource(uint64(esi), padRLC(patterned(esi, testRLCWidth)))
		}
		if esi >= window {
			first := esi - window + 1
			win := make([][]byte, window)
			for i := range win {
				win[i] = patterned(first+i, testRLCWidth)
			}
			seed = rlcNextSeed(seed)
			d.addRepair(uint64(first), window, seed, rlcRepair(win, seed))
		}
	}
	checked := 0
	for esi := 300; esi < 380; esi++ {
		if got := d.get(uint64(esi)); got != nil {
			if !bytes.Equal(got, patterned(esi, testRLCWidth)) {
				t.Fatalf("symbol %d recovered WRONG", esi)
			}
			checked++
		}
	}
	if checked < 40 || d.recovered == 0 {
		t.Fatalf("checked %d symbols, %d recovered — the soak exercised nothing", checked, d.recovered)
	}
}

// AN EQUATION REACHING PAST THE HISTORY IS ABANDONED, NEVER TRUNCATED: dropping the old unknown's term would make the
// equation wrong, and a wrong recovery is a wrong keystroke or a corrupt terminal stream.
func TestRLCDecoderAbandonsAnEquationReachingPastItsHistory(t *testing.T) {
	d := newRLCDecoder(4)
	symbols := make([][]byte, 10)
	for i := range symbols {
		symbols[i] = patterned(i, testRLCWidth)
		if i != 2 && i != 8 { // 8 stays inside the history: a TRUNCATED equation would 'solve' it, wrongly
			d.addSource(uint64(i), padRLC(symbols[i]))
		}
	}
	// newest 9, history 4: ESI 2 is gone from what the decoder may hold.
	if got := d.addRepair(2, 8, 77, rlcRepair(symbols[2:], 77)); len(got) != 0 {
		t.Fatalf("a repair over an ESI past the history made %v known", got)
	}
	if d.has(2) || d.has(8) {
		t.Fatal("ESI 2 or 8 was 'recovered' from an equation that reached past the history")
	}
}

func TestRLCDecoderRefusesAPayloadOfAnotherWidth(t *testing.T) {
	d := newRLCDecoder(1024)
	d.addSource(0, padRLC([]byte{1}))
	if got := d.addSource(1, []byte{1, 2, 3}); len(got) != 0 || d.has(1) {
		t.Fatal("a payload of another width was accepted: the algebra needs one width")
	}
}

func TestRLCNextSeedIsTheEncodersStep(t *testing.T) {
	for _, seed := range []uint32{0, 1, 0x12345678, 0x80000000, 0xffffffff} {
		if got, want := rlcNextSeed(seed), newXorshift32(seed).next(); got != want {
			t.Fatalf("rlcNextSeed(%#x) = %#x, want %#x", seed, got, want)
		}
	}
}

func requirePivotsNormalised(t *testing.T, d *rlcDecoder) {
	t.Helper()
	for _, c := range d.debugPivotLeadingCoefficients() {
		if c != 1 {
			t.Fatalf("a pivot leads with %d, not 1: every later reduction against it fails to cancel", c)
		}
	}
}

// A repair over three-plus unknowns arrives BEFORE one of its sources: when it does, the pivot's leading unknown
// becomes known, terms remain, and the equation is re-keyed onto a later ESI. It must be re-normalised there
// (rlc.ts's once-shipped defect), and what it later recovers must be RIGHT.
func TestRLCDecoderReKeysAPivotWithoutBreakingItsNormalisation(t *testing.T) {
	symbols := make([][]byte, 4)
	for i := range symbols {
		symbols[i] = patterned(i, testRLCWidth)
	}
	d := newRLCDecoder(1024)
	d.addRepair(0, 4, 0xc0ffee, rlcRepair(symbols, 0xc0ffee))
	if got := d.debugPivotLeadingCoefficients(); len(got) != 1 || got[0] != 1 {
		t.Fatalf("a four-unknown repair left pivots %v, want one leading with 1", got)
	}
	d.addSource(0, padRLC(symbols[0])) // three terms remain: re-keyed onto a later ESI
	if len(d.pivots) != 1 {
		t.Fatalf("%d pivots after the re-key, want 1 — the path under test did not run", len(d.pivots))
	}
	requirePivotsNormalised(t, d)
	d.addSource(1, padRLC(symbols[1]))
	d.addSource(3, padRLC(symbols[3]))
	if !bytes.Equal(d.get(2), padRLC(symbols[2])) {
		t.Fatalf("recovered %x from the re-keyed pivot, want %x", d.get(2), padRLC(symbols[2]))
	}
}

// The invariant through a long run with three losses in every eight and two repairs per step, so windows carry three
// unknowns and leading unknowns keep becoming known.
func TestRLCDecoderKeepsEveryPivotNormalisedThroughReKeying(t *testing.T) {
	d := newRLCDecoder(1024)
	const window = 8
	seed := uint32(0x7654321)
	for esi := 0; esi < 400; esi++ {
		if esi%8 > 3 {
			d.addSource(uint64(esi), padRLC(patterned(esi, testRLCWidth)))
		}
		if esi >= window {
			first := esi - window + 1
			win := make([][]byte, window)
			for i := range win {
				win[i] = patterned(first+i, testRLCWidth)
			}
			for r := 0; r < 2; r++ {
				seed = seed*1103515245 + 12345
				d.addRepair(uint64(first), window, seed, rlcRepair(win, seed))
			}
		}
		requirePivotsNormalised(t, d)
	}
	for esi := 300; esi < 380; esi++ {
		if got := d.get(uint64(esi)); got != nil && !bytes.Equal(got, patterned(esi, testRLCWidth)) {
			t.Fatalf("symbol %d recovered WRONG", esi)
		}
	}
}

// A SOURCE BELOW THE FLOOR IS REFUSED: prune deletes it at once, so the ESI addSource returned named a symbol get could
// not give — the lane's engine then acknowledged bytes no stream was handed. rlc.test.ts runs the same case.
func TestRLCDecoderRefusesASourceBelowItsFloor(t *testing.T) {
	d := newRLCDecoder(1024)
	payload := make([]byte, 32)
	d.addSource(2000, payload)
	if got := d.addSource(500, payload); len(got) != 0 || d.has(500) {
		t.Fatalf("a source below the floor (976) returned %v, held %v; want nothing", got, d.has(500))
	}
	if got := d.addSource(976, payload); len(got) != 1 || !d.has(976) {
		t.Fatalf("a source AT the floor is kept by prune and must be taken: returned %v", got)
	}
}
