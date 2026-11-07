package main

// The recovery-policy callback's ONE structural guarantee: it is delivered through the peer's
// ordered dispatcher, like every other rdev callback, and it still returns a status.
//
// WHY THAT PAIR IS THE WHOLE TEST. Those two requirements pull against each other — the dispatcher
// is asynchronous and a status is synchronous — and the resolution (enqueue a closure carrying a
// reply channel, then wait on it) is invisible in the value that arrives. A test that only checked
// the update reached the sink would pass just as happily against an INLINE call, which is the one
// implementation that breaks teardown: PionPeer.close releases the retained ctx on the line after
// pion_peer_close returns, on the stated grounds that no callback can fire after close. An inline
// policy update fires whenever the controller's evaluation timer says so, close or no close, and
// dereferences memory Swift has already freed.
//
// So the assertion is about TIMING, not about the payload: occupy the dispatcher, and delivery must
// not be able to complete. Nothing else distinguishes the two implementations from outside.

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRecoveryPolicyIsDeliveredThroughTheOrderedDispatcher(t *testing.T) {
	peer := &rdevPeer{
		events:         make(chan func(), 8),
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
	}
	go peer.dispatch()
	// Registered FIRST so it runs LAST: defers are LIFO, and stopping the dispatcher must happen
	// after the callback parking it has been released.
	defer func() { close(peer.done); <-peer.dispatcherDone }()

	// Occupy the dispatcher with a callback that will not return until this test releases it. While
	// it is parked, an ordered delivery CANNOT run and an inline one is unaffected — which is
	// precisely the difference being measured.
	occupied := make(chan struct{})
	release := make(chan struct{})
	// Released from a defer as well as inline, via Once, because the assertions below use t.Fatal:
	// an aborted test skips the inline close, the dispatcher stays parked inside this callback
	// forever, and the deferred `<-peer.dispatcherDone` then deadlocks. That converts a clean
	// failure into a ten-minute timeout with no message — which is exactly what a mutation run of
	// this test produced before the Once was added.
	var releaseOnce sync.Once
	releaseDispatcher := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseDispatcher()
	peer.enqueue(func() { close(occupied); <-release })
	<-occupied

	var applied atomic.Bool
	peer.onRecoveryPolicy = func(update RecoveryPolicyUpdate) error {
		applied.Store(true)
		return nil
	}

	returned := make(chan error, 1)
	go func() {
		returned <- peer.deliverRecoveryPolicy(RecoveryPolicyUpdate{
			Sequence: 1, Tier: FlexFECTierLow, MediaBitrateBitsPerSecond: 1_700_000,
		})
	}()

	select {
	case <-returned:
		t.Fatal("deliverRecoveryPolicy returned while the dispatcher was occupied, so the sink ran " +
			"INLINE rather than through the ordered dispatcher. An inline callback can fire after " +
			"pion_peer_close returns, dereferencing the ctx Swift released on the next line.")
	case <-time.After(100 * time.Millisecond):
	}
	if applied.Load() {
		t.Fatal("the sink ran while the dispatcher was parked — delivery is not ordered against " +
			"the other callbacks, which is the guarantee close() depends on")
	}

	releaseDispatcher()
	select {
	case err := <-returned:
		if err != nil {
			t.Fatalf("deliver: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("deliverRecoveryPolicy never returned after the dispatcher was released")
	}
	if !applied.Load() {
		t.Fatal("the dispatcher drained but the sink never ran")
	}
}

// The status has to survive the hop, or the engine believes a rejected update was applied. The
// coordinator on the Swift side is what rejects an invalid sequence, a zero bitrate or a sequence
// conflict; this asserts the error it returns is the error the engine sees.
func TestRecoveryPolicyReturnsTheSinksError(t *testing.T) {
	peer := &rdevPeer{
		events:         make(chan func(), 8),
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
	}
	go peer.dispatch()
	defer func() { close(peer.done); <-peer.dispatcherDone }()

	peer.onRecoveryPolicy = func(update RecoveryPolicyUpdate) error {
		return errors.New("the coordinator rejected this update")
	}
	err := peer.deliverRecoveryPolicy(RecoveryPolicyUpdate{
		Sequence: 7, Tier: FlexFECTierHigh, MediaBitrateBitsPerSecond: 1_200_000,
	})
	if err == nil {
		t.Fatal("a rejecting sink reported success, so the controller would believe an update was " +
			"applied that was not, and the total would exceed the budget it exists to respect")
	}
}

// THE TEARDOWN ESCAPE. Waiting on a reply from a dispatcher that will never run again is a deadlock,
// and the controller's evaluation timer keeps firing while a session closes. `done` is the escape,
// and a closed peer must report failure rather than block: the update genuinely was not applied.
func TestRecoveryPolicyOnAClosedPeerFailsRatherThanBlocking(t *testing.T) {
	peer := &rdevPeer{
		events:         make(chan func()), // unbuffered: nothing can be parked without a consumer
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
	}
	close(peer.done) // torn down; no dispatcher is running and none ever will be

	peer.onRecoveryPolicy = func(update RecoveryPolicyUpdate) error { return nil }

	returned := make(chan error, 1)
	go func() {
		returned <- peer.deliverRecoveryPolicy(RecoveryPolicyUpdate{
			Sequence: 1, Tier: FlexFECTierLow, MediaBitrateBitsPerSecond: 1_700_000,
		})
	}()
	select {
	case err := <-returned:
		if err == nil {
			t.Fatal("a torn-down peer reported the update as APPLIED; it was discarded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("deliverRecoveryPolicy blocked forever on a closed peer — the controller's " +
			"evaluation goroutine is now wedged against a dispatcher that will never drain")
	}
}

// A peer with no sink installed must not panic. Nothing installs one until Swift calls
// pion_set_callbacks, and the controller can evaluate before that.
func TestRecoveryPolicyWithNoSinkIsAnError(t *testing.T) {
	peer := &rdevPeer{
		events:         make(chan func(), 8),
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
	}
	go peer.dispatch()
	defer func() { close(peer.done); <-peer.dispatcherDone }()

	if err := peer.deliverRecoveryPolicy(RecoveryPolicyUpdate{
		Sequence: 1, Tier: FlexFECTierLow, MediaBitrateBitsPerSecond: 1_700_000,
	}); err == nil {
		t.Fatal("no sink installed, but the update reported success")
	}
}

// RDEV_LLV_RECOVERY: the two accepted values, and the refusal.
//
// THE REFUSAL IS THE POINT. A typo that silently selected the other recovery stack would be
// invisible from outside — the session connects, streams and decodes either way, and the only
// difference is which repair mechanism runs. That is this repo's most-repeated defect shape, and on
// this knob it would corrupt a measurement rather than break a build: the certification harness sets
// this variable to choose the arm it is measuring.
func TestConfiguredRecoveryAcceptsTwoValuesAndRefusesTheRest(t *testing.T) {
	for _, testCase := range []struct {
		raw     string
		want    RecoveryMode
		refused bool
	}{
		{raw: "", want: RecoveryNACKRTXFlexFEC},
		{raw: "nack-rtx", want: RecoveryNACKRTX},
		{raw: "  nack-rtx  ", want: RecoveryNACKRTX},
		{raw: "nack-rtx-flexfec", want: RecoveryNACKRTXFlexFEC},
		{raw: "flexfec", refused: true},
		{raw: "nack_rtx_flexfec", refused: true},
		{raw: "NACK-RTX-FLEXFEC", refused: true},
		{raw: "true", refused: true},
	} {
		t.Setenv("RDEV_LLV_RECOVERY", testCase.raw)
		got, err := rdevConfiguredRecovery()
		if testCase.refused {
			if err == nil {
				t.Fatalf("RDEV_LLV_RECOVERY=%q was accepted; an unrecognised value must refuse the "+
					"session, not pick a stack the caller did not ask for", testCase.raw)
			}
			continue
		}
		if err != nil {
			t.Fatalf("RDEV_LLV_RECOVERY=%q: %v", testCase.raw, err)
		}
		if got != testCase.want {
			t.Fatalf("RDEV_LLV_RECOVERY=%q gave %v, want %v", testCase.raw, got, testCase.want)
		}
	}
}

// THE DEFAULT IS FlexFEC AS OF 2026-08-18, and it must carry all four of the fields the engine
// demands — a default that selected FlexFEC while leaving one of them zero would be refused by
// validateSessionConfiguration and take every session down at creation.
func TestTheDefaultSessionIsFlexFEC(t *testing.T) {
	t.Setenv("RDEV_LLV_RECOVERY", "")
	configuration, err := rdevSessionConfiguration("[]", 20_000_000)
	if err != nil {
		t.Fatalf("configuration: %v", err)
	}
	if configuration.Recovery != RecoveryNACKRTXFlexFEC {
		t.Fatalf("default recovery is %v, want nack-rtx-flexfec", configuration.Recovery)
	}
	if configuration.FlexFECPolicy != FlexFECPolicyAdaptive {
		t.Fatalf("default FlexFEC policy is %v, want adaptive — a fixed tier spends a constant "+
			"overhead whatever the link is doing, and the controller selected by LLV's WAN "+
			"experiments is the adaptive one", configuration.FlexFECPolicy)
	}
	if configuration.ScalabilityMode != AV1ScalabilityL1T1 {
		t.Fatalf("scalability is %v, want L1T1", configuration.ScalabilityMode)
	}
	if configuration.FramesPerSecond != rdevFlexFECFramesPerSecond {
		t.Fatalf("fps is %d, want %d", configuration.FramesPerSecond, rdevFlexFECFramesPerSecond)
	}
	if configuration.TotalRTPBudgetBitsPerSecond != 20_000_000 {
		t.Fatalf("budget is %d, want the cap passed across the ABI",
			configuration.TotalRTPBudgetBitsPerSecond)
	}
}

// THE OPT-OUT STILL WORKS, and it is the only way to recover a machine whose browser cannot answer
// FlexFEC without a rebuild. Safari and Firefox have never been exercised against rdev, and with
// Recovery fixed at construction there is no mid-session downgrade.
func TestTheOptOutRestoresNackRtxWithEveryFlexFECFieldZero(t *testing.T) {
	t.Setenv("RDEV_LLV_RECOVERY", "nack-rtx")
	configuration, err := rdevSessionConfiguration("[]", 20_000_000)
	if err != nil {
		t.Fatalf("configuration: %v", err)
	}
	if configuration.Recovery != RecoveryNACKRTX {
		t.Fatalf("opt-out gave %v, want nack-rtx", configuration.Recovery)
	}
	// Validate refuses a non-zero budget outside FlexFEC mode, so a leaked field fails every session.
	if configuration.TotalRTPBudgetBitsPerSecond != 0 || configuration.FlexFECPolicy != 0 ||
		configuration.ScalabilityMode != 0 || configuration.FramesPerSecond != 0 {
		t.Fatalf("FlexFEC-only fields leaked into the opt-out: budget=%d policy=%v scalability=%v fps=%d",
			configuration.TotalRTPBudgetBitsPerSecond, configuration.FlexFECPolicy,
			configuration.ScalabilityMode, configuration.FramesPerSecond)
	}
	configuration.ICEPort = 55555
	if err := validateSessionConfiguration(configuration); err != nil {
		t.Fatalf("the engine refuses rdev's opt-out configuration: %v", err)
	}
}

// THE CONTROLLER rdev RUNS IS THE ONE IT WAS ASKED TO RUN.
//
// `ll100-d1000-h250-b2x4` is the configuration LLV's WAN experiments selected, and rdev gets it by
// leaving FlexFECControllerPolicyJSON EMPTY so the engine's embedded policy is used. That is a
// silent coupling: nothing else in this repo would notice if a re-import changed the embedded file
// or if someone supplied an explicit policy here, and either would leave rdev running a controller
// nobody chose while every gate stayed green.
func TestTheEmbeddedControllerIsTheOneRdevWasAskedToRun(t *testing.T) {
	t.Setenv("RDEV_LLV_RECOVERY", "nack-rtx-flexfec")
	configuration, err := rdevSessionConfiguration("[]", 20_000_000)
	if err != nil {
		t.Fatalf("configuration: %v", err)
	}
	if len(configuration.FlexFECControllerPolicyJSON) != 0 {
		t.Fatal("rdev supplied its own controller policy; leaving it empty is what selects the " +
			"engine's embedded one, and a copy here would fork from the engine on re-import")
	}
	assets, err := loadFlexFECControllerAssets(configuration.FlexFECControllerPolicyJSON)
	if err != nil {
		t.Fatalf("embedded controller assets: %v", err)
	}
	if assets.Policy.ControllerVersion != "ll100-d1000-h250-b2x4" {
		t.Fatalf("rdev would run controller %q, want ll100-d1000-h250-b2x4",
			assets.Policy.ControllerVersion)
	}
}

// The mirror: with FlexFEC selected, the budget must actually arrive, and a zero one is refused
// rather than passed to a controller that cannot use it.
func TestFlexFECCarriesTheBudgetAndRefusesAZeroOne(t *testing.T) {
	t.Setenv("RDEV_LLV_RECOVERY", "nack-rtx-flexfec")
	configuration, err := rdevSessionConfiguration("[]", 20_000_000)
	if err != nil {
		t.Fatalf("configuration: %v", err)
	}
	if configuration.Recovery != RecoveryNACKRTXFlexFEC {
		t.Fatalf("recovery is %v, want nack-rtx-flexfec", configuration.Recovery)
	}
	if configuration.TotalRTPBudgetBitsPerSecond != 20_000_000 {
		t.Fatalf("budget is %d, want the 20000000 passed across the ABI — if this is 0 the ratio's "+
			"denominator is wrong and every applied bitrate is silently wrong in proportion",
			configuration.TotalRTPBudgetBitsPerSecond)
	}
	if _, err := rdevSessionConfiguration("[]", 0); err == nil {
		t.Fatal("FlexFEC accepted a zero budget; the controller divides by it")
	}
}

// THE CONFIGURATION rdev PRODUCES UNDER FlexFEC MUST BE ONE THE ENGINE ACCEPTS.
//
// Both validators are the SHARED ones the answering path uses, and either could refuse rdev's
// configuration for a reason that has nothing to do with the browser — a missing callback, a budget
// the validator dislikes, a field the offer path never had to fill in before. Without this the first
// evidence would arrive at the moment the default is flipped, tangled up with whatever the browser
// does, and the two causes would be indistinguishable.
func TestTheFlexFECConfigurationRdevProducesIsAcceptedByTheEngine(t *testing.T) {
	t.Setenv("RDEV_LLV_RECOVERY", "nack-rtx-flexfec")
	configuration, err := rdevSessionConfiguration("[]", 20_000_000)
	if err != nil {
		t.Fatalf("configuration: %v", err)
	}
	// newRdevPeer probes a free UDP port and fills this in; rdevSessionConfiguration deliberately
	// does not, so the test supplies what the real construction path would.
	configuration.ICEPort = 55555
	if err := validateSessionConfiguration(configuration); err != nil {
		t.Fatalf("the engine refuses rdev's own FlexFEC configuration: %v", err)
	}

	// validateSessionCallbacks is what demands OnRecoveryPolicy for FlexFEC of ANY policy, and it is
	// the single check that stood between this branch and the default.
	peer := &rdevPeer{
		events:         make(chan func(), 8),
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
	}
	peer.onRecoveryPolicy = peer.emitRecoveryPolicy
	callbacks := SessionCallbacks{OnRecoveryPolicy: peer.deliverRecoveryPolicy}
	if err := validateSessionCallbacks(configuration, callbacks); err != nil {
		t.Fatalf("callbacks refused under FlexFEC: %v", err)
	}
}
