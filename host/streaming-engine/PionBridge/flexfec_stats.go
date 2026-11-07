package main

import (
	"sync"
	"sync/atomic"
	"time"
)

type FlexFECTierStore struct {
	value    atomic.Uint32
	counters *FlexFECCounters
}

func NewFlexFECTierStore(initial FlexFECTier, counters *FlexFECCounters) *FlexFECTierStore {
	store := &FlexFECTierStore{counters: counters}
	store.value.Store(uint32(initial))
	if counters != nil {
		counters.setTier(initial)
	}
	return store
}

func (store *FlexFECTierStore) Load() FlexFECTier {
	if store == nil {
		return FlexFECTierOff
	}
	return FlexFECTier(store.value.Load())
}

func (store *FlexFECTierStore) Set(tier FlexFECTier) {
	if store == nil || tier > FlexFECTierHigh {
		return
	}
	old := FlexFECTier(store.value.Swap(uint32(tier)))
	if old != tier && store.counters != nil {
		store.counters.setTier(tier)
	}
}

type FlexFECStatsSnapshot struct {
	SelectedFramesByTemporalID map[uint8]uint64              `json:"selectedFramesByTemporalID"`
	ProtectedMediaPackets      uint64                        `json:"protectedMediaPackets"`
	GroupSizeHistogram         map[int]uint64                `json:"groupSizeHistogram"`
	FECPackets                 uint64                        `json:"fecPackets"`
	FECBytes                   uint64                        `json:"fecBytes"`
	Failures                   uint64                        `json:"failures"`
	DisableReason              string                        `json:"disableReason,omitempty"`
	CurrentTier                FlexFECTier                   `json:"-"`
	TimeInCurrentTier          time.Duration                 `json:"timeInCurrentTierNanoseconds"`
	TimeByTier                 map[FlexFECTier]time.Duration `json:"timeByTierNanoseconds"`
}

type FlexFECCounters struct {
	mutex sync.Mutex
	now   func() time.Time

	selectedFramesByTemporalID map[uint8]uint64
	protectedMediaPackets      uint64
	groupSizeHistogram         map[int]uint64
	fecPackets                 uint64
	fecBytes                   uint64
	failures                   uint64
	disableReason              string
	currentTier                FlexFECTier
	tierChangedAt              time.Time
	timeByTier                 map[FlexFECTier]time.Duration
}

func NewFlexFECCounters(now func() time.Time) *FlexFECCounters {
	if now == nil {
		now = time.Now
	}
	current := now()
	return &FlexFECCounters{
		now:                        now,
		selectedFramesByTemporalID: make(map[uint8]uint64, 3),
		groupSizeHistogram:         make(map[int]uint64, 109),
		tierChangedAt:              current,
		timeByTier:                 make(map[FlexFECTier]time.Duration, 4),
	}
}

func (counters *FlexFECCounters) setTier(tier FlexFECTier) {
	if counters == nil {
		return
	}
	now := counters.now()
	counters.mutex.Lock()
	if counters.tierChangedAt.IsZero() {
		counters.tierChangedAt = now
	}
	if counters.currentTier != tier {
		counters.timeByTier[counters.currentTier] += now.Sub(counters.tierChangedAt)
		counters.currentTier = tier
		counters.tierChangedAt = now
	}
	counters.mutex.Unlock()
}

func (counters *FlexFECCounters) recordSelectedFrame(temporalID uint8) {
	if counters == nil {
		return
	}
	counters.mutex.Lock()
	if temporalID <= 2 {
		counters.selectedFramesByTemporalID[temporalID]++
	}
	counters.mutex.Unlock()
}

func (counters *FlexFECCounters) recordGroup(mediaPackets int, fecPackets int, fecBytes int) {
	if counters == nil {
		return
	}
	counters.mutex.Lock()
	if mediaPackets > 0 && mediaPackets <= 109 {
		counters.groupSizeHistogram[mediaPackets]++
		counters.protectedMediaPackets += uint64(mediaPackets)
	}
	if fecPackets > 0 {
		counters.fecPackets += uint64(fecPackets)
	}
	if fecBytes > 0 {
		counters.fecBytes += uint64(fecBytes)
	}
	counters.mutex.Unlock()
}

func (counters *FlexFECCounters) recordFailure(err error) {
	if counters == nil || err == nil {
		return
	}
	counters.mutex.Lock()
	counters.failures++
	if counters.disableReason == "" {
		counters.disableReason = err.Error()
	}
	counters.mutex.Unlock()
}

func (counters *FlexFECCounters) Snapshot(currentTier FlexFECTier) FlexFECStatsSnapshot {
	if counters == nil {
		return FlexFECStatsSnapshot{
			SelectedFramesByTemporalID: make(map[uint8]uint64),
			GroupSizeHistogram:         make(map[int]uint64),
			TimeByTier:                 make(map[FlexFECTier]time.Duration), CurrentTier: currentTier,
		}
	}
	now := counters.now()
	counters.mutex.Lock()
	defer counters.mutex.Unlock()
	selected := make(map[uint8]uint64, len(counters.selectedFramesByTemporalID))
	for temporalID, count := range counters.selectedFramesByTemporalID {
		selected[temporalID] = count
	}
	histogram := make(map[int]uint64, len(counters.groupSizeHistogram))
	for size, count := range counters.groupSizeHistogram {
		histogram[size] = count
	}
	timeByTier := make(map[FlexFECTier]time.Duration, len(counters.timeByTier)+1)
	for tier, duration := range counters.timeByTier {
		timeByTier[tier] = duration
	}
	currentDuration := time.Duration(0)
	if !counters.tierChangedAt.IsZero() && now.After(counters.tierChangedAt) {
		currentDuration = now.Sub(counters.tierChangedAt)
	}
	timeByTier[counters.currentTier] += currentDuration
	return FlexFECStatsSnapshot{
		SelectedFramesByTemporalID: selected,
		ProtectedMediaPackets:      counters.protectedMediaPackets,
		GroupSizeHistogram:         histogram,
		FECPackets:                 counters.fecPackets,
		FECBytes:                   counters.fecBytes,
		Failures:                   counters.failures,
		DisableReason:              counters.disableReason,
		CurrentTier:                currentTier,
		TimeInCurrentTier:          currentDuration,
		TimeByTier:                 timeByTier,
	}
}
