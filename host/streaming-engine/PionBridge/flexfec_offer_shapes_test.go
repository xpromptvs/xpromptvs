package main

import (
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// THE OFFER PATH PRODUCES THREE VIDEO-SECTION SHAPES AND THE VALIDATOR ONLY EVER UNDERSTOOD ONE.
//
// rdev renegotiates on every subscribe and unsubscribe, so its local offer is not the single
// sending m=video section validateFlexFECOffer/Answer were written against. Measured against pion
// v4.2.18, an rdev FlexFEC session offers:
//
//   one source     m=video 45 46 47 · a=sendrecv · FID + FEC-FR
//   two sources    TWO such sections, each complete, mid:0 and mid:1
//   none (removed) ONE section, a=recvonly, and NO ssrc-group lines at all
//
// The last two were REFUSED — "multiple video sections" and "answer needs matching FID and FEC-FR
// groups" — and each refusal killed video for the rest of the session. Reported from real use:
// stream one window to an iPhone, close it, open another, and the second one never paints.
//
// These tests build the SDP from a REAL pion offer rather than a fixture, because a fixture would
// only ever assert what its author believed pion emits, and the belief is exactly what was wrong.

func flexFECOfferSession(t *testing.T) *Session {
	t.Helper()
	configuration := testOfferConfiguration(t)
	configuration.Recovery = RecoveryNACKRTXFlexFEC
	configuration.FlexFECPolicy = FlexFECPolicyAdaptive
	configuration.ScalabilityMode = AV1ScalabilityL1T1
	configuration.TotalRTPBudgetBitsPerSecond = 8_000_000
	configuration.FramesPerSecond = 60
	session, err := newOfferSession(configuration, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnChannelMessage:    func(string, []byte) {},
		OnChannelOpen:       func(string) {},
		OnRecoveryPolicy:    func(RecoveryPolicyUpdate) error { return nil },
	})
	if err != nil {
		t.Fatalf("newOfferSession: %v", err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session
}

func countVideoSections(sdp string) int {
	count := 0
	for _, raw := range strings.Split(sdp, "\n") {
		if strings.HasPrefix(strings.TrimSuffix(raw, "\r"), "m=video ") {
			count++
		}
	}
	return count
}

// TWO SUBSCRIBED SOURCES. rdev's source cap is unbounded and every source gets its own track, so
// this is ordinary operation, not an edge case — and pion gives each section its own complete
// FID/FEC-FR pair, so there is nothing malformed for the parser to object to.
func TestFlexFECLocalOfferAcceptsTwoSendingSources(t *testing.T) {
	session := flexFECOfferSession(t)
	for _, id := range []string{"win:1", "win:2"} {
		if _, err := session.AddVideoTrack(id); err != nil {
			t.Fatalf("AddVideoTrack(%s): %v", id, err)
		}
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("two-source offer refused: %v", err)
	}
	if got := countVideoSections(sdp); got != 2 {
		t.Fatalf("video sections = %d, want 2 — this test no longer covers the multi-source shape", got)
	}
}

// EVERY SUBSCRIBED SOURCE UNSUBSCRIBED. pion recycles the transceiver to recvonly and drops its
// a=ssrc lines, so there are no SSRC groups — correctly, since we are no longer a sender. There is
// no FlexFEC contract to check in a section that sends nothing.
func TestFlexFECLocalOfferAcceptsAnOfferThatSendsNoVideo(t *testing.T) {
	session := flexFECOfferSession(t)
	slot, err := session.AddVideoTrack("win:1")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("first offer: %v", err)
	}
	// Get back to stable the way a real round does, so the removal offer is the SECOND offer
	// rather than an illegal transition.
	answerRemotely(t, session)
	if err := session.RemoveVideoTrack(slot); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("the offer that removes the last video track was refused: %v", err)
	}
	if !strings.Contains(sdp, "a=recvonly") {
		t.Fatalf("expected a recvonly video section after the last removal:\n%s", sdp)
	}
}

// THE AMPLIFIER, and the reason one bad offer cost the whole session rather than one renegotiation.
//
// createOffer used to call SetLocalDescription BEFORE validating, so a refusal left the peer in
// have-local-offer with an offer that was never sent. driveOffer only emits from `stable`, and the
// only thing that returns a peer to stable is the answer to an offer the remote never received —
// so every later renegotiation returned early, silently, forever. The user's log shows exactly
// that: ONE failure line, then `no negotiated bindings` on every write for the rest of the run.
func TestARefusedOfferLeavesTheSignalingStateUntouched(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if state := session.peer.SignalingState(); state != webrtc.SignalingStateStable {
		t.Fatalf("precondition: signaling state = %s, want stable", state)
	}
	// A refusal is forced through an EXISTING check rather than a test seam: the peer was built
	// with FlexFEC and offers flexfec-03, so telling the session it is on legacy recovery makes
	// validateLegacyRecoverySDP reject its own offer ("legacy SDP contains FlexFEC/TWCC").
	// Mutating config directly is safe here and nowhere else — this test is single-goroutine and
	// nothing else reads it concurrently. The POINT is not which check fires; it is that ANY
	// refusal must leave the peer able to offer again.
	session.config.Recovery = RecoveryNACKRTX
	if _, err := session.CreateOffer(); err == nil {
		t.Fatal("setup: the offer was accepted; this test needs a refusal to observe")
	}
	session.config.Recovery = RecoveryNACKRTXFlexFEC
	if state := session.peer.SignalingState(); state != webrtc.SignalingStateStable {
		t.Fatalf("signaling state after a REFUSED offer = %s, want stable — a refused offer that "+
			"leaves the peer in have-local-offer wedges every later renegotiation", state)
	}
	// And the session must still be able to offer: this is the recovery the user never got.
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("the session could not offer again after a refusal: %v", err)
	}
}

// answerRemotely completes one offer/answer round with a plain pion peer built by the same
// newPeerAPI, so the session returns to `stable` and can offer again.
func answerRemotely(t *testing.T, session *Session) {
	t.Helper()
	offer := session.peer.LocalDescription()
	if offer == nil {
		t.Fatal("no local description to answer")
	}
	icePort := reserveUDPPort(t)
	signalPort := reserveTCPPort(t)
	for signalPort == icePort {
		signalPort = reserveTCPPort(t)
	}
	api, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: icePort, SignalPort: signalPort,
		Recovery: session.config.Recovery, RTXMaxAge: session.config.RTXMaxAge,
		TotalRTPBudgetBitsPerSecond: session.config.TotalRTPBudgetBitsPerSecond,
		FramesPerSecond:             session.config.FramesPerSecond,
	})
	if err != nil {
		t.Fatalf("build answerer API: %v", err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	answerer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("build answerer: %v", err)
	}
	t.Cleanup(func() { _ = answerer.Close() })
	if err := answerer.SetRemoteDescription(*offer); err != nil {
		t.Fatalf("answerer SetRemoteDescription: %v", err)
	}
	answer, err := answerer.CreateAnswer(nil)
	if err != nil {
		t.Fatalf("CreateAnswer: %v", err)
	}
	if err := answerer.SetLocalDescription(answer); err != nil {
		t.Fatalf("answerer SetLocalDescription: %v", err)
	}
	if err := session.peer.SetRemoteDescription(*answerer.LocalDescription()); err != nil {
		t.Fatalf("session SetRemoteDescription(answer): %v", err)
	}
}

// THE CONTROLLER NEVER STARTED ON THE OFFER PATH, AND NOTHING SAID SO.
//
// SetFlexFECNegotiation decides `negotiated` from the identity it is handed, and requires the three
// SSRCs to be non-zero — because on the ANSWERING path the description it validates is the host's
// own answer, which carries them. The offer path hands it the REMOTE's answer instead, parsed with
// requireSSRCGroups=false, so all three are zero: FlexFEC records itself as not negotiated and
// FlexFECController.Start() — the goroutine that evaluates loss and moves off the `off` tier — is
// never called. FEC is negotiated on the wire, costs its ~5% of the media budget, and never engages.
//
// The SSRCs that matter here are OURS: we are the sender, and they are in the offer we just
// validated, not in the receiver's answer.
func TestOfferPathMarksFlexFECNegotiatedAfterTheAnswer(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	answer := buildRemoteAnswer(t, session)
	if err := session.SetAnswer(answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	stats, _ := session.apiResources.FlexFECSnapshot()
	if stats == nil {
		t.Fatal("no FlexFEC snapshot on a FlexFEC session")
	}
	if !stats.Negotiated {
		t.Fatal("FlexFEC reports NOT negotiated after a successful answer — the adaptive " +
			"controller is never started, so FEC costs its share of the budget and never engages")
	}
}

// buildRemoteAnswer answers the session's current offer with a fresh peer built by the same
// newPeerAPI. Single-round only — a renegotiation must be answered by the SAME peer, which is what
// newFlexFECAnswerer below is for.
func buildRemoteAnswer(t *testing.T, session *Session) string {
	t.Helper()
	return newFlexFECAnswerer(t, session).answer(t, session)
}

// flexFECAnswerer is one remote peer that can answer a session repeatedly, which is what makes a
// subscribe/unsubscribe SEQUENCE testable: a fresh peer per round would have no transceiver state
// and would not reproduce the recycling that produced the recvonly section in the first place.
type flexFECAnswerer struct{ peer *webrtc.PeerConnection }

func (remote *flexFECAnswerer) answer(t *testing.T, session *Session) string {
	t.Helper()
	offer := session.peer.LocalDescription()
	if offer == nil {
		t.Fatal("no local description to answer")
	}
	if err := remote.peer.SetRemoteDescription(*offer); err != nil {
		t.Fatalf("answerer SetRemoteDescription: %v", err)
	}
	answer, err := remote.peer.CreateAnswer(nil)
	if err != nil {
		t.Fatalf("CreateAnswer: %v", err)
	}
	if err := remote.peer.SetLocalDescription(answer); err != nil {
		t.Fatalf("answerer SetLocalDescription: %v", err)
	}
	// A bare pion answer echoes `apt=45` and NOT `rtx-time`, which the parser requires. Real Chrome
	// does echo it — measured, 2026-08-18, `scripts/probe-flexfec-answer.sh`, 13/13 fields — so
	// advertising it here makes this stand-in as faithful as the browser rdev actually talks to,
	// using the same call the answering path makes on its own answer.
	advertised, err := advertiseRTXTime(*remote.peer.LocalDescription(), session.config.negotiatedRTXTime())
	if err != nil {
		t.Fatalf("advertise rtx-time on the stand-in answer: %v", err)
	}
	return advertised.SDP
}

func newFlexFECAnswerer(t *testing.T, session *Session) *flexFECAnswerer {
	t.Helper()
	icePort := reserveUDPPort(t)
	signalPort := reserveTCPPort(t)
	for signalPort == icePort {
		signalPort = reserveTCPPort(t)
	}
	api, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: icePort, SignalPort: signalPort,
		Recovery: session.config.Recovery, RTXMaxAge: session.config.RTXMaxAge,
		TotalRTPBudgetBitsPerSecond: session.config.TotalRTPBudgetBitsPerSecond,
		FramesPerSecond:             session.config.FramesPerSecond,
	})
	if err != nil {
		t.Fatalf("build answerer API: %v", err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	answerer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("build answerer: %v", err)
	}
	t.Cleanup(func() { _ = answerer.Close() })
	return &flexFECAnswerer{peer: answerer}
}

// THE REPORTED SEQUENCE, END TO END: stream one window, close it, open another.
//
// Three renegotiations, each answered by the SAME remote peer so the transceiver recycling that
// produced the recvonly section is real rather than staged. Before the fix this died on round 2 —
// the offer that removes the last track — and round 3's track then never bound, so the second
// window encoded at full rate into a track the remote had never been told about
// (`no negotiated bindings`, once per frame, forever).
func TestSubscribeUnsubscribeSubscribeKeepsNegotiating(t *testing.T) {
	session := flexFECOfferSession(t)
	remote := newFlexFECAnswerer(t, session)

	round := func(label string) {
		t.Helper()
		if _, err := session.CreateOffer(); err != nil {
			t.Fatalf("%s: CreateOffer: %v", label, err)
		}
		if err := session.SetAnswer(remote.answer(t, session)); err != nil {
			t.Fatalf("%s: SetAnswer: %v", label, err)
		}
		if state := session.peer.SignalingState(); state != webrtc.SignalingStateStable {
			t.Fatalf("%s: signaling state = %s, want stable", label, state)
		}
	}

	first, err := session.AddVideoTrack("win:7128")
	if err != nil {
		t.Fatalf("AddVideoTrack(first): %v", err)
	}
	round("subscribe the first window")

	if err := session.RemoveVideoTrack(first); err != nil {
		t.Fatalf("RemoveVideoTrack: %v", err)
	}
	round("close the first window")

	if _, err := session.AddVideoTrack("win:17331"); err != nil {
		t.Fatalf("AddVideoTrack(second): %v", err)
	}
	round("open the second window")

	// THE ASSERTION THAT MATTERS IS NOT "no error": it is that the second window's track is
	// negotiated, which is the thing WriteVideo needs and the thing that was missing. A session
	// that renegotiated cleanly but left the track unbound looks identical from the outside.
	stats, _ := session.apiResources.FlexFECSnapshot()
	if stats == nil || !stats.Negotiated {
		t.Fatal("FlexFEC is not negotiated after the second window was subscribed")
	}
	senders := 0
	for _, sender := range session.peer.GetSenders() {
		if track := sender.Track(); track != nil && track.Kind() == webrtc.RTPCodecTypeVideo {
			senders++
			if len(sender.GetParameters().Encodings) == 0 {
				t.Fatal("the second window's sender has no negotiated encoding")
			}
		}
	}
	if senders != 1 {
		t.Fatalf("video senders = %d, want exactly the second window's", senders)
	}
}

// AN ANSWER THAT SIMPLY DOES NOT CARRY flexfec-03 IS A RECEIVER DECLINING A CAPABILITY, and it must
// get video on NACK/RTX rather than a dead session.
//
// This is also the only safety valve for Safari and Firefox, neither of which has ever been
// exercised against rdev's FlexFEC — and it is the device this whole codec arc exists for that is
// most likely to decline.
func TestAMissingFlexFECDegradesRatherThanFailing(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.SetAnswer(stripFlexFEC(t, buildRemoteAnswer(t, session))); err != nil {
		t.Fatalf("an answer without flexfec-03 killed the session: %v", err)
	}
	if got := session.ActiveRecovery(); got != "nack-rtx" {
		t.Fatalf("activeRecovery = %q, want nack-rtx", got)
	}
}

// AN ANSWER THAT CARRIES flexfec-03 AND GETS IT WRONG IS STILL AN ERROR. A payload type outside the
// media line is a description rdev cannot act on, and accepting it would put the FEC in a state its
// own validators call impossible. Degrading must not become "accept anything".
func TestAMalformedFlexFECStillFails(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.SetAnswer(corruptFlexFEC(t, buildRemoteAnswer(t, session))); err == nil {
		t.Fatal("a malformed flexfec-03 was accepted")
	}
}

// A HEALTHY ANSWER STILL REPORTS FlexFEC, so the degradation cannot be satisfied by never
// negotiating it at all.
func TestAFlexFECAnswerReportsFlexFEC(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.SetAnswer(buildRemoteAnswer(t, session)); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	if got := session.ActiveRecovery(); got != "nack-rtx-flexfec" {
		t.Fatalf("activeRecovery = %q, want nack-rtx-flexfec", got)
	}
}

// stripFlexFEC removes flexfec-03 entirely — its rtpmap, its fmtp, its ssrc-group and its payload
// number in the m=video line — which is what an answer from a receiver that does not support it
// looks like.
func stripFlexFEC(t *testing.T, sdp string) string {
	t.Helper()
	payload := ""
	for _, line := range strings.Split(sdp, "\n") {
		trimmed := strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(trimmed, "a=rtpmap:") && strings.Contains(strings.ToLower(trimmed), "flexfec-03") {
			payload = strings.TrimPrefix(strings.Fields(trimmed)[0], "a=rtpmap:")
		}
	}
	if payload == "" {
		t.Fatal("the answer carried no flexfec-03 to strip, so this test would prove nothing")
	}
	out := make([]string, 0)
	for _, line := range strings.Split(sdp, "\n") {
		trimmed := strings.TrimSuffix(line, "\r")
		lower := strings.ToLower(trimmed)
		if strings.Contains(lower, "flexfec-03") ||
			strings.HasPrefix(trimmed, "a=fmtp:"+payload+" ") ||
			strings.HasPrefix(trimmed, "a=ssrc-group:FEC-FR") {
			continue
		}
		if strings.HasPrefix(trimmed, "m=video ") {
			fields := strings.Fields(trimmed)
			kept := fields[:3]
			for _, token := range fields[3:] {
				if token != payload {
					kept = append(kept, token)
				}
			}
			trimmed = strings.Join(kept, " ")
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\r\n")
}

// corruptFlexFEC leaves the rtpmap in place but removes its payload number from the m=video line,
// so the codec is present-but-not-negotiated — a description rdev cannot act on.
func corruptFlexFEC(t *testing.T, sdp string) string {
	t.Helper()
	payload := ""
	for _, line := range strings.Split(sdp, "\n") {
		trimmed := strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(trimmed, "a=rtpmap:") && strings.Contains(strings.ToLower(trimmed), "flexfec-03") {
			payload = strings.TrimPrefix(strings.Fields(trimmed)[0], "a=rtpmap:")
		}
	}
	if payload == "" {
		t.Fatal("the answer carried no flexfec-03 to corrupt")
	}
	out := make([]string, 0)
	for _, line := range strings.Split(sdp, "\n") {
		trimmed := strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(trimmed, "m=video ") {
			fields := strings.Fields(trimmed)
			kept := fields[:3]
			for _, token := range fields[3:] {
				if token != payload {
					kept = append(kept, token)
				}
			}
			trimmed = strings.Join(kept, " ")
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\r\n")
}

// THE ANSWER MAY NARROW THE CODEC SET, AND rdev REJECTED THAT AS TAMPERING.
//
// The offer/answer comparison in parseFlexFECVideoSection checked the PRIMARY payload type, which
// is right only while rdev offers one codec. `PreferredPayloadType` is the first of rdev's
// preference order PRESENT IN THAT DESCRIPTION — 45 (AV1) in our three-codec offer, 102 (H.264) in
// the answer of a receiver with no AV1 decoder. So every AV1-less device, which is the entire
// reason this codec work exists, was refused with "answer changed FlexFEC identity": a message
// about FEC for a failure about codecs, on a path where nothing had tampered with anything.
//
// THE OFFER IS A REAL PION OFFER, for the reason this file's header gives. THE ANSWER CANNOT BE:
// pion answers with everything it supports, and the shape under test is a receiver that does not
// support AV1. It is synthesized by stripping the real offer, which is what a browser does to the
// codecs it lacks and what e2e/codec-negotiation-verify.mjs does to force one.

// attributePayloadOf returns the payload type an a=rtpmap/fmtp/rtcp-fb line applies to, or "".
func attributePayloadOf(line string) string {
	for _, prefix := range []string{"a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"} {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		rest := line[len(prefix):]
		if end := strings.IndexByte(rest, ' '); end >= 0 {
			return rest[:end]
		}
		return rest
	}
	return ""
}

// stripVideoPayloads removes each payload type from a description ENTIRELY: its rtpmap, its fmtp,
// its rtcp-fb lines, and its number in the m=video line.
func stripVideoPayloads(sdp string, payloads ...int) string {
	drop := map[string]bool{}
	for _, payload := range payloads {
		drop[strconv.Itoa(payload)] = true
	}
	var kept []string
	for _, raw := range strings.Split(sdp, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		if payload := attributePayloadOf(line); payload != "" && drop[payload] {
			continue
		}
		if strings.HasPrefix(line, "m=video ") {
			fields := strings.Fields(line)
			rebuilt := make([]string, 0, len(fields))
			for i, field := range fields {
				if i < 3 || !drop[field] {
					rebuilt = append(rebuilt, field)
				}
			}
			line = strings.Join(rebuilt, " ")
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\r\n")
}

// renumberVideoPayload moves a payload type to a new number EVERYWHERE it appears: its rtpmap,
// fmtp and rtcp-fb lines, any apt= that names it, and the m=video line.
//
// A PARTIAL RENUMBER IS WHY THE FIRST VERSION OF THESE TESTS PROVED NOTHING. Renumbering the
// rtpmap alone leaves the payload absent from the m=video line, so the parser rejects the
// description for that inconsistency — and both "we never offered this" tests passed against a
// build with the subset check DELETED. Keep every site in step, or the test measures the wrong
// rejection.
func renumberVideoPayload(sdp string, from, to int) string {
	fromText, toText := strconv.Itoa(from), strconv.Itoa(to)
	var out []string
	for _, raw := range strings.Split(sdp, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		if attributePayloadOf(line) == fromText {
			for _, prefix := range []string{"a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"} {
				if strings.HasPrefix(line, prefix) {
					line = prefix + toText + line[len(prefix)+len(fromText):]
					break
				}
			}
		}
		if strings.HasPrefix(line, "a=fmtp:") {
			// apt= names a primary BY NUMBER, so renumbering that primary has to follow it.
			line = strings.Replace(line, "apt="+fromText+";", "apt="+toText+";", 1)
			if strings.HasSuffix(line, "apt="+fromText) {
				line = strings.TrimSuffix(line, "apt="+fromText) + "apt=" + toText
			}
		}
		if strings.HasPrefix(line, "m=video ") {
			fields := strings.Fields(line)
			for i, field := range fields {
				if i >= 3 && field == fromText {
					fields[i] = toText
				}
			}
			line = strings.Join(fields, " ")
		}
		out = append(out, line)
	}
	return strings.Join(out, "\r\n")
}

// unusedExtmapID returns an a=extmap id no section of this description uses.
func unusedExtmapID(sdp string) int {
	highest := 0
	for _, raw := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if !strings.HasPrefix(line, "a=extmap:") {
			continue
		}
		idText := strings.TrimPrefix(strings.Fields(line)[0], "a=extmap:")
		if slash := strings.IndexByte(idText, '/'); slash >= 0 {
			idText = idText[:slash]
		}
		if id, err := strconv.Atoi(idText); err == nil && id > highest {
			highest = id
		}
	}
	return highest + 1
}

// offerAndNarrowedAnswer returns rdev's real three-codec offer identity, the sections it sends on,
// and an answer narrowed to H.264 alone — an AV1-less receiver's shape.
func offerAndNarrowedAnswer(t *testing.T) (flexFECNegotiation, []int, string, time.Duration) {
	t.Helper()
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("offer refused: %v", err)
	}
	maxAge := session.config.RTXMaxAge
	identity, sections, err := validateFlexFECLocalOffer(sdp, maxAge)
	if err != nil {
		t.Fatalf("our own offer was refused: %v", err)
	}
	// A GUARD ON THE FIXTURE, not on the code: if rdev ever stops offering all three codecs these
	// tests would still pass while covering nothing, because narrowing would be a no-op.
	if len(identity.Primaries) != 3 {
		t.Fatalf("offer carries %d primaries, want 3 — this test no longer narrows anything: %#v",
			len(identity.Primaries), identity.Primaries)
	}
	narrowed := stripVideoPayloads(sdp,
		av1PayloadType, rtxPayloadType, h265PayloadType, h265RTXPayloadType)
	return identity, sections, narrowed, maxAge
}

func TestFlexFECRemoteAnswerMayNarrowToH264(t *testing.T) {
	identity, sections, narrowed, maxAge := offerAndNarrowedAnswer(t)
	negotiated, err := validateFlexFECRemoteAnswer(narrowed, identity, sections, maxAge)
	if err != nil {
		t.Fatalf("an AV1-less receiver's answer was refused: %v", err)
	}
	if len(negotiated.Primaries) != 1 || negotiated.Primaries[h264PayloadType] != h264RTXPayloadType {
		t.Fatalf("negotiated primaries = %#v, want {%d: %d}",
			negotiated.Primaries, h264PayloadType, h264RTXPayloadType)
	}
	// THE NUMBER THE OLD CHECK COMPARED. It differs from the offer's on purpose: that difference IS
	// the narrowing, and asserting it is what stops the strict comparison being reinstated.
	if negotiated.PreferredPayloadType != h264PayloadType {
		t.Fatalf("preferred payload = %d, want %d", negotiated.PreferredPayloadType, h264PayloadType)
	}
	if identity.PreferredPayloadType == negotiated.PreferredPayloadType {
		t.Fatalf("offer and answer agree on the preferred payload (%d), so this test would pass "+
			"under the strict comparison it exists to reject", negotiated.PreferredPayloadType)
	}
}

// A SUBSET IS NOT AN INVENTION. Without this half the check would accept a codec rdev never
// registered and cannot encode — a bound track producing a stream nothing can decode.
func TestFlexFECRemoteAnswerRejectsAPrimaryNeverOffered(t *testing.T) {
	identity, sections, narrowed, maxAge := offerAndNarrowedAnswer(t)
	// 96 is a valid dynamic payload type that this offer never carried. Renumbered consistently,
	// so the ONLY thing wrong with the answer is that we never proposed it.
	renumbered := renumberVideoPayload(narrowed, h264PayloadType, 96)
	if renumbered == narrowed {
		t.Fatal("test mutation did not change the fixture")
	}
	if _, err := validateFlexFECRemoteAnswer(renumbered, identity, sections, maxAge); err == nil {
		t.Fatal("an answer negotiating a payload we never offered was accepted")
	}
}

// THE RTX PAIRING IS PART OF THE OFFER TOO. An answer repairing our H.264 with the RTX payload we
// paired to AV1 describes a retransmission stream we never proposed.
func TestFlexFECRemoteAnswerRejectsARepairPairingWeNeverOffered(t *testing.T) {
	identity, sections, narrowed, maxAge := offerAndNarrowedAnswer(t)
	repaired := renumberVideoPayload(narrowed, h264RTXPayloadType, rtxPayloadType)
	if repaired == narrowed {
		t.Fatal("test mutation did not change the fixture")
	}
	if _, err := validateFlexFECRemoteAnswer(repaired, identity, sections, maxAge); err == nil {
		t.Fatal("an answer pairing our primary with an RTX we never paired to it was accepted")
	}
}

// NARROWING THE CODECS DOES NOT LOOSEN THE FEC'S OWN IDENTITY. These fields are ours, we offered
// them, and an answer that alters one describes a FlexFEC configuration we never proposed.
//
// BOTH MUTATIONS ARE INDIVIDUALLY VALID DESCRIPTIONS, which is the whole difficulty: a mutation
// the standalone parser rejects tests the parser, not the comparison. Renumbering flexfec-03 and
// moving the TWCC extmap are the only two identity fields that CAN differ while staying valid —
// `RepairWindowMicroseconds` is deliberately untested here because parseFlexFECRepairWindow
// requires the exact constant, so an answer whose window differs from the offer's is already
// rejected one layer down and can never reach this comparison.
func TestFlexFECRemoteAnswerStillGuardsTheFECsOwnIdentity(t *testing.T) {
	identity, sections, narrowed, maxAge := offerAndNarrowedAnswer(t)
	twcc := strconv.Itoa(identity.TWCCExtensionID)
	moved := strconv.Itoa(unusedExtmapID(narrowed))
	tests := []struct {
		name   string
		mutate func(string) string
	}{
		{name: "flexfec payload type", mutate: func(sdp string) string {
			return renumberVideoPayload(sdp, flexfecPayloadType, flexfecPayloadType+20)
		}},
		{name: "twcc extension id", mutate: func(sdp string) string {
			return strings.Replace(sdp, "a=extmap:"+twcc+" "+twccURI, "a=extmap:"+moved+" "+twccURI, 1)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			mutated := test.mutate(narrowed)
			if mutated == narrowed {
				t.Fatal("test mutation did not change the fixture")
			}
			if _, err := validateFlexFECRemoteAnswer(mutated, identity, sections, maxAge); err == nil {
				t.Fatalf("an answer that changed the FlexFEC %s was accepted", test.name)
			}
		})
	}
}
