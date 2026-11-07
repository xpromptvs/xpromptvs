package main

import (
	"sync/atomic"
	"time"
)

type RTXAgeDecisionSnapshot struct {
	FreshRequests    uint64                 `json:"freshRequests"`
	StaleRequests    uint64                 `json:"staleRequests"`
	CacheMisses      uint64                 `json:"cacheMisses"`
	PacketAgeBuckets RTXAgePacketAgeBuckets `json:"packetAgeBuckets"`
}

type RTXAgePacketAgeBuckets struct {
	LE30  uint64 `json:"le30"`
	LE75  uint64 `json:"le75"`
	LE150 uint64 `json:"le150"`
	LE300 uint64 `json:"le300"`
	LE500 uint64 `json:"le500"`
	GT500 uint64 `json:"gt500"`
}

type rtxAgeDecisionClass uint8

const (
	rtxAgeDecisionFresh rtxAgeDecisionClass = iota + 1
	rtxAgeDecisionStale
	rtxAgeDecisionCacheMiss
)

type RecoverySnapshot struct {
	NACKPacketsSent            uint64                 `json:"nackPacketsSent"`
	NACKSequencesSent          uint64                 `json:"nackSequencesSent"`
	NACKPacketsReceived        uint64                 `json:"nackPacketsReceived"`
	NACKSequencesReceived      uint64                 `json:"nackSequencesReceived"`
	RTXPacketsSent             uint64                 `json:"rtxPacketsSent"`
	RTXBytesSent               uint64                 `json:"rtxBytesSent"`
	RTXPacketsReceived         uint64                 `json:"rtxPacketsReceived"`
	RTXBytesReceived           uint64                 `json:"rtxBytesReceived"`
	PacketsRepaired            uint64                 `json:"packetsRepaired"`
	StaleRTXRequestsSuppressed uint64                 `json:"staleRTXRequestsSuppressed"`
	ResponderCacheMisses       uint64                 `json:"responderCacheMisses"`
	ResponderCacheEvictions    uint64                 `json:"responderCacheEvictions"`
	RecoveryKeyframeRequests   uint64                 `json:"recoveryKeyframeRequests"`
	PLIResponsesCoalesced      uint64                 `json:"pliResponsesCoalesced"`
	IncompleteFramesExpired    uint64                 `json:"incompleteFramesExpired"`
	DependentFramesAbandoned   uint64                 `json:"dependentFramesAbandoned"`
	RTCPPacketsObserved        uint64                 `json:"rtcpPacketsObserved"`
	RRTRPacketsReceived        uint64                 `json:"rrtrPacketsReceived"`
	DLRRPacketsSent            uint64                 `json:"dlrrPacketsSent"`
	SenderReportsReceived      uint64                 `json:"senderReportsReceived"`
	RetainedFramesCurrent      uint64                 `json:"retainedFramesCurrent"`
	RetainedFramesPeak         uint64                 `json:"retainedFramesPeak"`
	RTXAgeDecisions            RTXAgeDecisionSnapshot `json:"rtxAgeDecisions"`
}

type RecoveryCounters struct {
	nackPacketsSent            atomic.Uint64
	nackSequencesSent          atomic.Uint64
	nackPacketsReceived        atomic.Uint64
	nackSequencesReceived      atomic.Uint64
	rtxPacketsSent             atomic.Uint64
	rtxBytesSent               atomic.Uint64
	rtxPacketsReceived         atomic.Uint64
	rtxBytesReceived           atomic.Uint64
	packetsRepaired            atomic.Uint64
	staleRTXRequestsSuppressed atomic.Uint64
	responderCacheMisses       atomic.Uint64
	responderCacheEvictions    atomic.Uint64
	recoveryKeyframeRequests   atomic.Uint64
	pliResponsesCoalesced      atomic.Uint64
	incompleteFramesExpired    atomic.Uint64
	dependentFramesAbandoned   atomic.Uint64
	rtcpPacketsObserved        atomic.Uint64
	rrtrPacketsReceived        atomic.Uint64
	dlrrPacketsSent            atomic.Uint64
	senderReportsReceived      atomic.Uint64
	retainedFramesCurrent      atomic.Uint64
	retainedFramesPeak         atomic.Uint64
	rtxAgeFreshRequests        atomic.Uint64
	rtxAgeStaleRequests        atomic.Uint64
	rtxAgeCacheMisses          atomic.Uint64
	rtxAgePacketBuckets        [6]atomic.Uint64
}

func (counters *RecoveryCounters) Snapshot() RecoverySnapshot {
	packetAgeBuckets := RTXAgePacketAgeBuckets{
		LE30:  counters.rtxAgePacketBuckets[0].Load(),
		LE75:  counters.rtxAgePacketBuckets[1].Load(),
		LE150: counters.rtxAgePacketBuckets[2].Load(),
		LE300: counters.rtxAgePacketBuckets[3].Load(),
		LE500: counters.rtxAgePacketBuckets[4].Load(),
		GT500: counters.rtxAgePacketBuckets[5].Load(),
	}
	return RecoverySnapshot{
		NACKPacketsSent:            counters.nackPacketsSent.Load(),
		NACKSequencesSent:          counters.nackSequencesSent.Load(),
		NACKPacketsReceived:        counters.nackPacketsReceived.Load(),
		NACKSequencesReceived:      counters.nackSequencesReceived.Load(),
		RTXPacketsSent:             counters.rtxPacketsSent.Load(),
		RTXBytesSent:               counters.rtxBytesSent.Load(),
		RTXPacketsReceived:         counters.rtxPacketsReceived.Load(),
		RTXBytesReceived:           counters.rtxBytesReceived.Load(),
		PacketsRepaired:            counters.packetsRepaired.Load(),
		StaleRTXRequestsSuppressed: counters.staleRTXRequestsSuppressed.Load(),
		ResponderCacheMisses:       counters.responderCacheMisses.Load(),
		ResponderCacheEvictions:    counters.responderCacheEvictions.Load(),
		RecoveryKeyframeRequests:   counters.recoveryKeyframeRequests.Load(),
		PLIResponsesCoalesced:      counters.pliResponsesCoalesced.Load(),
		IncompleteFramesExpired:    counters.incompleteFramesExpired.Load(),
		DependentFramesAbandoned:   counters.dependentFramesAbandoned.Load(),
		RTCPPacketsObserved:        counters.rtcpPacketsObserved.Load(),
		RRTRPacketsReceived:        counters.rrtrPacketsReceived.Load(),
		DLRRPacketsSent:            counters.dlrrPacketsSent.Load(),
		SenderReportsReceived:      counters.senderReportsReceived.Load(),
		RetainedFramesCurrent:      counters.retainedFramesCurrent.Load(),
		RetainedFramesPeak:         counters.retainedFramesPeak.Load(),
		RTXAgeDecisions: RTXAgeDecisionSnapshot{
			FreshRequests:    counters.rtxAgeFreshRequests.Load(),
			StaleRequests:    counters.rtxAgeStaleRequests.Load(),
			CacheMisses:      counters.rtxAgeCacheMisses.Load(),
			PacketAgeBuckets: packetAgeBuckets,
		},
	}
}

func (counters *RecoveryCounters) addRTXAgeDecision(
	class rtxAgeDecisionClass,
	packetAge *time.Duration,
) {
	switch class {
	case rtxAgeDecisionFresh:
		counters.rtxAgeFreshRequests.Add(1)
	case rtxAgeDecisionStale:
		counters.rtxAgeStaleRequests.Add(1)
	case rtxAgeDecisionCacheMiss:
		counters.rtxAgeCacheMisses.Add(1)
	}
	if packetAge == nil {
		return
	}
	index := 5
	for candidate, limit := range []time.Duration{
		30 * time.Millisecond,
		75 * time.Millisecond,
		150 * time.Millisecond,
		300 * time.Millisecond,
		500 * time.Millisecond,
	} {
		if *packetAge <= limit {
			index = candidate
			break
		}
	}
	counters.rtxAgePacketBuckets[index].Add(1)
}

func (counters *RecoveryCounters) addNACKSent(sequences uint64) {
	counters.nackPacketsSent.Add(1)
	counters.nackSequencesSent.Add(sequences)
}

func (counters *RecoveryCounters) addNACKReceived(sequences uint64) {
	counters.nackPacketsReceived.Add(1)
	counters.nackSequencesReceived.Add(sequences)
}

func (counters *RecoveryCounters) addRTXSent(bytes uint64) {
	counters.rtxPacketsSent.Add(1)
	counters.rtxBytesSent.Add(bytes)
}

func (counters *RecoveryCounters) addRTXReceived(bytes uint64) {
	counters.rtxPacketsReceived.Add(1)
	counters.rtxBytesReceived.Add(bytes)
}

func (counters *RecoveryCounters) addPacketRepaired() {
	counters.packetsRepaired.Add(1)
}

func (counters *RecoveryCounters) addStaleRTXRequestSuppressed() {
	counters.staleRTXRequestsSuppressed.Add(1)
}

func (counters *RecoveryCounters) addResponderCacheMiss() {
	counters.responderCacheMisses.Add(1)
}

func (counters *RecoveryCounters) addResponderCacheEviction() {
	counters.responderCacheEvictions.Add(1)
}

func (counters *RecoveryCounters) addRecoveryKeyframeRequest() {
	counters.recoveryKeyframeRequests.Add(1)
}

func (counters *RecoveryCounters) addPLIResponseCoalesced() {
	counters.pliResponsesCoalesced.Add(1)
}

func (counters *RecoveryCounters) addIncompleteFramesExpired(count uint64) {
	counters.incompleteFramesExpired.Add(count)
}

func (counters *RecoveryCounters) addDependentFramesAbandoned(count uint64) {
	counters.dependentFramesAbandoned.Add(count)
}

func (counters *RecoveryCounters) addRTCPPacketObserved() {
	counters.rtcpPacketsObserved.Add(1)
}

func (counters *RecoveryCounters) addRRTRReceived() {
	counters.rrtrPacketsReceived.Add(1)
}

func (counters *RecoveryCounters) addDLRRSent() {
	counters.dlrrPacketsSent.Add(1)
}

func (counters *RecoveryCounters) addSenderReportReceived() {
	counters.senderReportsReceived.Add(1)
}

func (counters *RecoveryCounters) setRetainedFrames(current uint64) {
	counters.retainedFramesCurrent.Store(current)
	for peak := counters.retainedFramesPeak.Load(); current > peak; peak = counters.retainedFramesPeak.Load() {
		if counters.retainedFramesPeak.CompareAndSwap(peak, current) {
			break
		}
	}
}
