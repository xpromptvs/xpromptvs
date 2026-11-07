package main

import "testing"

// A WINDOW OF ZEROES MUST STILL PRINT, and that is the whole reason this reporter exists.
//
// rdev had no counter for repair packets at all: the host logged that FlexFEC was NEGOTIATED and
// logged the media/FEC budget split, and nothing anywhere said whether a single repair packet
// reached the wire. That gap is not academic — a 50%-forced session on a real iPad could not be told
// apart from a dead one. And silence is the wrong way to report nothing: zero repair packets is the
// CORRECT reading on a quiet link, so `repair 0 pkts` beside `media N pkts` is what distinguishes
// "FEC sent nothing" from "no instrument at all".
func TestRecoveryReportPrintsAWindowOfZeroes(t *testing.T) {
	line := formatRecoveryReport(recoveryState{tier: "off"}, recoverySample{}, recoverySample{})
	want := "[bridge] fec: tier=off · media 0 pkts · repair 0 pkts"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// THE NUMBERS ARE PER WINDOW, NOT CUMULATIVE. `[encode]` reports per 5 s window, and correlating a
// tier change against a running total is far harder than against a window.
func TestRecoveryReportSubtractsThePreviousSample(t *testing.T) {
	prev := recoverySample{mediaPackets: 1000, fecPackets: 100, fecBytes: 50_000}
	cur := recoverySample{mediaPackets: 2420, fecPackets: 810, fecBytes: 676_688}
	line := formatRecoveryReport(recoveryState{tier: "low"}, prev, cur)
	want := "[bridge] fec: tier=low · media 1420 pkts · repair 710 pkts (50.0%) 612.0 KB"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// A WINDOW WITH NO MEDIA CANNOT HAVE AN OVERHEAD RATIO, and printing one would mean dividing by
// zero. Repair packets are still reported: they are the fact being measured.
func TestRecoveryReportOmitsTheRatioWithoutMedia(t *testing.T) {
	cur := recoverySample{mediaPackets: 0, fecPackets: 3, fecBytes: 2048}
	line := formatRecoveryReport(recoveryState{tier: "low"}, recoverySample{}, cur)
	want := "[bridge] fec: tier=low · media 0 pkts · repair 3 pkts 2.0 KB"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// COUNTERS THAT APPEAR TO GO BACKWARDS REPORT ZERO, NEVER A HUGE NUMBER. They are monotonic within a
// peer, so this cannot happen today — but they are unsigned, so an unguarded subtraction would wrap
// to billions and read as a catastrophic FEC storm rather than as the bookkeeping slip it is.
func TestRecoveryReportDoesNotWrapOnADecreasingCounter(t *testing.T) {
	prev := recoverySample{mediaPackets: 500, fecPackets: 250, fecBytes: 1024}
	line := formatRecoveryReport(recoveryState{tier: "off"}, prev, recoverySample{})
	want := "[bridge] fec: tier=off · media 0 pkts · repair 0 pkts"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// A DEGRADED SESSION SAYS SO, because "tier=off with no repair packets" and "this connection has no
// FlexFEC at all" look identical in every other field and mean entirely different things.
func TestRecoveryReportNamesTheDegradation(t *testing.T) {
	line := formatRecoveryReport(
		recoveryState{tier: "off", degraded: true, degradedReason: "the answer declined FlexFEC"},
		recoverySample{}, recoverySample{})
	want := "[bridge] fec: DEGRADED to nack-rtx (the answer declined FlexFEC) · " +
		"media 0 pkts · repair 0 pkts"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// A FORCED OVERRIDE MUST NOT REPORT ITSELF AS THE ADAPTIVE TIER, and the first real device session
// with this instrument is what exposed it: the line read `tier=off` while 487 repair packets and
// 456 KB per window were going out, because a forced ratio bypasses the tier entirely
// (selectFlexFECFrame returns overrideBp > 0 when overridden) and the adaptive tier really is off.
// True, and it reads as "FEC is off" — the exact ambiguity this reporter exists to remove.
//
// PRINTING BOTH NUMBERS IS THE POINT. The delivered ratio EXCEEDS the forced one — 50% asked, ~64%
// on the wire — because the repair count is per FRAME and rounds UP, so at 2-3 packets per frame
// ceil(2 x 0.5)=1 and ceil(3 x 0.5)=2 average out well above the setting. Showing the request beside
// the delivery is what makes that legible instead of looking like a broken control.
func TestRecoveryReportNamesAForcedOverrideRatherThanTheTier(t *testing.T) {
	state := recoveryState{tier: "off", overrideBp: 5000, overridden: true}
	cur := recoverySample{mediaPackets: 758, fecPackets: 487, fecBytes: 467_558}
	line := formatRecoveryReport(state, recoverySample{}, cur)
	want := "[bridge] fec: forced=50.0% · media 758 pkts · repair 487 pkts (64.2%) 456.6 KB"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}

// A DEGRADED SESSION OUTRANKS A FORCED RATIO: the answer declined FlexFEC, so there is nothing to
// force and reporting a percentage would name overhead that cannot exist.
func TestRecoveryReportPrefersDegradationOverAForcedOverride(t *testing.T) {
	state := recoveryState{tier: "off", degraded: true, degradedReason: "declined", overrideBp: 5000, overridden: true}
	line := formatRecoveryReport(state, recoverySample{}, recoverySample{})
	want := "[bridge] fec: DEGRADED to nack-rtx (declined) · media 0 pkts · repair 0 pkts"
	if line != want {
		t.Fatalf("line = %q, want %q", line, want)
	}
}
