package main

import "fmt"

// recoverySample is the FlexFEC output counted so far on one session. Deltas between consecutive
// samples are what the periodic `[bridge] fec:` line reports.
type recoverySample struct {
	mediaPackets uint64
	fecPackets   uint64
	fecBytes     uint64
}

// recoverySampleFrom reads the three counters out of a session's FlexFEC stats.
func recoverySampleFrom(stats *SessionFlexFECStats) recoverySample {
	if stats == nil {
		return recoverySample{}
	}
	return recoverySample{
		mediaPackets: stats.ProtectedMediaPackets,
		fecPackets:   stats.FECPackets,
		fecBytes:     stats.FECBytes,
	}
}

// formatRecoveryReport renders one window of FlexFEC output.
//
// IT EXISTS BECAUSE rdev COULD NOT SEE ITS OWN FEC. The engine has maintained
// FlexFECCounters.FECPackets all along and NOTHING in rdev read it — not the host, not RdevCore, not
// the web client — so the log could say FlexFEC was negotiated and say how the budget was split, and
// still leave "did any repair packet reach the wire" unanswerable. A 50%-forced session on a real
// iPad was indistinguishable from a dead one.
//
// ZEROES ARE PRINTED, NOT OMITTED. On a quiet link zero repair packets is the CORRECT reading, which
// is precisely why silence is the wrong way to report it: `repair 0 pkts` beside `media N pkts`
// separates "FEC sent nothing" from "no instrument at all". Same reasoning as the negotiated= line
// one layer up, which exists because the negotiation taking effect was not inferable either.
// recoveryState is how the session describes its own recovery configuration to the report. Read back
// from the engine rather than restated from what rdev believes it set — the same rule the
// `negotiated=` line follows, and for the same reason.
type recoveryState struct {
	tier           string
	degraded       bool
	degradedReason string
	overrideBp     uint32
	overridden     bool
}

func formatRecoveryReport(state recoveryState, prev recoverySample, cur recoverySample) string {
	media := windowDelta(prev.mediaPackets, cur.mediaPackets)
	repair := windowDelta(prev.fecPackets, cur.fecPackets)
	bytes := windowDelta(prev.fecBytes, cur.fecBytes)

	// A FORCED RATIO BYPASSES THE TIER ENTIRELY, so reporting the tier while an override is set
	// prints `tier=off` beside hundreds of repair packets — true, and it reads as "FEC is off",
	// which is the exact ambiguity this reporter exists to remove. Degradation outranks both: the
	// answer declined FlexFEC, so there is no overhead to name.
	label := fmt.Sprintf("tier=%s", state.tier)
	switch {
	case state.degraded:
		label = "DEGRADED to nack-rtx"
		if state.degradedReason != "" {
			label += fmt.Sprintf(" (%s)", state.degradedReason)
		}
	case state.overridden:
		label = fmt.Sprintf("forced=%.1f%%", float64(state.overrideBp)/100)
	}

	line := fmt.Sprintf("[bridge] fec: %s · media %d pkts · repair %d pkts", label, media, repair)
	// The overhead ratio is the number the forced-percentage control claims to set, so it belongs
	// beside the counts — but it needs media to divide by, and a window with none has no ratio
	// rather than a ratio of zero.
	if media > 0 && repair > 0 {
		line += fmt.Sprintf(" (%.1f%%)", float64(repair)/float64(media)*100)
	}
	if repair > 0 {
		line += fmt.Sprintf(" %.1f KB", float64(bytes)/1024)
	}
	return line
}

// windowDelta subtracts two cumulative counters WITHOUT WRAPPING. They are monotonic within a peer,
// so a decrease cannot happen today — but they are unsigned, and an unguarded subtraction would wrap
// to billions and read as a catastrophic FEC storm rather than as the bookkeeping slip it is.
func windowDelta(prev, cur uint64) uint64 {
	if cur < prev {
		return 0
	}
	return cur - prev
}
