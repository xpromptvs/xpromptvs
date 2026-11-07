// THE CROSS-IMPLEMENTATION VECTOR. The Go encoder and the TypeScript decoder must agree on the
// field, on the coefficient generator and on the byte order, and a disagreement in any of them
// DECODES TO PLAUSIBLE GARBAGE rather than to an error — the picture would simply be wrong in ways
// that look like a codec bug. The same vector is asserted in web/test/rlc.test.ts; the pair is the
// only thing that can catch a one-sided edit.
package main

import "testing"

func TestGF256MatchesTheSharedVector(t *testing.T) {
	if got := gfMul(3, 7); got != 9 {
		t.Fatalf("gfMul(3,7) = %d, want 9", got)
	}
	if got := gfMul(200, 150); got != 118 {
		t.Fatalf("gfMul(200,150) = %d, want 118", got)
	}
	if got := gfDiv(1, 3); got != 244 {
		t.Fatalf("gfDiv(1,3) = %d, want 244", got)
	}
	// Every non-zero element times its inverse is 1 — the property the decoder's back-substitution
	// depends on, checked across the whole field rather than at a sampled point.
	for a := 1; a < 256; a++ {
		if got := gfMul(byte(a), gfDiv(1, byte(a))); got != 1 {
			t.Fatalf("%d * (1/%d) = %d, want 1", a, a, got)
		}
	}
}

func TestCoefficientGeneratorMatchesTheSharedVector(t *testing.T) {
	got := make([]byte, 8)
	rlcCoefficients(0x12345678, got)
	want := []byte{33, 57, 35, 123, 59, 3, 193, 118}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("rlcCoefficients(0x12345678)[%d] = %d, want %d (full: %v)", i, got[i], want[i], got)
		}
	}
	// A zero coefficient would silently shrink the window and make the measured code rate a lie.
	for i, c := range got {
		if c == 0 {
			t.Fatalf("coefficient %d is zero", i)
		}
	}
}

// A single repair symbol recovers a single erasure — the property the whole scheme rests on, checked
// end to end through the real encoder rather than by restating the algebra.
func TestRepairRecoversOneErasure(t *testing.T) {
	const symbolBytes = 8
	encoder := newRLCEncoder(symbolBytes, 4, 0xabcdef01)
	sources := [][]byte{
		{1, 2, 3, 4, 5, 6, 7, 8},
		{9, 10, 11, 12, 13, 14, 15, 16},
		{17, 18, 19, 20, 21, 22, 23, 24},
	}
	for esi, s := range sources {
		encoder.addSource(s, uint32(esi))
	}
	repair, firstESI, windowLen, seed := encoder.buildRepair()
	if windowLen != 3 || firstESI != 0 {
		t.Fatalf("window = [%d, +%d), want [0, +3)", firstESI, windowLen)
	}
	// Erase source 1 and rebuild it from the repair plus the two survivors.
	coefficients := make([]byte, windowLen)
	rlcCoefficients(seed, coefficients)
	residual := append([]byte(nil), repair...)
	gfMulAddInto(residual, sources[0], coefficients[0])
	gfMulAddInto(residual, sources[2], coefficients[2])
	recovered := make([]byte, symbolBytes)
	gfMulAddInto(recovered, residual, gfDiv(1, coefficients[1]))
	for i := range sources[1] {
		if recovered[i] != sources[1][i] {
			t.Fatalf("recovered[%d] = %d, want %d (full: %v)", i, recovered[i], sources[1][i], recovered)
		}
	}
}
