package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"

	"github.com/pion/rtp"
)

// rdev stamps a playout-delay header extension on every video packet, and what it says decides how
// much jitter the RECEIVER is allowed to absorb.
//
// THE MINIMUM IS ZERO AND MUST STAY ZERO. It is what governs steady-state latency — "play this out
// as soon as you can" — and it is the whole point of the project.
//
// THE MAXIMUM IS A CEILING, NOT A TARGET, AND ZERO WAS THE WRONG VALUE. rdev sent
// `rtp.PlayoutDelayExtension{}` — min 0, max 0 — which additionally tells the receiver that a frame
// arriving late may only be DISCARDED, never held. That is not a latency optimisation: rendering a
// late P-frame 15 ms late costs 15 ms, while dropping it breaks the reference chain, forces a
// keyframe request, and costs a round trip plus an IDR — measured at 20-30% of the bitrate on a real
// iPad, which then starves the encoder and drops more frames.
//
// IT ALSO OVERRODE THE RECEIVER'S OWN KNOB. A sender-signalled maximum caps the buffer whatever the
// page asks for, which is why setting `RTCRtpReceiver.jitterBufferTarget = 50` on a Safari 27 that
// supports it measured `jbuf=0.9ms`: the extension won. BOTH must be non-zero, and that pairing is
// the whole fix — a ceiling with nothing requested under it changes nothing, and a request under a
// zero ceiling is capped away.
//
// THE CEILING IS PERMISSIVE — 500 ms — AND IT USED TO BE 10, MEASURED ON A PATH THAT FIT UNDER IT.
// The maximum only PERMITS a receiver to buffer, but WebKit takes it literally: a frame arriving
// later than the ceiling allows is DISCARDED. On a relayed path with 9 ms of jitter a 10 ms ceiling
// discarded 82 frames per five seconds with 27 fps reaching the screen (`dropped=` on the client's
// own [rx] line, `lost=0` throughout). With the extension omitted entirely — the receiver left to its
// own estimator — both engines were smooth on loopback and free of discards on the relay, and that
// is what this default reproduces on the wire: min 0, max 500.
//
// IT IS ALSO WHAT MAKES THE ADAPTIVE FLOOR MEASURABLE. The client sizes the floor from how late
// frames ARRIVE (web/src/lib/playout-floor.ts), sampled from the frames the element PRESENTS. Under
// a tight ceiling the discarded frames are exactly the late ones, and the survivors of a burst are
// its youngest members, late by a fraction of the stall — so the measurement under-reads the stall
// it exists to see. A ceiling the receiver never hits keeps every arrival in the sample.
//
// THE COST, MEASURED: left to itself the receiver chose ~13 ms of buffer on loopback where the 10 ms
// ceiling pinned it near 10. Three milliseconds, on the one path that needed no ceiling. Chromium
// adapts past the ceiling either way. 500 rather than the extension's full range because a receiver
// holding more than that is not interactive by any definition, and the floor would have been raised
// long before.
//
// The earlier rationale for 10 — a 50 ms ceiling let a real iPad settle at ~25 ms of buffer against
// ~15 ms under 10 — measured a path whose jitter FIT under the ceiling, and on such a path a receiver
// does hold more when permitted. It did not measure a path whose jitter did not fit, where the same
// ceiling discards; and the extra buffer it saw is what the client's measured floor would now ask
// for on that path in any case.
const defaultPlayoutDelayMaxMilliseconds = 500

// playoutDelayMaxVariable tunes the ceiling without a rebuild. GO SNAPSHOTS THE ENVIRONMENT AT
// RUNTIME INIT, so it must be set in the shell before the host starts — setting it from Swift can
// never be seen (this codebase has the incident on record).
const playoutDelayMaxVariable = "RDEV_LLV_PLAYOUT_DELAY_MAX_MS"

// playoutDelayMinVariable forces a FLOOR on the receiver's playout delay.
//
// DEFAULT 0, AND THAT DEFAULT IS THE PROJECT'S WHOLE POINT — "play this out as soon as you can" is
// what governs steady-state latency. This exists because the maximum turned out not to be reachable
// on every receiver: `max` only PERMITS buffering, and `RTCRtpReceiver.jitterBufferTarget` is the
// request that goes with it — but WebKit honours the sender's extension over the page's request, so
// on Safari neither knob can make the receiver hold anything. Measured on an iPhone: ceiling raised
// to 200 ms, `jitterBufferTarget` set to 100 and then 200, and `jbuf` never left 0.1-1.9 ms.
//
// THE MINIMUM IS THE ONLY FIELD THAT FORCES RATHER THAN PERMITS, so it is the only lever left for
// that receiver. It is also unconditional: unlike a jitter buffer it does not adapt, so every frame
// waits this long on every link forever, including links that need none. Treat any non-zero value as
// a latency price paid on purpose, not a default to drift upward.
const playoutDelayMinVariable = "RDEV_LLV_PLAYOUT_DELAY_MIN_MS"

// playoutDelayUnit is the extension's resolution: both fields are 12-bit counts of 10 ms.
const playoutDelayUnitMilliseconds = 10

// playoutDelayUnitsFromMilliseconds converts to the extension's own unit.
//
// ROUNDS UP, because the field is a PERMISSION: rounding 55 ms down to 50 would grant less slack
// than asked for, and the whole point of the ceiling is to be generous enough that discarding a
// usable frame is never the receiver's best option.
//
// UNITS ARE THE TRAP HERE. 50 ms is 5, not 50 — and 50 would silently mean 500 ms. This is the same
// class as playoutDelayHint taking SECONDS while jitterBufferTarget takes MILLISECONDS: invisible at
// zero, wrong by 10x the moment the value is not zero.
func playoutDelayUnitsFromMilliseconds(ms int) (uint16, bool) {
	if ms < 0 {
		return 0, false
	}
	units := (ms + playoutDelayUnitMilliseconds - 1) / playoutDelayUnitMilliseconds
	if units > (1<<12)-1 {
		return 0, false
	}
	return uint16(units), true //nolint:gosec
}

var (
	playoutDelayOnce sync.Once
	playoutDelayMax  uint16
	playoutDelayMin  uint16
)

// configuredPlayoutDelayMaxMilliseconds reads the ceiling from the environment, falling back to the
// default.
//
// A TYPO MUST NOT TAKE VIDEO DOWN — the rule this project already applies to an unrecognised codec
// preference — so an unparseable or out-of-range value is reported loudly and then ignored.
func configuredPlayoutDelayMaxMilliseconds() int {
	return configuredPlayoutDelayMilliseconds(
		playoutDelayMaxVariable, defaultPlayoutDelayMaxMilliseconds)
}

// configuredPlayoutDelayMilliseconds reads one of the two bounds from the environment. Shared by
// both so a bad value is REFUSED rather than clamped in one place and not the other — the same rule
// every other RDEV_LLV_ variable follows.
func configuredPlayoutDelayMilliseconds(variable string, fallback int) int {
	raw, set := os.LookupEnv(variable)
	if !set {
		return fallback
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil {
		fmt.Printf("[bridge] %s=%q is not a number of milliseconds; using %d\n",
			variable, raw, fallback)
		return fallback
	}
	if _, ok := playoutDelayUnitsFromMilliseconds(parsed); !ok {
		fmt.Printf("[bridge] %s=%d is outside the extension's range; using %d\n",
			variable, parsed, fallback)
		return fallback
	}
	return parsed
}

// playoutDelayExtension is what goes on every video packet: the configured floor and ceiling. The
// floor is zero unless deliberately set — see playoutDelayMinVariable.
func playoutDelayExtension() rtp.PlayoutDelayExtension {
	return playoutDelayExtensionWithMinimum(defaultPlayoutDelayMinimumUnits())
}

// playoutDelayExtensionWithMinimum is what actually goes on the packet, given THIS track's floor.
//
// THE FLOOR IS PER TRACK AND THE CEILING IS PER PROCESS, which is not an inconsistency: the ceiling
// is a deployment-wide permission set by the operator, while the floor is a live control a client
// owns and one client must never be able to retune another's session.
func playoutDelayExtensionWithMinimum(minimumUnits uint16) rtp.PlayoutDelayExtension {
	ensurePlayoutDelayBounds()
	if minimumUnits > playoutDelayMax {
		minimumUnits = 0
	}
	return rtp.PlayoutDelayExtension{MinDelay: minimumUnits, MaxDelay: playoutDelayMax}
}

// defaultPlayoutDelayMinimumUnits is the floor a freshly created track starts at: whatever the
// environment asked for, or zero. A client's control overrides it per session; this is the initial
// value, not the only one.
func defaultPlayoutDelayMinimumUnits() uint16 {
	ensurePlayoutDelayBounds()
	return playoutDelayMin
}

// playoutDelayCeilingUnits lets a setter refuse a floor it could never satisfy.
func playoutDelayCeilingUnits() uint16 {
	ensurePlayoutDelayBounds()
	return playoutDelayMax
}

// ensurePlayoutDelayBounds resolves both environment-derived bounds exactly once and announces them.
func ensurePlayoutDelayBounds() {
	playoutDelayOnce.Do(func() {
		playoutDelayMax, _ = playoutDelayUnitsFromMilliseconds(configuredPlayoutDelayMaxMilliseconds())
		playoutDelayMin, _ = playoutDelayUnitsFromMilliseconds(
			configuredPlayoutDelayMilliseconds(playoutDelayMinVariable, 0))
		// A MINIMUM ABOVE THE MAXIMUM IS NOT A CLAMP, IT IS A CONTRADICTION on the wire, and a
		// receiver's reading of it is undefined. Refuse the minimum rather than silently raising the
		// ceiling to accommodate it: the ceiling is the deliberate setting of the two.
		if playoutDelayMin > playoutDelayMax {
			fmt.Printf("[bridge] playout delay: %s=%dms exceeds the %dms ceiling — ignoring it\n",
				playoutDelayMinVariable, int(playoutDelayMin)*playoutDelayUnitMilliseconds,
				int(playoutDelayMax)*playoutDelayUnitMilliseconds)
			playoutDelayMin = 0
		}
		fmt.Printf("[bridge] playout delay: min %dms max %dms (receiver may buffer up to this "+
			"rather than discard a late frame)\n",
			int(playoutDelayMin)*playoutDelayUnitMilliseconds,
			int(playoutDelayMax)*playoutDelayUnitMilliseconds)
	})
}
