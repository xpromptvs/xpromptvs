package main

import (
	"fmt"
	"sync"
)

const minimumRecoveryMediaBitsPerSecond uint32 = 2_000_000
const initialRecoveryMediaPercent uint64 = 95

type RTPRateObservation struct {
	MediaBitsPerSecond uint64
	FECBitsPerSecond   uint64
	RTXBitsPerSecond   uint64
}

type RecoveryBudgetSnapshot struct {
	ConfiguredRTPBudgetBitsPerSecond uint32 `json:"configuredRTPBudgetBitsPerSecond"`
	ScalabilityMode                  string `json:"scalabilityMode"`
	ObservationCount                 uint64 `json:"observationCount"`
	MediaBitsPerSecond               uint64 `json:"mediaBitsPerSecond"`
	FECBitsPerSecond                 uint64 `json:"fecBitsPerSecond"`
	RTXBitsPerSecond                 uint64 `json:"rtxBitsPerSecond"`
	RecoveryBitsPerSecondEWMA        uint64 `json:"recoveryBitsPerSecondEWMA"`
	ConservativeCeilingBitsPerSecond uint32 `json:"conservativeCeilingBitsPerSecond"`
	MediaTargetBitsPerSecond         uint32 `json:"mediaTargetBitsPerSecond"`
}

type RecoveryBudgetAllocator struct {
	mutex sync.Mutex

	budget uint32
	mode   AV1ScalabilityMode

	observationCount uint64
	latest           RTPRateObservation
	recoveryEWMA     uint64
	lastCeiling      uint32
	lastTarget       uint32
}

func NewRecoveryBudgetAllocator(
	budget uint32,
	mode AV1ScalabilityMode,
) (*RecoveryBudgetAllocator, error) {
	if budget == 0 || mode < AV1ScalabilityL1T1 || mode > AV1ScalabilityL1T3 {
		return nil, fmt.Errorf("%w: invalid recovery budget", errInvalidPeerConfig)
	}
	initialTarget := conservativeRecoveryMediaTarget(budget, mode, FlexFECTierOff)
	return &RecoveryBudgetAllocator{
		budget: budget, mode: mode, lastTarget: initialTarget,
	}, nil
}

func (allocator *RecoveryBudgetAllocator) Target(tier FlexFECTier) uint32 {
	if allocator == nil || tier > FlexFECTierHigh {
		return 0
	}
	allocator.mutex.Lock()
	defer allocator.mutex.Unlock()
	ceiling := conservativeRecoveryMediaTarget(allocator.budget, allocator.mode, tier)
	if ceiling == 0 {
		return 0
	}
	target := uint64(ceiling)
	if allocator.observationCount > 0 {
		currentRecovery := saturatedRateSum(
			allocator.latest.FECBitsPerSecond,
			allocator.latest.RTXBitsPerSecond,
		)
		reservedRecovery := allocator.recoveryEWMA
		if currentRecovery > reservedRecovery {
			reservedRecovery = currentRecovery
		}
		available := uint64(0)
		if reservedRecovery < uint64(allocator.budget) {
			available = uint64(allocator.budget) - reservedRecovery
		}
		minimum := uint64(minimumRecoveryMediaBitsPerSecond)
		if minimum > uint64(allocator.budget) {
			minimum = uint64(allocator.budget)
		}
		if available < minimum {
			available = minimum
		}
		if allocator.latest.MediaBitsPerSecond > 0 {
			corrected := uint64(allocator.lastTarget) * available /
				allocator.latest.MediaBitsPerSecond
			if corrected < minimum {
				corrected = minimum
			}
			if corrected < target {
				target = corrected
			}
		} else if available < target {
			target = available
		}
	}
	allocator.lastCeiling = ceiling
	return uint32(target)
}

func (allocator *RecoveryBudgetAllocator) AcceptTarget(target uint32) {
	if allocator == nil || target == 0 {
		return
	}
	allocator.mutex.Lock()
	allocator.lastTarget = target
	allocator.mutex.Unlock()
}

func (allocator *RecoveryBudgetAllocator) Observe(observation RTPRateObservation) {
	if allocator == nil {
		return
	}
	recovery := saturatedRateSum(
		observation.FECBitsPerSecond,
		observation.RTXBitsPerSecond,
	)
	allocator.mutex.Lock()
	defer allocator.mutex.Unlock()
	allocator.latest = observation
	if allocator.observationCount == 0 {
		allocator.recoveryEWMA = recovery
	} else {
		allocator.recoveryEWMA = weightedQuarterEWMA(
			allocator.recoveryEWMA,
			recovery,
		)
	}
	allocator.observationCount++
}

func (allocator *RecoveryBudgetAllocator) Snapshot() RecoveryBudgetSnapshot {
	if allocator == nil {
		return RecoveryBudgetSnapshot{}
	}
	allocator.mutex.Lock()
	defer allocator.mutex.Unlock()
	return RecoveryBudgetSnapshot{
		ConfiguredRTPBudgetBitsPerSecond: allocator.budget,
		ScalabilityMode:                  scalabilityModeName(allocator.mode),
		ObservationCount:                 allocator.observationCount,
		MediaBitsPerSecond:               allocator.latest.MediaBitsPerSecond,
		FECBitsPerSecond:                 allocator.latest.FECBitsPerSecond,
		RTXBitsPerSecond:                 allocator.latest.RTXBitsPerSecond,
		RecoveryBitsPerSecondEWMA:        allocator.recoveryEWMA,
		ConservativeCeilingBitsPerSecond: allocator.lastCeiling,
		MediaTargetBitsPerSecond:         allocator.lastTarget,
	}
}

func conservativeRecoveryMediaTarget(
	budget uint32,
	mode AV1ScalabilityMode,
	tier FlexFECTier,
) uint32 {
	if budget == 0 || mode < AV1ScalabilityL1T1 || mode > AV1ScalabilityL1T3 ||
		tier > FlexFECTierHigh {
		return 0
	}
	mediaBudget := uint64(budget) * initialRecoveryMediaPercent / 100
	minimum := uint64(minimumRecoveryMediaBitsPerSecond)
	if minimum > uint64(budget) {
		minimum = uint64(budget)
	}
	if mediaBudget < minimum {
		mediaBudget = minimum
	}
	if tier == FlexFECTierOff {
		return uint32(mediaBudget)
	}

	selectedNumerator, selectedDenominator := uint64(1), uint64(1)
	ratioNumerator, ratioDenominator := uint64(0), uint64(1)
	switch tier {
	case FlexFECTierLow:
		ratioNumerator, ratioDenominator = 1, 10
		switch mode {
		case AV1ScalabilityL1T2:
			selectedNumerator, selectedDenominator = 1, 2
		case AV1ScalabilityL1T3:
			selectedNumerator, selectedDenominator = 1, 4
		}
	case FlexFECTierMedium:
		ratioNumerator, ratioDenominator = 1, 5
		if mode == AV1ScalabilityL1T3 {
			selectedNumerator, selectedDenominator = 1, 2
		}
	case FlexFECTierHigh:
		ratioNumerator, ratioDenominator = 2, 5
	}
	overheadNumerator := selectedNumerator * ratioNumerator
	overheadDenominator := selectedDenominator * ratioDenominator
	target := mediaBudget * overheadDenominator /
		(overheadDenominator + overheadNumerator)
	if target < minimum {
		target = minimum
	}
	return uint32(target)
}

// overrideRecoveryMediaTarget is the continuous analogue of conservativeRecoveryMediaTarget: the
// media bitrate that leaves room for `bp` basis points of FEC overhead on top of it.
//
// IT SHARES THE FIRST HALF OF THAT FUNCTION ON PURPOSE — the same 95% standing reservation and the
// same 2 Mbit/s floor — so a forced 2000bp and tier Medium land on the SAME number. Duplicating the
// constants here would let the two drift into describing different quantities while both looked
// right in isolation.
func overrideRecoveryMediaTarget(
	budget uint32,
	mode AV1ScalabilityMode,
	bp uint32,
) uint32 {
	if budget == 0 || mode < AV1ScalabilityL1T1 || mode > AV1ScalabilityL1T3 ||
		bp > maximumFlexFECOverrideBasisPoints {
		return 0
	}
	mediaBudget := uint64(budget) * initialRecoveryMediaPercent / 100
	minimum := uint64(minimumRecoveryMediaBitsPerSecond)
	if minimum > uint64(budget) {
		minimum = uint64(budget)
	}
	if mediaBudget < minimum {
		mediaBudget = minimum
	}
	target := mediaBudget * 10_000 / (10_000 + uint64(bp))
	if target < minimum {
		target = minimum
	}
	return uint32(target)
}

func saturatedRateSum(first uint64, second uint64) uint64 {
	maximum := ^uint64(0)
	if maximum-first < second {
		return maximum
	}
	return first + second
}

func weightedQuarterEWMA(previous uint64, current uint64) uint64 {
	whole := previous/4*3 + current/4
	remainder := (previous%4*3 + current%4) / 4
	return whole + remainder
}

func scalabilityModeName(mode AV1ScalabilityMode) string {
	switch mode {
	case AV1ScalabilityL1T1:
		return "L1T1"
	case AV1ScalabilityL1T2:
		return "L1T2"
	case AV1ScalabilityL1T3:
		return "L1T3"
	default:
		return "invalid"
	}
}
