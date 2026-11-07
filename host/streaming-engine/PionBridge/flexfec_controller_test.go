package main

import (
	"errors"
	"sync"
	"testing"
	"time"
)

type flexFECControllerHarness struct {
	t          *testing.T
	now        time.Time
	history    *TWCCPacketHistory
	rtt        *mediaRTTEstimator
	tier       *FlexFECTierStore
	budget     *RecoveryBudgetAllocator
	updates    []RecoveryPolicyUpdate
	applyError error
	controller *FlexFECController
	mutex      sync.Mutex
}

func newFlexFECControllerHarness(t *testing.T) *flexFECControllerHarness {
	t.Helper()
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	harness := &flexFECControllerHarness{
		t: t, now: time.Unix(1_000, 0), rtt: &mediaRTTEstimator{},
		tier: NewFlexFECTierStore(FlexFECTierOff, nil),
	}
	policy := assets.Policy
	policy.MinimumFinalizedPackets = 100
	harness.history = mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{
		Now:             func() time.Time { return harness.now },
		ReorderingGrace: time.Duration(policy.ReorderingGraceMilliseconds) * time.Millisecond,
	})
	harness.budget, err = NewRecoveryBudgetAllocator(8_000_000, AV1ScalabilityL1T3)
	if err != nil {
		t.Fatal(err)
	}
	harness.controller, err = NewFlexFECController(FlexFECControllerConfig{
		Policy: policy, AllowedTiers: assets.AllowedTiers,
		Tier: harness.tier, History: harness.history, MediaRTT: harness.rtt,
		Budget: harness.budget, Now: func() time.Time { return harness.now },
		Apply: func(update RecoveryPolicyUpdate) error {
			harness.mutex.Lock()
			defer harness.mutex.Unlock()
			harness.updates = append(harness.updates, update)
			return harness.applyError
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = harness.controller.Close() })
	return harness
}

func (harness *flexFECControllerHarness) advance(duration time.Duration) {
	harness.now = harness.now.Add(duration)
}

func (harness *flexFECControllerHarness) addWindow(
	delivered uint64,
	lost uint64,
	queueTrend time.Duration,
) {
	history := harness.history
	history.mutex.Lock()
	history.feedbackPackets++
	history.lastFeedback = harness.now
	history.deliveredPackets += delivered
	history.finalizedLostPackets += lost
	history.queueTrend = queueTrend
	media := history.byClass[TWCCMedia]
	media.SentPackets += delivered + lost
	media.SentBytes += (delivered + lost) * 1_000
	media.DeliveredPackets += delivered
	media.DeliveredBytes += delivered * 1_000
	media.FinalizedLostPackets += lost
	history.byClass[TWCCMedia] = media
	history.mutex.Unlock()
}

func (harness *flexFECControllerHarness) addClassBytes(
	class TWCCPacketClass,
	bytes uint64,
) {
	history := harness.history
	history.mutex.Lock()
	stats := history.byClass[class]
	stats.SentBytes += bytes
	history.byClass[class] = stats
	history.mutex.Unlock()
}

func (harness *flexFECControllerHarness) addClassWindow(
	class TWCCPacketClass,
	delivered uint64,
	lost uint64,
) {
	history := harness.history
	history.mutex.Lock()
	stats := history.byClass[class]
	stats.SentPackets += delivered + lost
	stats.DeliveredPackets += delivered
	stats.FinalizedLostPackets += lost
	history.byClass[class] = stats
	history.mutex.Unlock()
}

func (harness *flexFECControllerHarness) updateCount() int {
	harness.mutex.Lock()
	defer harness.mutex.Unlock()
	return len(harness.updates)
}

func TestFlexFECControllerWaitsForRTTAndCompleteTWCCWindow(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	if harness.updateCount() != 1 || harness.tier.Load() != FlexFECTierOff {
		t.Fatalf("initial updates/tier = %d/%d", harness.updateCount(), harness.tier.Load())
	}
	harness.addWindow(99, 1, 0)
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierOff {
		t.Fatal("controller adapted without RTT")
	}
	harness.rtt.Observe(10 * time.Millisecond)
	harness.advance(100 * time.Millisecond)
	harness.addWindow(49, 1, 0)
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierOff {
		t.Fatal("controller adapted without a complete window")
	}
}

func TestFlexFECControllerAccumulatesSubthresholdFeedbackIntoCompleteWindow(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)

	harness.addWindow(50, 0, 0)
	harness.controller.evaluate(harness.now)
	if snapshot := harness.controller.Snapshot(); snapshot.Ready || snapshot.CompleteWindow {
		t.Fatalf("first partial window snapshot = %#v", snapshot)
	}

	harness.advance(50 * time.Millisecond)
	harness.addWindow(50, 0, 0)
	harness.controller.evaluate(harness.now)
	if snapshot := harness.controller.Snapshot(); !snapshot.Ready ||
		!snapshot.CompleteWindow || snapshot.LastFinalizedPackets != 100 {
		t.Fatalf("accumulated clean window snapshot = %#v", snapshot)
	}
}

func TestFlexFECControllerRefinesCurrentTierOnlyAfterOneSecondBudgetWindow(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.tier.Set(FlexFECTierMedium)
	harness.controller.setCurrentTierForTest(FlexFECTierMedium, harness.now)

	harness.advance(500 * time.Millisecond)
	harness.addWindow(500, 0, 0)
	harness.addClassBytes(TWCCFEC, 125_000)
	harness.controller.evaluate(harness.now)
	if harness.updateCount() != 1 {
		t.Fatalf("subthreshold budget window updates=%d, want 1", harness.updateCount())
	}

	harness.advance(500 * time.Millisecond)
	harness.addWindow(500, 0, 0)
	harness.addClassBytes(TWCCFEC, 125_000)
	harness.controller.evaluate(harness.now)
	if harness.updateCount() != 2 {
		t.Fatalf("complete budget window updates=%d, want 2", harness.updateCount())
	}
	harness.mutex.Lock()
	update := harness.updates[len(harness.updates)-1]
	harness.mutex.Unlock()
	if update.Tier != FlexFECTierMedium ||
		update.MediaBitrateBitsPerSecond != 5_700_000 ||
		harness.tier.Load() != FlexFECTierMedium ||
		harness.controller.Snapshot().LastReason != "budget-refinement" {
		t.Fatalf("budget refinement update=%#v snapshot=%#v", update, harness.controller.Snapshot())
	}
}

func TestFlexFECControllerRaisesOneTierAfterSustainedLoss(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	for window := 0; window < 2; window++ {
		harness.addWindow(99, 1, 0)
		harness.controller.evaluate(harness.now)
		harness.advance(100 * time.Millisecond)
	}
	if harness.tier.Load() != FlexFECTierLow || harness.updateCount() != 2 {
		t.Fatalf("tier/updates = %d/%d, want low/2", harness.tier.Load(), harness.updateCount())
	}
	if snapshot := harness.controller.Snapshot(); snapshot.LastReason != "sustained-loss" ||
		snapshot.AcceptedTransitions != 2 {
		t.Fatalf("controller snapshot = %#v", snapshot)
	}
}

func TestFlexFECControllerNACKBurstRaisesAtMostOneTierPerEvaluation(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.addWindow(100, 0, 0)
	harness.controller.evaluate(harness.now)
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatalf("four-NACK burst jumped to tier %d", harness.tier.Load())
	}
	harness.advance(500 * time.Millisecond)
	harness.addWindow(100, 0, 0)
	for index := 0; index < 2; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierMedium {
		t.Fatalf("second NACK burst tier = %d, want medium", harness.tier.Load())
	}
}

func TestFlexFECControllerCapsProtectionWhenRepairPacketsAreMostlyLost(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.tier.Set(FlexFECTierHigh)
	harness.controller.setCurrentTierForTest(FlexFECTierHigh, harness.now)
	harness.advance(500 * time.Millisecond)
	harness.addWindow(90, 10, 0)
	harness.addClassWindow(TWCCFEC, 2, 8)
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierMedium ||
		harness.controller.Snapshot().LastReason != "repair-loss-cap" {
		t.Fatalf("repair-loss cap snapshot = %#v", harness.controller.Snapshot())
	}
}

func TestFlexFECControllerDisablesProtectionWhileRepairLossIsSevere(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.tier.Set(FlexFECTierLow)
	harness.controller.setCurrentTierForTest(FlexFECTierLow, harness.now)
	harness.advance(500 * time.Millisecond)
	harness.addWindow(90, 10, 0)
	harness.addClassWindow(TWCCFEC, 2, 8)
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierOff || harness.updateCount() != 2 {
		t.Fatalf("repair-loss disable tier/updates = %d/%d", harness.tier.Load(), harness.updateCount())
	}

	harness.advance(100 * time.Millisecond)
	harness.addWindow(90, 10, 0)
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierOff || harness.updateCount() != 2 {
		t.Fatalf("persistent repair-loss disable tier/updates = %d/%d", harness.tier.Load(), harness.updateCount())
	}
}

func TestFlexFECControllerQueueTrendRequiresFinalizedLoss(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	for window := 0; window < 2; window++ {
		harness.addWindow(100, 0, 5*time.Millisecond)
		harness.controller.evaluate(harness.now)
		harness.advance(100 * time.Millisecond)
	}
	if harness.tier.Load() != FlexFECTierOff {
		t.Fatal("queue trend alone raised protection")
	}
	for window := 0; window < 2; window++ {
		harness.addWindow(999, 1, 5*time.Millisecond)
		harness.controller.evaluate(harness.now)
		harness.advance(100 * time.Millisecond)
	}
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatalf("queue plus loss tier = %d, want low", harness.tier.Load())
	}
}

func TestFlexFECControllerCleanAndStaleFeedbackStepTowardOff(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.tier.Set(FlexFECTierHigh)
	harness.controller.setCurrentTierForTest(FlexFECTierHigh, harness.now)
	cleanMilliseconds := harness.controller.policy.DownCleanMilliseconds
	for elapsed := 0; elapsed <= cleanMilliseconds; elapsed += 100 {
		harness.addWindow(100, 0, 0)
		harness.controller.evaluate(harness.now)
		harness.advance(100 * time.Millisecond)
	}
	if harness.tier.Load() != FlexFECTierMedium {
		t.Fatalf("clean decay tier = %d, want medium", harness.tier.Load())
	}
	harness.advance(time.Duration(
		harness.controller.policy.FeedbackStaleMilliseconds,
	) * time.Millisecond)
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatalf("stale decay tier = %d, want low", harness.tier.Load())
	}
}

func TestFlexFECControllerHoldAndAcknowledgmentFailurePreserveTier(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	harness.rtt.Observe(10 * time.Millisecond)
	harness.addWindow(100, 0, 0)
	harness.controller.evaluate(harness.now)
	for index := 0; index < 2; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatal("initial burst did not raise to low")
	}
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatal("transition hold allowed immediate reversal/change")
	}
	harness.advance(500 * time.Millisecond)
	harness.applyError = errors.New("encoder rejected")
	harness.addWindow(100, 0, 0)
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.tier.Load() != FlexFECTierLow {
		t.Fatal("failed acknowledgment changed tier")
	}
	if snapshot := harness.controller.Snapshot(); snapshot.RejectedTransitions != 1 ||
		snapshot.RequestedTier != FlexFECTierMedium {
		t.Fatalf("failed transition snapshot = %#v", snapshot)
	}
}

func TestFlexFECControllerCloseSuppressesLaterCallbacks(t *testing.T) {
	harness := newFlexFECControllerHarness(t)
	before := harness.updateCount()
	if err := harness.controller.Close(); err != nil {
		t.Fatal(err)
	}
	harness.rtt.Observe(10 * time.Millisecond)
	for index := 0; index < 4; index++ {
		harness.controller.ObserveNACK()
	}
	harness.controller.evaluate(harness.now)
	if harness.updateCount() != before || !harness.controller.Snapshot().Closed {
		t.Fatalf("close updates/snapshot = %d/%#v", harness.updateCount(), harness.controller.Snapshot())
	}
}
