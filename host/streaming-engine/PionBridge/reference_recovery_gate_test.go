package main

import (
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"io"
	"testing"
	"time"
)

func TestReferenceRecoveryCompletesWithoutMovingKeyframeBoundary(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(900, 0)}
	requests := 0
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond, Now: clock.Now, RequestKeyframe: func(uint32) { requests++ }}, nil)
	h.writePrimary(t, 1, []byte{1}, nil)
	h.factory.MarkKeyframeSent(10, 1)
	boundary := h.stream.keyframeStart
	readRTCPPackets(t, h.interceptor, []rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: 10}})
	if requests != 1 {
		t.Fatal(requests)
	}
	h.factory.MarkReferenceRecoverySent(10, "e", "1")
	if h.stream.keyframeRequestPending || h.stream.keyframeStart != boundary {
		t.Fatal("inter response stayed pending or moved keyframe boundary")
	}
	readRTCPPackets(t, h.interceptor, []rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: 10}})
	if requests != 1 {
		t.Fatal("duplicate PLI was not coalesced")
	}
	h.factory.MarkReferenceRecoveryPresented(10, "old", "1")
	readRTCPPackets(t, h.interceptor, []rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: 10}})
	if requests != 1 {
		t.Fatal("stale epoch completed attempt")
	}
	h.factory.MarkReferenceRecoveryPresented(10, "e", "1")
	readRTCPPackets(t, h.interceptor, []rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: 10}})
	if requests != 2 || h.stream.keyframeStart != boundary {
		t.Fatal("presentation did not release gate")
	}
}
func TestReferenceRecoveryTimeoutAndDamageKeepHostRetryPolicy(t *testing.T) {
	for _, damage := range []bool{false, true} {
		clock := &responderFakeClock{now: time.Unix(900, 0)}
		var independent []bool
		h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond, Now: clock.Now,
			RequestRecovery: func(_ uint32, _ string, force bool) { independent = append(independent, force) }}, nil)
		r := h.interceptor.(*ageAwareNACKResponder)
		r.requestKeyframe("pli", 10, nil, false)
		h.factory.MarkReferenceRecoverySent(10, "e", "1")
		if damage {
			h.writePrimary(t, 2, []byte{2}, nil)
			clock.Advance(time.Second)
			readNACK(t, h.interceptor, &rtcp.TransportLayerNack{MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 2}}})
		} else {
			clock.Advance(time.Second)
			r.requestKeyframe("pli", 10, nil, false)
		}
		if len(independent) != 2 || independent[0] || independent[1] {
			t.Fatalf("fallback intent: %v", independent)
		}
		h.factory.MarkReferenceRecoveryPresented(10, "e", "1")
		if !h.stream.keyframeRequestPending {
			t.Fatal("late receipt undid fallback")
		}
	}
}
func TestFIRUsesOnlyTheResponderGate(t *testing.T) {
	requests := 0
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond, RequestKeyframe: func(uint32) { requests++ }}, nil)
	raw, err := rtcp.Marshal([]rtcp.Packet{&rtcp.FullIntraRequest{FIR: []rtcp.FIREntry{{SSRC: 10, SequenceNumber: 1}}}})
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	reader := h.interceptor.BindRTCPReader(interceptor.RTCPReaderFunc(func(b []byte, a interceptor.Attributes) (int, interceptor.Attributes, error) {
		if reads > 0 {
			return 0, a, io.EOF
		}
		reads++
		return copy(b, raw), a, nil
	}))
	legacy := 0
	readFrameTrackRTCP(reader, func() { legacy++ }, false, false)
	if requests != 1 || legacy != 0 {
		t.Fatalf("FIR responder=%d legacy=%d", requests, legacy)
	}
	h.factory.MarkReferenceRecoverySent(10, "e", "1")
	readRTCPPackets(t, h.interceptor, []rtcp.Packet{&rtcp.FullIntraRequest{FIR: []rtcp.FIREntry{{SSRC: 10, SequenceNumber: 2}}}})
	if requests != 1 {
		t.Fatal("FIR bypassed active inter attempt")
	}
}
func TestReferenceRecoveryFailureAndCancelReleaseOnlyTheirStream(t *testing.T) {
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond}, nil)
	r := h.interceptor.(*ageAwareNACKResponder)
	info := h.stream.info
	info.SSRC = 11
	info.SSRCRetransmission = 21
	r.BindLocalStream(&info, interceptor.RTPWriterFunc(func(_ *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) { return len(p), nil }))
	r.requestKeyframe("pli", 10, nil, false)
	r.requestKeyframe("pli", 11, nil, false)
	h.factory.MarkReferenceRecoverySent(10, "e", "1")
	h.factory.MarkReferenceRecoverySent(11, "other", "1")
	h.factory.FailReferenceRecovery(10, "e", "1")
	if r.streams[10].referenceRecovery != nil || r.streams[11].referenceRecovery == nil {
		t.Fatal("failure crossed streams")
	}
	h.factory.CancelReferenceRecovery(11, "other", "1")
	if r.streams[11].referenceRecovery != nil {
		t.Fatal("cancel left attempt outstanding")
	}
}

func TestReferenceRecoveryReceiptSurvivesNormalSlotReuse(t *testing.T) {
	var ledger referenceFrameLedger
	ledger.Reset("e")
	token := referenceToken{Epoch: "e", FrameID: "70", Slot: 0, Generation: "2"}
	result := referenceSendResult{RTPTimestamp: 200, WireFrameNumber: 70, Complete: true}
	ledger.RecordToken(referenceFrameMetadata{Epoch: "e", FrameID: "70", RefreshSlotMask: 63, Token: &token, RecoveryID: "attempt"}, result)
	ledger.RecordToken(referenceFrameMetadata{Epoch: "e", FrameID: "71", RefreshSlotMask: 1}, referenceSendResult{RTPTimestamp: 201, WireFrameNumber: 71, Complete: true})
	if !ledger.MatchReceipt(token, "attempt", 200) {
		t.Fatal("normal slot reuse revoked an in-flight recovery receipt")
	}
	ledger.Reset("new")
	if ledger.MatchReceipt(token, "attempt", 200) {
		t.Fatal("epoch reset retained recovery")
	}
}
func TestRecoveryRequestKeepsReasonAndIndependentIntent(t *testing.T) {
	var reasons []string
	legacy := 0
	session := &Session{callbackGate: newCallbackGate(), apiResources: &peerAPIResources{counters: &RecoveryCounters{}}, callbacks: SessionCallbacks{
		OnRecoveryKeyframe: func(uint64) { legacy++ },
		OnRecoveryRequest: func(stream uint64, reason string, independent bool) {
			if stream != 2 || independent {
				t.Fatal("incorrect repair intent")
			}
			reasons = append(reasons, reason)
		},
	}}
	session.emitRecoveryRequest(2, "fir", false)
	session.emitRecoveryKeyframe(2)
	if len(reasons) != 1 || reasons[0] != "fir" || legacy != 1 {
		t.Fatalf("reason lost or duplicate handler: %v %d", reasons, legacy)
	}
}

func TestPartialReferenceSendNeverOpensAnOutstandingResponse(t *testing.T) {
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond}, nil)
	r := h.interceptor.(*ageAwareNACKResponder)
	r.requestKeyframe("pli", 10, nil, false)
	track := NewFrameTrack("video", "source")
	writer := &referenceFailWriter{failAt: 2}
	track.bindings["ref"] = &frameTrackBinding{id: "ref", ssrc: 10, profile: videoCodecProfiles()[0], writer: writer, playoutDelayExtensionID: 8, dependencyDescriptorExtensionID: 9}
	peer := &rdevPeer{session: &Session{videoTracks: map[int]*videoTrackSlot{0: {track: track}}, apiResources: &peerAPIResources{responderFactory: h.factory}}}
	token := referenceToken{Epoch: "e", FrameID: "1", Slot: 6, Generation: "1"}
	err := peer.writeReferenceVideo(0, testAV1AccessUnit(4000), 1, true, referenceFrameMetadata{Version: 1, Epoch: "e", FrameID: "1", RefreshSlotMask: 255, Token: &token}, nil)
	if err == nil || h.stream.referenceRecovery != nil || h.stream.keyframeResponseOutstanding {
		t.Fatal("partial send became an outstanding response")
	}
}

func TestReferenceBindingNamesAUniqueTrackAfterReplacement(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	first, err := session.AddVideoTrack("win:1")
	if err != nil {
		t.Fatal(err)
	}
	old := session.videoTrackForTest(first).ID()
	if err := session.RemoveVideoTrack(first); err != nil {
		t.Fatal(err)
	}
	second, err := session.AddVideoTrack("win:1")
	if err != nil {
		t.Fatal(err)
	}
	if session.videoTrackForTest(second).ID() == old {
		t.Fatal("replacement binding can name the old receiver")
	}
	if session.videoTrackForTest(second).StreamID() != "win:1" {
		t.Fatal("source identity changed")
	}
}

func TestReferenceRTPAdmissionIgnoresUnusedDataChannelRegistry(t *testing.T) {
	peer := &rdevPeer{session: &Session{}}
	if !peer.referenceRTPAllowed(0) {
		t.Fatal("plain RTP refused")
	}
	registry := &dcDelivery{streams: map[int]*dcVideoStream{}}
	peer.session.dcDelivery.Store(registry)
	if !peer.referenceRTPAllowed(0) {
		t.Fatal("the product always has an empty DC registry; it is not DC media")
	}
	registry.streams[1] = &dcVideoStream{sourceIndex: 1}
	if !peer.referenceRTPAllowed(0) {
		t.Fatal("another source's DC routing blocked RTP")
	}
	registry.streams[0] = &dcVideoStream{sourceIndex: 0}
	if peer.referenceRTPAllowed(0) {
		t.Fatal("actual DC media admitted")
	}
}

func TestInstrumentedFIRTraversesTheRealRTCPReader(t *testing.T) {
	var reasons []string
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond,
		RequestRecovery: func(ssrc uint32, reason string, independent bool) {
			if ssrc != 10 || independent {
				t.Errorf("wrong FIR request: %d %v", ssrc, independent)
			}
			reasons = append(reasons, reason)
		}}, nil)
	raw, err := (&rtcp.FullIntraRequest{FIR: []rtcp.FIREntry{{SSRC: 10, SequenceNumber: 1}}}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.factory.injectReferenceTestRTCP(raw); err != nil {
		t.Fatal(err)
	}
	if len(reasons) != 1 || reasons[0] != "fir" {
		t.Fatalf("FIR did not reach handler: %v", reasons)
	}
	if err := h.factory.injectReferenceTestRTCP([]byte{1, 2}); err == nil {
		t.Fatal("malformed RTCP accepted")
	}
}

func TestOldLossDoesNotInvalidateReferenceRepair(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(900, 0)}
	requests := 0
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestRecovery: func(_ uint32, _ string, _ bool) { requests++ }}, nil)
	h.writePrimary(t, 1, []byte{1}, nil)
	h.factory.MarkKeyframeSent(10, 1)
	h.writePrimary(t, 2, []byte{2}, nil)
	clock.Advance(31 * time.Millisecond)
	nack := func() {
		readNACK(t, h.interceptor, &rtcp.TransportLayerNack{MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: 2}}})
	}
	nack()
	h.writePrimary(t, 3, []byte{3}, nil)
	h.factory.MarkReferenceRecoverySent(10, "e", "1")
	nack()
	if requests != 1 {
		t.Fatalf("old loss requested another recovery during repair: %d", requests)
	}
	h.factory.MarkReferenceRecoveryPresented(10, "e", "1")
	nack()
	if requests != 1 {
		t.Fatalf("obsolete loss requested recovery after presentation: %d", requests)
	}
	if h.stream.keyframeStart != 1 {
		t.Fatal("reference recovery changed keyframe cache boundary")
	}
}

func TestReferenceBoundaryUsesWholeResponseTimestampAcrossWrapAndDelayedCallback(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(900, 0)}
	requests := 0
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestRecovery: func(_ uint32, _ string, independent bool) {
			if independent {
				t.Error("transport bypassed host retry budget")
			}
			requests++
		}}, nil)
	write := func(seq uint16, stamp uint32) {
		h.writePrimary(t, seq, []byte{1}, &rtp.Header{Version: 2, PayloadType: 45, SSRC: 10, SequenceNumber: seq, Timestamp: stamp})
	}
	nack := func(seq uint16) {
		readNACK(t, h.interceptor, &rtcp.TransportLayerNack{MediaSSRC: 10, Nacks: []rtcp.NackPair{{PacketID: seq}}})
	}
	write(65533, 100)
	h.factory.MarkKeyframeSent(10, 65533)
	write(65534, 200)
	clock.Advance(31 * time.Millisecond)
	nack(65534)
	write(65535, 300)
	write(0, 300)
	write(1, 400)
	// Ordinary data already followed the two-packet response when the callback arrived.
	h.factory.referenceOutcome(10, "e", "repair", "sent", 300)
	nack(65534)
	if requests != 1 {
		t.Fatal("pre-response loss was not ignored")
	}
	h.factory.MarkReferenceRecoveryPresented(10, "e", "repair")
	clock.Advance(31 * time.Millisecond)
	nack(65535)
	nack(0)
	if requests != 1 {
		t.Fatal("confirmed response packets still trigger recovery")
	}
	nack(1)
	if requests != 2 {
		t.Fatal("new damage after the response was incorrectly hidden")
	}
	if h.stream.keyframeStart != 1 {
		t.Fatal("keyframe-specific boundary changed")
	}
}

func TestReferenceTimerRetryNeedsNoNewRTCPRequest(t *testing.T) {
	h := newResponderHarness(t, AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond}, nil)
	h.stream.keyframeRequestPending = true
	h.writePrimary(t, 1, []byte{1}, nil)
	h.factory.MarkReferenceRecoverySent(10, "e", "first")
	h.factory.FailReferenceRecovery(10, "e", "first")
	h.writePrimary(t, 2, []byte{2}, nil)
	h.factory.MarkReferenceRecoverySent(10, "e", "retry")
	if h.stream.referenceRecovery == nil {
		t.Fatal("host timer retry was not registered")
	}
	h.factory.MarkReferenceRecoveryPresented(10, "e", "retry")
	if h.stream.confirmedRecoveryEnd != 2 {
		t.Fatalf("retry did not confirm loss boundary: %d", h.stream.confirmedRecoveryEnd)
	}
}
