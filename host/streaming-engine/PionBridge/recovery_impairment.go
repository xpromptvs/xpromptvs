package main

import (
	"container/heap"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"math/bits"
	"math/rand"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/transport/v4"
)

type recoveryMatrixEndpoint string

const (
	matrixHost   recoveryMatrixEndpoint = "host"
	matrixViewer recoveryMatrixEndpoint = "viewer"
)

type recoveryPacketClass string

const (
	matrixPacketLegacyOriginalSeed recoveryPacketClass = "original"
	matrixPacketMedia              recoveryPacketClass = "media"
	matrixPacketOriginal           recoveryPacketClass = matrixPacketMedia
	matrixPacketFEC                recoveryPacketClass = "fec"
	matrixPacketRTX                recoveryPacketClass = "rtx"
	matrixPacketNACK               recoveryPacketClass = "nack"
	matrixPacketPLIFIR             recoveryPacketClass = "pli-fir"
	matrixPacketTWCC               recoveryPacketClass = "twcc"
	matrixPacketOtherRTCP          recoveryPacketClass = "other-rtcp"
	matrixPacketOther              recoveryPacketClass = "other"
)

func (class *recoveryPacketClass) UnmarshalText(text []byte) error {
	value := recoveryPacketClass(text)
	if value == "original" {
		value = matrixPacketMedia
	}
	for _, candidate := range recoveryPacketClasses() {
		if value == candidate {
			*class = value
			return nil
		}
	}
	return fmt.Errorf("unknown recovery packet class %q", text)
}

func recoveryPacketClasses() []recoveryPacketClass {
	return []recoveryPacketClass{
		matrixPacketMedia, matrixPacketFEC, matrixPacketRTX, matrixPacketNACK,
		matrixPacketPLIFIR, matrixPacketTWCC, matrixPacketOtherRTCP,
		matrixPacketOther,
	}
}

type recoveryDatagramClassification struct {
	Endpoint        recoveryMatrixEndpoint
	Class           recoveryPacketClass
	RTPSequence     *uint16
	RTPTimestamp    *uint32
	Bytes           int
	WireFingerprint string
	traceOrdinal    uint64

	OriginalFrameOrdinal     uint64
	OriginalFramePacketIndex uint64
}

const (
	matrixActionAdmit              = "admit"
	matrixActionDrop               = "drop"
	matrixActionDuplicateImmediate = "duplicate-immediate"
	matrixActionDuplicateDelayed   = "duplicate-delayed"
)

type recoveryImpairmentDecision struct {
	Endpoint                 recoveryMatrixEndpoint `json:"endpoint"`
	Class                    recoveryPacketClass    `json:"class"`
	ClassOrdinal             uint64                 `json:"classOrdinal"`
	OriginalFrameOrdinal     uint64                 `json:"originalFrameOrdinal,omitempty"`
	OriginalFramePacketIndex uint64                 `json:"originalFramePacketIndex,omitempty"`
	RTPSequence              *uint16                `json:"rtpSequence,omitempty"`
	Action                   string                 `json:"action"`
	DelayMicroseconds        int                    `json:"delayMicroseconds,omitempty"`
	ElapsedMicroseconds      int64                  `json:"elapsedMicroseconds"`
	Bytes                    int                    `json:"bytes"`

	duplicateDelayMicroseconds int
}

type recoveryNACKAttempt struct {
	ObservedAt time.Time
}

type recoveryPacketTotals struct {
	Packets uint64 `json:"packets"`
	Bytes   uint64 `json:"bytes"`
}

const recoveryBandwidthQueueModelVirtualFluid = "virtual-fluid-v1"

type recoveryBandwidthQueue struct {
	rateBitsPerSecond uint64
	capacityBits      uint64
	queuedBits        uint64
	updatedAt         time.Time
}

func newRecoveryBandwidthQueue(
	rateBitsPerSecond int64,
	capacityBytes uint64,
) (recoveryBandwidthQueue, error) {
	if rateBitsPerSecond <= 0 {
		return recoveryBandwidthQueue{}, errors.New("bandwidth queue rate must be positive")
	}
	if capacityBytes == 0 {
		return recoveryBandwidthQueue{}, errors.New("bandwidth queue capacity must be positive")
	}
	if capacityBytes > math.MaxUint64/8 {
		return recoveryBandwidthQueue{}, errors.New("bandwidth queue capacity overflows bits")
	}
	return recoveryBandwidthQueue{
		rateBitsPerSecond: uint64(rateBitsPerSecond),
		capacityBits:      capacityBytes * 8,
	}, nil
}

func (queue *recoveryBandwidthQueue) reserve(
	arrival time.Time,
	packetBytes uint64,
) (time.Time, bool, error) {
	if packetBytes == 0 {
		return time.Time{}, false, errors.New("bandwidth queue packet must not be empty")
	}
	if packetBytes > math.MaxUint64/8 {
		return time.Time{}, false, errors.New("bandwidth queue packet size overflows bits")
	}
	if !queue.updatedAt.IsZero() && arrival.Before(queue.updatedAt) {
		return time.Time{}, false, errors.New("bandwidth queue arrival moved backwards")
	}

	if queue.updatedAt.IsZero() {
		queue.updatedAt = arrival
	} else {
		elapsedNanoseconds := uint64(arrival.Sub(queue.updatedAt))
		drained := recoveryMulDivFloorCapped(
			elapsedNanoseconds,
			queue.rateBitsPerSecond,
			uint64(time.Second),
			queue.queuedBits,
		)
		queue.queuedBits -= drained
		queue.updatedAt = arrival
	}

	packetBits := packetBytes * 8
	if packetBits > queue.capacityBits-queue.queuedBits {
		return time.Time{}, false, nil
	}
	newQueuedBits := queue.queuedBits + packetBits
	serializationNanoseconds, err := recoveryMulDivCeilDuration(
		newQueuedBits,
		uint64(time.Second),
		queue.rateBitsPerSecond,
	)
	if err != nil {
		return time.Time{}, false, err
	}
	queue.queuedBits = newQueuedBits
	return arrival.Add(serializationNanoseconds), true, nil
}

func (queue *recoveryBandwidthQueue) reset() {
	queue.queuedBits = 0
	queue.updatedAt = time.Time{}
}

func recoveryMulDivFloorCapped(
	left uint64,
	right uint64,
	divisor uint64,
	limit uint64,
) uint64 {
	if limit == 0 {
		return 0
	}
	productHigh, productLow := bits.Mul64(left, right)
	limitHigh, limitLow := bits.Mul64(limit, divisor)
	if productHigh > limitHigh ||
		(productHigh == limitHigh && productLow >= limitLow) {
		return limit
	}
	quotient, _ := bits.Div64(productHigh, productLow, divisor)
	return quotient
}

func recoveryMulDivCeilDuration(
	left uint64,
	right uint64,
	divisor uint64,
) (time.Duration, error) {
	productHigh, productLow := bits.Mul64(left, right)
	if productHigh >= divisor {
		return 0, errors.New("bandwidth queue serialization duration overflows")
	}
	quotient, remainder := bits.Div64(productHigh, productLow, divisor)
	if remainder != 0 {
		if quotient == math.MaxUint64 {
			return 0, errors.New("bandwidth queue serialization duration overflows")
		}
		quotient++
	}
	if quotient > math.MaxInt64 {
		return 0, errors.New("bandwidth queue serialization duration exceeds time.Duration")
	}
	return time.Duration(quotient), nil
}

type RecoveryImpairmentSnapshot struct {
	Attempted                    map[recoveryPacketClass]recoveryPacketTotals `json:"attempted"`
	ControllerDropped            map[recoveryPacketClass]recoveryPacketTotals `json:"controllerDropped"`
	AdmittedToVNet               map[recoveryPacketClass]recoveryPacketTotals `json:"admittedToVnet"`
	Delivered                    map[recoveryPacketClass]recoveryPacketTotals `json:"delivered"`
	EffectiveQueueDropped        map[recoveryPacketClass]recoveryPacketTotals `json:"effectiveQueueDropped"`
	DuplicatesScheduled          recoveryPacketTotals                         `json:"duplicatesScheduled"`
	ScheduledBytesCurrent        uint64                                       `json:"scheduledBytesCurrent"`
	ScheduledBytesPeak           uint64                                       `json:"scheduledBytesPeak"`
	OutstandingMediaBytesCurrent uint64                                       `json:"outstandingMediaBytesCurrent"`
	OutstandingMediaBytesPeak    uint64                                       `json:"outstandingMediaBytesPeak"`
	DecisionCount                uint64                                       `json:"decisionCount"`
	DecisionSHA256               string                                       `json:"decisionSha256"`
	SourceCoordinateDrops        []RecoveryMatrixSourceCoordinate             `json:"sourceCoordinateDrops"`
	BandwidthQueueModel          string                                       `json:"bandwidthQueueModel,omitempty"`
}

type RecoveryImpairmentController struct {
	pathGate                    sync.RWMutex
	mu                          sync.Mutex
	profile                     RecoveryMatrixProfile
	active                      bool
	accepting                   bool
	activatedAt                 time.Time
	closed                      bool
	ordinals                    map[string]uint64
	random                      map[string]*rand.Rand
	decisions                   []recoveryImpairmentDecision
	attempted                   map[recoveryPacketClass]recoveryPacketTotals
	dropped                     map[recoveryPacketClass]recoveryPacketTotals
	admitted                    map[recoveryPacketClass]recoveryPacketTotals
	delivered                   map[recoveryPacketClass]recoveryPacketTotals
	duplicates                  recoveryPacketTotals
	scheduledNow                uint64
	scheduledPeak               uint64
	outstandingNow              uint64
	outstandingPeak             uint64
	pending                     uint64
	changed                     chan struct{}
	asyncError                  error
	schedulers                  map[recoveryMatrixEndpoint]*recoveryImpairmentScheduler
	readPumps                   map[*recoveryImpairmentReadPump]struct{}
	nackAttempts                chan recoveryNACKAttempt
	nackAttempt                 func()
	meterWrites                 bool
	bandwidthRateBitsPerSecond  int64
	bandwidthDuration           time.Duration
	bandwidthQueueBytes         uint64
	bandwidthQueues             map[recoveryMatrixEndpoint]*recoveryBandwidthQueue
	originalPayloadType         uint8
	originalSSRC                uint32
	hasOriginalStream           bool
	flexFECPayloadType          uint8
	flexFECSSRC                 uint32
	hasFlexFECStream            bool
	decisionOriginalTimestamp   uint32
	hasDecisionOriginalTime     bool
	decisionOriginalFrame       uint64
	decisionOriginalPacket      uint64
	recoveryOutstanding         bool
	decryptedRTCPClassification bool
	trace                       *recoveryTraceRecorder
	traceReadID                 atomic.Int64
}

type RecoveryImpairmentConfiguration struct {
	Profile RecoveryMatrixProfile
	Seed    int64
	Trace   *recoveryTraceRecorder
}

func NewRecoveryImpairmentController(
	configuration RecoveryImpairmentConfiguration,
) (*RecoveryImpairmentController, error) {
	if err := validateRecoveryMatrixProfile(configuration.Profile); err != nil {
		return nil, fmt.Errorf("invalid recovery impairment configuration: %w", err)
	}
	profile := cloneRecoveryMatrixProfile(configuration.Profile)
	profile.Seed = new(int64)
	*profile.Seed = configuration.Seed
	controller := newRecoveryImpairmentController(profile)
	controller.trace = configuration.Trace
	controller.meterWrites = true
	if profile.BandwidthPermille > 0 {
		controller.bandwidthRateBitsPerSecond = int64(
			profile.NominalMediaBitsPerSecond * profile.BandwidthPermille / 1_000,
		)
		controller.bandwidthDuration =
			time.Duration(profile.BandwidthDurationMilliseconds) * time.Millisecond
		deltaBytes := (profile.NominalMediaBitsPerSecond + profile.FPS*8 - 1) /
			(profile.FPS * 8)
		largestFrameBytes := deltaBytes * profile.KeyframeSizeMultiplier
		const conservativePayloadBytes = maximumRTPBytes - 128
		packetsPerFrame := (largestFrameBytes + conservativePayloadBytes - 1) /
			conservativePayloadBytes
		controller.bandwidthQueueBytes = uint64(
			packetsPerFrame * maximumRTPBytes * profile.QueueFrames,
		)
		controller.bandwidthQueues = make(map[recoveryMatrixEndpoint]*recoveryBandwidthQueue, 2)
		for _, endpoint := range []recoveryMatrixEndpoint{matrixHost, matrixViewer} {
			queue, err := newRecoveryBandwidthQueue(
				controller.bandwidthRateBitsPerSecond,
				controller.bandwidthQueueBytes,
			)
			if err != nil {
				_ = controller.Close()
				return nil, fmt.Errorf("configure %s bandwidth queue: %w", endpoint, err)
			}
			controller.bandwidthQueues[endpoint] = &queue
		}
	}
	return controller, nil
}

func newRecoveryImpairmentController(profile RecoveryMatrixProfile) *RecoveryImpairmentController {
	controller := &RecoveryImpairmentController{
		profile:      profile,
		ordinals:     make(map[string]uint64),
		random:       make(map[string]*rand.Rand),
		attempted:    make(map[recoveryPacketClass]recoveryPacketTotals),
		dropped:      make(map[recoveryPacketClass]recoveryPacketTotals),
		admitted:     make(map[recoveryPacketClass]recoveryPacketTotals),
		delivered:    make(map[recoveryPacketClass]recoveryPacketTotals),
		changed:      make(chan struct{}),
		nackAttempts: make(chan recoveryNACKAttempt, 256),
		schedulers:   make(map[recoveryMatrixEndpoint]*recoveryImpairmentScheduler, 2),
		readPumps:    make(map[*recoveryImpairmentReadPump]struct{}),
	}
	controller.schedulers[matrixHost] = newRecoveryImpairmentScheduler(controller)
	controller.schedulers[matrixViewer] = newRecoveryImpairmentScheduler(controller)
	return controller
}

func (controller *RecoveryImpairmentController) Activate() error {
	controller.pathGate.Lock()
	defer controller.pathGate.Unlock()
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.closed {
		return net.ErrClosed
	}
	if controller.active {
		return nil
	}
	controller.active = true
	controller.accepting = true
	controller.activatedAt = time.Now()
	controller.resetBandwidthQueuesLocked()
	return nil
}

func (controller *RecoveryImpairmentController) SetNACKAttemptCallback(callback func()) {
	controller.mu.Lock()
	controller.nackAttempt = callback
	controller.mu.Unlock()
}

func (controller *RecoveryImpairmentController) enableDecryptedRTCPClassification() {
	controller.mu.Lock()
	controller.decryptedRTCPClassification = true
	controller.mu.Unlock()
}

func (controller *RecoveryImpairmentController) filterIncomingRTCP(
	packets []rtcp.Packet,
) ([]rtcp.Packet, error) {
	controller.pathGate.RLock()
	defer controller.pathGate.RUnlock()
	controller.mu.Lock()
	active := controller.active && controller.accepting && !controller.closed
	controller.mu.Unlock()
	if !active {
		return packets, nil
	}
	kept := make([]rtcp.Packet, 0, len(packets))
	for _, packet := range packets {
		encoded, err := packet.Marshal()
		if err != nil {
			return nil, fmt.Errorf("marshal decrypted RTCP for impairment: %w", err)
		}
		classification := classifyRecoveryRTCPPacket(matrixViewer, packet, encoded)
		decision := controller.decide(classification)
		classification.traceOrdinal = decision.ClassOrdinal
		if decision.Action == matrixActionDrop {
			continue
		}
		controller.recordAdmitted(classification)
		controller.recordDelivered(classification)
		kept = append(kept, packet)
	}
	return kept, nil
}

func (controller *RecoveryImpairmentController) SetFlexFECIdentity(
	payloadType uint8,
	ssrc uint32,
) {
	controller.mu.Lock()
	controller.flexFECPayloadType = payloadType
	controller.flexFECSSRC = ssrc
	controller.hasFlexFECStream = payloadType != 0 && ssrc != 0
	controller.mu.Unlock()
}

func isRecoveryMediaClass(class recoveryPacketClass) bool {
	return class == matrixPacketOriginal || class == matrixPacketFEC || class == matrixPacketRTX
}

func (controller *RecoveryImpairmentController) decide(classification recoveryDatagramClassification) recoveryImpairmentDecision {
	controller.mu.Lock()
	observedAt := time.Now()
	controller.assignOriginalCoordinateLocked(&classification)

	key := fmt.Sprintf("%s/%s", classification.Endpoint, classification.Class)
	controller.ordinals[key]++
	decision := recoveryImpairmentDecision{
		Endpoint: classification.Endpoint, Class: classification.Class,
		ClassOrdinal: controller.ordinals[key], RTPSequence: classification.RTPSequence,
		OriginalFrameOrdinal:     classification.OriginalFrameOrdinal,
		OriginalFramePacketIndex: classification.OriginalFramePacketIndex,
		Action:                   matrixActionAdmit, Bytes: classification.Bytes,
	}
	if controller.active {
		decision.ElapsedMicroseconds = observedAt.Sub(controller.activatedAt).Microseconds()
	}
	decision.DelayMicroseconds = controller.profile.OneWayDelayMicroseconds
	if controller.profile.MaxJitterMicroseconds > 0 {
		decision.DelayMicroseconds += controller.randomIntnLocked(classification, "jitter",
			controller.profile.MaxJitterMicroseconds+1,
		)
	}

	shouldDrop := controller.matchesBurstLocked(decision)
	if decision.ClassOrdinal == 1 {
		shouldDrop = shouldDrop ||
			(classification.Class == matrixPacketFEC && controller.profile.DropFirstFEC) ||
			(classification.Class == matrixPacketNACK && controller.profile.DropFirstNACK) ||
			(classification.Class == matrixPacketRTX && controller.profile.DropFirstRTX) ||
			(classification.Class == matrixPacketTWCC && controller.profile.DropFirstTWCC)
	}
	if !shouldDrop {
		basisPoints := controller.lossBasisPointsLocked(classification.Class)
		shouldDrop = basisPoints > 0 &&
			controller.randomIntnLocked(classification, "loss", 10_000) < basisPoints
	}
	if shouldDrop {
		decision.Action = matrixActionDrop
		if classification.Class == matrixPacketOriginal {
			controller.recoveryOutstanding = true
		}
	} else if classification.Class == matrixPacketOriginal {
		if basisPoints := controller.profile.ImmediateDuplicationBasisPoints; basisPoints > 0 &&
			controller.randomIntnLocked(classification, "duplicate-immediate", 10_000) < basisPoints {
			decision.Action = matrixActionDuplicateImmediate
		} else if basisPoints := controller.profile.DelayedDuplicationBasisPoints; basisPoints > 0 &&
			controller.randomIntnLocked(classification, "duplicate-delayed", 10_000) < basisPoints {
			decision.Action = matrixActionDuplicateDelayed
			minimum := controller.profile.DuplicationDelayMinMicroseconds
			width := controller.profile.DuplicationDelayMaxMicroseconds - minimum
			decision.duplicateDelayMicroseconds = minimum
			if width > 0 {
				decision.duplicateDelayMicroseconds += controller.randomIntnLocked(
					classification, "duplicate-delay", width+1,
				)
			}
		}
	}

	controller.decisions = append(controller.decisions, decision)
	controller.addTotalsLocked(controller.attempted, classification.Class, classification.Bytes)
	if decision.Action == matrixActionDrop {
		controller.addTotalsLocked(controller.dropped, classification.Class, classification.Bytes)
	}
	callback := controller.nackAttempt
	trace := controller.trace
	if classification.Class == matrixPacketNACK && callback == nil {
		select {
		case controller.nackAttempts <- recoveryNACKAttempt{ObservedAt: observedAt}:
		default:
			if controller.asyncError == nil {
				controller.asyncError = errors.New("recovery impairment NACK event buffer overflow")
			}
		}
	}
	controller.mu.Unlock()
	if decision.Action == matrixActionDrop && classification.Class == matrixPacketOriginal {
		trace.Record(recoveryTraceEvent{
			Layer: traceLayerImpairment, Kind: traceOriginalDropped,
			RTPSequence:  classification.RTPSequence,
			RTPTimestamp: classification.RTPTimestamp,
		})
	}
	if classification.Class == matrixPacketNACK {
		action := decision.Action
		traceOrdinal := int64(decision.ClassOrdinal)
		wireFingerprint, packetSize := recoveryNACKTraceIdentity(classification)
		trace.Record(recoveryTraceEvent{
			Layer: traceLayerImpairment, Kind: traceNACKSocketAttempted,
			RTPSequence: classification.RTPSequence, Reason: &action,
			NumericValue:    &traceOrdinal,
			WireFingerprint: wireFingerprint,
			PacketSize:      packetSize,
		})
	}
	if classification.Class == matrixPacketNACK && callback != nil {
		callback()
	}
	return decision
}

func (controller *RecoveryImpairmentController) assignOriginalCoordinateLocked(
	classification *recoveryDatagramClassification,
) {
	if classification.Class != matrixPacketOriginal || classification.RTPTimestamp == nil {
		return
	}
	timestamp := *classification.RTPTimestamp
	if !controller.hasDecisionOriginalTime ||
		timestamp != controller.decisionOriginalTimestamp {
		controller.decisionOriginalFrame++
		controller.decisionOriginalPacket = 1
		controller.decisionOriginalTimestamp = timestamp
		controller.hasDecisionOriginalTime = true
	} else {
		controller.decisionOriginalPacket++
	}
	classification.OriginalFrameOrdinal = controller.decisionOriginalFrame
	classification.OriginalFramePacketIndex = controller.decisionOriginalPacket
}

func (controller *RecoveryImpairmentController) matchesBurstLocked(decision recoveryImpairmentDecision) bool {
	if decision.Class != matrixPacketOriginal {
		return false
	}
	for _, burst := range controller.profile.Bursts {
		switch burst.SelectorType {
		case "":
			end := burst.StartOriginalOrdinal + burst.Length
			if decision.ClassOrdinal >= burst.StartOriginalOrdinal && decision.ClassOrdinal < end {
				return true
			}
		case matrixBurstSourceCoordinates:
			for _, coordinate := range burst.SourceCoordinates {
				if decision.OriginalFrameOrdinal == coordinate.FrameOrdinal &&
					decision.OriginalFramePacketIndex == coordinate.PacketIndex {
					return true
				}
			}
		}
	}
	return false
}

func (controller *RecoveryImpairmentController) lossBasisPointsLocked(class recoveryPacketClass) int {
	switch class {
	case matrixPacketOriginal:
		return controller.profile.MediaLossBasisPoints
	case matrixPacketFEC:
		return controller.profile.FECLossBasisPoints
	case matrixPacketRTX:
		return controller.profile.RTXLossBasisPoints
	case matrixPacketNACK:
		return controller.profile.NACKLossBasisPoints
	case matrixPacketTWCC:
		return controller.profile.TWCCLossBasisPoints
	default:
		return 0
	}
}

func (controller *RecoveryImpairmentController) randomLocked(classification recoveryDatagramClassification, purpose string) *rand.Rand {
	seedClass := classification.Class
	// Preserve the established deterministic media-loss coordinates while the
	// external report vocabulary migrates from "original" to "media".
	if seedClass == matrixPacketMedia {
		seedClass = matrixPacketLegacyOriginalSeed
	}
	key := fmt.Sprintf("%s/%s/%s", classification.Endpoint, seedClass, purpose)
	if existing := controller.random[key]; existing != nil {
		return existing
	}
	seed := int64(0)
	if controller.profile.Seed != nil {
		seed = *controller.profile.Seed
	}
	seed = deriveRecoveryMatrixSeed(
		seed, classification.Endpoint, seedClass, purpose,
	)
	controller.random[key] = rand.New(rand.NewSource(seed))
	return controller.random[key]
}

func (controller *RecoveryImpairmentController) randomIntnLocked(
	classification recoveryDatagramClassification,
	purpose string,
	bound int,
) int {
	if classification.Class != matrixPacketOriginal ||
		classification.OriginalFrameOrdinal == 0 ||
		classification.OriginalFramePacketIndex == 0 {
		return controller.randomLocked(classification, purpose).Intn(bound)
	}
	seed := int64(0)
	if controller.profile.Seed != nil {
		seed = *controller.profile.Seed
	}
	seed = deriveRecoveryOriginalCoordinateSeed(
		seed,
		classification.Endpoint,
		purpose,
		classification.OriginalFrameOrdinal,
		classification.OriginalFramePacketIndex,
	)
	return rand.New(rand.NewSource(seed)).Intn(bound)
}

func deriveRecoveryOriginalCoordinateSeed(
	seed int64,
	endpoint recoveryMatrixEndpoint,
	purpose string,
	frameOrdinal uint64,
	packetIndex uint64,
) int64 {
	hasher := fnv.New64a()
	_, _ = fmt.Fprintf(
		hasher, "%d/%s/%s/%s/%d/%d",
		seed, endpoint, matrixPacketLegacyOriginalSeed, purpose, frameOrdinal, packetIndex,
	)
	return int64(hasher.Sum64())
}

func deriveRecoveryMatrixSeed(
	seed int64,
	endpoint recoveryMatrixEndpoint,
	class recoveryPacketClass,
	purpose string,
) int64 {
	hasher := fnv.New64a()
	_, _ = fmt.Fprintf(hasher, "%d/%s/%s/%s", seed, endpoint, class, purpose)
	return int64(hasher.Sum64())
}

func (controller *RecoveryImpairmentController) addTotalsLocked(
	totals map[recoveryPacketClass]recoveryPacketTotals,
	class recoveryPacketClass,
	bytes int,
) {
	current := totals[class]
	current.Packets++
	current.Bytes += uint64(bytes)
	totals[class] = current
}

func (controller *RecoveryImpairmentController) Snapshot() RecoveryImpairmentSnapshot {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	hasher := sha256.New()
	var sourceCoordinateDrops []RecoveryMatrixSourceCoordinate
	for _, decision := range controller.decisions {
		canonical := decision
		canonical.ElapsedMicroseconds = 0
		encoded, err := json.Marshal(canonical)
		if err != nil {
			panic(err)
		}
		hasher.Write(encoded)
		hasher.Write([]byte{'\n'})
		if decision.Class == matrixPacketOriginal && decision.Action == matrixActionDrop &&
			decision.OriginalFrameOrdinal != 0 && decision.OriginalFramePacketIndex != 0 {
			sourceCoordinateDrops = append(sourceCoordinateDrops, RecoveryMatrixSourceCoordinate{
				FrameOrdinal: decision.OriginalFrameOrdinal,
				PacketIndex:  decision.OriginalFramePacketIndex,
			})
		}
	}
	bandwidthQueueModel := ""
	if controller.bandwidthRateBitsPerSecond > 0 {
		bandwidthQueueModel = recoveryBandwidthQueueModelVirtualFluid
	}
	return RecoveryImpairmentSnapshot{
		Attempted:                    cloneRecoveryTotals(controller.attempted),
		ControllerDropped:            cloneRecoveryTotals(controller.dropped),
		AdmittedToVNet:               cloneRecoveryTotals(controller.admitted),
		Delivered:                    cloneRecoveryTotals(controller.delivered),
		EffectiveQueueDropped:        effectiveRecoveryQueueDrops(controller.admitted, controller.delivered),
		DuplicatesScheduled:          controller.duplicates,
		ScheduledBytesCurrent:        controller.scheduledNow,
		ScheduledBytesPeak:           controller.scheduledPeak,
		OutstandingMediaBytesCurrent: controller.outstandingNow,
		OutstandingMediaBytesPeak:    controller.outstandingPeak,
		DecisionCount:                uint64(len(controller.decisions)),
		DecisionSHA256:               hex.EncodeToString(hasher.Sum(nil)),
		SourceCoordinateDrops:        sourceCoordinateDrops,
		BandwidthQueueModel:          bandwidthQueueModel,
	}
}

func cloneRecoveryTotals(source map[recoveryPacketClass]recoveryPacketTotals) map[recoveryPacketClass]recoveryPacketTotals {
	result := make(map[recoveryPacketClass]recoveryPacketTotals, len(recoveryPacketClasses()))
	for _, class := range recoveryPacketClasses() {
		result[class] = recoveryPacketTotals{}
	}
	for class, totals := range source {
		if class == "original" {
			class = matrixPacketMedia
		}
		result[class] = totals
	}
	return result
}

func effectiveRecoveryQueueDrops(
	admitted, delivered map[recoveryPacketClass]recoveryPacketTotals,
) map[recoveryPacketClass]recoveryPacketTotals {
	result := make(map[recoveryPacketClass]recoveryPacketTotals)
	for _, class := range recoveryPacketClasses() {
		totals := admitted[class]
		delivery := delivered[class]
		if totals.Packets >= delivery.Packets && totals.Bytes >= delivery.Bytes {
			result[class] = recoveryPacketTotals{
				Packets: totals.Packets - delivery.Packets,
				Bytes:   totals.Bytes - delivery.Bytes,
			}
		}
	}
	return result
}

type recoveryScheduledDatagram struct {
	deadline        time.Time
	payload         []byte
	classification  recoveryDatagramClassification
	write           func([]byte) (int, error)
	prepareDelivery func() (func(), error)
	enqueueOrdinal  uint64
	index           int
}

type recoveryScheduledHeap []*recoveryScheduledDatagram

func (entries recoveryScheduledHeap) Len() int { return len(entries) }
func (entries recoveryScheduledHeap) Less(left, right int) bool {
	if entries[left].deadline.Equal(entries[right].deadline) {
		return entries[left].enqueueOrdinal < entries[right].enqueueOrdinal
	}
	return entries[left].deadline.Before(entries[right].deadline)
}
func (entries recoveryScheduledHeap) Swap(left, right int) {
	entries[left], entries[right] = entries[right], entries[left]
	entries[left].index = left
	entries[right].index = right
}
func (entries *recoveryScheduledHeap) Push(value any) {
	entry := value.(*recoveryScheduledDatagram)
	entry.index = len(*entries)
	*entries = append(*entries, entry)
}
func (entries *recoveryScheduledHeap) Pop() any {
	old := *entries
	last := old[len(old)-1]
	old[len(old)-1] = nil
	last.index = -1
	*entries = old[:len(old)-1]
	return last
}

type recoveryImpairmentScheduler struct {
	controller  *RecoveryImpairmentController
	mu          sync.Mutex
	entries     recoveryScheduledHeap
	wake        chan struct{}
	stop        chan struct{}
	done        chan struct{}
	closed      bool
	nextOrdinal uint64
}

func newRecoveryImpairmentScheduler(controller *RecoveryImpairmentController) *recoveryImpairmentScheduler {
	scheduler := &recoveryImpairmentScheduler{
		controller: controller,
		wake:       make(chan struct{}, 1), stop: make(chan struct{}), done: make(chan struct{}),
	}
	go scheduler.run()
	return scheduler
}

func (scheduler *recoveryImpairmentScheduler) enqueue(entry *recoveryScheduledDatagram) error {
	scheduler.mu.Lock()
	if scheduler.closed {
		scheduler.mu.Unlock()
		return net.ErrClosed
	}
	scheduler.nextOrdinal++
	entry.enqueueOrdinal = scheduler.nextOrdinal
	heap.Push(&scheduler.entries, entry)
	scheduler.mu.Unlock()
	select {
	case scheduler.wake <- struct{}{}:
	default:
	}
	return nil
}

func (scheduler *recoveryImpairmentScheduler) run() {
	defer close(scheduler.done)
	for {
		scheduler.mu.Lock()
		if scheduler.closed {
			pending := append(recoveryScheduledHeap(nil), scheduler.entries...)
			scheduler.entries = nil
			scheduler.mu.Unlock()
			for _, entry := range pending {
				scheduler.controller.finishScheduled(entry.classification, net.ErrClosed)
			}
			return
		}
		if len(scheduler.entries) == 0 {
			scheduler.mu.Unlock()
			select {
			case <-scheduler.wake:
				continue
			case <-scheduler.stop:
				continue
			}
		}
		entry := scheduler.entries[0]
		wait := time.Until(entry.deadline)
		scheduler.mu.Unlock()
		if wait > 0 {
			timer := time.NewTimer(wait)
			select {
			case <-timer.C:
			case <-scheduler.wake:
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				continue
			case <-scheduler.stop:
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				continue
			}
		}
		scheduler.mu.Lock()
		if scheduler.closed || len(scheduler.entries) == 0 || scheduler.entries[0] != entry {
			scheduler.mu.Unlock()
			continue
		}
		heap.Pop(&scheduler.entries)
		scheduler.mu.Unlock()
		scheduler.controller.recordAdmitted(entry.classification)
		n, err := entry.write(entry.payload)
		if err == nil && n != len(entry.payload) {
			err = fmt.Errorf("short scheduled datagram write: wrote %d of %d", n, len(entry.payload))
		}
		var commitDelivery func()
		if err == nil && entry.prepareDelivery != nil {
			commitDelivery, err = entry.prepareDelivery()
		}
		if err != nil {
			scheduler.controller.rollbackAdmitted(entry.classification)
		} else if scheduler.controller.meterWrites || entry.prepareDelivery != nil {
			scheduler.controller.recordDelivered(entry.classification)
		}
		scheduler.controller.finishScheduled(entry.classification, err)
		if err == nil && commitDelivery != nil {
			commitDelivery()
		}
	}
}

func (scheduler *recoveryImpairmentScheduler) close() {
	scheduler.mu.Lock()
	if !scheduler.closed {
		scheduler.closed = true
		close(scheduler.stop)
	}
	scheduler.mu.Unlock()
	<-scheduler.done
}

func (controller *RecoveryImpairmentController) SchedulePacketConnWrite(
	endpoint recoveryMatrixEndpoint,
	connection net.PacketConn,
	payload []byte,
	destination net.Addr,
) (int, error) {
	return controller.scheduleWrite(endpoint, payload, func(copyOfPayload []byte) (int, error) {
		return connection.WriteTo(copyOfPayload, destination)
	})
}

func (controller *RecoveryImpairmentController) scheduleWrite(
	endpoint recoveryMatrixEndpoint,
	payload []byte,
	write func([]byte) (int, error),
) (int, error) {
	controller.pathGate.RLock()
	defer controller.pathGate.RUnlock()
	controller.mu.Lock()
	if controller.closed {
		controller.mu.Unlock()
		return 0, net.ErrClosed
	}
	active := controller.active && controller.accepting
	controller.mu.Unlock()
	if !active {
		controller.observePassthrough(endpoint, payload)
		return write(payload)
	}

	classification := controller.classifyDatagram(endpoint, payload)
	decision := controller.decide(classification)
	classification.traceOrdinal = decision.ClassOrdinal
	if decision.Action == matrixActionDrop {
		return len(payload), nil
	}

	copies := 1
	if decision.Action == matrixActionDuplicateImmediate || decision.Action == matrixActionDuplicateDelayed {
		copies = 2
	}
	for copyIndex := 0; copyIndex < copies; copyIndex++ {
		delay := decision.DelayMicroseconds
		if copyIndex == 1 && decision.Action == matrixActionDuplicateDelayed {
			delay += decision.duplicateDelayMicroseconds
		}
		copyOfPayload := append([]byte(nil), payload...)
		arrival := time.Now()
		deadline, admitted, reserveErr := controller.reserveScheduledDeadline(
			classification,
			copyIndex > 0,
			arrival,
			time.Duration(delay)*time.Microsecond,
		)
		if reserveErr != nil {
			return 0, reserveErr
		}
		if classification.Class == matrixPacketOriginal && controller.trace != nil {
			kind := traceOriginalQueueRejected
			if admitted {
				kind = traceOriginalQueueAdmitted
			}
			controller.trace.Record(recoveryTraceEvent{
				Layer: traceLayerImpairment, Kind: kind,
				RTPSequence:  classification.RTPSequence,
				RTPTimestamp: classification.RTPTimestamp,
			})
		}
		if !admitted {
			continue
		}
		entry := &recoveryScheduledDatagram{
			deadline: deadline,
			payload:  copyOfPayload, classification: classification, write: write,
		}
		if err := controller.schedulers[endpoint].enqueue(entry); err != nil {
			controller.finishScheduled(classification, err)
			return 0, err
		}
	}
	return len(payload), nil
}

func (controller *RecoveryImpairmentController) reserveScheduledDeadline(
	classification recoveryDatagramClassification,
	duplicate bool,
	arrival time.Time,
	propagationDelay time.Duration,
) (time.Time, bool, error) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if propagationDelay < 0 {
		return time.Time{}, false, errors.New("recovery impairment propagation delay must not be negative")
	}
	bytes := uint64(classification.Bytes)
	bandwidthActive := controller.bandwidthRateBitsPerSecond > 0 &&
		(controller.bandwidthDuration == 0 ||
			arrival.Before(controller.activatedAt.Add(controller.bandwidthDuration)))
	deadline := arrival.Add(propagationDelay)
	if bandwidthActive {
		queue := controller.bandwidthQueues[classification.Endpoint]
		if queue == nil {
			return time.Time{}, false, fmt.Errorf(
				"recovery impairment has no %s bandwidth queue",
				classification.Endpoint,
			)
		}
		serializedDeparture, admitted, err := queue.reserve(arrival, bytes)
		if err != nil {
			return time.Time{}, false, err
		}
		if !admitted {
			controller.addTotalsLocked(
				controller.admitted, classification.Class, classification.Bytes,
			)
			if isRecoveryMediaClass(classification.Class) {
				if classification.Class == matrixPacketOriginal {
					controller.recoveryOutstanding = true
				}
				controller.outstandingNow += bytes
				if controller.outstandingNow > controller.outstandingPeak {
					controller.outstandingPeak = controller.outstandingNow
				}
			}
			controller.notifyLocked()
			return time.Time{}, false, nil
		}
		deadline = serializedDeparture.Add(propagationDelay)
	}
	controller.pending++
	controller.scheduledNow += bytes
	if controller.scheduledNow > controller.scheduledPeak {
		controller.scheduledPeak = controller.scheduledNow
	}
	if duplicate {
		controller.duplicates.Packets++
		controller.duplicates.Bytes += bytes
	}
	controller.notifyLocked()
	return deadline, true, nil
}

func (controller *RecoveryImpairmentController) resetBandwidthQueuesLocked() {
	for _, queue := range controller.bandwidthQueues {
		queue.reset()
	}
}

func (controller *RecoveryImpairmentController) reserveScheduled(
	classification recoveryDatagramClassification,
	duplicate bool,
) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	controller.pending++
	controller.scheduledNow += uint64(classification.Bytes)
	if controller.scheduledNow > controller.scheduledPeak {
		controller.scheduledPeak = controller.scheduledNow
	}
	if duplicate {
		controller.duplicates.Packets++
		controller.duplicates.Bytes += uint64(classification.Bytes)
	}
	controller.notifyLocked()
}

func (controller *RecoveryImpairmentController) finishScheduled(
	classification recoveryDatagramClassification,
	err error,
) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.pending == 0 || controller.scheduledNow < uint64(classification.Bytes) {
		panic("recovery impairment scheduled accounting underflow")
	}
	controller.pending--
	controller.scheduledNow -= uint64(classification.Bytes)
	if err != nil && controller.asyncError == nil && !errors.Is(err, net.ErrClosed) {
		controller.asyncError = err
	}
	controller.notifyLocked()
}

func (controller *RecoveryImpairmentController) recordAdmitted(classification recoveryDatagramClassification) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if !controller.active {
		return
	}
	controller.addTotalsLocked(controller.admitted, classification.Class, classification.Bytes)
	if isRecoveryMediaClass(classification.Class) {
		controller.outstandingNow += uint64(classification.Bytes)
		if controller.outstandingNow > controller.outstandingPeak {
			controller.outstandingPeak = controller.outstandingNow
		}
	}
}

func (controller *RecoveryImpairmentController) rollbackAdmitted(classification recoveryDatagramClassification) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	totals := controller.admitted[classification.Class]
	bytes := uint64(classification.Bytes)
	if totals.Packets == 0 || totals.Bytes < bytes {
		panic("recovery impairment admitted accounting underflow")
	}
	totals.Packets--
	totals.Bytes -= bytes
	controller.admitted[classification.Class] = totals
	if isRecoveryMediaClass(classification.Class) {
		if controller.outstandingNow >= bytes {
			controller.outstandingNow -= bytes
		} else {
			controller.outstandingNow = 0
		}
	}
}

func (controller *RecoveryImpairmentController) recordDelivered(classification recoveryDatagramClassification) {
	controller.mu.Lock()
	if !controller.active {
		controller.mu.Unlock()
		return
	}
	controller.addTotalsLocked(controller.delivered, classification.Class, classification.Bytes)
	delivered := controller.delivered[classification.Class]
	admitted := controller.admitted[classification.Class]
	if (delivered.Packets > admitted.Packets || delivered.Bytes > admitted.Bytes) && controller.asyncError == nil {
		controller.asyncError = fmt.Errorf("delivered %s accounting exceeds admission", classification.Class)
	}
	if isRecoveryMediaClass(classification.Class) {
		bytes := uint64(classification.Bytes)
		if controller.outstandingNow >= bytes {
			controller.outstandingNow -= bytes
		} else {
			controller.outstandingNow = 0
		}
	}
	if classification.Class == matrixPacketRTX {
		controller.recoveryOutstanding = false
	}
	controller.notifyLocked()
	trace := controller.trace
	controller.mu.Unlock()
	if classification.Class == matrixPacketNACK && classification.traceOrdinal != 0 {
		traceOrdinal := int64(classification.traceOrdinal)
		wireFingerprint, packetSize := recoveryNACKTraceIdentity(classification)
		trace.Record(recoveryTraceEvent{
			Layer: traceLayerImpairment, Kind: traceNACKSocketDelivered,
			RTPSequence:     classification.RTPSequence,
			NumericValue:    &traceOrdinal,
			WireFingerprint: wireFingerprint,
			PacketSize:      packetSize,
		})
	} else if classification.Class == matrixPacketOriginal {
		trace.Record(recoveryTraceEvent{
			Layer: traceLayerImpairment, Kind: traceOriginalSocketDelivered,
			RTPSequence:  classification.RTPSequence,
			RTPTimestamp: classification.RTPTimestamp,
		})
	}
}

func recoveryNACKTraceIdentity(
	classification recoveryDatagramClassification,
) (*string, *int) {
	if classification.Class != matrixPacketNACK || classification.WireFingerprint == "" {
		return nil, nil
	}
	fingerprint := classification.WireFingerprint
	packetSize := classification.Bytes
	return &fingerprint, &packetSize
}

func (controller *RecoveryImpairmentController) WaitForDrain(ctx context.Context) error {
	for {
		controller.mu.Lock()
		if controller.pending == 0 {
			err := controller.asyncError
			controller.mu.Unlock()
			return err
		}
		changed := controller.changed
		controller.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (controller *RecoveryImpairmentController) ResetMeasurement(ctx context.Context) error {
	controller.pathGate.Lock()
	defer controller.pathGate.Unlock()

	controller.mu.Lock()
	if controller.closed {
		controller.mu.Unlock()
		return net.ErrClosed
	}
	if !controller.active {
		controller.mu.Unlock()
		return errors.New("recovery impairment reset requires an active controller")
	}
	controller.accepting = false
	controller.notifyLocked()
	controller.mu.Unlock()

	if err := controller.WaitForDrain(ctx); err != nil {
		controller.mu.Lock()
		controller.accepting = true
		controller.notifyLocked()
		controller.mu.Unlock()
		return err
	}
	// Reset the diagnostic epoch at the same boundary as impairment counters.
	// In particular, discard the deliberate loss used to settle a primed
	// libwebrtc receiver before the measured loss is introduced.
	controller.trace.Reset()

	controller.mu.Lock()
	controller.ordinals = make(map[string]uint64)
	controller.random = make(map[string]*rand.Rand)
	controller.decisions = nil
	controller.attempted = make(map[recoveryPacketClass]recoveryPacketTotals)
	controller.dropped = make(map[recoveryPacketClass]recoveryPacketTotals)
	controller.admitted = make(map[recoveryPacketClass]recoveryPacketTotals)
	controller.delivered = make(map[recoveryPacketClass]recoveryPacketTotals)
	controller.duplicates = recoveryPacketTotals{}
	controller.scheduledNow = 0
	controller.scheduledPeak = 0
	controller.outstandingNow = 0
	controller.outstandingPeak = 0
	controller.resetBandwidthQueuesLocked()
	controller.decisionOriginalTimestamp = 0
	controller.hasDecisionOriginalTime = false
	controller.decisionOriginalFrame = 0
	controller.decisionOriginalPacket = 0
	controller.recoveryOutstanding = false
	controller.activatedAt = time.Now()
	controller.accepting = true
	controller.notifyLocked()
	controller.mu.Unlock()

	for {
		select {
		case <-controller.nackAttempts:
		default:
			return nil
		}
	}
}

func (controller *RecoveryImpairmentController) DeactivateAndWaitForDrain(
	ctx context.Context,
) error {
	controller.pathGate.Lock()
	controller.mu.Lock()
	controller.accepting = false
	controller.notifyLocked()
	controller.mu.Unlock()
	controller.pathGate.Unlock()
	if err := controller.WaitForDrain(ctx); err != nil {
		return err
	}
	controller.mu.Lock()
	controller.active = false
	controller.mu.Unlock()
	return nil
}

func (controller *RecoveryImpairmentController) ReconcileQueueLossAfterDrain() {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.pending != 0 {
		if controller.asyncError == nil {
			controller.asyncError = errors.New("reconciled recovery queue loss before scheduler drain")
		}
		return
	}
	controller.outstandingNow = 0
	controller.notifyLocked()
}

func (controller *RecoveryImpairmentController) ResolveRecovery() {
	controller.mu.Lock()
	controller.recoveryOutstanding = false
	controller.mu.Unlock()
}

func (controller *RecoveryImpairmentController) notifyLocked() {
	close(controller.changed)
	controller.changed = make(chan struct{})
}

func (controller *RecoveryImpairmentController) Close() error {
	controller.mu.Lock()
	if controller.closed {
		controller.mu.Unlock()
		return nil
	}
	controller.closed = true
	pumps := make([]*recoveryImpairmentReadPump, 0, len(controller.readPumps))
	for pump := range controller.readPumps {
		pumps = append(pumps, pump)
	}
	controller.readPumps = make(map[*recoveryImpairmentReadPump]struct{})
	schedulers := []*recoveryImpairmentScheduler{
		controller.schedulers[matrixHost], controller.schedulers[matrixViewer],
	}
	controller.notifyLocked()
	controller.mu.Unlock()
	for _, pump := range pumps {
		_ = pump.Close()
	}
	for _, scheduler := range schedulers {
		scheduler.close()
	}
	return nil
}

type recoveryImpairmentPacketConn struct {
	net.PacketConn
	endpoint   recoveryMatrixEndpoint
	controller *RecoveryImpairmentController
	readPump   *recoveryImpairmentReadPump
}

func (connection *recoveryImpairmentPacketConn) WriteTo(payload []byte, destination net.Addr) (int, error) {
	return connection.controller.SchedulePacketConnWrite(
		connection.endpoint, connection.PacketConn, payload, destination,
	)
}

func (connection *recoveryImpairmentPacketConn) ReadFrom(payload []byte) (int, net.Addr, error) {
	if connection.readPump != nil {
		return connection.readPump.ReadFrom(payload)
	}
	n, address, err := connection.PacketConn.ReadFrom(payload)
	if n > 0 {
		connection.controller.recordDelivered(classifyRecoveryDatagram(
			oppositeMatrixEndpoint(connection.endpoint), payload[:n],
		))
	}
	return n, address, err
}

func (connection *recoveryImpairmentPacketConn) SetReadDeadline(deadline time.Time) error {
	if connection.readPump != nil {
		return connection.readPump.SetReadDeadline(deadline)
	}
	return connection.PacketConn.SetReadDeadline(deadline)
}

func (connection *recoveryImpairmentPacketConn) SetDeadline(deadline time.Time) error {
	if connection.readPump != nil {
		if err := connection.readPump.SetReadDeadline(deadline); err != nil {
			return err
		}
		return connection.PacketConn.SetWriteDeadline(deadline)
	}
	return connection.PacketConn.SetDeadline(deadline)
}

func (connection *recoveryImpairmentPacketConn) Close() error {
	if connection.readPump == nil {
		return connection.PacketConn.Close()
	}
	err := connection.readPump.Close()
	connection.controller.unregisterReadPump(connection.readPump)
	return err
}

func (controller *RecoveryImpairmentController) handlePacketConnRead(
	endpoint recoveryMatrixEndpoint,
	pump *recoveryImpairmentReadPump,
	readID int64,
	datagram recoveryReadDatagram,
) error {
	controller.pathGate.RLock()
	defer controller.pathGate.RUnlock()
	controller.mu.Lock()
	active := controller.active && controller.accepting
	closed := controller.closed
	controller.mu.Unlock()
	if closed {
		return net.ErrClosed
	}
	if !active {
		commit, err := pump.prepareDelivery(datagram)
		if err != nil {
			return err
		}
		commit()
		return nil
	}

	classification := controller.classifyDatagram(
		oppositeMatrixEndpoint(endpoint), datagram.payload,
	)
	controller.recordNACKDecisionBoundary(
		traceNACKImpairmentDecisionCalled, readID, classification,
	)
	decision := controller.decide(classification)
	controller.recordNACKDecisionBoundary(
		traceNACKImpairmentDecisionReturned, readID, classification,
	)
	classification.traceOrdinal = decision.ClassOrdinal
	if decision.Action == matrixActionDrop {
		return nil
	}

	copies := 1
	if decision.Action == matrixActionDuplicateImmediate ||
		decision.Action == matrixActionDuplicateDelayed {
		copies = 2
	}
	for copyIndex := 0; copyIndex < copies; copyIndex++ {
		delay := decision.DelayMicroseconds
		if copyIndex == 1 && decision.Action == matrixActionDuplicateDelayed {
			delay += decision.duplicateDelayMicroseconds
		}
		copyOfDatagram := recoveryReadDatagram{
			payload: append([]byte(nil), datagram.payload...),
			source:  datagram.source,
		}
		arrival := time.Now()
		deadline, admitted, reserveErr := controller.reserveScheduledDeadline(
			classification,
			copyIndex > 0,
			arrival,
			time.Duration(delay)*time.Microsecond,
		)
		if reserveErr != nil {
			return reserveErr
		}
		if !admitted {
			continue
		}
		entry := &recoveryScheduledDatagram{
			deadline:       deadline,
			payload:        copyOfDatagram.payload,
			classification: classification,
			write: func(payload []byte) (int, error) {
				return len(payload), nil
			},
			prepareDelivery: func() (func(), error) {
				return pump.prepareDelivery(copyOfDatagram)
			},
		}
		if err := controller.schedulers[classification.Endpoint].enqueue(entry); err != nil {
			controller.finishScheduled(classification, err)
			return err
		}
	}
	return nil
}

func (controller *RecoveryImpairmentController) beginPacketConnRead() int64 {
	trace := controller.trace
	if trace == nil || !trace.enabled {
		return 0
	}
	readID := controller.traceReadID.Add(1)
	trace.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: tracePacketConnReadStarted,
		NumericValue: &readID,
	})
	return readID
}

func (controller *RecoveryImpairmentController) recordPacketConnReadReturned(
	readID int64,
	packet []byte,
) {
	if readID <= 0 {
		return
	}
	fingerprint := recoveryWireFingerprint(packet)
	packetSize := len(packet)
	controller.trace.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: tracePacketConnReadReturned,
		NumericValue: &readID, WireFingerprint: &fingerprint,
		PacketSize: &packetSize,
	})
}

func (controller *RecoveryImpairmentController) recordNACKDecisionBoundary(
	kind recoveryTraceKind,
	readID int64,
	classification recoveryDatagramClassification,
) {
	if readID <= 0 || classification.Class != matrixPacketNACK {
		return
	}
	fingerprint := classification.WireFingerprint
	packetSize := classification.Bytes
	controller.trace.Record(recoveryTraceEvent{
		Layer: traceLayerImpairment, Kind: kind,
		NumericValue: &readID, WireFingerprint: &fingerprint,
		PacketSize: &packetSize,
	})
}

func (controller *RecoveryImpairmentController) observePassthrough(
	endpoint recoveryMatrixEndpoint,
	packet []byte,
) {
	if endpoint != matrixHost || !isRecoveryRTP(packet) {
		return
	}
	controller.mu.Lock()
	if !controller.hasOriginalStream {
		controller.originalPayloadType = packet[1] & 0x7f
		controller.originalSSRC = binary.BigEndian.Uint32(packet[8:12])
		controller.hasOriginalStream = true
	}
	controller.mu.Unlock()
}

func (controller *RecoveryImpairmentController) classifyDatagram(
	endpoint recoveryMatrixEndpoint,
	packet []byte,
) recoveryDatagramClassification {
	classification := classifyRecoveryDatagram(endpoint, packet)
	controller.mu.Lock()
	decryptedRTCPClassification := controller.decryptedRTCPClassification
	controller.mu.Unlock()
	if endpoint == matrixViewer && isRecoveryRTCP(packet) &&
		decryptedRTCPClassification {
		classification.Class = matrixPacketOther
		classification.WireFingerprint = ""
		return classification
	}
	if endpoint != matrixHost || !isRecoveryRTP(packet) {
		return classification
	}
	controller.mu.Lock()
	hasOriginal := controller.hasOriginalStream
	originalPayloadType := controller.originalPayloadType
	originalSSRC := controller.originalSSRC
	hasFlexFEC := controller.hasFlexFECStream
	flexFECPayloadType := controller.flexFECPayloadType
	flexFECSSRC := controller.flexFECSSRC
	controller.mu.Unlock()
	if !hasOriginal {
		return classification
	}
	sequence := binary.BigEndian.Uint16(packet[2:4])
	timestamp := binary.BigEndian.Uint32(packet[4:8])
	classification.RTPSequence = &sequence
	classification.RTPTimestamp = &timestamp
	if binary.BigEndian.Uint32(packet[8:12]) == originalSSRC &&
		packet[1]&0x7f == originalPayloadType {
		classification.Class = matrixPacketOriginal
	} else if hasFlexFEC && binary.BigEndian.Uint32(packet[8:12]) == flexFECSSRC &&
		packet[1]&0x7f == flexFECPayloadType {
		classification.Class = matrixPacketFEC
	} else {
		classification.Class = matrixPacketRTX
	}
	return classification
}

func isRecoveryRTCP(packet []byte) bool {
	return len(packet) >= 8 && packet[0]>>6 == 2 &&
		packet[1] >= 192 && packet[1] <= 223
}

func isRecoveryRTP(packet []byte) bool {
	if len(packet) < 12 || packet[0]>>6 != 2 {
		return false
	}
	packetType := packet[1]
	return packetType < 192 || packetType > 223
}

func (controller *RecoveryImpairmentController) wrapHostPacketConn(
	connection net.PacketConn,
) net.PacketConn {
	return controller.wrapPacketConn(matrixHost, connection, true)
}

func (controller *RecoveryImpairmentController) wrapPacketConn(
	endpoint recoveryMatrixEndpoint,
	connection net.PacketConn,
	shapeReads bool,
) net.PacketConn {
	wrapper := &recoveryImpairmentPacketConn{
		PacketConn: connection, endpoint: endpoint, controller: controller,
	}
	if !shapeReads {
		return wrapper
	}
	pump := newRecoveryImpairmentReadPump(
		connection,
		controller,
		func(pump *recoveryImpairmentReadPump, readID int64, datagram recoveryReadDatagram) error {
			return controller.handlePacketConnRead(endpoint, pump, readID, datagram)
		},
	)
	wrapper.readPump = pump
	if !controller.registerReadPump(pump) {
		_ = pump.Close()
	}
	return wrapper
}

func (controller *RecoveryImpairmentController) registerReadPump(
	pump *recoveryImpairmentReadPump,
) bool {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if controller.closed {
		return false
	}
	controller.readPumps[pump] = struct{}{}
	return true
}

func (controller *RecoveryImpairmentController) unregisterReadPump(
	pump *recoveryImpairmentReadPump,
) {
	controller.mu.Lock()
	delete(controller.readPumps, pump)
	controller.mu.Unlock()
}

func oppositeMatrixEndpoint(endpoint recoveryMatrixEndpoint) recoveryMatrixEndpoint {
	if endpoint == matrixHost {
		return matrixViewer
	}
	return matrixHost
}

type recoveryImpairmentNet struct {
	transport.Net
	endpoint   recoveryMatrixEndpoint
	controller *RecoveryImpairmentController
	shapeReads bool
}

func (controller *RecoveryImpairmentController) WrapHostNet(
	underlying transport.Net,
) transport.Net {
	return &recoveryImpairmentNet{
		Net: underlying, endpoint: matrixHost, controller: controller, shapeReads: true,
	}
}

func (controller *RecoveryImpairmentController) WrapNet(
	endpoint recoveryMatrixEndpoint,
	underlying transport.Net,
) transport.Net {
	return &recoveryImpairmentNet{
		Net: underlying, endpoint: endpoint, controller: controller,
	}
}

func (network *recoveryImpairmentNet) ListenPacket(name, address string) (net.PacketConn, error) {
	connection, err := network.Net.ListenPacket(name, address)
	if err != nil {
		return nil, err
	}
	return network.controller.wrapPacketConn(
		network.endpoint, connection, network.shapeReads,
	), nil
}

func (network *recoveryImpairmentNet) ListenUDP(name string, address *net.UDPAddr) (transport.UDPConn, error) {
	connection, err := network.Net.ListenUDP(name, address)
	if err != nil {
		return nil, err
	}
	return &recoveryImpairmentUDPConn{UDPConn: connection, endpoint: network.endpoint, controller: network.controller}, nil
}

func (network *recoveryImpairmentNet) DialUDP(
	name string,
	local, remote *net.UDPAddr,
) (transport.UDPConn, error) {
	connection, err := network.Net.DialUDP(name, local, remote)
	if err != nil {
		return nil, err
	}
	return &recoveryImpairmentUDPConn{UDPConn: connection, endpoint: network.endpoint, controller: network.controller}, nil
}

type recoveryImpairmentUDPConn struct {
	transport.UDPConn
	endpoint   recoveryMatrixEndpoint
	controller *RecoveryImpairmentController
}

func (connection *recoveryImpairmentUDPConn) Write(payload []byte) (int, error) {
	return connection.controller.scheduleWrite(connection.endpoint, payload, connection.UDPConn.Write)
}

func (connection *recoveryImpairmentUDPConn) WriteTo(payload []byte, address net.Addr) (int, error) {
	return connection.controller.scheduleWrite(connection.endpoint, payload, func(copyOfPayload []byte) (int, error) {
		return connection.UDPConn.WriteTo(copyOfPayload, address)
	})
}

func (connection *recoveryImpairmentUDPConn) WriteToUDP(payload []byte, address *net.UDPAddr) (int, error) {
	return connection.controller.scheduleWrite(connection.endpoint, payload, func(copyOfPayload []byte) (int, error) {
		return connection.UDPConn.WriteToUDP(copyOfPayload, address)
	})
}

func (connection *recoveryImpairmentUDPConn) WriteMsgUDP(
	payload, oob []byte,
	address *net.UDPAddr,
) (int, int, error) {
	connection.controller.mu.Lock()
	active := connection.controller.active
	closed := connection.controller.closed
	connection.controller.mu.Unlock()
	if closed {
		return 0, 0, net.ErrClosed
	}
	if !active {
		return connection.UDPConn.WriteMsgUDP(payload, oob, address)
	}
	copyOfOOB := append([]byte(nil), oob...)
	_, err := connection.controller.scheduleWrite(connection.endpoint, payload, func(copyOfPayload []byte) (int, error) {
		n, _, writeErr := connection.UDPConn.WriteMsgUDP(copyOfPayload, copyOfOOB, address)
		return n, writeErr
	})
	if err != nil {
		return 0, 0, err
	}
	return len(payload), len(oob), nil
}

func (connection *recoveryImpairmentUDPConn) Read(payload []byte) (int, error) {
	n, err := connection.UDPConn.Read(payload)
	connection.meterRead(payload, n)
	return n, err
}

func (connection *recoveryImpairmentUDPConn) ReadFrom(payload []byte) (int, net.Addr, error) {
	n, address, err := connection.UDPConn.ReadFrom(payload)
	connection.meterRead(payload, n)
	return n, address, err
}

func (connection *recoveryImpairmentUDPConn) ReadFromUDP(payload []byte) (int, *net.UDPAddr, error) {
	n, address, err := connection.UDPConn.ReadFromUDP(payload)
	connection.meterRead(payload, n)
	return n, address, err
}

func (connection *recoveryImpairmentUDPConn) ReadMsgUDP(
	payload, oob []byte,
) (int, int, int, *net.UDPAddr, error) {
	n, oobn, flags, address, err := connection.UDPConn.ReadMsgUDP(payload, oob)
	connection.meterRead(payload, n)
	return n, oobn, flags, address, err
}

func (connection *recoveryImpairmentUDPConn) meterRead(payload []byte, count int) {
	if count > 0 {
		connection.controller.recordDelivered(classifyRecoveryDatagram(
			oppositeMatrixEndpoint(connection.endpoint), payload[:count],
		))
	}
}

func classifyRecoveryDatagram(endpoint recoveryMatrixEndpoint, packet []byte) recoveryDatagramClassification {
	classification := recoveryDatagramClassification{
		Endpoint: endpoint,
		Class:    matrixPacketOther,
		Bytes:    len(packet),
	}
	if len(packet) < 4 || packet[0]>>6 != 2 {
		return classification
	}
	if isRecoveryRTCP(packet) {
		feedbackMessageType := packet[0] & 0x1f
		switch {
		case packet[1] == uint8(rtcp.TypeTransportSpecificFeedback) && feedbackMessageType == 1:
			classification.Class = matrixPacketNACK
			classification.WireFingerprint = recoveryWireFingerprint(packet)
		case packet[1] == uint8(rtcp.TypeTransportSpecificFeedback) && feedbackMessageType == 15:
			classification.Class = matrixPacketTWCC
		case packet[1] == uint8(rtcp.TypePayloadSpecificFeedback) &&
			(feedbackMessageType == 1 || feedbackMessageType == 4):
			classification.Class = matrixPacketPLIFIR
		default:
			classification.Class = matrixPacketOtherRTCP
		}
		return classification
	}
	if len(packet) < 12 {
		return classification
	}

	sequence := binary.BigEndian.Uint16(packet[2:4])
	timestamp := binary.BigEndian.Uint32(packet[4:8])
	switch packet[1] & 0x7f {
	case av1PayloadType:
		classification.Class = matrixPacketOriginal
		classification.RTPSequence = &sequence
		classification.RTPTimestamp = &timestamp
	case rtxPayloadType:
		classification.Class = matrixPacketRTX
		classification.RTPSequence = &sequence
		classification.RTPTimestamp = &timestamp
	}
	return classification
}

func classifyRecoveryRTCPPacket(
	endpoint recoveryMatrixEndpoint,
	packet rtcp.Packet,
	encoded []byte,
) recoveryDatagramClassification {
	classification := recoveryDatagramClassification{
		Endpoint: endpoint,
		Class:    matrixPacketOtherRTCP,
		Bytes:    len(encoded),
	}
	switch packet.(type) {
	case *rtcp.TransportLayerNack:
		classification.Class = matrixPacketNACK
		classification.WireFingerprint = recoveryWireFingerprint(encoded)
	case *rtcp.TransportLayerCC:
		classification.Class = matrixPacketTWCC
	case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
		classification.Class = matrixPacketPLIFIR
	}
	return classification
}

// Package-local aliases keep the retained matrix orchestration source-compatible.
type recoveryImpairmentController = RecoveryImpairmentController
type recoveryImpairmentSnapshot = RecoveryImpairmentSnapshot
