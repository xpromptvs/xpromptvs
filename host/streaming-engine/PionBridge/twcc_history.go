package main

import (
	"container/list"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/pion/rtcp"
)

const (
	defaultTWCCMaxPackets      = 32_768
	defaultTWCCMaxAge          = 10 * time.Second
	defaultTWCCReorderingGrace = 50 * time.Millisecond
)

var errInvalidTWCCFeedback = errors.New("invalid TWCC feedback")

type TWCCPacketClass string

const (
	TWCCMedia TWCCPacketClass = "media"
	TWCCFEC   TWCCPacketClass = "fec"
	TWCCRTX   TWCCPacketClass = "rtx"
)

type TWCCSentPacket struct {
	SSRC              uint32
	RTPSequence       uint16
	TransportSequence uint16
	Class             TWCCPacketClass
	Bytes             int
	Departure         time.Time
}

type TWCCClassSnapshot struct {
	SentPackets          uint64 `json:"sentPackets"`
	SentBytes            uint64 `json:"sentBytes"`
	DeliveredPackets     uint64 `json:"deliveredPackets"`
	DeliveredBytes       uint64 `json:"deliveredBytes"`
	ProvisionalPackets   uint64 `json:"provisionalPackets"`
	FinalizedLostPackets uint64 `json:"finalizedLostPackets"`
}

type TWCCSnapshot struct {
	FeedbackPackets          uint64                                `json:"feedbackPackets"`
	DeliveredPackets         uint64                                `json:"deliveredPackets"`
	FinalizedLostPackets     uint64                                `json:"finalizedLostPackets"`
	ProvisionalPackets       uint64                                `json:"provisionalPackets"`
	EvictedPackets           uint64                                `json:"evictedPackets"`
	MalformedFeedbackPackets uint64                                `json:"malformedFeedbackPackets"`
	UnknownFeedbackPackets   uint64                                `json:"unknownFeedbackPackets"`
	LatestRTT                time.Duration                         `json:"latestRTTNanoseconds"`
	FeedbackAge              time.Duration                         `json:"feedbackAgeNanoseconds"`
	QueueTrend               time.Duration                         `json:"queueTrendNanoseconds"`
	ByClass                  map[TWCCPacketClass]TWCCClassSnapshot `json:"byClass"`
}

type TWCCPacketHistoryConfig struct {
	MaxPackets      int
	MaxAge          time.Duration
	ReorderingGrace time.Duration
	Now             func() time.Time
}

type twccPacketState uint8

const (
	twccPending twccPacketState = iota
	twccProvisional
	twccDelivered
	twccFinalizedLost
)

type twccHistoryEntry struct {
	packet        TWCCSentPacket
	extended      uint64
	recordedAt    time.Time
	state         twccPacketState
	provisionalAt time.Time
	element       *list.Element
}

type TWCCPacketHistory struct {
	mutex sync.Mutex

	config  TWCCPacketHistoryConfig
	entries map[uint64]*twccHistoryEntry
	order   *list.List
	closed  bool

	hasSequence bool
	maxExtended uint64
	frontier    uint64
	hasFrontier bool

	feedbackPackets          uint64
	deliveredPackets         uint64
	finalizedLostPackets     uint64
	provisionalPackets       uint64
	evictedPackets           uint64
	malformedFeedbackPackets uint64
	unknownFeedbackPackets   uint64
	latestRTT                time.Duration
	lastFeedback             time.Time
	queueTrend               time.Duration
	hasQueuePoint            bool
	lastQueueDeparture       time.Time
	lastQueueArrival         time.Time
	byClass                  map[TWCCPacketClass]TWCCClassSnapshot
	feedbackObserver         func()
}

func NewTWCCPacketHistory(config TWCCPacketHistoryConfig) (*TWCCPacketHistory, error) {
	if config.MaxPackets < 0 || config.MaxAge < 0 || config.ReorderingGrace < 0 {
		return nil, errors.New("invalid TWCC history configuration")
	}
	if config.MaxPackets == 0 {
		config.MaxPackets = defaultTWCCMaxPackets
	}
	if config.MaxAge == 0 {
		config.MaxAge = defaultTWCCMaxAge
	}
	if config.ReorderingGrace == 0 {
		config.ReorderingGrace = defaultTWCCReorderingGrace
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	return &TWCCPacketHistory{
		config:  config,
		entries: make(map[uint64]*twccHistoryEntry),
		order:   list.New(),
		byClass: newTWCCClassMap(),
	}, nil
}

func newTWCCClassMap() map[TWCCPacketClass]TWCCClassSnapshot {
	return map[TWCCPacketClass]TWCCClassSnapshot{
		TWCCMedia: {}, TWCCFEC: {}, TWCCRTX: {},
	}
}

func (history *TWCCPacketHistory) now() time.Time {
	if history == nil || history.config.Now == nil {
		return time.Now()
	}
	return history.config.Now()
}

func validTWCCClass(class TWCCPacketClass) bool {
	return class == TWCCMedia || class == TWCCFEC || class == TWCCRTX
}

func (history *TWCCPacketHistory) RecordSent(packet TWCCSentPacket) {
	if history == nil {
		return
	}
	now := history.now()
	if packet.Departure.IsZero() {
		packet.Departure = now
	}
	if !validTWCCClass(packet.Class) {
		packet.Class = TWCCMedia
	}
	history.mutex.Lock()
	defer history.mutex.Unlock()
	if history.closed {
		return
	}
	extended := uint64(packet.TransportSequence)
	if history.hasSequence {
		extended = extendTWCCSequence(packet.TransportSequence, history.maxExtended)
	}
	if existing := history.entries[extended]; existing != nil {
		history.removeEntryLocked(existing, true)
	}
	entry := &twccHistoryEntry{
		packet: packet, extended: extended, recordedAt: now,
	}
	entry.element = history.order.PushBack(entry)
	history.entries[extended] = entry
	if !history.hasSequence || extended > history.maxExtended {
		history.maxExtended = extended
		history.hasSequence = true
	}
	class := history.byClass[packet.Class]
	class.SentPackets++
	if packet.Bytes > 0 {
		class.SentBytes += uint64(packet.Bytes)
	}
	history.byClass[packet.Class] = class
	history.evictLocked(now)
}

func extendTWCCSequence(sequence uint16, reference uint64) uint64 {
	candidate := reference&^uint64(0xffff) | uint64(sequence)
	if candidate+0x8000 < reference {
		candidate += 0x10000
	} else if candidate > reference+0x8000 && candidate >= 0x10000 {
		candidate -= 0x10000
	}
	return candidate
}

type twccFeedbackStatus struct {
	sequence uint16
	received bool
	arrival  time.Time
}

func parseTWCCFeedback(feedback *rtcp.TransportLayerCC) ([]twccFeedbackStatus, error) {
	if feedback == nil || feedback.PacketStatusCount == 0 {
		return nil, fmt.Errorf("%w: empty packet", errInvalidTWCCFeedback)
	}
	statuses := make([]twccFeedbackStatus, 0, feedback.PacketStatusCount)
	nextArrival := time.Time{}.Add(time.Duration(feedback.ReferenceTime) * 64 * time.Millisecond)
	deltaIndex := 0
	appendSymbol := func(symbol uint16) error {
		if len(statuses) >= int(feedback.PacketStatusCount) {
			return nil
		}
		status := twccFeedbackStatus{sequence: feedback.BaseSequenceNumber + uint16(len(statuses))} //nolint:gosec
		switch symbol {
		case rtcp.TypeTCCPacketNotReceived:
		case rtcp.TypeTCCPacketReceivedSmallDelta, rtcp.TypeTCCPacketReceivedLargeDelta:
			if deltaIndex >= len(feedback.RecvDeltas) || feedback.RecvDeltas[deltaIndex] == nil ||
				feedback.RecvDeltas[deltaIndex].Type != symbol {
				return fmt.Errorf("%w: missing or mismatched receive delta", errInvalidTWCCFeedback)
			}
			nextArrival = nextArrival.Add(time.Duration(feedback.RecvDeltas[deltaIndex].Delta) * time.Microsecond)
			deltaIndex++
			status.received = true
			status.arrival = nextArrival
		case rtcp.TypeTCCPacketReceivedWithoutDelta:
			status.received = true
		default:
			return fmt.Errorf("%w: reserved packet status", errInvalidTWCCFeedback)
		}
		statuses = append(statuses, status)
		return nil
	}
	for _, packetChunk := range feedback.PacketChunks {
		switch chunk := packetChunk.(type) {
		case *rtcp.RunLengthChunk:
			if chunk == nil || chunk.RunLength == 0 {
				return nil, fmt.Errorf("%w: empty run", errInvalidTWCCFeedback)
			}
			for index := uint16(0); index < chunk.RunLength && len(statuses) < int(feedback.PacketStatusCount); index++ {
				if err := appendSymbol(chunk.PacketStatusSymbol); err != nil {
					return nil, err
				}
			}
		case *rtcp.StatusVectorChunk:
			if chunk == nil || len(chunk.SymbolList) == 0 {
				return nil, fmt.Errorf("%w: empty status vector", errInvalidTWCCFeedback)
			}
			for _, symbol := range chunk.SymbolList {
				if err := appendSymbol(symbol); err != nil {
					return nil, err
				}
				if len(statuses) == int(feedback.PacketStatusCount) {
					break
				}
			}
		default:
			return nil, fmt.Errorf("%w: unknown packet chunk", errInvalidTWCCFeedback)
		}
		if len(statuses) == int(feedback.PacketStatusCount) {
			break
		}
	}
	if len(statuses) != int(feedback.PacketStatusCount) || deltaIndex != len(feedback.RecvDeltas) {
		return nil, fmt.Errorf("%w: status or delta count mismatch", errInvalidTWCCFeedback)
	}
	return statuses, nil
}

func (history *TWCCPacketHistory) ApplyFeedback(feedback *rtcp.TransportLayerCC) error {
	statuses, err := parseTWCCFeedback(feedback)
	if err != nil {
		history.recordMalformedFeedback()
		return err
	}
	now := history.now()
	history.mutex.Lock()
	if history.closed {
		history.mutex.Unlock()
		return nil
	}
	history.feedbackPackets++
	history.lastFeedback = now
	baseExtended := uint64(statuses[0].sequence)
	if history.hasSequence {
		baseExtended = extendTWCCSequence(statuses[0].sequence, history.maxExtended)
	}
	for index, status := range statuses {
		extended := baseExtended + uint64(index)
		entry := history.entries[extended]
		if entry == nil {
			history.unknownFeedbackPackets++
			continue
		}
		if status.received {
			history.markDeliveredLocked(entry, status.arrival, now)
		} else if entry.state == twccPending {
			entry.state = twccProvisional
			entry.provisionalAt = now
			history.provisionalPackets++
			class := history.byClass[entry.packet.Class]
			class.ProvisionalPackets++
			history.byClass[entry.packet.Class] = class
		}
	}
	feedbackFrontier := baseExtended + uint64(len(statuses)-1)
	if !history.hasFrontier || feedbackFrontier > history.frontier {
		history.frontier = feedbackFrontier
		history.hasFrontier = true
	}
	history.finalizeLocked(now)
	history.evictLocked(now)
	observer := history.feedbackObserver
	history.mutex.Unlock()
	if observer != nil {
		observer()
	}
	return nil
}

func (history *TWCCPacketHistory) SetFeedbackObserver(observer func()) {
	if history == nil {
		return
	}
	history.mutex.Lock()
	if !history.closed {
		history.feedbackObserver = observer
	}
	history.mutex.Unlock()
}

func (history *TWCCPacketHistory) markDeliveredLocked(
	entry *twccHistoryEntry,
	arrival time.Time,
	feedbackAt time.Time,
) {
	if entry.state == twccDelivered || entry.state == twccFinalizedLost {
		return
	}
	if entry.state == twccProvisional {
		history.provisionalPackets--
		class := history.byClass[entry.packet.Class]
		class.ProvisionalPackets--
		history.byClass[entry.packet.Class] = class
	}
	entry.state = twccDelivered
	history.deliveredPackets++
	class := history.byClass[entry.packet.Class]
	class.DeliveredPackets++
	if entry.packet.Bytes > 0 {
		class.DeliveredBytes += uint64(entry.packet.Bytes)
	}
	history.byClass[entry.packet.Class] = class
	if feedbackAt.After(entry.packet.Departure) {
		history.latestRTT = feedbackAt.Sub(entry.packet.Departure)
	}
	if !arrival.IsZero() {
		if history.hasQueuePoint {
			receiverDelta := arrival.Sub(history.lastQueueArrival)
			senderDelta := entry.packet.Departure.Sub(history.lastQueueDeparture)
			history.queueTrend = receiverDelta - senderDelta
		}
		history.hasQueuePoint = true
		history.lastQueueArrival = arrival
		history.lastQueueDeparture = entry.packet.Departure
	}
}

func (history *TWCCPacketHistory) Finalize() {
	if history == nil {
		return
	}
	now := history.now()
	history.mutex.Lock()
	defer history.mutex.Unlock()
	if history.closed {
		return
	}
	history.finalizeLocked(now)
	history.evictLocked(now)
}

func (history *TWCCPacketHistory) finalizeLocked(now time.Time) {
	if !history.hasFrontier {
		return
	}
	for element := history.order.Front(); element != nil; element = element.Next() {
		entry := element.Value.(*twccHistoryEntry)
		if entry.state != twccProvisional || entry.extended >= history.frontier ||
			now.Sub(entry.provisionalAt) < history.config.ReorderingGrace {
			continue
		}
		entry.state = twccFinalizedLost
		history.provisionalPackets--
		history.finalizedLostPackets++
		class := history.byClass[entry.packet.Class]
		class.ProvisionalPackets--
		class.FinalizedLostPackets++
		history.byClass[entry.packet.Class] = class
	}
}

func (history *TWCCPacketHistory) evictLocked(now time.Time) {
	for history.order.Len() > 0 {
		oldest := history.order.Front().Value.(*twccHistoryEntry)
		tooMany := history.order.Len() > history.config.MaxPackets
		tooOld := now.Sub(oldest.recordedAt) > history.config.MaxAge
		if !tooMany && !tooOld {
			break
		}
		history.removeEntryLocked(oldest, true)
	}
}

func (history *TWCCPacketHistory) removeEntryLocked(entry *twccHistoryEntry, evicted bool) {
	if entry == nil || entry.element == nil {
		return
	}
	if entry.state == twccProvisional {
		history.provisionalPackets--
		class := history.byClass[entry.packet.Class]
		class.ProvisionalPackets--
		history.byClass[entry.packet.Class] = class
	}
	delete(history.entries, entry.extended)
	history.order.Remove(entry.element)
	entry.element = nil
	if evicted {
		history.evictedPackets++
	}
}

func (history *TWCCPacketHistory) recordMalformedFeedback() {
	if history == nil {
		return
	}
	history.mutex.Lock()
	if !history.closed {
		history.malformedFeedbackPackets++
	}
	history.mutex.Unlock()
}

func (history *TWCCPacketHistory) Snapshot() TWCCSnapshot {
	if history == nil {
		return TWCCSnapshot{ByClass: newTWCCClassMap()}
	}
	now := history.now()
	history.mutex.Lock()
	defer history.mutex.Unlock()
	byClass := newTWCCClassMap()
	for class, snapshot := range history.byClass {
		byClass[class] = snapshot
	}
	feedbackAge := time.Duration(0)
	if !history.lastFeedback.IsZero() && now.After(history.lastFeedback) {
		feedbackAge = now.Sub(history.lastFeedback)
	}
	return TWCCSnapshot{
		FeedbackPackets:          history.feedbackPackets,
		DeliveredPackets:         history.deliveredPackets,
		FinalizedLostPackets:     history.finalizedLostPackets,
		ProvisionalPackets:       history.provisionalPackets,
		EvictedPackets:           history.evictedPackets,
		MalformedFeedbackPackets: history.malformedFeedbackPackets,
		UnknownFeedbackPackets:   history.unknownFeedbackPackets,
		LatestRTT:                history.latestRTT,
		FeedbackAge:              feedbackAge,
		QueueTrend:               history.queueTrend,
		ByClass:                  byClass,
	}
}

func (history *TWCCPacketHistory) Reset() {
	if history == nil {
		return
	}
	history.mutex.Lock()
	defer history.mutex.Unlock()
	history.entries = make(map[uint64]*twccHistoryEntry)
	history.order.Init()
	history.hasSequence = false
	history.maxExtended = 0
	history.frontier = 0
	history.hasFrontier = false
	history.feedbackPackets = 0
	history.deliveredPackets = 0
	history.finalizedLostPackets = 0
	history.provisionalPackets = 0
	history.evictedPackets = 0
	history.malformedFeedbackPackets = 0
	history.unknownFeedbackPackets = 0
	history.latestRTT = 0
	history.lastFeedback = time.Time{}
	history.queueTrend = 0
	history.hasQueuePoint = false
	history.lastQueueDeparture = time.Time{}
	history.lastQueueArrival = time.Time{}
	history.byClass = newTWCCClassMap()
}

func (history *TWCCPacketHistory) Close() error {
	if history == nil {
		return nil
	}
	history.mutex.Lock()
	history.closed = true
	history.feedbackObserver = nil
	history.entries = make(map[uint64]*twccHistoryEntry)
	history.order.Init()
	history.provisionalPackets = 0
	for class, snapshot := range history.byClass {
		snapshot.ProvisionalPackets = 0
		history.byClass[class] = snapshot
	}
	history.mutex.Unlock()
	return nil
}
