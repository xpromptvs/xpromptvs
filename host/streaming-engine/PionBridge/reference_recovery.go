package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"time"
)

var errReferenceRecovery = errors.New("independent AV1 recovery required")

type referenceToken struct {
	Epoch      string `json:"epoch"`
	FrameID    string `json:"frameId"`
	Slot       uint8  `json:"slot"`
	Generation string `json:"slotGeneration"`
}
type referenceFrameMetadata struct {
	Version         int             `json:"v"`
	Epoch           string          `json:"epoch"`
	FrameID         string          `json:"frameId"`
	Dependencies    []string        `json:"dependencies"`
	RefreshSlotMask uint8           `json:"refreshSlotMask"`
	Token           *referenceToken `json:"token,omitempty"`
	RecoveryID      string          `json:"recoveryId,omitempty"`
}
type referenceSendResult struct {
	RTPTimestamp    uint32 `json:"rtpTimestamp"`
	WireFrameNumber uint64 `json:"wireFrameNumber,string"`
	Complete        bool   `json:"complete"`
}

func referenceDecimal(s string) (uint64, error) {
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil || strconv.FormatUint(n, 10) != s {
		return 0, errReferenceRecovery
	}
	return n, nil
}
func (m referenceFrameMetadata) validate(key bool) (uint64, []uint64, error) {
	id, err := referenceDecimal(m.FrameID)
	if err != nil || m.Version != 1 || len(m.Epoch) == 0 || len(m.Epoch) > 128 || len(m.Dependencies) > 7 || len(m.RecoveryID) > 128 {
		return 0, nil, errReferenceRecovery
	}
	if key && (len(m.Dependencies) != 0 || m.RecoveryID != "" || m.RefreshSlotMask != 255) {
		return 0, nil, errReferenceRecovery
	}
	if !key && len(m.Dependencies) == 0 {
		return 0, nil, errReferenceRecovery
	}
	var deps []uint64
	seen := map[uint64]bool{}
	for _, s := range m.Dependencies {
		n, e := referenceDecimal(s)
		if e != nil || n >= id || seen[n] {
			return 0, nil, errReferenceRecovery
		}
		seen[n] = true
		deps = append(deps, n)
	}
	if m.Token != nil {
		token := m.Token
		if _, e := referenceDecimal(token.Generation); e != nil || token.Epoch != m.Epoch || token.FrameID != m.FrameID || token.Slot > 7 || m.RefreshSlotMask&(1<<token.Slot) == 0 {
			return 0, nil, errReferenceRecovery
		}
	}
	if m.RecoveryID != "" && (m.Token == nil || len(deps) != 1 || m.RefreshSlotMask != 63) {
		return 0, nil, errReferenceRecovery
	}
	return id, deps, nil
}
func parseReferenceMetadata(raw []byte, key bool) (referenceFrameMetadata, error) {
	var m referenceFrameMetadata
	if len(raw) == 0 || len(raw) > 4096 {
		return m, errReferenceRecovery
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, err
	}
	_, _, err := m.validate(key)
	return m, err
}

// Owned by the track mutex. Recent successful sends map full encoder IDs to
// full wire counters; at most eight current slot identities survive eviction.
// A partial send never enters either collection.
type referenceFrameLedger struct {
	lastRecovery *referenceReceipt
	lastWire     uint64
	hasLast      bool
	epoch        string
	frames       map[uint64]referenceSendResult
	order        []uint64
	retained     [8]*referenceReceipt
}
type referenceReceipt struct {
	Token      referenceToken
	RecoveryID string
	Result     referenceSendResult
}

func (l *referenceFrameLedger) Reset(epoch string) {
	*l = referenceFrameLedger{epoch: epoch, frames: make(map[uint64]referenceSendResult)}
}
func (l *referenceFrameLedger) RecordSent(id uint64, result referenceSendResult) {
	if !result.Complete {
		return
	}
	if l.frames == nil {
		l.frames = make(map[uint64]referenceSendResult)
	}
	if _, ok := l.frames[id]; !ok {
		l.order = append(l.order, id)
	}
	l.frames[id] = result
	l.lastWire = result.WireFrameNumber
	l.hasLast = true
	if len(l.order) > 512 {
		delete(l.frames, l.order[0])
		l.order = l.order[1:]
	}
}
func (l *referenceFrameLedger) RecordToken(m referenceFrameMetadata, result referenceSendResult) {
	if !result.Complete {
		return
	}
	for slot := range l.retained {
		if m.RefreshSlotMask&(1<<slot) != 0 {
			l.retained[slot] = nil
		}
	}
	if m.Token != nil {
		l.retained[m.Token.Slot] = &referenceReceipt{Token: *m.Token, RecoveryID: m.RecoveryID, Result: result}
		if m.RecoveryID != "" {
			l.lastRecovery = l.retained[m.Token.Slot]
		}
	}
}
func (l *referenceFrameLedger) MatchReceipt(token referenceToken, recoveryID string, timestamp uint32) bool {
	if token.Epoch != l.epoch || token.Slot > 7 {
		return false
	}
	r := l.retained[token.Slot]
	if recoveryID != "" {
		r = l.lastRecovery
	}
	return r != nil && r.Token == token && r.RecoveryID == recoveryID && r.Result.Complete && r.Result.RTPTimestamp == timestamp
}
func (l *referenceFrameLedger) Dependencies(epoch string, ids []uint64, next uint64) ([]uint16, error) {
	if epoch != l.epoch {
		return nil, errReferenceRecovery
	}
	diffs := make([]uint16, 0, len(ids))
	for _, id := range ids {
		result, ok := l.frames[id]
		if !ok {
			for _, r := range l.retained {
				if r != nil && r.Token.FrameID == strconv.FormatUint(id, 10) {
					result = r.Result
					ok = true
					break
				}
			}
		}
		if !ok || !result.Complete || next <= result.WireFrameNumber || next-result.WireFrameNumber > 4096 {
			return nil, fmt.Errorf("%w: missing or distant frame %d", errReferenceRecovery, id)
		}
		diffs = append(diffs, uint16(next-result.WireFrameNumber))
	}
	sort.Slice(diffs, func(i, j int) bool { return diffs[i] < diffs[j] })
	return diffs, nil
}

// The encoder is the sole writer for an eligible source. The send path checks
// the distance again under the track lock, so a stale observation fails closed.
func (session *Session) NextReferenceFrame(slot int) (uint64, error) {
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	closing := session.closing
	session.mutex.Unlock()
	if closing || entry == nil {
		return 0, errReferenceRecovery
	}
	track := entry.track
	track.mutex.Lock()
	defer track.mutex.Unlock()
	if len(track.bindings) != 1 {
		return 0, errReferenceRecovery
	}
	for _, b := range track.bindings {
		if !b.profile.emitsDependencyDescriptor || b.dependencyDescriptorExtensionID == 0 {
			return 0, errReferenceRecovery
		}
	}
	return track.dependencyFrameNumber, nil
}

func (peer *rdevPeer) writeReferenceVideo(slot int, payload []byte, pts int64, key bool, metadata referenceFrameMetadata, onSent func([]byte)) error {
	result, err := peer.session.WriteVideoReference(slot, payload, pts, key, metadata)
	if err != nil {
		return err
	}
	peer.recordReferenceTestFrame(slot, metadata, result, key, payload)
	if metadata.RecoveryID != "" && peer.session.apiResources != nil && peer.session.apiResources.responderFactory != nil {
		peer.session.ReferenceRecoveryOutcome(slot, metadata.Epoch, metadata.RecoveryID, "sent")
	}
	if metadata.Token != nil {
		peer.armReferenceTestFIR(slot, metadata.Epoch)
	}
	if metadata.Token != nil && onSent != nil {
		rttNs := ""
		if peer.session.apiResources != nil {
			if rtt, _, ok := peer.session.apiResources.MediaRTTSnapshot(); ok && rtt > 0 {
				rttNs = strconv.FormatInt(int64(rtt), 10)
			}
		}
		data, err := json.Marshal(struct {
			Metadata referenceFrameMetadata `json:"metadata"`
			Result   referenceSendResult    `json:"result"`
			RTTNs    string                 `json:"rttNs,omitempty"`
		}{metadata, result, rttNs})
		if err != nil {
			return err
		}
		// Both entry and track locks have been released before the callback is queued.
		peer.enqueue(func() { onSent(data) })
	}
	return nil
}

type referenceRecoveryAttempt struct {
	epoch, id                 string
	sentAt                    time.Time
	firstOrdinal, lastOrdinal uint64
}

func (factory *ageAwareNACKResponderFactory) referenceOutcome(ssrc uint32, epoch, id, kind string, timestamps ...uint32) {
	factory.mutex.Lock()
	responders := make([]*ageAwareNACKResponder, 0, len(factory.responders))
	for r := range factory.responders {
		responders = append(responders, r)
	}
	factory.mutex.Unlock()
	for _, r := range responders {
		r.mutex.Lock()
		stream := r.streams[ssrc]
		closed := r.closed
		r.mutex.Unlock()
		if stream == nil || closed {
			continue
		}
		now := r.config.Now()
		stream.mutex.Lock()
		if kind == "sent" {
			// A validated host timer retry need not have a new RTCP request.
			if stream.referenceRecovery == nil {
				live := &referenceRecoveryAttempt{epoch: epoch, id: id, sentAt: now}
				// Match the actual RTP timestamp, not whatever ordinary frame was last by
				// the time the ordered Swift callback returned. Zero is a valid timestamp.
				var stamp uint32
				if len(timestamps) > 0 {
					stamp = timestamps[0]
				} else if e := stream.ledgerOrder.Back(); e != nil {
					stamp = e.Value.(ageAwareLedgerEntry).timestamp
				}
				for e := stream.ledgerOrder.Back(); e != nil; e = e.Prev() {
					packet := e.Value.(ageAwareLedgerEntry)
					if packet.timestamp == stamp {
						if live.lastOrdinal == 0 {
							live.lastOrdinal = packet.ordinal
						}
						live.firstOrdinal = packet.ordinal
					} else if live.lastOrdinal != 0 {
						break
					}
				}
				stream.referenceRecovery = live
				stream.keyframeRequestPending = false
				stream.keyframeResponseOutstanding = false
			}
		} else if live := stream.referenceRecovery; live != nil && live.epoch == epoch && live.id == id {
			if kind == "presented" && live.lastOrdinal > stream.confirmedRecoveryEnd {
				stream.confirmedRecoveryEnd = live.lastOrdinal
			}
			stream.referenceRecovery = nil
			stream.keyframeRequestPending = false
		}
		stream.mutex.Unlock()
	}
}
func (f *ageAwareNACKResponderFactory) MarkReferenceRecoverySent(ssrc uint32, epoch, id string) {
	f.referenceOutcome(ssrc, epoch, id, "sent")
}
func (f *ageAwareNACKResponderFactory) MarkReferenceRecoveryPresented(ssrc uint32, epoch, id string) {
	f.referenceOutcome(ssrc, epoch, id, "presented")
}
func (f *ageAwareNACKResponderFactory) FailReferenceRecovery(ssrc uint32, epoch, id string) {
	f.referenceOutcome(ssrc, epoch, id, "failed")
}
func (f *ageAwareNACKResponderFactory) CancelReferenceRecovery(ssrc uint32, epoch, id string) {
	f.referenceOutcome(ssrc, epoch, id, "cancelled")
}
func (r *ageAwareNACKResponder) referenceResponseWait() time.Duration {
	if rtt, _, ok := r.config.MediaRTT.Snapshot(); ok {
		return min(2*time.Second, max(500*time.Millisecond, 4*rtt))
	}
	return time.Second
}

func (session *Session) ReferenceRecoveryOutcome(slot int, epoch, id, kind string) bool {
	if epoch == "" || id == "" || len(epoch) > 128 || len(id) > 128 {
		return false
	}
	switch kind {
	case "sent", "presented", "failed", "cancelled":
	default:
		return false
	}
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	closing := session.closing
	session.mutex.Unlock()
	if closing || entry == nil || session.apiResources == nil || session.apiResources.responderFactory == nil {
		return false
	}
	track := entry.track
	track.mutex.Lock()
	record := track.referenceLedger.lastRecovery
	if record == nil || record.Token.Epoch != epoch || record.RecoveryID != id || !record.Result.Complete {
		track.mutex.Unlock()
		return false
	}
	timestamp := record.Result.RTPTimestamp
	var ssrcs []uint32
	for _, b := range track.bindings {
		ssrcs = append(ssrcs, uint32(b.ssrc))
	}
	if kind != "sent" {
		track.referenceLedger.lastRecovery = nil
	}
	track.mutex.Unlock()
	for _, ssrc := range ssrcs {
		session.apiResources.responderFactory.referenceOutcome(ssrc, epoch, id, kind, timestamp)
	}
	return len(ssrcs) > 0
}

func (peer *rdevPeer) referenceRTPAllowed(slot int) bool {
	if peer == nil || peer.session == nil {
		return false
	}
	registry := peer.session.dcDelivery.Load()
	return registry == nil || registry.sourceIndexFor(slot) < 0
}
