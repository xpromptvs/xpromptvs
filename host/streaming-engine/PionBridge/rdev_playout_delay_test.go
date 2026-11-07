package main

import "testing"

// 50 ms IS 5, NOT 50. The extension's fields are 12-bit counts of 10 ms, so passing milliseconds
// straight through would ask for 500 ms — ten times the ceiling intended, and invisible in every
// other reading. Same class as playoutDelayHint taking SECONDS while jitterBufferTarget takes
// MILLISECONDS: correct-looking at zero, wrong by 10x the moment the value is not zero.
func TestPlayoutDelayIsCountedInTensOfMilliseconds(t *testing.T) {
	for _, test := range []struct {
		ms    int
		units uint16
	}{{0, 0}, {10, 1}, {50, 5}, {100, 10}, {1000, 100}} {
		units, ok := playoutDelayUnitsFromMilliseconds(test.ms)
		if !ok || units != test.units {
			t.Fatalf("%dms = %d (ok=%v), want %d", test.ms, units, ok, test.units)
		}
	}
}

// ROUNDS UP, because the field is a PERMISSION. Rounding 55ms down to 50 grants less slack than
// asked for, and the point of the ceiling is to be generous enough that discarding a usable frame is
// never the receiver's best option.
func TestPlayoutDelayRoundsUpToTheNextUnit(t *testing.T) {
	for _, test := range []struct {
		ms    int
		units uint16
	}{{1, 1}, {11, 2}, {55, 6}, {59, 6}} {
		if units, ok := playoutDelayUnitsFromMilliseconds(test.ms); !ok || units != test.units {
			t.Fatalf("%dms = %d, want %d", test.ms, units, test.units)
		}
	}
}

func TestPlayoutDelayRejectsWhatTheFieldCannotCarry(t *testing.T) {
	if _, ok := playoutDelayUnitsFromMilliseconds(-1); ok {
		t.Fatal("a negative ceiling was accepted")
	}
	// 12 bits of 10ms units is 40950ms; one unit past that cannot be encoded.
	if _, ok := playoutDelayUnitsFromMilliseconds(40_960); ok {
		t.Fatal("a ceiling beyond the 12-bit field was accepted")
	}
	if _, ok := playoutDelayUnitsFromMilliseconds(40_950); !ok {
		t.Fatal("the largest encodable ceiling was rejected")
	}
}

// THE MINIMUM MUST STAY ZERO. It is what governs steady-state latency, and raising it would add
// delay to every frame on a clean path — the opposite of what this project exists for. Only the
// CEILING moved.
func TestPlayoutDelayMinimumIsAlwaysZero(t *testing.T) {
	if got := playoutDelayExtension().MinDelay; got != 0 {
		t.Fatalf("MinDelay = %d, want 0 — the minimum is what costs latency", got)
	}
}

// The shipped ceiling is non-zero. Zero told the receiver that a late frame may only be DISCARDED,
// which forces a keyframe request and costs a round trip plus an IDR — far worse for latency than
// rendering that frame late.
func TestPlayoutDelayCeilingIsNotZero(t *testing.T) {
	if got := playoutDelayExtension().MaxDelay; got == 0 {
		t.Fatal("MaxDelay = 0 — a late frame may then only be discarded, never held")
	}
}

// THE SHIPPED CEILING IS PERMISSIVE: 500ms, fifty units. It shipped at ONE unit for a long time, on
// the strength of a real measurement — a 50ms ceiling let an iPad settle at ~25ms of buffer against
// ~15ms under 10ms, with keyframe requests at ~0 either way — and that measurement was of a path
// whose jitter FIT under the ceiling. On a path whose jitter does not fit, WebKit DISCARDS what
// arrives past it: 82 frames per five seconds, 27fps on screen, against 9ms of jitter. A permissive
// ceiling turns those discards into buffer, and the extra buffer the iPad measurement saw is what
// the client's measured floor would ask for on that path anyway.
//
// PINNED, so that a change here is a decision with its own measurement rather than a drift. Fifty
// units and not the field's full range: past 500ms a receiver is not interactive by any definition.
func TestPlayoutDelayCeilingIsPermissive(t *testing.T) {
	if got := playoutDelayExtension().MaxDelay; got != 50 {
		t.Fatalf("MaxDelay = %d units, want 50 (500ms) — a tight ceiling discards the late frames the "+
			"adaptive floor is measured from", got)
	}
}
