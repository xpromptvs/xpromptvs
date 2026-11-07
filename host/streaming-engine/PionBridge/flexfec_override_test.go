package main

import "testing"

// THE OVERRIDE REPLACES THE TIER TABLE AT EXACTLY TWO DECISION POINTS, and the ratio has to reach
// BOTH or the knob lies: flexFECRepairCount decides how many repair packets exist, while the media
// bitrate decides how much room they have. A change to one alone reads as "40% recovery" on a wire
// carrying none.

func TestRepairCountFollowsTheOverrideRatio(t *testing.T) {
	for _, c := range []struct {
		name     string
		bp       uint32
		keyframe bool
		media    int
		want     uint32
	}{
		{"10 percent", 1000, false, 20, 2},
		{"20 percent", 2000, false, 20, 4},
		{"40 percent", 4000, false, 20, 8},
		{"50 percent", 5000, false, 20, 10},
		// KEYFRAMES FOLLOW THE OVERRIDE TOO. Under Auto they are pinned at 2/5 whatever the tier,
		// which would make a forced 10% carry more overhead than it claims and a forced 0% carry
		// FEC at all.
		{"keyframe follows the ratio", 1000, true, 20, 2},
		// Rounds UP, so a small frame at a small ratio still gets one repair packet rather than
		// silently none.
		{"rounds up", 1000, false, 11, 2},
		{"zero means zero", 0, false, 20, 0},
		{"zero means zero on keyframes", 0, true, 20, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			shape := flexFECShape{tier: FlexFECTierOff, overrideBp: c.bp, overridden: true}
			if got := flexFECRepairCount(shape, c.keyframe, c.media); got != c.want {
				t.Fatalf("repair count = %d, want %d", got, c.want)
			}
		})
	}
}

// EVERY FRAME IS PROTECTED WHEN OVERRIDDEN, ignoring both the tier and the temporal-layer test. The
// layer test is inert for rdev anyway — L1T1 has only layer 0 — but an override must not depend on
// that remaining true.
func TestFrameSelectionFollowsTheOverride(t *testing.T) {
	forced := flexFECShape{tier: FlexFECTierOff, overrideBp: 2000, overridden: true}
	for _, temporalID := range []uint8{0, 1, 2, 3} {
		if !selectFlexFECFrame(forced, false, temporalID) {
			t.Fatalf("temporal layer %d was not protected under a forced ratio", temporalID)
		}
	}
	if !selectFlexFECFrame(forced, true, 0) {
		t.Fatal("a keyframe was not protected under a forced ratio")
	}
	off := flexFECShape{tier: FlexFECTierHigh, overrideBp: 0, overridden: true}
	if selectFlexFECFrame(off, false, 0) || selectFlexFECFrame(off, true, 0) {
		t.Fatal("a forced 0% still selected a frame — it must be genuinely off, tier notwithstanding")
	}
}

// AUTO MUST REPRODUCE THE IMPORTED ENGINE EXACTLY. This is the assertion that catches the keyframe
// departure above leaking into the default path — which is the one behaviour the certification's
// comparison arm depends on.
func TestAutoReproducesTheTierTable(t *testing.T) {
	for _, c := range []struct {
		tier     FlexFECTier
		keyframe bool
		media    int
		want     uint32
	}{
		{FlexFECTierOff, false, 20, 0},
		{FlexFECTierLow, false, 20, 2},
		{FlexFECTierMedium, false, 20, 4},
		{FlexFECTierHigh, false, 20, 8},
		// The imported 2/5 keyframe rule, identical at EVERY tier including Low.
		{FlexFECTierLow, true, 20, 8},
		{FlexFECTierMedium, true, 20, 8},
		{FlexFECTierHigh, true, 20, 8},
	} {
		shape := flexFECShape{tier: c.tier}
		if got := flexFECRepairCount(shape, c.keyframe, c.media); got != c.want {
			t.Fatalf("tier %v keyframe=%v: repair count = %d, want %d",
				c.tier, c.keyframe, got, c.want)
		}
	}
	// And the temporal-layer selection, which the override ignores and Auto must not.
	if selectFlexFECFrame(flexFECShape{tier: FlexFECTierLow}, false, 1) {
		t.Fatal("Auto at tier Low protected temporal layer 1")
	}
	if !selectFlexFECFrame(flexFECShape{tier: FlexFECTierMedium}, false, 1) {
		t.Fatal("Auto at tier Medium did not protect temporal layer 1")
	}
}

// The store is read on the RTP write path, so both facts must arrive in one load: a reader that saw
// "set" and "basis points" separately could observe a half-applied change mid-frame.
func TestOverrideStoreCarriesBothFactsInOneLoad(t *testing.T) {
	store := NewFlexFECOverrideStore()
	if _, set := store.Load(); set {
		t.Fatal("a fresh store reports an override")
	}
	store.Set(2500)
	bp, set := store.Load()
	if !set || bp != 2500 {
		t.Fatalf("Load() = (%d, %v), want (2500, true)", bp, set)
	}
	store.Set(0)
	bp, set = store.Load()
	if !set || bp != 0 {
		t.Fatalf("a forced 0%% must read as SET with bp 0, got (%d, %v)", bp, set)
	}
	store.Clear()
	if _, set := store.Load(); set {
		t.Fatal("Clear() did not return the store to Auto")
	}
}

// The media target is the OTHER half of the same number. mediaBudget is the budget less the
// engine's standing 5% reservation, and a forced ratio divides it the way a tier does: a 20%
// overhead means media gets 10000/12000 of it.
func TestOverrideMediaTargetDividesTheMediaBudget(t *testing.T) {
	const budget uint32 = 20_000_000
	auto := conservativeRecoveryMediaTarget(budget, AV1ScalabilityL1T1, FlexFECTierMedium)
	forced := overrideRecoveryMediaTarget(budget, AV1ScalabilityL1T1, 2000)
	// Tier Medium IS 20% overhead, so a forced 2000bp must land on the same number. This is the
	// assertion that keeps the continuous formula and the tier table describing one quantity.
	if forced != auto {
		t.Fatalf("forced 20%% target = %d, tier Medium = %d; the two must agree", forced, auto)
	}
	if zero := overrideRecoveryMediaTarget(budget, AV1ScalabilityL1T1, 0); zero !=
		conservativeRecoveryMediaTarget(budget, AV1ScalabilityL1T1, FlexFECTierOff) {
		t.Fatalf("forced 0%% target = %d, tier Off = %d", zero,
			conservativeRecoveryMediaTarget(budget, AV1ScalabilityL1T1, FlexFECTierOff))
	}
	// Monotonic: more overhead leaves less for media.
	if overrideRecoveryMediaTarget(budget, AV1ScalabilityL1T1, 5000) >=
		overrideRecoveryMediaTarget(budget, AV1ScalabilityL1T1, 1000) {
		t.Fatal("a larger forced ratio did not leave less media bitrate")
	}
}

// SETTING AN OVERRIDE MUST EMIT EXACTLY ONE UPDATE, and it must carry the matching media target —
// that update is the only route by which rdev's encoders learn to make room for the FEC.
func TestSetRecoveryOverrideEmitsOneMatchingUpdate(t *testing.T) {
	resources := newOverrideTestResources(t, 20_000_000)
	var updates []RecoveryPolicyUpdate
	sink := func(u RecoveryPolicyUpdate) error { updates = append(updates, u); return nil }

	if err := resources.SetRecoveryOverride(2000, sink); err != nil {
		t.Fatalf("SetRecoveryOverride(2000): %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("emitted %d updates, want exactly 1", len(updates))
	}
	want := overrideRecoveryMediaTarget(20_000_000, AV1ScalabilityL1T1, 2000)
	if updates[0].MediaBitrateBitsPerSecond != want {
		t.Fatalf("media target = %d, want %d", updates[0].MediaBitrateBitsPerSecond, want)
	}
	if bp, set := resources.flexFECOverride.Load(); !set || bp != 2000 {
		t.Fatalf("store = (%d, %v), want (2000, true)", bp, set)
	}
}

// WHILE AN OVERRIDE IS SET THE CONTROLLER IS IGNORED, AND ACKNOWLEDGED. Returning an error instead
// would make the controller record a degradation and report itself broken for the duration of every
// test — the knob would look like it had broken FlexFEC.
func TestControllerUpdatesAreSuppressedButAcknowledgedWhileOverridden(t *testing.T) {
	resources := newOverrideTestResources(t, 20_000_000)
	delivered := 0
	sink := func(RecoveryPolicyUpdate) error { delivered++; return nil }

	if err := resources.SetRecoveryOverride(3000, sink); err != nil {
		t.Fatalf("SetRecoveryOverride: %v", err)
	}
	delivered = 0
	if err := resources.applyRecoveryPolicyUpdate(
		RecoveryPolicyUpdate{Sequence: 99, Tier: FlexFECTierHigh, MediaBitrateBitsPerSecond: 1}, sink,
	); err != nil {
		t.Fatalf("a suppressed controller update must be acknowledged, got: %v", err)
	}
	if delivered != 0 {
		t.Fatalf("controller update reached the sink %d times while overridden", delivered)
	}
	if bp, _ := resources.flexFECOverride.Load(); bp != 3000 {
		t.Fatalf("a controller update changed the forced ratio to %d", bp)
	}

	// Auto hands authority back, and the very next controller update lands.
	if err := resources.SetRecoveryOverride(-1, sink); err != nil {
		t.Fatalf("SetRecoveryOverride(-1): %v", err)
	}
	delivered = 0
	if err := resources.applyRecoveryPolicyUpdate(
		RecoveryPolicyUpdate{Sequence: 100, Tier: FlexFECTierLow, MediaBitrateBitsPerSecond: 17_000_000}, sink,
	); err != nil {
		t.Fatalf("applyRecoveryPolicyUpdate after Auto: %v", err)
	}
	if delivered != 1 {
		t.Fatalf("controller update reached the sink %d times after Auto, want 1", delivered)
	}
}

func TestSetRecoveryOverrideRefusesOutOfRange(t *testing.T) {
	resources := newOverrideTestResources(t, 20_000_000)
	sink := func(RecoveryPolicyUpdate) error { return nil }
	for _, bp := range []int{-2, 5001, 100000} {
		if err := resources.SetRecoveryOverride(bp, sink); err == nil {
			t.Fatalf("SetRecoveryOverride(%d) was accepted", bp)
		}
	}
	if _, set := resources.flexFECOverride.Load(); set {
		t.Fatal("a refused value still armed the override")
	}
}

// newOverrideTestResources builds the minimum peerAPIResources the override path touches: the two
// stores, the counters they report through, and the recovery budget allocator the media target is
// computed from. It deliberately does NOT build a peer — this path is pure state plus one callback.
func newOverrideTestResources(t *testing.T, budget uint32) *peerAPIResources {
	t.Helper()
	counters := NewFlexFECCounters(nil)
	resources := &peerAPIResources{
		counters:        &RecoveryCounters{},
		flexFECCounters: counters,
		flexFECTier:     NewFlexFECTierStore(FlexFECTierOff, counters),
		flexFECOverride: NewFlexFECOverrideStore(),
	}
	allocator, err := NewRecoveryBudgetAllocator(budget, AV1ScalabilityL1T1)
	if err != nil {
		t.Fatalf("NewRecoveryBudgetAllocator: %v", err)
	}
	resources.recoveryBudget = allocator
	resources.configuredRTPBudget = budget
	resources.scalabilityMode = AV1ScalabilityL1T1
	return resources
}
