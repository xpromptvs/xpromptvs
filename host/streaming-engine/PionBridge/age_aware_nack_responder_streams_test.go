package main

import (
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

// ONE RESPONDER SERVES EVERY VIDEO TRACK ON A SESSION, and rdev opens one track per subscribed
// window. These tests are about the state that spans them.
//
// The per-SSRC ledger (ageAwareLocalStream) was always correctly scoped. The KEYFRAME GATE was
// not: keyframeRequestPending / keyframeResponseOutstanding / keyframeResponseSentAt lived on the
// responder, so a keyframe sent on one track answered a request made for another. That was
// recorded in session.go as inert "because exactly one track ever sends today" -- a property of
// how the session was used, not of the code, and one click in the client away from being false.
//
// EVERY CALL SITE ALREADY HAD THE SSRC. requestKeyframe's three callers are the PLI branch
// (value.MediaSSRC, already checked against hasStream) and two NACK branches (mediaSSRC), so
// keying the gate needed no new plumbing -- only for the state to be stored where its question is
// asked.

// bindResponderStream adds a SECOND local stream to an existing responder, which is what the
// single-stream harness cannot express and what every test here needs.
func bindResponderStream(
	t *testing.T,
	harness *responderHarness,
	ssrc, retransmission uint32,
) interceptor.RTPWriter {
	t.Helper()
	info := &interceptor.StreamInfo{
		SSRC:                      ssrc,
		SSRCRetransmission:        retransmission,
		PayloadType:               45,
		PayloadTypeRetransmission: 46,
		RTCPFeedback:              []interceptor.RTCPFeedback{{Type: "nack"}},
		RTPHeaderExtensions: []interceptor.RTPHeaderExtension{
			{URI: frameMetadataURI, ID: 3},
		},
	}
	writer := harness.interceptor.BindLocalStream(info, interceptor.RTPWriterFunc(func(
		header *rtp.Header,
		payload []byte,
		_ interceptor.Attributes,
	) (int, error) {
		return len(payload), nil
	}))
	concrete, ok := harness.interceptor.(*ageAwareNACKResponder)
	if !ok {
		t.Fatalf("responder type = %T", harness.interceptor)
	}
	concrete.mutex.Lock()
	stream := concrete.streams[ssrc]
	concrete.mutex.Unlock()
	if stream == nil {
		t.Fatalf("stream %d did not bind", ssrc)
	}
	return writer
}

// writeOnStream sends one media packet on a secondary stream, so that stream has a ledger to lose
// packets from.
func writeOnStream(
	t *testing.T,
	writer interceptor.RTPWriter,
	ssrc uint32,
	sequence uint16,
	keyframe bool,
) {
	t.Helper()
	header := &rtp.Header{
		Version: 2, PayloadType: 45, SequenceNumber: sequence,
		Timestamp: uint32(sequence) * 3_000, SSRC: ssrc,
	}
	if keyframe {
		metadata, err := (FrameMetadata{
			Version: frameMetadataVersion, Keyframe: true, StreamID: 1,
			FrameID: uint64(sequence), PacketCount: 1, OriginalAccessUnitBytes: 1,
		}).MarshalBinary()
		if err != nil {
			t.Fatal(err)
		}
		if err := header.SetExtension(3, metadata); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := writer.Write(header, []byte{byte(sequence)}, nil); err != nil {
		t.Fatal(err)
	}
}

// newTwoStreamResponder builds a responder carrying two bound local streams, the shape rdev has
// whenever a client subscribes to a second window.
func newTwoStreamResponder(
	t *testing.T,
	clock *responderFakeClock,
	keyframes *atomic.Uint64,
) (*responderHarness, interceptor.RTPWriter) {
	t.Helper()
	harness := newResponderHarness(t, AgeAwareResponderConfig{
		MaxAge: 30 * time.Millisecond, Now: clock.Now,
		RequestKeyframe: func(uint32) { keyframes.Add(1) },
	}, nil)
	second := bindResponderStream(t, harness, 11, 21)
	return harness, second
}

// A PLI on one track must not swallow a PLI on another. Both receivers are missing a picture; one
// keyframe request names no track, so answering both with a single request is only correct if the
// two tracks are the same track.
func TestKeyframeGateDoesNotCoalesceAcrossStreams(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_000, 0)}
	var keyframes atomic.Uint64
	harness, second := newTwoStreamResponder(t, clock, &keyframes)
	harness.writePrimary(t, 1, []byte{1}, nil)
	writeOnStream(t, second, 11, 1, false)

	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 11},
	})

	if got := keyframes.Load(); got != 2 {
		t.Fatalf("keyframe requests = %d, want 2 (one per stream); "+
			"a PLI on stream 11 was coalesced into stream 10's pending request", got)
	}
}

// The response latch is the same defect one step later: stream 10's keyframe SENT must not
// satisfy stream 11's outstanding need for one. This is the reachable half -- markKeyframeSent is
// per stream, so whichever encoder emits first clears the gate for every other source.
func TestOneStreamsKeyframeDoesNotSatisfyAnothersRequest(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_000, 0)}
	var keyframes atomic.Uint64
	harness, second := newTwoStreamResponder(t, clock, &keyframes)
	harness.writePrimary(t, 1, []byte{1}, nil)
	writeOnStream(t, second, 11, 1, false)

	// Stream 10 asks, and its encoder answers.
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})
	harness.writePrimary(t, 2, []byte{2}, keyframeHeaderForStream(t, 10, 2))
	harness.factory.MarkKeyframeSent(10, 2)

	// Stream 11 has still never had one.
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 11},
	})

	if got := keyframes.Load(); got != 2 {
		t.Fatalf("keyframe requests = %d, want 2; stream 10's keyframe answered stream 11's PLI, "+
			"so a source that never received a picture waited out another source's response window",
			got)
	}
}

// A NACK that PROVES its own stream's latest keyframe is damaged bypasses the response latch
// (damageProven). It must not be swallowed by another stream's merely-pending request.
func TestProvenDamageIsNotCoalescedByAnotherStreamsPendingRequest(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_000, 0)}
	var keyframes atomic.Uint64
	harness, second := newTwoStreamResponder(t, clock, &keyframes)

	// Stream 11 gets a keyframe, then a packet after it that will go stale.
	writeOnStream(t, second, 11, 1, true)
	harness.factory.MarkKeyframeSent(11, 1)
	writeOnStream(t, second, 11, 2, false)

	// Stream 10 opens the gate first.
	harness.writePrimary(t, 1, []byte{1}, nil)
	readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
		&rtcp.PictureLossIndication{MediaSSRC: 10},
	})

	// Stream 11 now loses a packet at or after its own keyframe, too old to repair.
	clock.Advance(31 * time.Millisecond)
	readNACK(t, harness.interceptor, &rtcp.TransportLayerNack{
		MediaSSRC: 11, Nacks: []rtcp.NackPair{{PacketID: 2}},
	})

	if got := keyframes.Load(); got != 2 {
		t.Fatalf("keyframe requests = %d, want 2; stream 11 proved its own keyframe was damaged "+
			"and was still coalesced into stream 10's pending request", got)
	}
}

// THE GUARD THAT KEEPS THE FIX HONEST: coalescing WITHIN one stream is the behaviour the gate
// exists for, and must survive being keyed per stream. Without this, "make it per stream" could be
// satisfied by removing the gate entirely.
func TestKeyframeGateStillCoalescesWithinOneStream(t *testing.T) {
	clock := &responderFakeClock{now: time.Unix(3_000, 0)}
	var keyframes atomic.Uint64
	harness, second := newTwoStreamResponder(t, clock, &keyframes)
	harness.writePrimary(t, 1, []byte{1}, nil)
	writeOnStream(t, second, 11, 1, false)

	for range 3 {
		readRTCPPackets(t, harness.interceptor, []rtcp.Packet{
			&rtcp.PictureLossIndication{MediaSSRC: 11},
		})
	}

	if got := keyframes.Load(); got != 1 {
		t.Fatalf("keyframe requests = %d, want 1; three PLIs on ONE stream must coalesce", got)
	}
}

func keyframeHeaderForStream(t *testing.T, ssrc uint32, sequence uint16) *rtp.Header {
	t.Helper()
	metadata, err := (FrameMetadata{
		Version: frameMetadataVersion, Keyframe: true, StreamID: 1, FrameID: uint64(sequence),
		PacketCount: 1, OriginalAccessUnitBytes: 1,
	}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	header := &rtp.Header{
		Version: 2, PayloadType: 45, SequenceNumber: sequence,
		Timestamp: uint32(sequence) * 3_000, SSRC: ssrc,
	}
	if err := header.SetExtension(3, metadata); err != nil {
		t.Fatal(err)
	}
	return header
}

// THE OTHER HALF OF THE FIX, AND THE ONE THAT KEEPS IT FROM BEING A REGRESSION.
//
// Keying the gate per stream makes the responder ask once per damaged window. If the REQUEST still
// named no window, rdev would answer each ask by re-keying EVERY source -- so a fix for one starved
// window would cost N times the IDRs, and at 2 Mbit/s one IDR is most of a second's budget. The
// request carries the media SSRC now, and this is the seam that turns it back into a slot.
//
// It negotiates for real rather than staging a binding: SSRCs are assigned by pion and the track is
// bound inside SetRemoteDescription, so a fixture would be asserting what its author believed pion
// does -- which is exactly the belief that was wrong in the offer-shape defect.
func TestKeyframeRequestResolvesToTheSlotThatOwnsTheSSRC(t *testing.T) {
	session := flexFECOfferSession(t)
	first, err := session.AddVideoTrack("win:1")
	if err != nil {
		t.Fatalf("AddVideoTrack(win:1): %v", err)
	}
	second, err := session.AddVideoTrack("win:2")
	if err != nil {
		t.Fatalf("AddVideoTrack(win:2): %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.SetAnswer(buildRemoteAnswer(t, session)); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}

	for _, slot := range []int{first, second} {
		ssrc := sessionSlotSSRC(t, session, slot)
		if got := session.keyframeStreamIDForSSRC(ssrc); got != videoKeyframeStreamID(slot) {
			t.Fatalf("slot %d (ssrc %d) resolved to keyframe stream %d, want %d; a PLI raised "+
				"for one window would re-key %s", slot, ssrc, got, videoKeyframeStreamID(slot),
				map[bool]string{true: "every window", false: "the wrong window"}[got == eagerVideoKeyframeStreamID])
		}
	}

	// AN SSRC NO TRACK CARRIES MUST STILL FAN OUT. That is the answering path's eager track and
	// every request made before a track binds, and it is what rdev reads as "all of this client's
	// sources" -- the behaviour every request had before this change.
	if got := session.keyframeStreamIDForSSRC(1); got != eagerVideoKeyframeStreamID {
		t.Fatalf("an unowned SSRC resolved to keyframe stream %d, want the eager %d", got,
			eagerVideoKeyframeStreamID)
	}
}

func sessionSlotSSRC(t *testing.T, session *Session, slot int) uint32 {
	t.Helper()
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	session.mutex.Unlock()
	if entry == nil {
		t.Fatalf("slot %d has no video track", slot)
	}
	if !entry.track.IsBound() {
		t.Fatalf("slot %d never bound, so this test could not observe its SSRC", slot)
	}
	encodings := entry.sender.GetParameters().Encodings
	if len(encodings) == 0 {
		t.Fatalf("slot %d sender reported no encodings", slot)
	}
	return uint32(encodings[0].SSRC)
}

// WHY a keyframe was requested was computed and thrown away — it reached only `Trace`, which is
// inactive outside the certification harness. So on a real session `pli`, `generic-nack-stale` and
// `generic-nack-cache-miss` were indistinguishable, and they want completely different fixes.
//
// This pins the ONCE-PER-REASON rule rather than the printing: these are interceptor hot paths
// running at five requests per second on the iPad session that motivated it, and a line per request
// would be the drop-spam defect in a different costume. The RATE already lives on the encoder's
// periodic `produced` line; what was missing is WHICH cause.
func TestKeyframeReasonIsAnnouncedOncePerReason(t *testing.T) {
	responder := &ageAwareNACKResponder{}

	if !responder.shouldAnnounceKeyframeReasonForTest("pli") {
		t.Fatal("the first sighting of a reason must announce")
	}
	if responder.shouldAnnounceKeyframeReasonForTest("pli") {
		t.Fatal("a repeat of the same reason must NOT announce — five per second would be spam")
	}

	// A DIFFERENT cause is a different fact and must still be reported, or the first reason to fire
	// would mask every other one for the rest of the session.
	if !responder.shouldAnnounceKeyframeReasonForTest("generic-nack-stale") {
		t.Fatal("a second, distinct reason must announce")
	}
	if responder.shouldAnnounceKeyframeReasonForTest("generic-nack-stale") {
		t.Fatal("a repeat of the second reason must NOT announce")
	}
	if responder.shouldAnnounceKeyframeReasonForTest("pli") {
		t.Fatal("the first reason must stay announced after a second one appeared")
	}
}
