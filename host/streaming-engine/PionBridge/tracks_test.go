package main

import (
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// THE MSID IS THE WHOLE POINT OF THIS TEST. rdev maps a video track back to the SOURCE it
// captures through the SDP MSID and through nothing else: ChannelHub keys
// videoSlots[clientId][sourceID], the web client keys streamsBySource by stream.id, and
// RdevViewer routes an incoming track to a source by the msid its C++ session reports. Get this
// wrong and video arrives attributed to the WRONG WINDOW, which presents as a client bug — a
// window showing another window's picture, with nothing on the host side looking broken.
//
// Asserted on the OFFER SDP rather than on the Go field, because the field is not the contract:
// pion is what turns StreamID() into `a=msid:`, and a track whose stream id never reaches the
// wire is indistinguishable from a correct one if you only read the struct back.
func TestAddVideoTrackUsesTheSourceIDAsStreamID(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})

	slot, err := session.AddVideoTrack("win:1234")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if slot < 0 {
		t.Fatalf("bad slot %d", slot)
	}

	offer, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer after AddVideoTrack: %v", err)
	}
	if got := msidStreamIDs(offer); !containsString(got, "win:1234") {
		t.Fatalf(
			"offer msid stream ids = %v, want one of them to be %q — MSID is how rdev maps a "+
				"track to its source",
			got, "win:1234",
		)
	}
}

// A track added by AddVideoTrack has to reach the WIRE, which takes an offer built after it
// exists. Asserted separately from the MSID above because the two fail for different reasons: a
// track that is never offered produces an msid list missing the id, which reads as "the stream
// id is wrong" rather than "the m-section is missing".
//
// IT GOES THROUGH A FULL OFFER/ANSWER FIRST, because pion refuses SetLocalDescription(offer) while
// it is already in have-local-offer (`invalid proposed signaling state transition:
// have-local-offer->SetLocal(offer)->have-local-offer`) — so two CreateOffer calls with nothing
// between them fail on the SECOND one, for a reason that has nothing to do with tracks. That is
// also the real sequence: rdev offers, the client answers, and a subscribe renegotiates.
func TestAddVideoTrackAddsAVideoMSection(t *testing.T) {
	pair := newTestOfferPair(t)
	// ZERO, and asserted rather than assumed: the offer path has no eager track, so rdev's first
	// offer is data-channels-only. If that ever stops being true the delta below would be measured
	// against a section nothing sends on, which is the state this increment removed.
	baseline := strings.Count(pair.offer, "m=video")
	if baseline != 0 {
		t.Fatalf("the first offer already carries %d video m-sections:\n%s", baseline, pair.offer)
	}
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}

	if _, err := pair.session.AddVideoTrack("win:99"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	after, err := pair.session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer after AddVideoTrack: %v", err)
	}
	if got := strings.Count(after, "m=video"); got != baseline+1 {
		t.Fatalf("video m-sections %d -> %d, want %d:\n%s", baseline, got, baseline+1, after)
	}
	if got := msidStreamIDs(after); !containsString(got, "win:99") {
		t.Fatalf("renegotiated offer msid stream ids = %v, want one of them to be %q", got, "win:99")
	}
}

// CreateOffer must SURVIVE a second video m-section, and this is the assertion that pins it.
// advertiseRTXTime tracked its "duplicate RTX fmtp" set across the WHOLE description, so the same
// RTX payload type appearing once per video section — which is what pion emits, since payload
// types are assigned per description and not per section — read as malformed and CreateOffer failed
// with `invalid peer configuration: duplicate local RTX fmtp`. TWO SOURCES IS ORDINARY rdev: a
// client subscribes to as many windows as it opens, each on its own track.
func TestCreateOfferSurvivesASecondVideoTrack(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	if _, err := session.AddVideoTrack("win:a"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.AddVideoTrack("win:b"); err != nil {
		t.Fatalf("AddVideoTrack second: %v", err)
	}
	offer, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer with a second video m-section: %v", err)
	}
	if got := strings.Count(offer, "m=video"); got < 2 {
		t.Fatalf("offer has %d video m-sections, so this test proved nothing:\n%s", got, offer)
	}
	// The RTX window still has to be advertised on every one of them, or the remote learns a
	// retransmission window for one track and none for the other.
	// ONE PER CODEC PER SECTION. Derived, so adding a codec does not need this edited: what is
	// under test is that EVERY section carries the window, not the absolute count.
	want := 2 * len(videoCodecProfiles())
	if got := strings.Count(offer, "rtx-time=30"); got != want {
		t.Fatalf("offer advertises rtx-time %d times, want %d:\n%s", got, want, offer)
	}
}

// The collection is a MAP KEYED BY SLOT, and this is the only test that can tell that from a
// single field with a slot-shaped accessor. Two tracks are added — which EXERCISES the
// collection rather than building the N>1 behaviour increment 3 owns — and each is required to
// keep its own identity: its own stream id, and its own keyframe-request route back to the
// session.
//
// PER-TRACK CALLBACK IDENTITY IS WHAT THIS ASSERTS, and it is the property a reviewer found the
// task-4 drift test blind to: trackWiringOf can only report non-nil, so two tracks sharing ONE
// closure passes every non-nil check. Firing each track's keyframe request and demanding its OWN
// slot back is the only thing that separates them.
func TestVideoTracksAreKeyedBySlotAndKeepTheirOwnCallbacks(t *testing.T) {
	keyframes := make(chan uint64, 8)
	session := newTestOfferSession(t, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnRecoveryKeyframe:  func(streamID uint64) { keyframes <- streamID },
	})

	first, err := session.AddVideoTrack("win:1")
	if err != nil {
		t.Fatalf("AddVideoTrack first: %v", err)
	}
	second, err := session.AddVideoTrack("win:2")
	if err != nil {
		t.Fatalf("AddVideoTrack second: %v", err)
	}
	if first == second {
		t.Fatalf("both tracks got slot %d — the collection is not keyed", first)
	}

	firstTrack := session.videoTrackForTest(first)
	secondTrack := session.videoTrackForTest(second)
	if firstTrack == nil || secondTrack == nil {
		t.Fatalf(
			"missing track: slot %d -> %p, slot %d -> %p", first, firstTrack, second, secondTrack,
		)
	}
	if firstTrack == secondTrack {
		t.Fatal("both slots resolve to the SAME FrameTrack — the collection is not keyed")
	}
	if firstTrack.StreamID() != "win:1" || secondTrack.StreamID() != "win:2" {
		t.Fatalf(
			"stream ids = %q, %q, want %q, %q",
			firstTrack.StreamID(), secondTrack.StreamID(), "win:1", "win:2",
		)
	}

	// Each track's keyframe request must report ITS OWN slot. One shared closure, or a closure
	// capturing a loop variable, gives both the same number.
	fireKeyframeRequest(t, firstTrack)
	requireRecoveryStream(t, keyframes, videoKeyframeStreamID(first))
	fireKeyframeRequest(t, secondTrack)
	requireRecoveryStream(t, keyframes, videoKeyframeStreamID(second))
}

// TestAddVideoTrackWiresEverythingTheEagerTrackHas USED TO BE HERE AND IS DELIBERATELY GONE.
//
// It compared an offer session's eager track against a dynamically added one INSIDE ONE SESSION,
// to catch a wiring added to assembleSession's inline eager-track block and not to AddVideoTrack.
// Two things removed its subject. The inline block became wireVideoTrack, the single definition of
// "a wired track", which BOTH kinds now come from — so the drift it named cannot happen by copy any
// more. And the offer path no longer has an eager track at all, so the comparison it made is not
// expressible on this path.
//
// The assertion itself did not go: TestOfferSessionAssemblesTheSamePeerAndTrackAsTheAnsweringPath
// now compares the ANSWERING path's eager track with an offer-path DYNAMIC one, which is the same
// comparison across the two entry points instead of inside one — and is the stronger version, since
// it is also the pair the certification's claim rests on. Recorded rather than silently deleted,
// because a test disappearing from a count is exactly the kind of change that should have to argue
// for itself.

// A removed slot must stop resolving, and a write to it must be REFUSED rather than silently
// dropped. rdev's own bridge no-ops a write to an unknown slot; this session reports, because a
// silent no-op is exactly how "video stopped and every state reads healthy" happens.
func TestRemoveVideoTrackForgetsTheSlot(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	slot, err := session.AddVideoTrack("win:5")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if err := session.RemoveVideoTrack(slot); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}
	if track := session.videoTrackForTest(slot); track != nil {
		t.Fatalf("slot %d still resolves to %p after removal", slot, track)
	}
	if err := session.RemoveVideoTrack(slot); err == nil {
		t.Fatal("removing an already-removed slot was accepted")
	}
	if err := session.WriteVideo(slot, []byte{0x01}, 0, true); err == nil {
		t.Fatal("a write to a removed slot was accepted")
	}
}

// A removed track must also leave the WIRE, or the client keeps a window for a source nobody is
// sending. Goes through a full offer/answer before renegotiating, for the same pion signaling-state
// reason as TestAddVideoTrackAddsAVideoMSection.
//
// The MSID is what is asserted, NOT the m-section count: pion recycles a removed transceiver's
// section as a direction change rather than deleting the line, so counting `m=video` would be
// asserting pion's recycling policy instead of whether the source is still advertised.
func TestRemoveVideoTrackDropsItsMSID(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	slot, err := pair.session.AddVideoTrack("win:removed")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	offered := pair.renegotiate(t)
	if !containsString(msidStreamIDs(offered), "win:removed") {
		t.Fatalf(
			"the added track never reached the wire, so removal cannot be measured:\n%s", offered,
		)
	}
	if err := pair.session.RemoveVideoTrack(slot); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}
	after := pair.renegotiate(t)
	if containsString(msidStreamIDs(after), "win:removed") {
		t.Fatalf("the removed source is still offered:\n%s", after)
	}
}

// renegotiate drives ONE full offer/answer round trip through the pair's answerer and returns the
// offer the session produced.
//
// IT EXISTS BECAUSE pion REFUSES BACK-TO-BACK OFFERS: SetLocalDescription(offer) while already in
// have-local-offer fails with `invalid proposed signaling state transition`, so a test that offers
// twice with nothing in between fails on the second call for a reason unrelated to what it is
// testing. It is also the real sequence — rdev renegotiates on every track add and remove — so
// going through it is more faithful than sampling one offer.
func (pair *offerPair) renegotiate(t *testing.T) string {
	t.Helper()
	offer, err := pair.session.CreateOffer()
	if err != nil {
		t.Fatalf("renegotiate CreateOffer: %v", err)
	}
	pair.mutex.Lock()
	answerer := pair.answerer
	pair.mutex.Unlock()
	if answerer == nil {
		t.Fatal("renegotiate needs an answerer")
	}
	if err := answerer.SetRemoteDescription(
		prepareTestRemoteOffer(t, offer, testOfferRTXMaxAge),
	); err != nil {
		t.Fatalf("renegotiate answerer SetRemoteDescription: %v", err)
	}
	answer, err := gatherPeerDescription(answerer, false)
	if err != nil {
		t.Fatalf("renegotiate answerer gather: %v", err)
	}
	if err := pair.session.SetAnswer(
		advertiseTestAnswerRTXTime(t, answer, testOfferRTXMaxAge),
	); err != nil {
		t.Fatalf("renegotiate SetAnswer: %v", err)
	}
	return offer
}

// THE LOAD-BEARING POSITIVE. Everything else in this file asserts a refusal, a slot number or an
// SDP line, and every one of them would still pass if a slot-keyed track could never actually send
// — which is the failure this project keeps hitting: a track that reports healthy while no RTP
// egresses. This drives the whole real sequence — offer, answer, connect, AddVideoTrack,
// renegotiate — and then requires WriteVideo to succeed, which it can only do once the track has a
// negotiated binding and a live RTP writer.
func TestWriteVideoSendsOnADynamicallyAddedTrack(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)

	slot, err := pair.session.AddVideoTrack("win:live")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)

	track := pair.session.videoTrackForTest(slot)
	if track == nil {
		t.Fatalf("slot %d does not resolve after renegotiation", slot)
	}
	// Polled rather than asserted once: Bind runs inside pion's SetRemoteDescription -> Send path,
	// on its own goroutines, so a single sample right after SetAnswer races a correct
	// implementation.
	deadline := time.Now().Add(10 * time.Second)
	for !track.IsBound() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !track.IsBound() {
		t.Fatal("the dynamically added track never bound, so no write could succeed")
	}

	// A REAL AV1 ACCESS UNIT, not arbitrary bytes: pion's AV1Payloader parses OBUs and emits ZERO
	// packets for a payload it cannot read, which WriteAccessUnit reports as "AV1 payloader emitted
	// 0 packets". Reusing the suite's own testAV1AccessUnit keeps this a test of the slot plumbing
	// rather than of the payloader.
	before := pair.session.Stats().VideoFramesSent
	if err := pair.session.WriteVideo(
		slot, testAV1AccessUnit(2_000), 16_000_000, true,
	); err != nil {
		t.Fatalf("WriteVideo keyframe: %v", err)
	}
	if err := pair.session.WriteVideo(
		slot, testAV1AccessUnit(2_000), 32_000_000, false,
	); err != nil {
		t.Fatalf("WriteVideo delta: %v", err)
	}
	// The session's own counter is what proves both writes reached the track rather than being
	// swallowed: WriteVideo increments it only after WriteAccessUnit returned without error.
	if after := pair.session.Stats().VideoFramesSent; after != before+2 {
		t.Fatalf("VideoFramesSent %d -> %d, want %d", before, after, before+2)
	}
}

func TestWriteVideoRejectsAnUnknownSlot(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	err := session.WriteVideo(4_242, []byte{0x01}, 0, true)
	if err == nil {
		t.Fatal("a write to a slot that was never added was accepted")
	}
	if !strings.Contains(err.Error(), "4242") {
		t.Fatalf("error = %q, want it to name the slot", err)
	}
}

// An empty payload is refused AT THE SESSION BOUNDARY rather than handed to WriteAccessUnit, which
// rejects it as "invalid access-unit byte count 0" — a message naming the symptom and not the
// caller. rdev's own writeTrackVideo returns silently here; this does not.
//
// THE errFrameTrack ASSERTION IS WHAT MAKES THIS TEST MEAN ANYTHING. "It returned an error" passes
// with the session-level check DELETED, because the track refuses an empty payload too — measured,
// by deleting it. The discriminating property is WHICH layer refused, so that is what is asserted.
func TestWriteVideoRejectsAnEmptyPayload(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	slot, err := session.AddVideoTrack("win:6")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	err = session.WriteVideo(slot, nil, 0, true)
	if err == nil {
		t.Fatal("an empty payload was accepted")
	}
	if !errors.Is(err, errSession) {
		t.Fatalf("error = %v, want it to wrap errSession", err)
	}
	if errors.Is(err, errFrameTrack) {
		t.Fatalf(
			"error = %v, want it refused by the session; it reached the frame track instead", err,
		)
	}
}

// A FAILED write must not consume a frame id. FrameTrack's onFrameStart is
// RecoveryFrameClockBudget.AdvanceFrame when FlexFEC is on, and that rejects any id which is not
// exactly its predecessor + 1 — so a counter that advanced on ATTEMPTS would leave a permanent gap
// after the first early write, and every later frame would be an "invalid progression". Writing
// before the renegotiation lands is a normal transient here, so this is reachable, not theoretical.
//
// It is asserted on the counter rather than through a FlexFEC session because newOfferSession
// refuses FlexFEC outright, so the budget cannot be reached from this path at all — which is
// exactly why the invariant needs pinning here instead of being left to a downstream failure.
func TestWriteVideoDoesNotConsumeAFrameIDWhenItFails(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)
	slot, err := pair.session.AddVideoTrack("win:gap")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}

	// Two writes that must FAIL: one before the track is negotiated, one with an empty payload.
	if err := pair.session.WriteVideo(slot, testAV1AccessUnit(64), 0, true); err == nil {
		t.Fatal("a write before renegotiation was accepted, so this test cannot measure a gap")
	}
	if err := pair.session.WriteVideo(slot, nil, 0, true); err == nil {
		t.Fatal("an empty payload was accepted")
	}
	if got := pair.session.frameIDForTest(slot); got != 0 {
		t.Fatalf("frame id = %d after two FAILED writes, want 0 — a failed write consumed an id", got)
	}

	pair.renegotiate(t)
	track := pair.session.videoTrackForTest(slot)
	deadline := time.Now().Add(10 * time.Second)
	for !track.IsBound() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !track.IsBound() {
		t.Fatal("the track never bound, so no successful write could follow")
	}
	// The first SUCCESSFUL write must be frame 1, not frame 3.
	if err := pair.session.WriteVideo(slot, testAV1AccessUnit(64), 0, true); err != nil {
		t.Fatalf("WriteVideo after renegotiation: %v", err)
	}
	if got := pair.session.frameIDForTest(slot); got != 1 {
		t.Fatalf("frame id = %d after the first successful write, want 1", got)
	}
	if err := pair.session.WriteVideo(slot, testAV1AccessUnit(64), 0, false); err != nil {
		t.Fatalf("second WriteVideo: %v", err)
	}
	if got := pair.session.frameIDForTest(slot); got != 2 {
		t.Fatalf("frame id = %d after two successful writes, want 2 — ids must be consecutive", got)
	}
}

// A write to a track that exists but was never NEGOTIATED must fail, and it must be visible which
// of the two it was. This is the failure a caller hits when it writes before the renegotiation
// lands, and it is the whole reason WriteVideo returns an error instead of no-oping: rdev's
// writeTrackVideo drops the frame, and a stream that never starts with nothing logged is the
// hardest failure in this project to diagnose.
func TestWriteVideoRefusesAnUnboundTrack(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	slot, err := session.AddVideoTrack("win:8")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	err = session.WriteVideo(slot, []byte{0x01, 0x02}, 0, true)
	if err == nil {
		t.Fatal("a write to an un-negotiated track was accepted")
	}
	if !strings.Contains(err.Error(), "no negotiated bindings") {
		t.Fatalf("error = %q, want it to name the missing binding", err)
	}
}

// An EMPTY source id is refused at construction. RdevViewer keys its AV1 decoders by msid, and
// CLAUDE.md already records a real unsynchronised-decoder residue for two streams that both resolve
// to "" — so an unnamed source cannot be routed anywhere, and letting it through would produce a
// track that streams into the wrong decoder rather than one that fails.
func TestAddVideoTrackRefusesAnEmptySourceID(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	slot, err := session.AddVideoTrack("")
	if err == nil {
		t.Fatalf("an empty source id was accepted at slot %d", slot)
	}
	if slot != -1 {
		t.Fatalf("slot = %d on failure, want -1", slot)
	}
	if !strings.Contains(err.Error(), "MSID") {
		t.Fatalf("error = %q, want it to say what the source id is FOR", err)
	}
	// It must not have burned a slot either, or a caller retrying with a real id would find the
	// numbering had moved for a track that never existed.
	good, err := session.AddVideoTrack("win:after")
	if err != nil {
		t.Fatalf("AddVideoTrack after a refusal: %v", err)
	}
	if good != 0 {
		t.Fatalf("slot = %d after a refused add, want 0 — the refusal consumed a slot", good)
	}
}

// READINESS NOW MEANS WHAT IT SAYS ON THIS PATH, AND THIS IS THE TEST THAT INVERTED. Its
// predecessor — TestMediaReadyIsSatisfiedByTheEagerTrackAlone — pinned the opposite: with
// assembleSession's eager `desktop` track kept on the offer path, the first track to bind was
// always that one, so a connected session reported media-ready with ZERO rdev tracks and the C ABI
// could not have exposed readiness without lying. Its own comment said that if someone removed the
// eager track it would fail and point at the decision. That is what happened, and this is the
// decision.
//
// BOTH DIRECTIONS ARE ASSERTED, because either alone is weak. "Not ready without a track" passes on
// a session that can never become ready at all; "ready after a track binds" passes on a session
// that was ready before it. The NAMED BLOCKER is what makes the first half discriminating — the
// diagnostic has to say which precondition is missing, not merely time out.
func TestOfferSessionIsNotMediaReadyUntilAnRdevTrackBinds(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)

	// Short on purpose: everything else readiness waits on (ICE, signalling, both channels) is
	// satisfied by now, so the only outstanding precondition is the track — and if that is wrong,
	// the blocker list below says so by name instead of leaving a bare timeout.
	err := pair.session.WaitReady(2 * time.Second)
	if err == nil {
		t.Fatal(
			"the session reported ready with no rdev video track — readiness is being satisfied by " +
				"something that carries no source's frames, which is what removing the eager track " +
				"was for",
		)
	}
	if !strings.Contains(err.Error(), "video track not bound") {
		t.Fatalf("readiness timeout = %q, want it to name the unbound video track", err)
	}
	pair.session.mutex.Lock()
	tracks := len(pair.session.videoTracks)
	eager := pair.session.track
	pair.session.mutex.Unlock()
	if tracks != 0 || eager != nil {
		t.Fatalf("videoTracks = %d, eager track = %p, want 0 and nil", tracks, eager)
	}

	// And now the other half: a real per-source track binds and readiness follows.
	if _, err := pair.session.AddVideoTrack("win:ready"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)
	if err := pair.session.WaitReady(10 * time.Second); err != nil {
		t.Fatalf("WaitReady after a per-source track was negotiated: %v", err)
	}
}

// A FAILED removal must SAY that the sender is still attached, because the slot is already gone and
// there is nothing the caller can retry. The map entry — the only reference to that sender — is
// dropped before peer.RemoveTrack on purpose, so that a concurrent write is refused from the moment
// removal starts; the cost is this unrecoverable state, and the error is the only place it can be
// recorded.
//
// The peer is closed DIRECTLY rather than through session.Close(), because that is what makes
// pion's RemoveTrack fail (`InvalidStateError: connection closed`) while the session still holds the
// slot. Reaching into session.peer is deliberate: the alternative was leaving this branch untested
// and its message unverified, which is how a diagnostic nobody has ever seen ends up naming the
// wrong thing.
func TestRemoveVideoTrackReportsAnOrphanedSender(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	slot, err := session.AddVideoTrack("win:orphan")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if err := session.peer.Close(); err != nil {
		t.Fatalf("peer.Close: %v", err)
	}

	err = session.RemoveVideoTrack(slot)
	if err == nil {
		t.Fatal("removing a track from a closed peer was reported as success")
	}
	// The consequence, not just the cause: "connection closed" alone would leave a caller believing
	// it could retry.
	if !strings.Contains(err.Error(), "still attached") {
		t.Fatalf("error = %q, want it to say the sender is still attached to the peer", err)
	}
	if !strings.Contains(err.Error(), "cannot be retried") {
		t.Fatalf("error = %q, want it to say the removal cannot be retried", err)
	}
	// And the slot really is gone, which is what makes "cannot be retried" true rather than
	// pessimistic.
	if track := session.videoTrackForTest(slot); track != nil {
		t.Fatalf("slot %d still resolves after a failed removal, so a retry WOULD be possible", slot)
	}
}

// A DUPLICATE source id is refused, for the sharper form of the reason an empty one is. The
// receiver keys by msid, so a second track carrying an existing source's id has its frames
// attributed to the FIRST one's window — the wrong-window failure the MSID contract exists to
// prevent, presenting as a client bug with nothing host-side looking broken.
func TestAddVideoTrackRefusesADuplicateSourceID(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	first, err := session.AddVideoTrack("win:dup")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	again, err := session.AddVideoTrack("win:dup")
	if err == nil {
		t.Fatalf("the same source id was accepted twice, at slots %d and %d", first, again)
	}
	if again != -1 {
		t.Fatalf("slot = %d on failure, want -1", again)
	}
	// The message has to name the slot the source already occupies, or a caller cannot tell a
	// duplicate from any other refusal.
	if !strings.Contains(err.Error(), "win:dup") || !strings.Contains(err.Error(), "slot 0") {
		t.Fatalf("error = %q, want it to name the source and the slot it already holds", err)
	}
	// A DIFFERENT id still works, so the check refuses duplicates rather than second tracks.
	if _, err := session.AddVideoTrack("win:other"); err != nil {
		t.Fatalf("a second track with a different source id was refused: %v", err)
	}
	// And the original is untouched — a refused duplicate must not disturb what is already there.
	if got := session.videoTrackForTest(first); got == nil || got.StreamID() != "win:dup" {
		t.Fatalf("the original track at slot %d was disturbed by the refusal: %v", first, got)
	}
}

// A source id FREED by removal may be added again. Without this, the duplicate check above would
// silently make minimize→restore — which unsubscribes and re-subscribes the same window — fail
// forever on the second subscribe.
func TestAddVideoTrackAcceptsASourceIDAgainAfterRemoval(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	first, err := session.AddVideoTrack("win:cycle")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if err := session.RemoveVideoTrack(first); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}
	second, err := session.AddVideoTrack("win:cycle")
	if err != nil {
		t.Fatalf("re-adding a removed source was refused: %v", err)
	}
	// Slots are never reused, so the re-added source must land on a NEW slot — which is what makes a
	// stale write from before the removal refusable rather than delivered to the new track.
	if second == first {
		t.Fatalf("the re-added source reused slot %d; slots must never be handed out twice", first)
	}
}

// CONCURRENT WRITES TO ONE SLOT MUST NOT SHARE A FRAME ID. Without the per-slot write lock both
// writers read the same frameID, compute the same successor, and both emit and commit it — two
// frames carrying one id, which is the corruption commit-on-success exists to prevent, reached from
// the other direction. Run under -race, which is also what would catch the unsynchronised read.
//
// The count is the assertion: every successful write must advance the id by exactly one, so after N
// successes the committed id is N. Under the unlocked version it lands BELOW N.
func TestWriteVideoSerialisesConcurrentWritesToOneSlot(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)
	slot, err := pair.session.AddVideoTrack("win:concurrent")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)
	track := pair.session.videoTrackForTest(slot)
	deadline := time.Now().Add(10 * time.Second)
	for !track.IsBound() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !track.IsBound() {
		t.Fatal("the track never bound, so no write could succeed")
	}

	const writers, each = 4, 25
	var group sync.WaitGroup
	failures := make(chan error, writers*each)
	for writer := 0; writer < writers; writer++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for index := 0; index < each; index++ {
				// Every frame after the very first is a DELTA: l1t1Dependency requires template 0
				// for a keyframe and 1 otherwise, so a burst of keyframes is fine too, but deltas
				// keep this closer to a real stream.
				if err := pair.session.WriteVideo(
					slot, testAV1AccessUnit(64), 0, false,
				); err != nil {
					failures <- err
					return
				}
			}
		}()
	}
	group.Wait()
	close(failures)
	for err := range failures {
		t.Fatalf("concurrent WriteVideo: %v", err)
	}

	if got := pair.session.frameIDForTest(slot); got != writers*each {
		t.Fatalf(
			"committed frame id = %d after %d successful writes, want %d — concurrent writers "+
				"shared an id",
			got, writers*each, writers*each,
		)
	}
	if got := pair.session.Stats().VideoFramesSent; got != writers*each {
		t.Fatalf("VideoFramesSent = %d, want %d", got, writers*each)
	}
}

// The eager track keeps keyframe stream 0, which is the ANSWERING path's contract: stock `llv
// capture-host` and its viewer both carry stream 0, and the task-4 drift test asserts 0 on BOTH
// arms. This pins that no dynamic slot can take it, which is what keeps a PLI on rdev's slot 0
// distinguishable from one on the eager track.
func TestVideoKeyframeStreamIDsNeverCollideWithTheEagerTrack(t *testing.T) {
	for _, slot := range []int{0, 1, 7, 1_000} {
		if got := videoKeyframeStreamID(slot); got == 0 {
			t.Fatalf("slot %d maps to keyframe stream 0, which the eager track owns", slot)
		}
	}
	if videoKeyframeStreamID(0) == videoKeyframeStreamID(1) {
		t.Fatal("two slots map to the same keyframe stream id")
	}
}

// msidStreamIDs returns the stream id every `a=msid:` line in an SDP names. Parsed off the wire
// rather than read from the Go struct — see TestAddVideoTrackUsesTheSourceIDAsStreamID for why.
func msidStreamIDs(sdp string) []string {
	var found []string
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimRight(line, "\r")
		const prefix = "a=msid:"
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		if fields := strings.Fields(strings.TrimPrefix(line, prefix)); len(fields) != 0 {
			found = append(found, fields[0])
		}
	}
	return found
}

func containsString(haystack []string, needle string) bool {
	for _, candidate := range haystack {
		if candidate == needle {
			return true
		}
	}
	return false
}

// videoTrackForTest resolves a slot to its FrameTrack, or nil. Test-only: production callers go
// through WriteVideo, which is what keeps the map's lock discipline in one place.
func (session *Session) videoTrackForTest(slot int) *FrameTrack {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	entry := session.videoTracks[slot]
	if entry == nil {
		return nil
	}
	return entry.track
}

// frameIDForTest reports the last frame id COMMITTED for a slot, which is the count of frames that
// actually reached the track. 0 for an unknown slot, which is also the value for a slot that has
// never had a successful write — the two are distinguished by videoTrackForTest.
//
// It takes writeMutex, not session.mutex, because that is what guards frameID — and it takes it
// AFTER releasing session.mutex, which is the lock order WriteVideo uses.
func (session *Session) frameIDForTest(slot int) uint64 {
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	session.mutex.Unlock()
	if entry == nil {
		return 0
	}
	entry.writeMutex.Lock()
	defer entry.writeMutex.Unlock()
	return entry.frameID
}

// UNSUBSCRIBING THE LAST SOURCE LEAVES AN m=video SECTION BEHIND, SO SetAnswer's STRICT PATH IS
// REACHED WITH NOTHING ACTIVE IN IT. That shape did not exist before the eager `desktop` track was
// removed from the offer path: there was always at least one ACTIVE video section, so
// `sdpHasVideoSection` and "there is live video" agreed. They no longer do, and this is a ROUTINE
// action — `−` minimize unsubscribes, and so does closing the last window.
//
// pion recycles a removed transceiver's line as a DIRECTION CHANGE rather than deleting it (the same
// fact TestRemoveVideoTrackDropsItsMSID relies on), so `sdpHasVideoSection` stays true, the strict
// `preparePionRemoteDescription` runs, and it requires a dependency-descriptor extmap INSIDE the
// answer's video section. Measured against pion's answerer: the offer's section becomes
// `a=recvonly`, the answer's becomes `a=inactive`, and the answer still echoes all three extmaps —
// so it passes. WHAT IS ASSERTED HERE IS THAT ROUND TRIP, and the guards are what stop it being
// vacuous: without them an implementation that deleted the m-section entirely, or one that skipped
// the strict path, would pass while testing nothing.
//
// **THIS IS VERIFIED AGAINST pion's ANSWERER ONLY, AND A BROWSER IS A DIFFERENT QUESTION.** If Chrome
// drops the extmaps from a section it answers `a=inactive`, `SetAnswer` fails, the remote description
// is never applied, and signalling — not merely video — stops: every later renegotiation fails from
// have-local-offer. This repo's own history is explicit that a pion answerer accepts what a browser
// will not (the H.265 `level-id` incident). The repro is one action: subscribe a window in Chrome,
// unsubscribe it, and watch for `[bridge] setAnswer: … missing … video extmap`.
func TestSetAnswerAcceptsAnAllInactiveVideoAnswer(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)
	slot, err := pair.session.AddVideoTrack("win:last")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)
	if err := pair.session.RemoveVideoTrack(slot); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}

	offer, err := pair.session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer after removing the last track: %v", err)
	}
	// GUARD 1: the strict path must actually be reached. If pion ever stopped recycling the section,
	// this test would be asserting the video-less path — which the first offer already covers — and
	// would silently stop covering the case it is named for.
	if !sdpHasVideoSection(offer) {
		t.Fatalf(
			"the offer has no video m-section after removing the last track, so SetAnswer's strict "+
				"path is not reached and this test proves nothing:\n%s", offer,
		)
	}
	// GUARD 2: and nothing may be left sending in it.
	if got := msidStreamIDs(offer); containsString(got, "win:last") {
		t.Fatalf("the removed source is still offered (%v), so the section is not inactive", got)
	}

	pair.mutex.Lock()
	answerer := pair.answerer
	pair.mutex.Unlock()
	if err := answerer.SetRemoteDescription(
		prepareTestRemoteOffer(t, offer, testOfferRTXMaxAge),
	); err != nil {
		t.Fatalf("answerer SetRemoteDescription: %v", err)
	}
	answer, err := gatherPeerDescription(answerer, false)
	if err != nil {
		t.Fatalf("answerer gather: %v", err)
	}
	// GUARD 3: the answer is the all-inactive shape, not a live one. Asserted off the wire, because
	// "SetAnswer succeeded" is also true of an answer that kept the track.
	if !strings.Contains(answer.SDP, "a=inactive") {
		t.Fatalf("the answer is not inactive, so the case under test was not produced:\n%s", answer.SDP)
	}
	// And the requirement the strict path actually enforces, recorded where a browser difference
	// would show up: the answer's video section still carries the dependency-descriptor extmap.
	if !strings.Contains(answer.SDP, dependencyDescriptorURI) {
		t.Fatalf(
			"the inactive answer dropped the dependency-descriptor extmap — this is the exact shape "+
				"that makes SetAnswer fail and signalling stop:\n%s", answer.SDP,
		)
	}
	if err := pair.session.SetAnswer(
		advertiseTestAnswerRTXTime(t, answer, testOfferRTXMaxAge),
	); err != nil {
		t.Fatalf(
			"SetAnswer refused an answer whose only video section is inactive, which is what "+
				"unsubscribing the last source produces: %v", err,
		)
	}
}
