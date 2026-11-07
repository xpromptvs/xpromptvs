package main

import (
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
)

const (
	recoveryBudgetObservationInterval = time.Second
)

type FlexFECControllerConfig struct {
	Policy       FlexFECControllerPolicy
	AllowedTiers []FlexFECTier
	Tier         *FlexFECTierStore
	History      *TWCCPacketHistory
	MediaRTT     *mediaRTTEstimator
	Budget       *RecoveryBudgetAllocator
	Apply        func(RecoveryPolicyUpdate) error
	Now          func() time.Time
}

type FlexFECControllerSnapshot struct {
	ControllerVersion          string                  `json:"controllerVersion"`
	Policy                     FlexFECControllerPolicy `json:"policy"`
	AllowedTiers               []FlexFECTier           `json:"allowedTiers"`
	CurrentTier                FlexFECTier             `json:"currentTier"`
	RequestedTier              FlexFECTier             `json:"requestedTier"`
	TransitionSequence         uint64                  `json:"transitionSequence"`
	AcceptedTransitions        uint64                  `json:"acceptedTransitions"`
	RejectedTransitions        uint64                  `json:"rejectedTransitions"`
	LastReason                 string                  `json:"lastReason"`
	LastError                  string                  `json:"lastError,omitempty"`
	RTTReady                   bool                    `json:"rttReady"`
	Ready                      bool                    `json:"ready"`
	CompleteWindow             bool                    `json:"completeWindow"`
	LastLossBasisPoints        int                     `json:"lastLossBasisPoints"`
	LastFinalizedPackets       uint64                  `json:"lastFinalizedPackets"`
	RepairLossCapped           bool                    `json:"repairLossCapped"`
	LastRepairLossBasisPoints  int                     `json:"lastRepairLossBasisPoints"`
	LastRepairFinalizedPackets uint64                  `json:"lastRepairFinalizedPackets"`
	LastTransitionAge          time.Duration           `json:"lastTransitionAgeNanoseconds"`
	Closed                     bool                    `json:"closed"`
}

type FlexFECController struct {
	evaluationMutex sync.Mutex
	mutex           sync.Mutex
	closeOnce       sync.Once

	policy  FlexFECControllerPolicy
	allowed []FlexFECTier
	tier    *FlexFECTierStore
	history *TWCCPacketHistory
	rtt     *mediaRTTEstimator
	budget  *RecoveryBudgetAllocator
	apply   func(RecoveryPolicyUpdate) error
	now     func() time.Time

	current                   FlexFECTier
	requested                 FlexFECTier
	mediaTarget               uint32
	sequence                  uint64
	accepted                  uint64
	rejected                  uint64
	lastReason                string
	lastError                 string
	lastTransition            time.Time
	cleanSince                time.Time
	upWindows                 int
	nacks                     []time.Time
	previousTWCC              TWCCSnapshot
	previousRepairTWCC        TWCCSnapshot
	previousBudgetTWCC        TWCCSnapshot
	previousBudgetEval        time.Time
	rttReady                  bool
	completeWindow            bool
	hasCompleteEvidence       bool
	lastLossBasisPoints       int
	lastFinalized             uint64
	repairLossCapped          bool
	lastRepairLossBasisPoints int
	lastRepairFinalized       uint64
	started                   bool
	closed                    bool
	stop                      chan struct{}
	done                      chan struct{}
	wake                      chan struct{}
}

func NewFlexFECController(config FlexFECControllerConfig) (*FlexFECController, error) {
	if err := validateFlexFECControllerConfig(config); err != nil {
		return nil, err
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	controller := &FlexFECController{
		policy: config.Policy, allowed: append([]FlexFECTier(nil), config.AllowedTiers...),
		tier: config.Tier, history: config.History, rtt: config.MediaRTT,
		budget: config.Budget, apply: config.Apply, now: now,
		current: FlexFECTierOff, requested: FlexFECTierOff,
		previousTWCC:       config.History.Snapshot(),
		previousRepairTWCC: config.History.Snapshot(),
		previousBudgetTWCC: config.History.Snapshot(),
		previousBudgetEval: now(),
		stop:               make(chan struct{}), done: make(chan struct{}), wake: make(chan struct{}, 1),
	}
	target := config.Budget.Target(FlexFECTierOff)
	if target == 0 {
		return nil, errors.New("adaptive FlexFEC initial media target is zero")
	}
	controller.sequence = 1
	update := RecoveryPolicyUpdate{
		Sequence: 1, Tier: FlexFECTierOff, MediaBitrateBitsPerSecond: target,
	}
	if err := config.Apply(update); err != nil {
		return nil, fmt.Errorf("acknowledge adaptive FlexFEC initial off tier: %w", err)
	}
	config.Budget.AcceptTarget(target)
	config.Tier.Set(FlexFECTierOff)
	controller.mediaTarget = target
	controller.accepted = 1
	controller.lastReason = "startup"
	return controller, nil
}

func validateFlexFECControllerConfig(config FlexFECControllerConfig) error {
	if err := validateFlexFECControllerPolicy(config.Policy); err != nil {
		return fmt.Errorf("invalid adaptive FlexFEC controller config: %w", err)
	}
	if len(config.AllowedTiers) < 2 || config.AllowedTiers[0] != FlexFECTierOff ||
		config.Tier == nil || config.History == nil || config.MediaRTT == nil ||
		config.Budget == nil || config.Apply == nil {
		return errors.New("invalid adaptive FlexFEC controller dependencies")
	}
	previous := FlexFECTierOff
	for index, tier := range config.AllowedTiers {
		if tier > FlexFECTierHigh || index > 0 && tier <= previous {
			return errors.New("adaptive FlexFEC tiers must be unique and ordered")
		}
		previous = tier
	}
	return nil
}

func (controller *FlexFECController) Start() error {
	if controller == nil {
		return errors.New("nil adaptive FlexFEC controller")
	}
	controller.mutex.Lock()
	if controller.closed {
		controller.mutex.Unlock()
		return errors.New("adaptive FlexFEC controller is closed")
	}
	if controller.started {
		controller.mutex.Unlock()
		return nil
	}
	controller.started = true
	interval := time.Duration(controller.policy.EvaluationIntervalMilliseconds) * time.Millisecond
	controller.mutex.Unlock()
	controller.history.SetFeedbackObserver(controller.wakeEvaluation)
	go controller.run(interval)
	return nil
}

func (controller *FlexFECController) run(interval time.Duration) {
	defer close(controller.done)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			controller.evaluate(controller.now())
		case <-controller.wake:
			controller.evaluate(controller.now())
		case <-controller.stop:
			return
		}
	}
}

func (controller *FlexFECController) ObserveNACK() {
	if controller == nil {
		return
	}
	now := controller.now()
	controller.mutex.Lock()
	if !controller.closed {
		controller.nacks = append(controller.nacks, now)
		controller.pruneNACKsLocked(now)
	}
	controller.mutex.Unlock()
	controller.wakeEvaluation()
}

func (controller *FlexFECController) wakeEvaluation() {
	if controller == nil {
		return
	}
	select {
	case controller.wake <- struct{}{}:
	default:
	}
}

func (controller *FlexFECController) evaluate(now time.Time) {
	if controller == nil {
		return
	}
	controller.evaluationMutex.Lock()
	defer controller.evaluationMutex.Unlock()

	history := controller.history.Snapshot()
	_, _, rttReady := controller.rtt.Snapshot()

	controller.mutex.Lock()
	if controller.closed {
		controller.mutex.Unlock()
		return
	}
	previous := controller.previousTWCC
	previousBudget := controller.previousBudgetTWCC
	budgetElapsed := now.Sub(controller.previousBudgetEval)
	controller.rttReady = rttReady
	controller.pruneNACKsLocked(now)
	nackCount := len(controller.nacks)
	current := controller.current
	policy := controller.policy

	media := history.ByClass[TWCCMedia]
	previousMedia := previous.ByClass[TWCCMedia]
	delivered, deliveredOK := counterDelta(media.DeliveredPackets, previousMedia.DeliveredPackets)
	lost, lostOK := counterDelta(media.FinalizedLostPackets, previousMedia.FinalizedLostPackets)
	finalized := delivered + lost
	complete := deliveredOK && lostOK && finalized >= policy.MinimumFinalizedPackets
	if complete || !deliveredOK || !lostOK {
		controller.previousTWCC = history
	}
	controller.completeWindow = complete
	controller.hasCompleteEvidence = controller.hasCompleteEvidence || complete
	controller.lastFinalized = finalized
	lossBasisPoints := 0
	if complete && lost > 0 {
		lossBasisPoints = int(lost * 10_000 / finalized)
	}
	controller.lastLossBasisPoints = lossBasisPoints
	repairLossCap := controller.observeRepairLossLocked(history)
	budgetWindow := recoveryBudgetObservationInterval
	budgetObserved := budgetElapsed >= budgetWindow
	if budgetObserved {
		controller.observeBudgetLocked(history, previousBudget, budgetElapsed)
		controller.previousBudgetTWCC = history
		controller.previousBudgetEval = now
	}

	hold := !controller.lastTransition.IsZero() &&
		now.Sub(controller.lastTransition) <
			time.Duration(policy.TransitionHoldMilliseconds)*time.Millisecond
	desired, reason := current, ""
	stale := history.FeedbackPackets > 0 &&
		history.FeedbackAge >= time.Duration(policy.FeedbackStaleMilliseconds)*time.Millisecond
	if stale && current != FlexFECTierOff {
		desired, reason = FlexFECTierOff, "stale-feedback"
	} else if rttReady && controller.hasCompleteEvidence {
		burstDesired := FlexFECTierOff
		if nackCount >= policy.HighBurstPackets {
			burstDesired = FlexFECTierHigh
		} else if nackCount >= policy.MediumBurstPackets {
			burstDesired = FlexFECTierMedium
		}
		lossDesired := FlexFECTierOff
		if complete {
			lossDesired = controller.lossTierLocked(lossBasisPoints)
		}
		if lossDesired == FlexFECTierOff && lost > 0 &&
			history.QueueTrend >= time.Duration(policy.QueueTrendMilliseconds)*time.Millisecond {
			lossDesired = FlexFECTierLow
		}
		if burstDesired > current {
			desired, reason = burstDesired, "nack-burst"
			controller.upWindows = 0
		} else if lossDesired > current {
			controller.upWindows++
			if controller.upWindows >= policy.UpHoldWindows {
				desired, reason = lossDesired, "sustained-loss"
			}
		} else {
			controller.upWindows = 0
		}
		clean := complete && lost == 0 && nackCount == 0 &&
			history.QueueTrend <= time.Duration(policy.QueueTrendMilliseconds)*time.Millisecond
		if clean {
			if controller.cleanSince.IsZero() {
				controller.cleanSince = now
			}
			if current != FlexFECTierOff &&
				now.Sub(controller.cleanSince) >= time.Duration(policy.DownCleanMilliseconds)*time.Millisecond {
				desired, reason = FlexFECTierOff, "clean-decay"
			}
		} else {
			controller.cleanSince = time.Time{}
		}
	}
	if repairLossCap && desired != FlexFECTierOff {
		desired = FlexFECTierOff
		reason = "repair-loss-cap"
		controller.upWindows = 0
	}
	next := current
	updateReason := ""
	tierChange := false
	if desired != current && (!hold || repairLossCap && desired < current) {
		next = controller.adjacentTierLocked(current, desired)
		if next != current {
			tierChange = true
			updateReason = reason
		}
	}
	if !tierChange && !budgetObserved {
		controller.mutex.Unlock()
		return
	}
	target := controller.budget.Target(next)
	if target == 0 {
		controller.lastError = "adaptive FlexFEC media target is zero"
		controller.rejected++
		controller.requested = next
		controller.mutex.Unlock()
		return
	}
	if !tierChange {
		if target == controller.mediaTarget {
			controller.mutex.Unlock()
			return
		}
		updateReason = "budget-refinement"
	}
	controller.sequence++
	sequence := controller.sequence
	controller.requested = next
	controller.mutex.Unlock()

	update := RecoveryPolicyUpdate{
		Sequence: sequence, Tier: next, MediaBitrateBitsPerSecond: target,
	}
	err := controller.apply(update)

	controller.mutex.Lock()
	defer controller.mutex.Unlock()
	if controller.closed {
		return
	}
	if err != nil {
		controller.rejected++
		controller.lastError = err.Error()
		return
	}
	controller.budget.AcceptTarget(target)
	controller.mediaTarget = target
	controller.tier.Set(next)
	controller.current = next
	controller.requested = next
	controller.accepted++
	controller.lastReason = updateReason
	controller.lastError = ""
	if tierChange {
		controller.lastTransition = now
		controller.cleanSince = time.Time{}
		controller.upWindows = 0
		controller.nacks = nil
	}
}

func (controller *FlexFECController) observeRepairLossLocked(
	current TWCCSnapshot,
) bool {
	previous := controller.previousRepairTWCC
	fec := current.ByClass[TWCCFEC]
	previousFEC := previous.ByClass[TWCCFEC]
	delivered, deliveredOK := counterDelta(
		fec.DeliveredPackets, previousFEC.DeliveredPackets,
	)
	lost, lostOK := counterDelta(
		fec.FinalizedLostPackets, previousFEC.FinalizedLostPackets,
	)
	if !deliveredOK || !lostOK {
		controller.previousRepairTWCC = current
		controller.repairLossCapped = false
		controller.lastRepairLossBasisPoints = 0
		controller.lastRepairFinalized = 0
		return false
	}
	finalized := delivered + lost
	if finalized < controller.policy.RepairLossMinimumPackets {
		return controller.repairLossCapped
	}
	basisPoints := 0
	if lost > 0 {
		basisPoints = int(lost * 10_000 / finalized)
	}
	controller.previousRepairTWCC = current
	controller.lastRepairFinalized = finalized
	controller.lastRepairLossBasisPoints = basisPoints
	controller.repairLossCapped = basisPoints >= controller.policy.RepairLossCapBasisPoints
	return controller.repairLossCapped
}

func (controller *FlexFECController) observeBudgetLocked(
	current TWCCSnapshot,
	previous TWCCSnapshot,
	elapsed time.Duration,
) {
	if elapsed <= 0 {
		return
	}
	rate := func(class TWCCPacketClass) uint64 {
		bytes, ok := counterDelta(current.ByClass[class].SentBytes, previous.ByClass[class].SentBytes)
		if !ok {
			return 0
		}
		return bytes * 8 * uint64(time.Second) / uint64(elapsed)
	}
	controller.budget.Observe(RTPRateObservation{
		MediaBitsPerSecond: rate(TWCCMedia),
		FECBitsPerSecond:   rate(TWCCFEC),
		RTXBitsPerSecond:   rate(TWCCRTX),
	})
}

func counterDelta(current uint64, previous uint64) (uint64, bool) {
	if current < previous {
		return 0, false
	}
	return current - previous, true
}

func (controller *FlexFECController) lossTierLocked(basisPoints int) FlexFECTier {
	switch {
	case basisPoints >= controller.policy.HighLossBasisPoints:
		return FlexFECTierHigh
	case basisPoints >= controller.policy.MediumLossBasisPoints:
		return FlexFECTierMedium
	case basisPoints >= controller.policy.LowLossBasisPoints:
		return FlexFECTierLow
	default:
		return FlexFECTierOff
	}
}

func (controller *FlexFECController) adjacentTierLocked(
	current FlexFECTier,
	desired FlexFECTier,
) FlexFECTier {
	currentIndex := slices.Index(controller.allowed, current)
	if currentIndex < 0 {
		return current
	}
	if desired > current {
		if currentIndex+1 < len(controller.allowed) {
			return controller.allowed[currentIndex+1]
		}
		return current
	}
	if desired < current && currentIndex > 0 {
		return controller.allowed[currentIndex-1]
	}
	return current
}

func (controller *FlexFECController) pruneNACKsLocked(now time.Time) {
	cutoff := now.Add(-time.Duration(controller.policy.BurstWindowMilliseconds) * time.Millisecond)
	first := 0
	for first < len(controller.nacks) && controller.nacks[first].Before(cutoff) {
		first++
	}
	if first > 0 {
		controller.nacks = append([]time.Time(nil), controller.nacks[first:]...)
	}
}

func (controller *FlexFECController) Snapshot() FlexFECControllerSnapshot {
	if controller == nil {
		return FlexFECControllerSnapshot{}
	}
	controller.mutex.Lock()
	defer controller.mutex.Unlock()
	age := time.Duration(0)
	if !controller.lastTransition.IsZero() {
		now := controller.now()
		if now.After(controller.lastTransition) {
			age = now.Sub(controller.lastTransition)
		}
	}
	return FlexFECControllerSnapshot{
		ControllerVersion: controller.policy.ControllerVersion,
		Policy:            controller.policy,
		AllowedTiers:      append([]FlexFECTier(nil), controller.allowed...),
		CurrentTier:       controller.current, RequestedTier: controller.requested,
		TransitionSequence:  controller.sequence,
		AcceptedTransitions: controller.accepted, RejectedTransitions: controller.rejected,
		LastReason: controller.lastReason, LastError: controller.lastError,
		RTTReady:                   controller.rttReady,
		Ready:                      controller.rttReady && controller.hasCompleteEvidence,
		CompleteWindow:             controller.completeWindow,
		LastLossBasisPoints:        controller.lastLossBasisPoints,
		LastFinalizedPackets:       controller.lastFinalized,
		RepairLossCapped:           controller.repairLossCapped,
		LastRepairLossBasisPoints:  controller.lastRepairLossBasisPoints,
		LastRepairFinalizedPackets: controller.lastRepairFinalized,
		LastTransitionAge:          age, Closed: controller.closed,
	}
}

func (controller *FlexFECController) Close() error {
	if controller == nil {
		return nil
	}
	controller.closeOnce.Do(func() {
		controller.evaluationMutex.Lock()
		controller.history.SetFeedbackObserver(nil)
		controller.mutex.Lock()
		controller.closed = true
		started := controller.started
		if started {
			close(controller.stop)
		}
		controller.mutex.Unlock()
		controller.evaluationMutex.Unlock()
		if started {
			<-controller.done
		}
	})
	return nil
}

func (controller *FlexFECController) setCurrentTierForTest(tier FlexFECTier, now time.Time) {
	controller.mutex.Lock()
	controller.current = tier
	controller.requested = tier
	controller.lastTransition = now
	controller.cleanSince = time.Time{}
	controller.tier.Set(tier)
	controller.mutex.Unlock()
}
