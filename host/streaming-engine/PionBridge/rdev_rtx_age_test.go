package main

import (
	"testing"
	"time"
)

// RDEV RUNS THE RTT-ADAPTIVE RETRANSMISSION WINDOW, NOT THE FIXED ONE.
//
// `RTXAgeMode` was never set, so `normalizedRTXAgeMode` returned RTXAgeFixed and the window was
// pinned at 30ms for every path. That is broken on a real WAN by the engine's own reference numbers:
// at 25ms one-way — 50ms RTT against a 30ms window — it records 2,478 NACKs, 11,669 stale
// suppressions and ZERO retransmissions, because every repair is age-refused before it can be sent.
//
// THE FLOOR IS WHAT MAKES THIS SAFE. `clamp(multiplier * RTT, Floor, Cap)` with Floor at the old
// fixed value can only ever WIDEN the window, never narrow it — so a low-RTT path behaves exactly as
// it did, and this is a strict superset of the previous behaviour rather than a re-tuning.
func TestRdevSessionConfigurationUsesTheRTTAdaptiveRTXWindow(t *testing.T) {
	configuration, err := rdevSessionConfiguration("", 20_000_000)
	if err != nil {
		t.Fatalf("rdevSessionConfiguration: %v", err)
	}
	if configuration.RTXAgeMode != RTXAgeRTT {
		t.Fatalf("RTXAgeMode = %v, want RTXAgeRTT", configuration.RTXAgeMode)
	}
	policy := configuration.rtxAgePolicyConfig()
	if policy.Mode != RTXAgeRTT {
		t.Fatalf("resolved policy mode = %v, want RTXAgeRTT", policy.Mode)
	}
	if policy.Floor != 30*time.Millisecond {
		t.Fatalf("floor = %v, want the previous fixed 30ms", policy.Floor)
	}
	if policy.Cap <= policy.Floor {
		t.Fatalf("cap %v does not exceed floor %v, so the window can never widen", policy.Cap, policy.Floor)
	}
	if policy.MultiplierMilli == 0 {
		t.Fatalf("multiplier is zero, which NewRTXAgePolicy refuses in RTT mode")
	}
	// The whole point: the config the engine will actually accept.
	if _, err := NewRTXAgePolicy(policy, &mediaRTTEstimator{}); err != nil {
		t.Fatalf("engine refuses rdev's RTX age policy: %v", err)
	}
}

// A LOW-RTT PATH MUST BE UNCHANGED. The floor is not decorative — without it, adapting to a LAN's
// sub-millisecond RTT would SHRINK the window below 30ms and refuse repairs that succeed today.
func TestRdevRTXWindowNeverNarrowsBelowTheOldFixedValue(t *testing.T) {
	configuration, err := rdevSessionConfiguration("", 20_000_000)
	if err != nil {
		t.Fatalf("rdevSessionConfiguration: %v", err)
	}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(200 * time.Microsecond) // a loopback-ish path
	policy, err := NewRTXAgePolicy(configuration.rtxAgePolicyConfig(), estimator)
	if err != nil {
		t.Fatalf("NewRTXAgePolicy: %v", err)
	}
	if got := policy.EffectiveMaxAge(); got < 30*time.Millisecond {
		t.Fatalf("effective max age on a fast path = %v, want >= 30ms", got)
	}
}

// AND A WAN PATH MUST ACTUALLY WIDEN, or enabling the mode bought nothing. 50ms RTT is the engine's
// own reference condition, the one that produced zero retransmissions under the fixed window.
func TestRdevRTXWindowWidensOnAWANPath(t *testing.T) {
	configuration, err := rdevSessionConfiguration("", 20_000_000)
	if err != nil {
		t.Fatalf("rdevSessionConfiguration: %v", err)
	}
	estimator := &mediaRTTEstimator{}
	estimator.Observe(50 * time.Millisecond)
	policy, err := NewRTXAgePolicy(configuration.rtxAgePolicyConfig(), estimator)
	if err != nil {
		t.Fatalf("NewRTXAgePolicy: %v", err)
	}
	got := policy.EffectiveMaxAge()
	if got <= 30*time.Millisecond {
		t.Fatalf("effective max age at 50ms RTT = %v, want > 30ms", got)
	}
	if got > configuration.RTXAgeCap {
		t.Fatalf("effective max age %v exceeds the cap %v", got, configuration.RTXAgeCap)
	}
}
