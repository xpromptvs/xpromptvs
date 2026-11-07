package main

import "testing"

func TestRecoveryCountersSnapshotTracksEveryEventAndRetainedPeak(t *testing.T) {
	counters := &RecoveryCounters{}
	counters.addNACKSent(2)
	counters.addNACKReceived(3)
	counters.addRTXSent(100)
	counters.addRTXReceived(101)
	counters.addPacketRepaired()
	counters.addStaleRTXRequestSuppressed()
	counters.addResponderCacheMiss()
	counters.addResponderCacheEviction()
	counters.addRecoveryKeyframeRequest()
	counters.addPLIResponseCoalesced()
	counters.addIncompleteFramesExpired(2)
	counters.addDependentFramesAbandoned(3)
	counters.addRTCPPacketObserved()
	counters.addRRTRReceived()
	counters.addDLRRSent()
	counters.addSenderReportReceived()
	counters.setRetainedFrames(5)
	counters.setRetainedFrames(2)

	want := RecoverySnapshot{
		NACKPacketsSent:            1,
		NACKSequencesSent:          2,
		NACKPacketsReceived:        1,
		NACKSequencesReceived:      3,
		RTXPacketsSent:             1,
		RTXBytesSent:               100,
		RTXPacketsReceived:         1,
		RTXBytesReceived:           101,
		PacketsRepaired:            1,
		StaleRTXRequestsSuppressed: 1,
		ResponderCacheMisses:       1,
		ResponderCacheEvictions:    1,
		RecoveryKeyframeRequests:   1,
		PLIResponsesCoalesced:      1,
		IncompleteFramesExpired:    2,
		DependentFramesAbandoned:   3,
		RTCPPacketsObserved:        1,
		RRTRPacketsReceived:        1,
		DLRRPacketsSent:            1,
		SenderReportsReceived:      1,
		RetainedFramesCurrent:      2,
		RetainedFramesPeak:         5,
	}
	if got := counters.Snapshot(); got != want {
		t.Fatalf("snapshot = %#v, want %#v", got, want)
	}
}
