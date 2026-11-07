package main

import (
	"errors"
	"fmt"
	"math"
	"sync"
	"time"
)

const recoveryFrameClockBudgetVersion = "frame-clock-v1"
const defaultRecoveryFrameClockBurstDuration = 20 * time.Millisecond

var errRecoveryFrameClockBudget = errors.New("invalid recovery frame-clock budget")
var errRecoveryFrameClockSuppressed = errors.New("recovery frame-clock budget suppressed packet")

type RecoveryFrameClockBudgetConfig struct {
	RateBitsPerSecond uint32
	FramesPerSecond   uint32
	BurstDuration     time.Duration
}

type RecoveryFrameClockWindowSnapshot struct {
	WindowFrames        uint64 `json:"windowFrames"`
	FirstFrameID        uint64 `json:"firstFrameID"`
	LastFrameID         uint64 `json:"lastFrameID"`
	EarnedBits          uint64 `json:"earnedBits"`
	AdmittedBits        uint64 `json:"admittedBits"`
	MediaBits           uint64 `json:"mediaBits"`
	MarginBits          int64  `json:"marginBits"`
	MediaOnlyExcessBits uint64 `json:"mediaOnlyExcessBits"`
}

type RecoveryFrameClockBudgetSnapshot struct {
	LedgerVersion             string                                      `json:"ledgerVersion"`
	RateBitsPerSecond         uint32                                      `json:"rateBitsPerSecond"`
	FramesPerSecond           uint32                                      `json:"framesPerSecond"`
	BurstDurationMilliseconds int64                                       `json:"burstDurationMilliseconds"`
	BurstCapacityBits         uint64                                      `json:"burstCapacityBits"`
	AvailableCreditBits       int64                                       `json:"availableCreditBits"`
	FirstFrameID              *uint64                                     `json:"firstFrameID,omitempty"`
	LastFrameID               *uint64                                     `json:"lastFrameID,omitempty"`
	FramesAdvanced            uint64                                      `json:"framesAdvanced"`
	CreditBitsEarned          uint64                                      `json:"creditBitsEarned"`
	CreditBitsDiscardedAtCap  uint64                                      `json:"creditBitsDiscardedAtCap"`
	MediaPackets              uint64                                      `json:"mediaPackets"`
	MediaBytes                uint64                                      `json:"mediaBytes"`
	RTXAdmittedPackets        uint64                                      `json:"rtxAdmittedPackets"`
	RTXAdmittedBytes          uint64                                      `json:"rtxAdmittedBytes"`
	RTXSuppressedPackets      uint64                                      `json:"rtxSuppressedPackets"`
	RTXSuppressedBytes        uint64                                      `json:"rtxSuppressedBytes"`
	FECAdmittedPackets        uint64                                      `json:"fecAdmittedPackets"`
	FECAdmittedBytes          uint64                                      `json:"fecAdmittedBytes"`
	FECSuppressedPackets      uint64                                      `json:"fecSuppressedPackets"`
	FECSuppressedBytes        uint64                                      `json:"fecSuppressedBytes"`
	InvalidFrameProgressions  uint64                                      `json:"invalidFrameProgressions"`
	MediaOnlyViolationCount   uint64                                      `json:"mediaOnlyViolationCount"`
	MaximumMediaDebtBits      uint64                                      `json:"maximumMediaDebtBits"`
	WorstMargins              map[string]RecoveryFrameClockWindowSnapshot `json:"worstMargins"`
}

type RecoveryFrameClockBudget struct {
	mutex sync.Mutex

	rateBitsPerSecond uint32
	framesPerSecond   uint32
	burstDuration     time.Duration
	burstCapacityBits int64
	availableCredit   int64
	creditRemainder   uint64
	hasFrame          bool
	firstFrameID      uint64
	lastFrameID       uint64
	// lastFrameByStream carries the progression invariant, which is PER STREAM. The budget's
	// CREDIT is per session and stays that way — one rate, one bucket — but "did a frame get
	// skipped" is a question about one stream's own numbering, and it only ever read as
	// session-wide because there was only ever one stream to read it on. rdev subscribes a video
	// track per source, each counting from its own base.
	lastFrameByStream    map[uint64]uint64
	framesAdvanced       uint64
	creditBitsEarned     uint64
	discardedCreditBits  uint64
	invalidProgressions  uint64
	mediaPackets         uint64
	mediaBytes           uint64
	mediaBits            uint64
	totalAdmittedBits    uint64
	rtxAdmittedPackets   uint64
	rtxAdmittedBytes     uint64
	rtxSuppressedPackets uint64
	rtxSuppressedBytes   uint64
	fecAdmittedPackets   uint64
	fecAdmittedBytes     uint64
	fecSuppressedPackets uint64
	fecSuppressedBytes   uint64
	mediaViolationCount  uint64
	maximumMediaDebtBits uint64
	frames               []recoveryFrameClockRecord
	worstMargins         map[string]RecoveryFrameClockWindowSnapshot
	mediaViolationActive map[string]bool
}

type recoveryFrameClockTotals struct {
	earnedBits   uint64
	admittedBits uint64
	mediaBits    uint64
}

type recoveryFrameClockRecord struct {
	frameID uint64
	totals  recoveryFrameClockTotals
}

func NewRecoveryFrameClockBudget(
	config RecoveryFrameClockBudgetConfig,
) (*RecoveryFrameClockBudget, error) {
	if config.RateBitsPerSecond == 0 || config.FramesPerSecond == 0 ||
		config.BurstDuration <= 0 || config.BurstDuration > 100*time.Millisecond {
		return nil, errRecoveryFrameClockBudget
	}
	capacity := uint64(config.RateBitsPerSecond) * uint64(config.BurstDuration) /
		uint64(time.Second)
	if capacity == 0 || capacity > math.MaxInt64 {
		return nil, errRecoveryFrameClockBudget
	}
	return &RecoveryFrameClockBudget{
		rateBitsPerSecond:    config.RateBitsPerSecond,
		framesPerSecond:      config.FramesPerSecond,
		burstDuration:        config.BurstDuration,
		burstCapacityBits:    int64(capacity),
		availableCredit:      int64(capacity),
		frames:               make([]recoveryFrameClockRecord, 0, 301),
		lastFrameByStream:    make(map[uint64]uint64, 2),
		worstMargins:         make(map[string]RecoveryFrameClockWindowSnapshot, 4),
		mediaViolationActive: make(map[string]bool, 4),
	}, nil
}

// AdvanceFrame is the SINGLE-STREAM spelling, and it is what the answering path uses: stock
// `llv capture-host` sends exactly one track, and it is the certification's comparison arm. It is
// AdvanceStreamFrame on stream 0 — which is also the stream id that path's eager track carries, so
// the two agree by construction rather than by coincidence.
func (budget *RecoveryFrameClockBudget) AdvanceFrame(frameID uint64) error {
	return budget.AdvanceStreamFrame(0, frameID)
}

// AdvanceStreamFrame ticks the clock for one frame of one stream.
//
// THE CREDIT IS STILL EARNED PER ADVANCE, AND WITH N STREAMS THAT IS N TIMES PER FRAME PERIOD.
// Stated rather than hidden: the bucket is a session-wide rate, so N concurrently sending sources
// earn N x the intended credit and the egress bound is correspondingly looser. It is a LOOSER
// GUARD, not a broken one, and it is slack to begin with — the rate is rdev's bitrate CAP
// (20 Mbit/s) while a source actually streams around 2. Tightening it needs a clock that is not
// "a frame started", which is a change to the ledger's determinism and therefore to what the
// certification harness reproduces. The progression invariant below is the half that was
// silently fatal, and it is the half fixed here.
func (budget *RecoveryFrameClockBudget) AdvanceStreamFrame(streamID, frameID uint64) error {
	if budget == nil {
		return errRecoveryFrameClockBudget
	}
	budget.mutex.Lock()
	defer budget.mutex.Unlock()
	lastForStream, seenStream := budget.lastFrameByStream[streamID]
	if seenStream &&
		(lastForStream == math.MaxUint64 || frameID != lastForStream+1) {
		if budget.invalidProgressions == math.MaxUint64 {
			return errRecoveryFrameClockBudget
		}
		budget.invalidProgressions++
		return errRecoveryFrameClockBudget
	}
	if budget.framesAdvanced == math.MaxUint64 {
		return errRecoveryFrameClockBudget
	}
	credit := uint64(budget.rateBitsPerSecond / budget.framesPerSecond)
	creditRemainder := budget.creditRemainder +
		uint64(budget.rateBitsPerSecond%budget.framesPerSecond)
	credit += creditRemainder / uint64(budget.framesPerSecond)
	creditRemainder %= uint64(budget.framesPerSecond)
	if math.MaxUint64-budget.creditBitsEarned < credit {
		return errRecoveryFrameClockBudget
	}
	uncapped := budget.availableCredit + int64(credit)
	discarded := uint64(0)
	if uncapped > budget.burstCapacityBits {
		discarded = uint64(uncapped - budget.burstCapacityBits)
		if math.MaxUint64-budget.discardedCreditBits < discarded {
			return errRecoveryFrameClockBudget
		}
		uncapped = budget.burstCapacityBits
	}
	if !budget.hasFrame {
		budget.hasFrame = true
		budget.firstFrameID = frameID
	}
	budget.lastFrameID = frameID
	budget.lastFrameByStream[streamID] = frameID
	budget.framesAdvanced++
	budget.creditRemainder = creditRemainder
	budget.creditBitsEarned += credit
	budget.discardedCreditBits += discarded
	budget.availableCredit = uncapped
	budget.frames = append(budget.frames, recoveryFrameClockRecord{
		frameID: frameID,
		totals: recoveryFrameClockTotals{
			earnedBits:   budget.creditBitsEarned,
			admittedBits: budget.totalAdmittedBits,
			mediaBits:    budget.mediaBits,
		},
	})
	if len(budget.frames) > 301 {
		copy(budget.frames, budget.frames[len(budget.frames)-301:])
		budget.frames = budget.frames[:301]
	}
	return budget.evaluateInvariantsLocked()
}

func frameClockPacketBits(packetBytes int) (int64, error) {
	if packetBytes <= 0 || uint64(packetBytes) > uint64(math.MaxInt64/8) {
		return 0, errRecoveryFrameClockBudget
	}
	return int64(packetBytes) * 8, nil
}

func (budget *RecoveryFrameClockBudget) ObserveMedia(packetBytes int) error {
	if budget == nil {
		return errRecoveryFrameClockBudget
	}
	packetBits, err := frameClockPacketBits(packetBytes)
	if err != nil {
		return err
	}
	budget.mutex.Lock()
	defer budget.mutex.Unlock()
	if !budget.hasFrame || budget.availableCredit < math.MinInt64+packetBits ||
		math.MaxUint64-budget.mediaBits < uint64(packetBits) ||
		math.MaxUint64-budget.totalAdmittedBits < uint64(packetBits) ||
		budget.mediaPackets == math.MaxUint64 ||
		math.MaxUint64-budget.mediaBytes < uint64(packetBytes) {
		return errRecoveryFrameClockBudget
	}
	budget.mediaPackets++
	budget.mediaBytes += uint64(packetBytes)
	budget.mediaBits += uint64(packetBits)
	budget.totalAdmittedBits += uint64(packetBits)
	budget.availableCredit -= packetBits
	if budget.availableCredit < 0 {
		debt := uint64(-(budget.availableCredit + 1)) + 1
		if debt > budget.maximumMediaDebtBits {
			budget.maximumMediaDebtBits = debt
		}
	}
	budget.updateCurrentFrameLocked()
	return budget.evaluateInvariantsLocked()
}

func (budget *RecoveryFrameClockBudget) TryAdmitRecovery(
	class TWCCPacketClass,
	packetBytes int,
) (bool, error) {
	if budget == nil || (class != TWCCRTX && class != TWCCFEC) {
		return false, errRecoveryFrameClockBudget
	}
	packetBits, err := frameClockPacketBits(packetBytes)
	if err != nil {
		return false, err
	}
	budget.mutex.Lock()
	defer budget.mutex.Unlock()
	if !budget.hasFrame {
		return false, errRecoveryFrameClockBudget
	}
	admitted := budget.availableCredit >= packetBits
	packets := &budget.rtxSuppressedPackets
	bytes := &budget.rtxSuppressedBytes
	if class == TWCCFEC {
		packets = &budget.fecSuppressedPackets
		bytes = &budget.fecSuppressedBytes
	}
	if admitted && class == TWCCRTX {
		packets = &budget.rtxAdmittedPackets
		bytes = &budget.rtxAdmittedBytes
	} else if admitted {
		packets = &budget.fecAdmittedPackets
		bytes = &budget.fecAdmittedBytes
	}
	if *packets == math.MaxUint64 || math.MaxUint64-*bytes < uint64(packetBytes) {
		return false, errRecoveryFrameClockBudget
	}
	if admitted && math.MaxUint64-budget.totalAdmittedBits < uint64(packetBits) {
		return false, errRecoveryFrameClockBudget
	}
	if admitted {
		budget.availableCredit -= packetBits
		budget.totalAdmittedBits += uint64(packetBits)
	}
	*packets++
	*bytes += uint64(packetBytes)
	if admitted {
		budget.updateCurrentFrameLocked()
		if err := budget.evaluateInvariantsLocked(); err != nil {
			return false, err
		}
	}
	return admitted, nil
}

func (budget *RecoveryFrameClockBudget) updateCurrentFrameLocked() {
	if len(budget.frames) == 0 {
		return
	}
	budget.frames[len(budget.frames)-1].totals = recoveryFrameClockTotals{
		earnedBits:   budget.creditBitsEarned,
		admittedBits: budget.totalAdmittedBits,
		mediaBits:    budget.mediaBits,
	}
}

func recoveryFrameClockMargin(allowedBits, admittedBits uint64) (int64, error) {
	if allowedBits >= admittedBits {
		difference := allowedBits - admittedBits
		if difference > math.MaxInt64 {
			return 0, errRecoveryFrameClockBudget
		}
		return int64(difference), nil
	}
	difference := admittedBits - allowedBits
	if difference > uint64(math.MaxInt64)+1 {
		return 0, errRecoveryFrameClockBudget
	}
	if difference == uint64(math.MaxInt64)+1 {
		return math.MinInt64, nil
	}
	return -int64(difference), nil
}

func (budget *RecoveryFrameClockBudget) evaluateInvariantsLocked() error {
	if len(budget.frames) == 0 {
		return nil
	}
	if err := budget.evaluateWindowLocked("prefix", uint64(budget.framesAdvanced), 0); err != nil {
		return err
	}
	for _, windowFrames := range []uint64{60, 120, 300} {
		if budget.framesAdvanced < windowFrames || uint64(len(budget.frames)) < windowFrames {
			continue
		}
		start := len(budget.frames) - int(windowFrames)
		if err := budget.evaluateWindowLocked(fmt.Sprintf("%d", windowFrames), windowFrames, start); err != nil {
			return err
		}
	}
	return nil
}

func (budget *RecoveryFrameClockBudget) evaluateWindowLocked(
	key string,
	windowFrames uint64,
	start int,
) error {
	current := budget.frames[len(budget.frames)-1]
	var prior recoveryFrameClockTotals
	if start > 0 {
		prior = budget.frames[start-1].totals
	}
	earnedBits := current.totals.earnedBits - prior.earnedBits
	admittedBits := current.totals.admittedBits - prior.admittedBits
	mediaBits := current.totals.mediaBits - prior.mediaBits
	allowedBits := uint64(budget.burstCapacityBits)
	if math.MaxUint64-allowedBits < earnedBits {
		return errRecoveryFrameClockBudget
	}
	allowedBits += earnedBits
	marginBits, err := recoveryFrameClockMargin(allowedBits, admittedBits)
	if err != nil {
		return err
	}
	mediaOnlyExcessBits := uint64(0)
	if mediaBits > allowedBits {
		mediaOnlyExcessBits = mediaBits - allowedBits
	}
	firstFrameID := budget.frames[start].frameID
	if key == "prefix" {
		firstFrameID = budget.firstFrameID
	}
	window := RecoveryFrameClockWindowSnapshot{
		WindowFrames:        windowFrames,
		FirstFrameID:        firstFrameID,
		LastFrameID:         current.frameID,
		EarnedBits:          earnedBits,
		AdmittedBits:        admittedBits,
		MediaBits:           mediaBits,
		MarginBits:          marginBits,
		MediaOnlyExcessBits: mediaOnlyExcessBits,
	}
	if previous, exists := budget.worstMargins[key]; !exists || window.MarginBits < previous.MarginBits {
		budget.worstMargins[key] = window
	}
	violated := mediaOnlyExcessBits > 0
	if violated && !budget.mediaViolationActive[key] {
		if budget.mediaViolationCount == math.MaxUint64 {
			return errRecoveryFrameClockBudget
		}
		budget.mediaViolationCount++
	}
	budget.mediaViolationActive[key] = violated
	return nil
}

func (budget *RecoveryFrameClockBudget) Snapshot() RecoveryFrameClockBudgetSnapshot {
	if budget == nil {
		return RecoveryFrameClockBudgetSnapshot{}
	}
	budget.mutex.Lock()
	defer budget.mutex.Unlock()
	snapshot := RecoveryFrameClockBudgetSnapshot{
		LedgerVersion:             recoveryFrameClockBudgetVersion,
		RateBitsPerSecond:         budget.rateBitsPerSecond,
		FramesPerSecond:           budget.framesPerSecond,
		BurstDurationMilliseconds: budget.burstDuration.Milliseconds(),
		BurstCapacityBits:         uint64(budget.burstCapacityBits),
		AvailableCreditBits:       budget.availableCredit,
		FramesAdvanced:            budget.framesAdvanced,
		CreditBitsEarned:          budget.creditBitsEarned,
		CreditBitsDiscardedAtCap:  budget.discardedCreditBits,
		MediaPackets:              budget.mediaPackets,
		MediaBytes:                budget.mediaBytes,
		RTXAdmittedPackets:        budget.rtxAdmittedPackets,
		RTXAdmittedBytes:          budget.rtxAdmittedBytes,
		RTXSuppressedPackets:      budget.rtxSuppressedPackets,
		RTXSuppressedBytes:        budget.rtxSuppressedBytes,
		FECAdmittedPackets:        budget.fecAdmittedPackets,
		FECAdmittedBytes:          budget.fecAdmittedBytes,
		FECSuppressedPackets:      budget.fecSuppressedPackets,
		FECSuppressedBytes:        budget.fecSuppressedBytes,
		InvalidFrameProgressions:  budget.invalidProgressions,
		MediaOnlyViolationCount:   budget.mediaViolationCount,
		MaximumMediaDebtBits:      budget.maximumMediaDebtBits,
		WorstMargins:              make(map[string]RecoveryFrameClockWindowSnapshot, len(budget.worstMargins)),
	}
	for key, margin := range budget.worstMargins {
		snapshot.WorstMargins[key] = margin
	}
	if budget.hasFrame {
		first := budget.firstFrameID
		last := budget.lastFrameID
		snapshot.FirstFrameID = &first
		snapshot.LastFrameID = &last
	}
	return snapshot
}
