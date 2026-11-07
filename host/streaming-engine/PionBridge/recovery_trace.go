package main

import "sync"

const recoveryTraceClockDomain = "macos-uptime-raw"

type recoveryTraceLayer string

const (
	traceLayerImpairment    recoveryTraceLayer = "impairment"
	traceLayerLibWebRTC     recoveryTraceLayer = "libwebrtc"
	traceLayerPionReceiver  recoveryTraceLayer = "pionReceiver"
	traceLayerPionResponder recoveryTraceLayer = "pionResponder"
	traceLayerSwiftHost     recoveryTraceLayer = "swiftHost"
	traceLayerPionSender    recoveryTraceLayer = "pionSender"
	traceLayerDecoder       recoveryTraceLayer = "decoder"
)

type recoveryTraceKind string

const (
	traceOriginalDropped                recoveryTraceKind = "originalDropped"
	traceOriginalSocketDelivered        recoveryTraceKind = "originalSocketDelivered"
	traceRTPGapObserved                 recoveryTraceKind = "rtpGapObserved"
	traceNACKMissingQueued              recoveryTraceKind = "nackMissingQueued"
	traceNACKEligibleSequence           recoveryTraceKind = "nackEligibleSequence"
	traceNACKEligibleTimer              recoveryTraceKind = "nackEligibleTimer"
	traceNACKBuffered                   recoveryTraceKind = "nackBuffered"
	tracePacketConnReadStarted          recoveryTraceKind = "packetConnReadStarted"
	tracePacketConnReadReturned         recoveryTraceKind = "packetConnReadReturned"
	traceNACKImpairmentDecisionCalled   recoveryTraceKind = "nackImpairmentDecisionCalled"
	traceNACKImpairmentDecisionReturned recoveryTraceKind = "nackImpairmentDecisionReturned"
	traceNACKSocketAttempted            recoveryTraceKind = "nackSocketAttempted"
	traceNACKSocketDelivered            recoveryTraceKind = "nackSocketDelivered"
	traceNACKParsed                     recoveryTraceKind = "nackParsed"
	traceNACKClassifiedFresh            recoveryTraceKind = "nackClassifiedFresh"
	traceNACKClassifiedStale            recoveryTraceKind = "nackClassifiedStale"
	traceNACKClassifiedCacheMiss        recoveryTraceKind = "nackClassifiedCacheMiss"
	traceRTXEmitted                     recoveryTraceKind = "rtxEmitted"
	traceRTXArrived                     recoveryTraceKind = "rtxArrived"
	tracePLIGenerated                   recoveryTraceKind = "pliGenerated"
	tracePLIParsed                      recoveryTraceKind = "pliParsed"
	traceKeyframeGateOpened             recoveryTraceKind = "keyframeGateOpened"
	traceKeyframeGateCoalesced          recoveryTraceKind = "keyframeGateCoalesced"
	traceSwiftRequestPending            recoveryTraceKind = "swiftRequestPending"
	traceSwiftRequestConsumed           recoveryTraceKind = "swiftRequestConsumed"
	traceKeyframeSubmitted              recoveryTraceKind = "keyframeSubmitted"
	traceKeyframeFirstPacketEmitted     recoveryTraceKind = "keyframeFirstPacketEmitted"
	traceKeyframePacketPacketized       recoveryTraceKind = "keyframePacketPacketized"
	traceOriginalQueueAdmitted          recoveryTraceKind = "originalQueueAdmitted"
	traceOriginalQueueRejected          recoveryTraceKind = "originalQueueRejected"
	traceRTPPacketIngress               recoveryTraceKind = "rtpPacketIngress"
	traceRTPPacketAcceptedForBuffer     recoveryTraceKind = "rtpPacketAcceptedForBuffer"
	traceRTPPacketRejectedBeforeBuffer  recoveryTraceKind = "rtpPacketRejectedBeforeBuffer"
	tracePacketBufferInsertResult       recoveryTraceKind = "packetBufferInsertResult"
	traceFrameAssembled                 recoveryTraceKind = "frameAssembled"
	traceFrameReferencesResolved        recoveryTraceKind = "frameReferencesResolved"
	traceFrameBufferInserted            recoveryTraceKind = "frameBufferInserted"
	traceFrameReleaseScheduled          recoveryTraceKind = "frameReleaseScheduled"
	traceFrameReleaseImmediate          recoveryTraceKind = "frameReleaseImmediate"
	traceFrameReleased                  recoveryTraceKind = "frameReleased"
	traceDecoderEntered                 recoveryTraceKind = "decoderEntered"
	traceDecoderInvoked                 recoveryTraceKind = "decoderInvoked"
)

type recoveryTraceEvent struct {
	Ordinal                    uint64             `json:"ordinal"`
	MonotonicNanoseconds       uint64             `json:"monotonicNanoseconds"`
	Layer                      recoveryTraceLayer `json:"layer"`
	Kind                       recoveryTraceKind  `json:"kind"`
	MediaSSRC                  *uint32            `json:"mediaSSRC,omitempty"`
	RTPSequence                *uint16            `json:"rtpSequence,omitempty"`
	RTPTimestamp               *uint32            `json:"rtpTimestamp,omitempty"`
	FrameID                    *uint64            `json:"frameID,omitempty"`
	PayloadType                *uint8             `json:"payloadType,omitempty"`
	PacketIndex                *uint16            `json:"packetIndex,omitempty"`
	PacketCount                *uint16            `json:"packetCount,omitempty"`
	Marker                     *bool              `json:"marker,omitempty"`
	Recovered                  *bool              `json:"recovered,omitempty"`
	IsFirstPacketInFrame       *bool              `json:"isFirstPacketInFrame,omitempty"`
	IsLastPacketInFrame        *bool              `json:"isLastPacketInFrame,omitempty"`
	IsKeyframe                 *bool              `json:"isKeyframe,omitempty"`
	Retry                      *uint32            `json:"retry,omitempty"`
	Trigger                    *string            `json:"trigger,omitempty"`
	Reason                     *string            `json:"reason,omitempty"`
	NumericValue               *int64             `json:"numericValue,omitempty"`
	PacketID                   *int64             `json:"packetID,omitempty"`
	WireFingerprint            *string            `json:"wireFingerprint,omitempty"`
	PacketSize                 *int               `json:"packetSize,omitempty"`
	PacketAgeNanoseconds       *int64             `json:"packetAgeNanoseconds,omitempty"`
	RTXAgeThresholdNanoseconds *int64             `json:"rtxAgeThresholdNanoseconds,omitempty"`
}

type recoveryTraceBufferHealth struct {
	Capacity      int `json:"capacity"`
	RetainedCount int `json:"retainedCount"`
	DroppedCount  int `json:"droppedCount"`
}

type recoveryTraceCalibration struct {
	OuterBeforeNanoseconds    uint64 `json:"outerBeforeNanoseconds"`
	NativeCapturedNanoseconds uint64 `json:"nativeCapturedNanoseconds"`
	OuterAfterNanoseconds     uint64 `json:"outerAfterNanoseconds"`
	UncertaintyNanoseconds    uint64 `json:"uncertaintyNanoseconds"`
}

type recoveryTraceSnapshot struct {
	SchemaVersion       int                       `json:"schemaVersion"`
	Source              string                    `json:"source"`
	ClockDomain         string                    `json:"clockDomain"`
	CapturedNanoseconds uint64                    `json:"capturedNanoseconds"`
	Calibration         *recoveryTraceCalibration `json:"calibration,omitempty"`
	Buffer              recoveryTraceBufferHealth `json:"buffer"`
	Events              []recoveryTraceEvent      `json:"events"`
	Complete            bool                      `json:"complete"`
}

type recoveryTraceRecorder struct {
	enabled  bool
	capacity int
	now      func() uint64

	mutex        sync.Mutex
	events       []recoveryTraceEvent
	nextOrdinal  uint64
	droppedCount int
}

func newRecoveryTraceRecorder(
	enabled bool,
	capacity int,
	now func() uint64,
) *recoveryTraceRecorder {
	recorder := &recoveryTraceRecorder{enabled: enabled}
	if !enabled {
		return recorder
	}
	if capacity <= 0 {
		panic("recovery trace capacity must be positive")
	}
	if now == nil {
		now = pionUptimeNanoseconds
	}
	recorder.capacity = capacity
	recorder.now = now
	recorder.events = make([]recoveryTraceEvent, 0, capacity)
	return recorder
}

func (recorder *recoveryTraceRecorder) Record(event recoveryTraceEvent) {
	if recorder == nil || !recorder.enabled {
		return
	}
	recorder.mutex.Lock()
	defer recorder.mutex.Unlock()

	event.Ordinal = recorder.nextOrdinal
	recorder.nextOrdinal++
	event.MonotonicNanoseconds = recorder.now()
	if len(recorder.events) >= recorder.capacity {
		recorder.droppedCount++
		return
	}
	recorder.events = append(recorder.events, event)
}

func (recorder *recoveryTraceRecorder) Reset() {
	if recorder == nil || !recorder.enabled {
		return
	}
	recorder.mutex.Lock()
	returnedReads := make(map[int64]struct{})
	for _, event := range recorder.events {
		if event.Kind == tracePacketConnReadReturned && event.NumericValue != nil {
			returnedReads[*event.NumericValue] = struct{}{}
		}
	}
	preserved := recorder.events[:0]
	for _, event := range recorder.events {
		if event.Kind != tracePacketConnReadStarted || event.NumericValue == nil {
			continue
		}
		if _, returned := returnedReads[*event.NumericValue]; returned {
			continue
		}
		event.Ordinal = uint64(len(preserved))
		preserved = append(preserved, event)
	}
	recorder.events = preserved
	recorder.nextOrdinal = uint64(len(preserved))
	recorder.droppedCount = 0
	recorder.mutex.Unlock()
}

func (recorder *recoveryTraceRecorder) Snapshot(source string) *recoveryTraceSnapshot {
	if recorder == nil || !recorder.enabled {
		return nil
	}
	recorder.mutex.Lock()
	defer recorder.mutex.Unlock()

	capturedNanoseconds := recorder.now()
	events := make([]recoveryTraceEvent, len(recorder.events))
	copy(events, recorder.events)
	return &recoveryTraceSnapshot{
		SchemaVersion:       3,
		Source:              source,
		ClockDomain:         recoveryTraceClockDomain,
		CapturedNanoseconds: capturedNanoseconds,
		Buffer: recoveryTraceBufferHealth{
			Capacity: recorder.capacity, RetainedCount: len(events),
			DroppedCount: recorder.droppedCount,
		},
		Events:   events,
		Complete: recorder.droppedCount == 0,
	}
}
