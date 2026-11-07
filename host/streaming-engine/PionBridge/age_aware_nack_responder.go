package main

import (
	"container/list"
	"encoding/binary"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

const (
	defaultRTXCachePackets      = 8_192
	defaultRTXCacheBytes        = 32 << 20
	responderLedgerPackets      = 8_192
	responderWorkCapacity       = 32
	defaultKeyframeResponseWait = 500 * time.Millisecond
	maximumKeyframeResponseWait = time.Second
)

var errInvalidAgeAwareResponderConfig = errors.New("invalid age-aware NACK responder configuration")

type AgeAwareResponderConfig struct {
	MaxAge        time.Duration
	AgePolicy     *RTXAgePolicy
	MaxPackets    int
	MaxBytes      int
	Now           func() time.Time
	Counters      *RecoveryCounters
	CacheCounters *ResponderCacheCounters
	ObserveNACK   func()
	// RequestKeyframe names the MEDIA STREAM whose receiver is missing a picture. It used to
	// take no argument, which forced BOTH the coalescing gate and the caller's re-key to be
	// session-wide: a request that names no track cannot be gated per track, and cannot be
	// answered by re-keying one either. Every call site already had the SSRC.
	RequestKeyframe func(mediaSSRC uint32)
	RequestRecovery func(mediaSSRC uint32, reason string, independent bool)
	ReportError     func(error)
	Trace           *recoveryTraceRecorder
	MediaRTT        *mediaRTTEstimator
}

type ageAwareNACKResponderFactory struct {
	config     AgeAwareResponderConfig
	mutex      sync.Mutex
	responders map[*ageAwareNACKResponder]struct{}
}

func NewAgeAwareNACKResponder(config AgeAwareResponderConfig) (*ageAwareNACKResponderFactory, error) {
	if config.AgePolicy == nil {
		policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
			Mode: RTXAgeFixed, Floor: config.MaxAge,
		}, config.MediaRTT)
		if err != nil {
			return nil, errInvalidAgeAwareResponderConfig
		}
		config.AgePolicy = policy
	} else if config.MaxAge != 0 {
		return nil, errInvalidAgeAwareResponderConfig
	}
	if config.MaxPackets < 0 || config.MaxBytes < 0 {
		return nil, errInvalidAgeAwareResponderConfig
	}
	if config.MaxPackets == 0 {
		config.MaxPackets = defaultRTXCachePackets
	}
	if config.MaxBytes == 0 {
		config.MaxBytes = defaultRTXCacheBytes
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.Counters == nil {
		config.Counters = &RecoveryCounters{}
	}
	if config.CacheCounters == nil {
		config.CacheCounters = &ResponderCacheCounters{}
	}
	if config.ObserveNACK == nil {
		config.ObserveNACK = func() {}
	}
	if config.RequestKeyframe == nil {
		config.RequestKeyframe = func(uint32) {}
	}
	if config.ReportError == nil {
		config.ReportError = func(error) {}
	}
	return &ageAwareNACKResponderFactory{
		config: config, responders: make(map[*ageAwareNACKResponder]struct{}),
	}, nil
}

func (factory *ageAwareNACKResponderFactory) NewInterceptor(
	_ string,
) (interceptor.Interceptor, error) {
	responder := &ageAwareNACKResponder{
		config:       factory.config,
		streams:      make(map[uint32]*ageAwareLocalStream),
		work:         make(chan responderWork, responderWorkCapacity),
		callbackGate: newCallbackGate(),
	}
	responder.workers.Add(1)
	go responder.run()
	factory.mutex.Lock()
	factory.responders[responder] = struct{}{}
	factory.mutex.Unlock()
	return responder, nil
}

func (factory *ageAwareNACKResponderFactory) DrainCache() {
	factory.mutex.Lock()
	responders := make([]*ageAwareNACKResponder, 0, len(factory.responders))
	for responder := range factory.responders {
		responders = append(responders, responder)
	}
	factory.mutex.Unlock()
	for _, responder := range responders {
		responder.drainCache()
	}
}

func (factory *ageAwareNACKResponderFactory) MarkKeyframeSent(ssrc uint32, sequence uint16) {
	factory.mutex.Lock()
	responders := make([]*ageAwareNACKResponder, 0, len(factory.responders))
	for responder := range factory.responders {
		responders = append(responders, responder)
	}
	factory.mutex.Unlock()
	for _, responder := range responders {
		responder.markKeyframeSent(ssrc, sequence)
	}
}

type responderWork struct {
	packets []rtcp.Packet
	done    chan struct{}
}

type ageAwareNACKResponder struct {
	interceptor.NoOp
	config AgeAwareResponderConfig

	mutex           sync.Mutex
	streams         map[uint32]*ageAwareLocalStream
	closed          bool
	work            chan responderWork
	workers         sync.WaitGroup
	closeOnce       sync.Once
	reportErrorOnce sync.Once
	callbackGate    *callbackGate
	// Reasons already announced this session, so `announceKeyframeReason` prints each cause once
	// rather than five times a second. Guarded by `mutex` with the rest of this struct.
	announcedKeyframeReasons map[string]bool
}

type ageAwareLocalStream struct {
	mutex                sync.Mutex
	info                 interceptor.StreamInfo
	writer               interceptor.RTPWriter
	sequencer            rtp.Sequencer
	metadataExtensionID  uint8
	ledgerOrdinal        uint64
	keyframeStart        uint64
	hasKeyframeStart     bool
	confirmedRecoveryEnd uint64
	// THE KEYFRAME GATE IS PER STREAM, and it belongs beside keyframeStart because it answers a
	// question about the same thing: has the keyframe THIS receiver is missing been sent yet.
	// Held on the responder it meant a keyframe emitted for one window answered a PLI raised for
	// another, so a source that had never received a picture waited out a sibling's response
	// window. session.go recorded that as inert "because exactly one track ever sends today" --
	// true of how the session was used, not of the code, and one subscribe away from false.
	referenceRecovery           *referenceRecoveryAttempt
	keyframeRequestPending      bool
	keyframeResponseOutstanding bool
	keyframeResponseSentAt      time.Time
	packets                     map[uint16]*ageAwareCachedPacket
	packetOrder                 *list.List
	ledger                      map[uint16]*list.Element
	ledgerOrder                 *list.List
	retainedBytes               int
	unbound                     bool
}

type ageAwareCachedPacket struct {
	header  rtp.Header
	payload []byte
	sentAt  time.Time
	charge  int
	order   *list.Element
}

func (responder *ageAwareNACKResponder) markKeyframeSent(ssrc uint32, sequence uint16) {
	responder.mutex.Lock()
	closed := responder.closed
	stream := responder.streams[ssrc]
	responder.mutex.Unlock()
	if stream == nil {
		return
	}
	now := responder.config.Now()
	stream.mutex.Lock()
	entry := stream.ledger[sequence]
	if entry == nil {
		stream.mutex.Unlock()
		return
	}
	stream.keyframeStart = entry.Value.(ageAwareLedgerEntry).ordinal
	stream.hasKeyframeStart = true
	stream.referenceRecovery = nil
	if !closed && stream.keyframeRequestPending {
		stream.keyframeRequestPending = false
		stream.keyframeResponseOutstanding = true
		stream.keyframeResponseSentAt = now
	}
	stream.mutex.Unlock()
}

func (responder *ageAwareNACKResponder) drainCache() {
	responder.mutex.Lock()
	streams := make([]*ageAwareLocalStream, 0, len(responder.streams))
	for _, stream := range responder.streams {
		streams = append(streams, stream)
	}
	responder.mutex.Unlock()
	for _, stream := range streams {
		clearAgeAwareStream(stream, responder.config.CacheCounters)
	}
}

type ageAwareLedgerEntry struct {
	timestamp uint32
	sequence  uint16
	sentAt    time.Time
	ordinal   uint64
}

func (responder *ageAwareNACKResponder) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	if !supportsNACK(info) || info.SSRC == 0 || info.SSRCRetransmission == 0 ||
		info.PayloadTypeRetransmission == 0 {
		return writer
	}
	stream := &ageAwareLocalStream{
		info:        cloneStreamInfo(info),
		writer:      writer,
		sequencer:   rtp.NewRandomSequencer(),
		packets:     make(map[uint16]*ageAwareCachedPacket),
		packetOrder: list.New(),
		ledger:      make(map[uint16]*list.Element),
		ledgerOrder: list.New(),
	}
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI == frameMetadataURI && extension.ID > 0 && extension.ID <= 255 {
			stream.metadataExtensionID = uint8(extension.ID)
			break
		}
	}
	responder.mutex.Lock()
	if responder.closed {
		responder.mutex.Unlock()
		return writer
	}
	responder.streams[info.SSRC] = stream
	responder.mutex.Unlock()

	return interceptor.RTPWriterFunc(func(
		header *rtp.Header,
		payload []byte,
		attributes interceptor.Attributes,
	) (int, error) {
		if header.SSRC == info.SSRC {
			responder.cachePrimary(stream, header, payload)
		}
		return writer.Write(header, payload, attributes)
	})
}

func cloneStreamInfo(info *interceptor.StreamInfo) interceptor.StreamInfo {
	cloned := *info
	cloned.RTPHeaderExtensions = append(
		[]interceptor.RTPHeaderExtension(nil), info.RTPHeaderExtensions...,
	)
	cloned.RTCPFeedback = append([]interceptor.RTCPFeedback(nil), info.RTCPFeedback...)
	return cloned
}

// outgoingPacketStartsKeyframe is REDUNDANT AND INERT ON A BROWSER SESSION, and that is fine —
// but only because a second, extension-free path sets the same fields.
//
// Chrome's answer drops `urn:llv:rtp-frame-metadata:1` (measured 2026-08-19), so extensionID is 0
// against every browser and this returns false without looking. `keyframeStart`/`hasKeyframeStart`
// are still set, by `markKeyframeSent` — which `FrameTrack` fires from `frame.Keyframe && index == 0`,
// the ENCODER's own flag, with no negotiated extension involved. So `lossCanInvalidateLatestKeyframe`
// works on the product path.
//
// DO NOT DELETE EITHER PATH BELIEVING THE OTHER IS THE REAL ONE. This one is the only route for a
// receiver whose frames rdev did not encode itself; `markKeyframeSent` is the only route for a
// browser.
func outgoingPacketStartsKeyframe(extensionID uint8, header *rtp.Header) bool {
	if extensionID == 0 {
		return false
	}
	metadataBytes := header.GetExtension(extensionID)
	if len(metadataBytes) == 0 {
		return false
	}
	metadata, err := ParseFrameMetadata(metadataBytes)
	return err == nil && metadata.Keyframe && metadata.PacketIndex == 0
}

func (responder *ageAwareNACKResponder) cachePrimary(
	stream *ageAwareLocalStream,
	header *rtp.Header,
	payload []byte,
) bool {
	now := responder.config.Now()
	stream.mutex.Lock()
	defer stream.mutex.Unlock()
	if stream.unbound {
		return false
	}
	ordinal := stream.updateLedger(header.SequenceNumber, header.Timestamp, now)
	startsKeyframe := outgoingPacketStartsKeyframe(stream.metadataExtensionID, header)
	if startsKeyframe {
		stream.keyframeStart = ordinal
		stream.hasKeyframeStart = true
	}
	if previous := stream.packets[header.SequenceNumber]; previous != nil {
		stream.removePacket(
			previous, false, responder.config.Counters, responder.config.CacheCounters,
		)
	}
	clonedHeader := header.Clone()
	entry := &ageAwareCachedPacket{
		header: clonedHeader, payload: append([]byte(nil), payload...), sentAt: now,
		charge: clonedHeader.MarshalSize() + len(payload),
	}
	entry.order = stream.packetOrder.PushBack(entry)
	stream.packets[header.SequenceNumber] = entry
	stream.retainedBytes += entry.charge
	responder.config.CacheCounters.adjust(1, int64(entry.charge))
	stream.evictPayload(now, responder.config)
	return startsKeyframe
}

func (stream *ageAwareLocalStream) updateLedger(sequence uint16, timestamp uint32, sentAt time.Time) uint64 {
	if previous := stream.ledger[sequence]; previous != nil {
		stream.ledgerOrder.Remove(previous)
	}
	stream.ledgerOrdinal++
	ordinal := stream.ledgerOrdinal
	element := stream.ledgerOrder.PushBack(ageAwareLedgerEntry{
		sequence:  sequence,
		timestamp: timestamp,
		sentAt:    sentAt,
		ordinal:   ordinal,
	})
	stream.ledger[sequence] = element
	for stream.ledgerOrder.Len() > responderLedgerPackets {
		oldest := stream.ledgerOrder.Front()
		entry := oldest.Value.(ageAwareLedgerEntry)
		delete(stream.ledger, entry.sequence)
		stream.ledgerOrder.Remove(oldest)
	}
	return ordinal
}

func (stream *ageAwareLocalStream) lossCanInvalidateLatestKeyframe(
	entry ageAwareLedgerEntry,
) bool {
	if entry.ordinal <= stream.confirmedRecoveryEnd {
		return false
	}
	if live := stream.referenceRecovery; live != nil && live.firstOrdinal != 0 && entry.ordinal < live.firstOrdinal {
		return false
	}
	return !stream.hasKeyframeStart || entry.ordinal >= stream.keyframeStart
}

func (stream *ageAwareLocalStream) evictPayload(
	now time.Time,
	config AgeAwareResponderConfig,
) {
	maxAge := config.AgePolicy.EffectiveMaxAge()
	for element := stream.packetOrder.Front(); element != nil; {
		next := element.Next()
		entry := element.Value.(*ageAwareCachedPacket)
		if now.Sub(entry.sentAt) <= maxAge {
			break
		}
		stream.removePacket(entry, true, config.Counters, config.CacheCounters)
		element = next
	}
	for len(stream.packets) > config.MaxPackets || stream.retainedBytes > config.MaxBytes {
		oldest := stream.packetOrder.Front()
		if oldest == nil {
			break
		}
		stream.removePacket(
			oldest.Value.(*ageAwareCachedPacket), true, config.Counters, config.CacheCounters,
		)
	}
}

func (stream *ageAwareLocalStream) removePacket(
	entry *ageAwareCachedPacket,
	countEviction bool,
	counters *RecoveryCounters,
	cacheCounters *ResponderCacheCounters,
) {
	delete(stream.packets, entry.header.SequenceNumber)
	stream.packetOrder.Remove(entry.order)
	stream.retainedBytes -= entry.charge
	entry.payload = nil
	cacheCounters.adjust(-1, -int64(entry.charge))
	if countEviction {
		counters.addResponderCacheEviction()
	}
}

func (responder *ageAwareNACKResponder) BindRTCPReader(
	reader interceptor.RTCPReader,
) interceptor.RTCPReader {
	return interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		count, returnedAttributes, err := reader.Read(buffer, attributes)
		if err != nil {
			return 0, nil, err
		}
		if returnedAttributes == nil {
			returnedAttributes = make(interceptor.Attributes)
		}
		packets, err := returnedAttributes.GetRTCPPackets(buffer[:count])
		if err != nil {
			return 0, nil, err
		}
		responder.enqueueRTCP(packets)
		return count, returnedAttributes, nil
	})
}

func (responder *ageAwareNACKResponder) enqueueRTCP(packets []rtcp.Packet) {
	work := responderWork{
		packets: append([]rtcp.Packet(nil), packets...),
		done:    make(chan struct{}),
	}
	responder.mutex.Lock()
	if responder.closed {
		responder.mutex.Unlock()
		return
	}
	responder.work <- work
	responder.mutex.Unlock()
	<-work.done
}

func (responder *ageAwareNACKResponder) run() {
	defer responder.workers.Done()
	for work := range responder.work {
		responder.handleRTCP(work.packets)
		close(work.done)
	}
}

func (responder *ageAwareNACKResponder) handleRTCP(packets []rtcp.Packet) {
	for _, packet := range packets {
		switch value := packet.(type) {
		case *rtcp.TransportLayerNack:
			if !responder.hasStream(value.MediaSSRC) {
				continue
			}
			responder.config.ObserveNACK()
			requested := uint64(0)
			for index := range value.Nacks {
				value.Nacks[index].Range(func(sequence uint16) bool {
					requested++
					mediaSSRC := value.MediaSSRC
					requestedSequence := sequence
					responder.config.Trace.Record(recoveryTraceEvent{
						Layer: traceLayerPionResponder, Kind: traceNACKParsed,
						MediaSSRC: &mediaSSRC, RTPSequence: &requestedSequence,
					})
					responder.handleNACK(value.MediaSSRC, sequence)
					return true
				})
			}
			responder.config.Counters.addNACKReceived(requested)
		case *rtcp.FullIntraRequest:
			for _, entry := range value.FIR {
				if responder.hasStream(entry.SSRC) {
					responder.requestKeyframe("fir", entry.SSRC, nil, false)
				}
			}
		case *rtcp.PictureLossIndication:
			if responder.hasStream(value.MediaSSRC) {
				mediaSSRC := value.MediaSSRC
				responder.config.Trace.Record(recoveryTraceEvent{
					Layer: traceLayerPionResponder, Kind: tracePLIParsed,
					MediaSSRC: &mediaSSRC,
				})
				responder.requestKeyframe("pli", value.MediaSSRC, nil, false)
			}
		}
	}
}

func (responder *ageAwareNACKResponder) hasStream(ssrc uint32) bool {
	responder.mutex.Lock()
	defer responder.mutex.Unlock()
	return !responder.closed && responder.streams[ssrc] != nil
}

func (responder *ageAwareNACKResponder) handleNACK(mediaSSRC uint32, sequence uint16) {
	responder.mutex.Lock()
	if responder.closed {
		responder.mutex.Unlock()
		return
	}
	stream := responder.streams[mediaSSRC]
	responder.mutex.Unlock()
	if stream == nil {
		return
	}

	now := responder.config.Now()
	threshold := responder.config.AgePolicy.EffectiveMaxAge()
	stream.mutex.Lock()
	if stream.unbound {
		stream.mutex.Unlock()
		return
	}
	ledgerElement := stream.ledger[sequence]
	if ledgerElement == nil {
		stream.mutex.Unlock()
		responder.config.Counters.addResponderCacheMiss()
		responder.config.Counters.addRTXAgeDecision(rtxAgeDecisionCacheMiss, nil)
		responder.recordNACKClassification(
			traceNACKClassifiedCacheMiss, mediaSSRC, sequence, nil, threshold,
		)
		responder.requestKeyframe("generic-nack-cache-miss", mediaSSRC, &sequence, false)
		return
	}
	ledgerEntry := ledgerElement.Value.(ageAwareLedgerEntry)
	packetAge := now.Sub(ledgerEntry.sentAt)
	if packetAge > threshold {
		requestKeyframe := stream.lossCanInvalidateLatestKeyframe(ledgerEntry)
		stream.mutex.Unlock()
		responder.config.Counters.addStaleRTXRequestSuppressed()
		responder.config.Counters.addRTXAgeDecision(rtxAgeDecisionStale, &packetAge)
		responder.recordNACKClassification(
			traceNACKClassifiedStale, mediaSSRC, sequence, &packetAge, threshold,
		)
		if requestKeyframe {
			responder.requestKeyframe("generic-nack-stale", mediaSSRC, &sequence, true)
		}
		return
	}
	cached := stream.packets[sequence]
	if cached == nil {
		requestKeyframe := stream.lossCanInvalidateLatestKeyframe(ledgerEntry)
		stream.mutex.Unlock()
		responder.config.Counters.addResponderCacheMiss()
		responder.config.Counters.addRTXAgeDecision(rtxAgeDecisionCacheMiss, &packetAge)
		responder.recordNACKClassification(
			traceNACKClassifiedCacheMiss, mediaSSRC, sequence, &packetAge, threshold,
		)
		if requestKeyframe {
			responder.requestKeyframe("generic-nack-cache-miss", mediaSSRC, &sequence, true)
		}
		return
	}

	header := cached.header.Clone()
	header.SSRC = stream.info.SSRCRetransmission
	header.PayloadType = stream.info.PayloadTypeRetransmission
	header.SequenceNumber = stream.sequencer.NextSequenceNumber()
	header.Padding = false
	header.PaddingSize = 0
	payload := make([]byte, len(cached.payload)+2)
	binary.BigEndian.PutUint16(payload, sequence)
	copy(payload[2:], cached.payload)
	writer := stream.writer
	stream.mutex.Unlock()
	responder.config.Counters.addRTXAgeDecision(rtxAgeDecisionFresh, &packetAge)
	responder.recordNACKClassification(
		traceNACKClassifiedFresh, mediaSSRC, sequence, &packetAge, threshold,
	)

	if _, err := writer.Write(&header, payload, interceptor.Attributes{}); err != nil {
		if errors.Is(err, errRecoveryFrameClockSuppressed) {
			return
		}
		responder.reportError(fmt.Errorf("write RTX repair: %w", err))
		return
	}
	responder.config.Counters.addRTXSent(uint64(header.MarshalSize() + len(payload)))
	media := mediaSSRC
	originalSequence := sequence
	repairSequence := int64(header.SequenceNumber)
	responder.config.Trace.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: traceRTXEmitted,
		MediaSSRC: &media, RTPSequence: &originalSequence,
		NumericValue: &repairSequence,
	})
}

func (responder *ageAwareNACKResponder) recordNACKClassification(
	kind recoveryTraceKind,
	mediaSSRC uint32,
	sequence uint16,
	packetAge *time.Duration,
	threshold time.Duration,
) {
	media := mediaSSRC
	requestedSequence := sequence
	thresholdNanoseconds := int64(threshold)
	var packetAgeNanoseconds *int64
	if packetAge != nil {
		value := int64(*packetAge)
		packetAgeNanoseconds = &value
	}
	responder.config.Trace.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: kind,
		MediaSSRC: &media, RTPSequence: &requestedSequence,
		PacketAgeNanoseconds:       packetAgeNanoseconds,
		RTXAgeThresholdNanoseconds: &thresholdNanoseconds,
	})
}

// requestKeyframe gates one stream's need for a keyframe, and mediaSSRC is which stream.
//
// A STREAM THAT HAS UNBOUND SINCE THE CALLER CHECKED IS DROPPED rather than requested for. Both
// call paths already resolved the stream -- the PLI branch through hasStream, the NACK branches
// through streams[mediaSSRC] -- so the only way to arrive here without one is an unbind racing the
// request, and a keyframe for a track nobody is sending on has nowhere to go.
// announceKeyframeReason prints WHY a keyframe was asked for, ONCE PER REASON PER SESSION.
//
// THE REASON WAS ALREADY COMPUTED AND THROWN AWAY. It reaches `Trace`, which is inactive outside the
// certification harness, so on a real session the three causes were indistinguishable — and they want
// completely different fixes:
//
//	pli                     the RECEIVER asked; its decoder could not continue
//	generic-nack-stale      a NACK arrived for a packet older than RTXMaxAge, so the repair was
//	                        refused and the loss escalated to a keyframe instead
//	generic-nack-cache-miss a NACK arrived for a packet no longer in the send cache
//
// Measured on a real iPad, H.265 on a STILL window: keyframes exactly equal keyframe requests, five
// per second, 15-24% of the bitrate — and the same session on AV1 does not do it. Four mechanisms
// were checked by reading the source and none could be told apart that way, which is what this line
// exists to end.
//
// ONCE PER REASON, not per request: these are interceptor hot paths at five per second, and the RATE
// is already on the encoder's periodic `produced` line as `requested`. What was missing is WHICH.
func (responder *ageAwareNACKResponder) announceKeyframeReason(reason string) {
	if responder.shouldAnnounceKeyframeReasonForTest(reason) {
		fmt.Printf("[bridge] recovery: keyframe requested — reason %q (first this session)\n", reason)
	}
}

// shouldAnnounceKeyframeReasonForTest reports whether this reason has not been seen before, and
// records it. Split out from the printing so the once-per-reason rule is testable without capturing
// stdout — the rule is the logic; the print is not.
func (responder *ageAwareNACKResponder) shouldAnnounceKeyframeReasonForTest(reason string) bool {
	responder.mutex.Lock()
	defer responder.mutex.Unlock()
	if responder.announcedKeyframeReasons == nil {
		responder.announcedKeyframeReasons = map[string]bool{}
	}
	if responder.announcedKeyframeReasons[reason] {
		return false
	}
	responder.announcedKeyframeReasons[reason] = true
	return true
}

func (responder *ageAwareNACKResponder) requestKeyframe(
	reason string,
	mediaSSRC uint32,
	sequence *uint16,
	damageProven bool,
) {
	responder.mutex.Lock()
	closed := responder.closed
	stream := responder.streams[mediaSSRC]
	responder.mutex.Unlock()
	if stream == nil {
		return
	}
	now := responder.config.Now()
	var responseWait *int64
	stream.mutex.Lock()
	// Recheck under this lock: a presentation receipt may have arrived since handleNACK.
	if sequence != nil {
		if e := stream.ledger[*sequence]; e != nil && !stream.lossCanInvalidateLatestKeyframe(e.Value.(ageAwareLedgerEntry)) {
			stream.mutex.Unlock()
			return
		}
	}
	coalesced := closed || stream.keyframeRequestPending
	independent := false
	if live := stream.referenceRecovery; live != nil {
		if now.Sub(live.sentAt) < responder.referenceResponseWait() {
			coalesced = true
		} else {
			stream.referenceRecovery = nil
			// Host owns the bounded retry budget. Packet loss does not destroy its anchor.
			independent = false
			if damageProven {
				reason = "reference-response-damaged"
			} else {
				reason = "reference-response-timeout"
			}
		}
	}
	outstanding := stream.keyframeResponseOutstanding
	if outstanding && !damageProven {
		wait := responder.keyframeResponseWait()
		if reason == "pli" {
			waitNanoseconds := int64(wait)
			responseWait = &waitNanoseconds
		}
		if now.Sub(stream.keyframeResponseSentAt) < wait {
			coalesced = true
		}
	}
	if coalesced {
		stream.mutex.Unlock()
		if !closed && reason == "pli" && outstanding {
			responder.config.Counters.addPLIResponseCoalesced()
		}
		requestReason := reason
		responder.config.Trace.Record(recoveryTraceEvent{
			Layer: traceLayerPionResponder, Kind: traceKeyframeGateCoalesced,
			RTPSequence: sequence, Reason: &requestReason, NumericValue: responseWait,
		})
		return
	}
	stream.keyframeRequestPending = true
	stream.mutex.Unlock()
	requestReason := reason
	responder.config.Trace.Record(recoveryTraceEvent{
		Layer: traceLayerPionResponder, Kind: traceKeyframeGateOpened,
		RTPSequence: sequence, Reason: &requestReason, NumericValue: responseWait,
	})
	responder.announceKeyframeReason(reason)
	if !responder.callbackGate.begin() {
		return
	}
	defer responder.callbackGate.end()
	if responder.config.RequestRecovery != nil {
		responder.config.RequestRecovery(mediaSSRC, reason, independent)
	} else {
		responder.config.RequestKeyframe(mediaSSRC)
	}
}

func (responder *ageAwareNACKResponder) keyframeResponseWait() time.Duration {
	wait := defaultKeyframeResponseWait
	if rtt, _, ok := responder.config.MediaRTT.Snapshot(); ok {
		wait = 2 * rtt
		if wait > maximumKeyframeResponseWait {
			wait = maximumKeyframeResponseWait
		}
	}
	maxAge := responder.config.AgePolicy.EffectiveMaxAge()
	if wait < maxAge {
		wait = maxAge
	}
	return wait
}

func (responder *ageAwareNACKResponder) reportError(err error) {
	responder.reportErrorOnce.Do(func() {
		if !responder.callbackGate.begin() {
			return
		}
		defer responder.callbackGate.end()
		responder.config.ReportError(err)
	})
}

func (responder *ageAwareNACKResponder) UnbindLocalStream(info *interceptor.StreamInfo) {
	responder.mutex.Lock()
	stream := responder.streams[info.SSRC]
	delete(responder.streams, info.SSRC)
	responder.mutex.Unlock()
	clearAgeAwareStream(stream, responder.config.CacheCounters)
}

func clearAgeAwareStream(stream *ageAwareLocalStream, counters *ResponderCacheCounters) {
	if stream == nil {
		return
	}
	stream.mutex.Lock()
	packets := len(stream.packets)
	bytes := stream.retainedBytes
	stream.unbound = true
	for _, entry := range stream.packets {
		entry.payload = nil
	}
	stream.packets = nil
	stream.packetOrder.Init()
	stream.ledger = nil
	stream.ledgerOrder.Init()
	stream.retainedBytes = 0
	stream.mutex.Unlock()
	if packets != 0 || bytes != 0 {
		counters.adjust(-int64(packets), -int64(bytes))
	}
}

func (responder *ageAwareNACKResponder) Close() error {
	responder.closeOnce.Do(func() {
		responder.mutex.Lock()
		responder.closed = true
		responder.callbackGate.startClose()
		streams := responder.streams
		responder.streams = make(map[uint32]*ageAwareLocalStream)
		close(responder.work)
		responder.mutex.Unlock()

		responder.workers.Wait()
		responder.callbackGate.wait()
		for _, stream := range streams {
			clearAgeAwareStream(stream, responder.config.CacheCounters)
		}
	})
	return nil
}

func supportsNACK(info *interceptor.StreamInfo) bool {
	for _, feedback := range info.RTCPFeedback {
		if feedback.Type == "nack" && feedback.Parameter == "" {
			return true
		}
	}
	return false
}
