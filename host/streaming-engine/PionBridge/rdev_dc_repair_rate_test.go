package main

import "testing"

// FIVE PERCENT ON A CLEAN LINK, and the reason it could not be that before is arithmetic: repair was
// counted PER FRAME, so one repair per frame is 100% on a one-symbol frame and 25% on a four-symbol
// one. The same setting meant four different things depending on the picture.
//
// A rate over SYMBOLS is the same promise at any frame size, and it is what makes "no more than 5%
// when nothing is being lost" expressible at all.
func TestRepairRateIsAFractionOfSymbols(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.05)

	// Two hundred single-symbol frames: at 5% that is about ten repair symbols, not two hundred.
	repairs := 0
	for i := 0; i < 200; i++ {
		packets := stream.packetsFor(make([]byte, 300), 0, false, 45, 1)
		for _, packet := range packets {
			if packet[5] == dcKindRepair {
				repairs++
			}
		}
	}
	if repairs < 8 || repairs > 13 {
		t.Fatalf("emitted %d repair symbols over 200, want ~10 (5%%)", repairs)
	}
}

// THE RATE APPLIES TO SYMBOLS, so a frame carrying four of them earns four times the credit. This is
// what keeps the promise honest across a picture that changes size — the case the per-frame count
// got wrong in both directions.
func TestRepairRateScalesWithSymbolsNotFrames(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.25)

	repairs := 0
	for i := 0; i < 20; i++ {
		// 4 symbols per frame => 80 source symbols => ~20 repairs at 25%.
		packets := stream.packetsFor(make([]byte, 4*dcSymbolBytes), 0, false, 45, 1)
		for _, packet := range packets {
			if packet[5] == dcKindRepair {
				repairs++
			}
		}
	}
	if repairs < 17 || repairs > 23 {
		t.Fatalf("emitted %d repair symbols over 80, want ~20 (25%%)", repairs)
	}
}

// A KEYFRAME IS PROTECTED WHATEVER THE RATE. It is the largest frame, so the likeliest to lose a
// symbol, and the costliest to lose — everything after it references it. At 5% a keyframe would
// otherwise often earn no repair at all.
func TestKeyframeIsAlwaysProtected(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.0)
	packets := stream.packetsFor(make([]byte, 300), 0, true, 45, 0)
	repairs := 0
	for _, packet := range packets {
		if packet[5] == dcKindRepair {
			repairs++
		}
	}
	if repairs == 0 {
		t.Fatal("a keyframe earned no repair even though it is the frame least able to afford a loss")
	}
}

// THE RATE FOLLOWS THE LOSS THE RECEIVER REPORTS, and lands at the floor when there is none.
func TestRepairRateFollowsReportedLoss(t *testing.T) {
	cases := []struct{ lossPercent, wantAtLeast, wantAtMost float64 }{
		{0.0, 0.04, 0.06},  // clean: the floor, and no more
		{1.0, 0.10, 0.30},  // a percent of loss buys real protection
		{10.0, 0.40, 0.60}, // heavy loss, capped rather than unbounded
		{90.0, 0.40, 0.60}, // a link this bad is not fixable with redundancy; do not spend forever
	}
	for _, test := range cases {
		got := repairRateForLoss(test.lossPercent)
		if got < test.wantAtLeast || got > test.wantAtMost {
			t.Fatalf("loss %.1f%% -> rate %.3f, want between %.2f and %.2f",
				test.lossPercent, got, test.wantAtLeast, test.wantAtMost)
		}
	}
}
