package main

import "testing"

// HOW FAR BACK A FRAME'S REFERENCE IS, which is what lets a receiver decide on ARRIVAL whether a
// frame can be decoded — rather than inferring it from a hole in the sequence and a timer.
//
// The DataChannel carried nothing about references, so the client could only ask "was there a gap
// anywhere" and stop everything until a keyframe. That is correct for a linear chain and wrong for
// anything else, and it was correct here only because the write path hardcodes L1T1 — an accident of
// configuration that nothing was checking.
func TestDependsOnOffsetForL1T1(t *testing.T) {
	// A keyframe references nothing: it is the start of the chain.
	if got := l1t1Dependency(true).DependsOnOffset(); got != 0 {
		t.Fatalf("keyframe offset = %d, want 0", got)
	}
	// Every delta frame references the one immediately before it.
	if got := l1t1Dependency(false).DependsOnOffset(); got != 1 {
		t.Fatalf("delta offset = %d, want 1", got)
	}
}

// L1T2 AND L1T3 ARE WHY THIS IS AN OFFSET RATHER THAN A FLAG. In a temporal hierarchy a base-layer
// frame skips over the upper-layer frames between it and its reference, so "the previous frame" is
// the wrong answer and losing an upper-layer frame costs nothing at all.
//
// These are the templates the encoder is already configured with in CAOMBridge.c; the offsets follow
// from them. Asserted here so that turning L1T2 on is a change of mode rather than a redesign.
func TestDependsOnOffsetAcrossTemporalLayers(t *testing.T) {
	cases := []struct {
		name     string
		mode     AV1ScalabilityMode
		template uint8
		want     uint8
	}{
		{"L1T2 keyframe", AV1ScalabilityL1T2, 0, 0},
		{"L1T2 base references the previous base", AV1ScalabilityL1T2, 1, 2},
		{"L1T2 upper references the frame before it", AV1ScalabilityL1T2, 2, 1},
		{"L1T3 keyframe", AV1ScalabilityL1T3, 0, 0},
		{"L1T3 base references the previous base", AV1ScalabilityL1T3, 1, 4},
		{"L1T3 middle references the previous base", AV1ScalabilityL1T3, 2, 2},
		{"L1T3 upper references the frame before it", AV1ScalabilityL1T3, 3, 1},
	}
	for _, test := range cases {
		dependency := AV1Dependency{Mode: test.mode, TemplateID: test.template}
		if got := dependency.DependsOnOffset(); got != test.want {
			t.Fatalf("%s: offset = %d, want %d", test.name, got, test.want)
		}
	}
}

// AN UNKNOWN STRUCTURE MUST BE TREATED AS A CHAIN, never as "depends on nothing". Reporting no
// dependency for a frame whose references are not understood would tell the receiver it is safe to
// decode, which is the one answer that produces a corrupt picture rather than a brief freeze.
func TestUnknownStructureIsTreatedAsAChain(t *testing.T) {
	dependency := AV1Dependency{Mode: AV1ScalabilityMode(99), TemplateID: 7}
	if got := dependency.DependsOnOffset(); got != 1 {
		t.Fatalf("unknown structure offset = %d, want 1 (the conservative answer)", got)
	}
}
