package main

// The offer half of the session's signalling: offer/answer and ICE trickle as callable
// operations, with no socket of the session's own.
//
// WHY THIS FILE EXISTS. LLV's host ANSWERS — newHostSession calls acceptSignalTCP and then
// serveAnswer, owning a TCP connection for the whole exchange and gathering ICE to
// completion before it replies. rdev's host OFFERS, over a WebSocket through the Cloudflare
// control plane, trickles its candidates, and renegotiates on every track add or remove.
// Inverting rdev's side instead would mean changing the web client, the control-plane
// protocol and RdevViewer, so LLV's side is the one that moves.
//
// Everything except the signalling is shared with the answering path — see assembleSession
// in session.go, which both entry points call, and which is where the reason that matters is
// written down.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/pion/webrtc/v4"
)

// localICECandidate is the wire shape rdev's ABI already carries in BOTH directions:
// `pion_peer_add_ice(h, cand_json)` takes it inbound (host/pion-bridge/peer.go, addICE) and
// the `pion_on_ice_candidate(ctx, cand_json)` callback emits it outbound, which
// PionPeer.handleIce turns straight back into the dictionary rdev's signalling sends.
// Matching it exactly is what lets the rdev ABI shim pass signalling through untranslated.
type localICECandidate struct {
	Candidate     string `json:"candidate"`
	SDPMid        string `json:"sdpMid"`
	SDPMLineIndex uint16 `json:"sdpMLineIndex"`
}

// newOfferSession builds a session that offers, with no socket of its own. The caller drives
// signalling: CreateOffer, then SetAnswer when the remote answer arrives, then AddRemoteICE
// for each trickled remote candidate; local candidates arrive on
// callbacks.OnLocalICECandidate as they are gathered.
//
// SignalPort IS VESTIGIAL ON THIS PATH AND STILL VALIDATED. It must be non-zero and
// distinct from ICEPort even though nothing listens on it here, because
// validateSessionConfiguration and PeerConfig.Validate are shared with the answering path and
// relaxing either would change what THAT path accepts. A caller passes a dummy.
//
// SUPERSEDED 2026-08-18 — THIS DESCRIBES ICEPolicyStrict, WHICH RDEV NO LONGER USES.
// Everything below is true of `capture-host`, which passes ICEPolicyStrict and is the
// certification's comparison arm. rdev's offer sessions pass ICEPolicyLAN: no local IP filter, no
// remote IP filter, query-only mDNS, the UDP mux bound unspecified, and ICE servers registered from
// `ice_servers_json`. So the two consequences below — the mDNS-obfuscated host candidate being
// unusable, and every TURN relay candidate being dropped — no longer apply to rdev. They are kept
// because they are why the policy exists and what `strict` still does.
//
// REMOTEIP IS NOT VESTIGIAL UNDER STRICT — IT IS A FILTER, AND IT BOUNDS WHO CAN EVER CONNECT.
// The answering path learns it from the accepted TCP connection; an offer session has no
// connection to learn it from, so the caller supplies it, and PeerConfig.Validate rejects a
// nil one — there is no opting out. newPeerAPI then turns the configuration into four ICE
// restrictions on one shared SettingEngine (peer_config.go:1016-1019):
//
//	SetNetworkTypes([UDP4])                  IPv4 UDP only
//	SetIPFilter(equal localIP)               gather on one local address
//	SetRemoteIPFilter(equal remoteIP)        accept remote candidates from ONE address
//	SetICEMulticastDNSMode(Disabled)
//
// So this session is reachable from exactly one pre-known IPv4 address, and TWO consequences
// follow that are decisive for a real browser client:
//
//   - Chrome's host candidate is mDNS-obfuscated, so the pair that wins in rdev today is a
//     PEER-REFLEXIVE one learned from Chrome's inbound check. That is no escape hatch:
//     pion/ice v4.2.7 runs prflx candidates through the SAME filter
//     (agent.go:1779 -> addRemoteCandidate -> shouldAcceptRemoteCandidate at :1256), so it is
//     dropped unless the address happens to equal remoteIP.
//   - Every TURN relay candidate carries the RELAY SERVER's address, not the peer's, so
//     rdev's whole WAN story is excluded by the same filter.
//
// It is therefore not "untested against a browser" — as configured it is STRUCTURALLY
// IMPOSSIBLE, and the fix has to modify newPeerAPI, which is SHARED with the answering path
// and is exactly what must not drift. Increment 1 is unaffected: its certification drives
// RdevViewer on a known LAN address (--local-ip), which satisfies the filter. Increment 2 —
// the browser client — is where this is a hard blocker, and is the first thing it must solve.
//
// FlexFEC is refused here rather than half-supported; see the error text for why.
//
// THERE IS NO EAGER TRACK ON THIS PATH, AND REMOVING IT WAS THE DECISION THIS FILE OWED. The
// answering path still builds one (`newHostSession`, MSID `desktop`, keyframe stream 0) because
// stock `llv capture-host` sends on it; an offer session's tracks come from AddVideoTrack, one per
// subscribed source. Keeping it here shipped an unused video m-section on every rdev offer, and
// that was wrong in three separate ways, of which only the first was known when the choice was
// deferred:
//
//   - It made readiness a LIE. mediaReady is set by the FIRST track to bind, which was always the
//     eager one, so a session reported ready-to-carry-media with zero rdev tracks — measured, and
//     pinned by a test that said so. With it gone, "video track not bound" means what it says.
//   - IT BROKE rdev's OWN HEADLESS SMOKE, which is the concrete cost. The web client keys incoming
//     streams by MSID and, on the test-pattern path where no view-set is ever sent, synthesises its
//     one window from the FIRST stream it received (`main.ts`, syncVideo). That first stream was
//     `desktop`, which never carries a frame, so `#screen` bound to a dead track and the smoke's
//     "video is live" assertion could not pass.
//   - It offered a source no client can subscribe to, unsubscribe from or focus, on a protocol
//     whose whole track→source identity is the MSID.
//
// THE COST IS TWO CALL-SITE CONDITIONS, both in this file and both explained where they are:
// CreateOffer skips advertiseRTXTime and SetAnswer skips preparePionRemoteDescription when there is
// no video m-section, because each of those requires something only a video section can carry.
// Neither shared function changed.
func newOfferSession(
	configuration SessionConfiguration,
	callbacks SessionCallbacks,
) (*Session, error) {
	if err := validateSessionConfiguration(configuration); err != nil {
		return nil, err
	}
	if err := validateSessionCallbacks(configuration, callbacks); err != nil {
		return nil, err
	}
	// Required, not optional: a session that cannot publish its candidates cannot signal,
	// and the failure mode is an ICE connection that mysteriously does not form — or, worse,
	// one that forms anyway on a LAN because either end can learn the other peer-reflexively
	// from an inbound check, and then fails on a real network. The same "returns silently"
	// hazard maybeReady has.
	if callbacks.OnLocalICECandidate == nil {
		return nil, fmt.Errorf(
			"%w: an offer session needs a local ICE candidate callback to signal with",
			errSession,
		)
	}
	// Required for the same reason and with the same failure shape. rdev's client drives
	// everything the host does over `control` — subscribe, focus, prefs — so a session that
	// silently discards inbound channel payloads comes up healthy, negotiates, reports ready,
	// and then never streams anything, because nothing ever asked it to.
	if callbacks.OnChannelMessage == nil {
		return nil, fmt.Errorf(
			"%w: an offer session needs a channel message callback to be driven through",
			errSession,
		)
	}
	// Required for the third time and the third failure of the same shape. rdev's host does
	// nothing until a channel opens — the first shell is spawned on `terminal`'s open and
	// control-state, the tab list and the view set are all pushed on `control`'s — so a session
	// that never reports an open connects, negotiates, streams nothing and says nothing about why.
	if callbacks.OnChannelOpen == nil {
		return nil, fmt.Errorf(
			"%w: an offer session needs a channel open callback, or nothing downstream ever "+
				"learns it may start",
			errSession,
		)
	}
	session, err := assembleSession(configuration, callbacks)
	if err != nil {
		return nil, err
	}
	// Created here rather than in assembleSession, because the channel set is what the two entry
	// points DIFFER by: this path creates rdev's (the lane and bulk), the answering path receives LLV's two.
	// It has to happen before the caller's first CreateOffer — a data m-section only appears in
	// an offer if a channel exists when that offer is built.
	if err := session.createRdevDataChannels(configuration.RdevSCTPChannels); err != nil {
		_ = session.Close()
		return nil, err
	}
	publishEveryRecoveryFailure(session)
	// Registered before CreateOffer, because SetLocalDescription is what starts gathering:
	// wiring this after the first offer would drop that offer's candidates.
	session.peer.OnICECandidate(session.emitLocalICECandidate)
	return session, nil
}

// publishEveryRecoveryFailure makes the recovery stack's fatal errors reach OnError EVERY TIME, not
// only when they happen to be the session's first failure.
//
// WHY IT IS NEEDED, AND WHY IT IS HERE RATHER THAN IN `fail`. `Session.fail` wraps its whole body —
// including emitError — in a `sync.Once`, and OnError is the C ABI's ONLY error observable. So
// whatever consumes that one shot first silences everything after it, on a project whose signature
// failure is "every state reads healthy and no picture arrives".
//
// UPDATED 2026-08-18. Until then the one shot was ALWAYS spent, on every same-machine session, by
// maybeReady failing the session over a peer-reflexive candidate pair — `selectedCandidateLocked`
// required host↔host, which is true of LLV's viewer and false of any browser. That is fixed at the
// source: an unmet readiness precondition is now a blocker rather than a failure. This wrapper is
// therefore no longer compensating for a guaranteed loss — it covers the ordinary case where some
// genuine earlier failure has consumed the once, which is rarer and still real.
//
// THE OBVIOUS FIX — make `fail` emit every error — WAS MEASURED AND REJECTED, and the measurement is
// the reason this exists. `fail` is shared with the answering path, whose Swift consumer keeps
// `latestBridgeError` LAST-WINS (`Sources/LLVWebRTC/PionSessionRegistry.swift`) and feeds it into the
// errors `PionSession` throws. Emitting every error would therefore make stock `llv capture-host`
// report a late symptom instead of the cause — a diagnostic REGRESSION on the certification's
// comparison arm, which is the opposite of the intent.
//
// IT IS A WRAP, NOT A COPY. The other two recovery callbacks are read out and passed straight back,
// so the wiring createSession installed is preserved by value rather than reconstructed here — a
// reconstructed copy is exactly the drift this whole task is arranged to avoid. `reportError` is
// still called, so session.failure, failedCh and readiness bookkeeping are untouched; the only
// change is that the error is also published.
//
// The two remaining `fail` callers on this path lose nothing: handlePeerState's failure states are
// logged by the ABI from the state number, which travels on a separate path `fail` cannot swallow,
// and `markChannelOpen`'s unrecognised-kind branch and `emitLocalICECandidate`'s marshal failure are
// both unreachable (two ChannelKinds exist; every marshalled field is a string or a uint16).
//
// The literal fix — not failing the session for a readiness precondition at all — belongs to
// `maybeReady`, which is shared, and is recorded against increment 2 in the design spec.
func publishEveryRecoveryFailure(session *Session) {
	resources := session.apiResources
	if resources == nil {
		return
	}
	resources.callbackMutex.Lock()
	requestKeyframe := resources.requestKeyframe
	reportError := resources.reportError
	observeNACK := resources.observeNACK
	resources.callbackMutex.Unlock()
	if reportError == nil {
		return
	}
	resources.SetRecoveryCallbacks(requestKeyframe, func(err error) {
		// Published FIRST. reportError is session.fail, which emits this same error if it happens
		// to be the session's first failure — so the very first recovery fatal of a session that
		// has not otherwise failed is logged twice. That is a duplicate line, against the
		// alternative of losing every one after the first.
		session.emitError(err)
		reportError(err)
	}, observeNACK)
}

// ONE ANSWERER-ROLE STEP HAS NO COUNTERPART HERE, DELIBERATELY AND DORMANTLY.
// The answering path calls negotiateReceiverReferenceTime (session.go:261), which echoes
// `a=rtcp-xr:rcvr-rtt=all` into the answer when the remote's OFFER carried it. Neither
// CreateOffer nor SetAnswer has an analogue, so receiver reference time is never negotiated on
// the offer path — an SDP-level asymmetry between the two arms that
// TestOfferSessionAssemblesTheSamePeerAndTrackAsTheAnsweringPath cannot see, because it
// compares peer construction and track wiring rather than SDP.
//
// IMPACT TODAY IS NIL, and that was measured rather than assumed: nothing under
// host/streaming-engine/ outside peer_config.go emits the attribute, so the step is dormant on
// BOTH arms, and its only consumer — keyframeResponseWait (age_aware_nack_responder.go:640) —
// falls back to defaultKeyframeResponseWait when RTT is unknown. Recorded so that whoever makes
// something offer the attribute knows the two arms will diverge in the RTT path at that moment,
// rather than rediscovering it as a latency difference with no cause.
//
// CreateOffer produces one offer and applies it as this session's local description. It does
// NOT wait for ICE gathering — that is the point of the offer path: the caller signals the
// offer immediately and the candidates follow on OnLocalICECandidate. (The answering path
// does wait, in gatherPeerDescription, because it has nowhere to trickle to.)
//
// The `closing` check here, and the matching ones in SetAnswer and AddRemoteICE, are NOT
// load-bearing: pion errors on a closed peer by itself, so they only turn a teardown race into
// a legible message instead of a pion internal one. They are present in all three rather than
// one so that nobody "restores" the missing two believing they matter, and they are
// deliberately untested — a post-Close test passes with OR without them, which would be a
// non-discriminating test counted as coverage.
func (session *Session) CreateOffer() (string, error) {
	return session.createOffer(nil)
}

// CreateICERestartOffer produces an offer that re-gathers ICE while keeping the DTLS transport,
// the data channels and every video track — rdev's `pion_peer_restart_ice`, which its client
// drives after a network change. It differs from CreateOffer by pion's ICERestart option and by
// nothing else, deliberately: an ICE restart that also rebuilt the description would be a
// reconnect wearing a restart's name, and rdev's client tags the resulting offer `restart:true`
// specifically to tell its peer NOT to rebuild.
func (session *Session) CreateICERestartOffer() (string, error) {
	return session.createOffer(&webrtc.OfferOptions{ICERestart: true})
}

func (session *Session) createOffer(options *webrtc.OfferOptions) (string, error) {
	if err := session.refuseWhenClosing(); err != nil {
		return "", err
	}
	offer, err := session.peer.CreateOffer(options)
	if err != nil {
		return "", fmt.Errorf("create offer: %w", err)
	}
	// REHEARSED AND VALIDATED BEFORE SetLocalDescription, AND THE ORDERING IS THE WHOLE POINT.
	//
	// SetLocalDescription moves the peer to have-local-offer. driveOffer emits only from `stable`,
	// and the only thing that returns a peer to stable is the ANSWER to an offer the remote
	// received — so refusing an offer after setting it locally strands the session permanently:
	// the offer is never sent, no answer can arrive, and every later renegotiation returns early,
	// silently, forever. Reported from real use as one `renegotiation offer failed` line followed
	// by `no negotiated bindings` on every write for the rest of the run. driveOffer's "left
	// pending so the next drive retries" was true of the flag and false of the peer.
	//
	// The rehearsal is the description pion just produced, put through the SAME transform the wire
	// copy gets below. The two differ only in the ICE candidates SetLocalDescription flushes into
	// the local description, and no check here reads a candidate line — so validating the rehearsal
	// is validating what we send.
	rehearsal, err := session.prepareLocalOffer(offer)
	if err != nil {
		return "", err
	}
	offered, offeredSections, err := session.checkLocalOffer(rehearsal.SDP)
	if err != nil {
		return "", err
	}

	if err := session.peer.SetLocalDescription(offer); err != nil {
		return "", fmt.Errorf("set local offer: %w", err)
	}
	local := session.peer.LocalDescription()
	if local == nil {
		return "", fmt.Errorf("%w: no local description after set", errSession)
	}
	wire, err := session.prepareLocalOffer(*local)
	if err != nil {
		return "", err
	}
	if session.config.Recovery == RecoveryNACKRTXFlexFEC {
		// ARMED FOR THIS ROUND ONLY, and it must also DISARM. An offer that sends no video — every
		// source unsubscribed — carries no FlexFEC contract, so the answer to it has none to match
		// and SetAnswer has to skip symmetrically. This was a one-way latch, which was invisible
		// while the first offer was the only video-less one.
		session.mutex.Lock()
		session.offeredFlexFEC = offered
		session.offeredFlexFECSections = offeredSections
		session.offeredFlexFECValid = len(offeredSections) > 0
		session.mutex.Unlock()
	}
	return wire.SDP, nil
}

// prepareLocalOffer applies to an outgoing description whatever this session's recovery mode
// requires of it. Split out of createOffer so the rehearsal above and the wire copy cannot drift.
func (session *Session) prepareLocalOffer(
	description webrtc.SessionDescription,
) (webrtc.SessionDescription, error) {
	// THE VIDEO-SECTION CONDITION IS THE RULING TASK 4 DEFERRED, AND IT IS APPLIED HERE RATHER
	// THAN INSIDE advertiseRTXTime SO THAT NO SHARED SDP CODE MOVES.
	//
	// rdev offers DATA CHANNELS FIRST and adds a video m-section on the renegotiation that adds
	// the first track, so this session's first offer legitimately carries no video at all —
	// and advertiseRTXTime fails loudly on a description with no RTX fmtp in it ("missing local
	// RTX fmtp"), which is exactly that offer. The rule is: skip the advertisement when there is
	// no video m-section, require it when there is. A video section with no RTX fmtp is still a
	// real misconfiguration and still fails, which is the half worth keeping.
	//
	// PLACING IT AT THE CALL SITE IS THE POINT. advertiseRTXTime is shared with the ANSWERING
	// path — the certification's comparison arm — and every answer that path produces carries its
	// own eager track's video section, so the function's behaviour there is identical either way.
	// Changing the function would have meant proving that; changing the caller means the shared
	// code is untouched and there is nothing to prove.
	if nackRTXEnabled(session.config.Recovery) && sdpHasVideoSection(description.SDP) {
		// Same call the answering path makes on the answer it sends, for the same reason:
		// rtx-time is how the remote learns the retransmission window this session's
		// responder actually enforces. The remote learns it before any RTX can happen,
		// because RTX cannot happen before there is a video track to retransmit for.
		return advertiseRTXTime(description, session.config.negotiatedRTXTime())
	}
	return description, nil
}

// checkLocalOffer judges an outgoing offer and returns the FlexFEC identity it carries plus the
// video sections that identity covers. Both are empty on the legacy recovery modes.
//
// NO VIDEO-SECTION CONDITION IS NEEDED ANY MORE, and its absence is the fix rather than an
// oversight. It used to guard rdev's data-channels-only first offer, which has no AV1, RTX or
// flexfec-03 payload to validate — but "sends on no video section" now covers that case and the
// two it did not: a section left recvonly by the last unsubscribe, which has no sender to
// identify, and the several sections a multi-source subscription produces.
func (session *Session) checkLocalOffer(sdp string) (flexFECNegotiation, []int, error) {
	if session.config.Recovery != RecoveryNACKRTXFlexFEC {
		if err := validateLegacyRecoverySDP(sdp, session.config.Recovery); err != nil {
			return flexFECNegotiation{}, nil, fmt.Errorf("validate local offer: %w", err)
		}
		return flexFECNegotiation{}, nil, nil
	}
	offered, sections, err := validateFlexFECLocalOffer(sdp, session.config.negotiatedRTXTime())
	if err != nil {
		// PRINT THE SECTIONS, for the same reason SetAnswer prints the answer's: a refusal that
		// names only the rule it enforced sends the next person to re-derive which shape produced
		// it, and this one is fatal to the renegotiation.
		fmt.Printf("[bridge] local FlexFEC offer REFUSED: %v\n%s\n",
			err, describeVideoSectionForDiagnosis(sdp))
		return flexFECNegotiation{}, nil, fmt.Errorf("validate local FlexFEC offer: %w", err)
	}
	return offered, sections, nil
}

// sdpHasVideoSection reports whether a description carries at least one `m=video` section.
//
// It exists because rdev's first offer has NONE — it offers data channels and adds video on the
// renegotiation that adds the first track — and two pieces of shared SDP machinery are written on
// the assumption that a description has video: advertiseRTXTime requires an RTX fmtp to rewrite,
// and preparePionRemoteDescription requires a dependency-descriptor extmap. Both are correct for
// every description the ANSWERING path handles and vacuous for a description with no video, so
// this predicate is what tells the two apart at the call sites.
//
// The `m=video ` prefix, with the space, is what the shared code itself matches on
// (videoSectionContainsAttribute, negotiateReceiverReferenceTime), so this cannot disagree with
// them about what a video section is.
func sdpHasVideoSection(sdp string) bool {
	for _, rawLine := range strings.Split(sdp, "\n") {
		if strings.HasPrefix(strings.TrimSuffix(rawLine, "\r"), "m=video ") {
			return true
		}
	}
	return false
}

// SetAnswer applies the remote answer. It mirrors what the answering path does to the
// description it RECEIVES, including passing requireRTXTime=false: a remote that does not
// echo rtx-time is accepted, and one that echoes a DIFFERENT value is refused.
//
// THE MOST LIKELY SURPRISE WHEN A REAL BROWSER FIRST ANSWERS THIS, and it is deliberate:
// validateLegacyRecoverySDP rejects an SDP containing "flexfec", "fec-fr", "transport-cc" or
// the TWCC URI ANYWHERE in it, case-insensitively. Every remote description the answering path
// sees comes from LLV's own viewer, so that check has only ever policed SDP this project
// wrote; here the remote is Chrome or RdevViewer. An answer may not add feedback the offer did
// not carry, and this offer carries only nack/nack-pli, so it should hold — but if a browser
// does slip one of those strings in, video stops with `legacy SDP contains FlexFEC/TWCC` and
// THAT is the reason. Kept rather than relaxed: it is what the answering path does, the two
// arms have to negotiate the same way to be comparable, and a loud stop beats mis-negotiating
// recovery quietly. Relaxing it needs a real-browser measurement, not a judgement call.
func (session *Session) SetAnswer(sdp string) error {
	if err := session.refuseWhenClosing(); err != nil {
		return err
	}
	if sdp == "" {
		return fmt.Errorf("%w: empty answer SDP", errSession)
	}
	answer := webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: sdp}
	if session.config.Recovery != RecoveryNACKRTXFlexFEC {
		if err := validateLegacyRecoverySDP(answer.SDP, session.config.Recovery); err != nil {
			return fmt.Errorf("validate remote answer: %w", err)
		}
	}
	engineAnswer := answer
	// THE SAME VIDEO-SECTION CONDITION AS CreateOffer, AND FOR THE SAME REASON: the answer to
	// rdev's data-channels-only first offer has no video section either, and
	// preparePionRemoteDescription's FIRST statement requires a dependency-descriptor extmap in
	// one ("missing … video extmap"). So without this the first answer of every rdev session is
	// rejected and the connection never comes up.
	//
	// SKIPPING THE CALL IS EXACTLY EQUIVALENT TO FIXING IT, WHICH IS WHY THE SHARED FUNCTION IS
	// NOT TOUCHED. Read what it does to a description with no video: the extmap check is the only
	// thing that can fire. Its other job is validating and rewriting RTX fmtp lines, and a
	// data-channel-only description has NO `a=fmtp:` LINES AT ALL — so parseFMTPLine returns
	// ok == false for every line and the loop body is never entered; with requireRTXTime=false an
	// association count of zero is not an error; and strings.Join(strings.Split(s,"\n"),"\n") is
	// exact identity, so the SDP comes back unmutated. So it is a no-op apart from the check that
	// should not apply.
	//
	// AN EARLIER VERSION OF THIS PROOF GAVE THE WRONG REASON — that "recoveryPayloadTypes finds no
	// `a=rtpmap:` for AV1 or rtx". It does not: that function PRE-SEEDS av1[45] and rtx[46]
	// unconditionally (peer_config.go), so those maps are never empty and the guard that actually
	// skips every line is parseFMTPLine's. The conclusion was right and the reason was not, which is
	// how the next person derives something false from a comment that reads as a proof.
	//
	// The answering path keeps the strict version: its remote description is the viewer's OFFER,
	// which always carries video, and a video-less one there is a genuine error worth failing at.
	if sdpHasVideoSection(answer.SDP) {
		prepared, err := preparePionRemoteDescription(
			answer, session.config.negotiatedRTXTime(), false,
		)
		if err != nil {
			return fmt.Errorf("validate remote answer: %w", err)
		}
		engineAnswer = prepared
	}
	// ARMED ONLY WHEN WE ACTUALLY OFFERED FlexFEC IN THIS ROUND. The offeredFlexFECValid latch is
	// what distinguishes "the answer to a data-channels-only offer", which carries no video and
	// nothing to match, from an answer that has something to say about the FEC we offered.
	//
	// A RECEIVER THAT DECLINES FlexFEC ENTIRELY DEGRADES TO NACK/RTX RATHER THAN DYING. Declining a
	// capability is legitimate — it is what a browser without FlexFEC does, and it is what the
	// AV1-less devices this codec work exists for are most likely to do. A receiver that ANSWERS
	// FlexFEC and gets it wrong is a different case and still fails: accepting a description the
	// FEC's own validators call impossible would arm it into a state it cannot run in.
	if session.config.Recovery == RecoveryNACKRTXFlexFEC {
		session.mutex.Lock()
		offered, valid := session.offeredFlexFEC, session.offeredFlexFECValid
		sections := session.offeredFlexFECSections
		session.mutex.Unlock()
		if valid && answerDeclinesFlexFEC(answer.SDP, sections) {
			// SAID ONCE, WHERE IT CAN BE SEEN. Which recovery stack a connection ended up on is
			// otherwise invisible, and it is a real difference in resilience: FlexFEC repairs in
			// band with no round trip, which is the only mechanism that helps at all on a path
			// where RTX is age-refused before a NACK can arrive.
			session.setActiveRecovery("nack-rtx")
			fmt.Printf("[bridge] recovery: the answer declined FlexFEC — this connection runs " +
				"nack-rtx\n")
		}
		if valid && !answerDeclinesFlexFEC(answer.SDP, sections) {
			negotiated, ffErr := validateFlexFECRemoteAnswer(
				answer.SDP, offered, sections, session.config.negotiatedRTXTime(),
			)
			if ffErr != nil {
				// PRINT WHAT THE ANSWER ACTUALLY SAID. A parser rejection that names only the rule
				// it enforced sends the next person to re-derive which field the browser omitted,
				// and this failure is FATAL — the track never binds, so capture and encode run at
				// full rate into nothing while every other line in the log reads healthy. That is
				// the exact shape of the H.265 `level-id` incident, whose diagnosis needed the
				// answer's own fmtp lines logged before it could be seen at all.
				fmt.Printf("[bridge] FlexFEC answer REJECTED: %v\n%s\n",
					ffErr, describeVideoSectionForDiagnosis(answer.SDP))
				return fmt.Errorf("validate remote FlexFEC answer: %w", ffErr)
			}
			// THE SSRCs ARE OURS, AND ONLY OUR OFFER CARRIES THEM.
			//
			// SetFlexFECNegotiation decides `negotiated` — and with it whether
			// FlexFECController.Start() is ever called — from the three SSRCs being non-zero. On
			// the ANSWERING path that works, because the description it validates is the host's
			// own answer, i.e. the sender's. Here the sender is us and the description is the
			// RECEIVER's, so it is parsed with requireSSRCGroups=false and all three come back
			// zero. Handing that straight over recorded FlexFEC as NOT negotiated on every rdev
			// session: the evaluation goroutine never ran, the controller never left the `off`
			// tier, and FEC kept charging its ~5% of the media budget while never once repairing
			// a packet. Nothing in the logs contradicted it.
			//
			// Copied field by field rather than by passing `offered` wholesale, so this stays
			// correct if the identity check above is ever loosened.
			//
			// WITH SEVERAL SUBSCRIBED SOURCES THESE ARE THE FIRST ONE'S. The engine keeps one
			// identity per session while rdev sends one stream per source, so the SSRCs reported
			// in stats — and handed to the impairment harness — describe the first sending
			// section. The tier and budget the controller decides are per session and apply to
			// all of them, which is the part that governs behaviour.
			negotiated.MediaSSRC = offered.MediaSSRC
			negotiated.RTXSSRC = offered.RTXSSRC
			negotiated.FlexFECSSRC = offered.FlexFECSSRC
			session.apiResources.SetFlexFECNegotiation(negotiated)
			session.setActiveRecovery("nack-rtx-flexfec")
			// WHETHER IT TOOK WAS NOT INFERABLE FROM ANYTHING ELSE IN THE LOG, and that is how a
			// dead adaptive controller hid for a day. `[bridge] recovery: … adaptive FlexFEC`
			// reports which stack was CONFIGURED at construction; it says nothing about whether
			// the negotiation the stack needs actually completed. Between the two, FEC can be
			// fully negotiated on the wire and still never engage.
			//
			// The state is READ BACK from the engine rather than restated here. Repeating
			// SetFlexFECNegotiation's own rule would make this line agree with the code by
			// construction and report `negotiated=true` in exactly the case it exists to catch —
			// the ninth such check this project has found, and the reason for the rule.
			if stats, _ := session.apiResources.FlexFECSnapshot(); stats != nil {
				fmt.Printf(
					"[bridge] FlexFEC negotiated=%v pt=%d repair-window=%dus twcc=%d "+
						"media-ssrc=%d fec-ssrc=%d over %d video section(s)\n",
					stats.Negotiated, negotiated.FlexFECPayloadType,
					negotiated.RepairWindowMicroseconds, negotiated.TWCCExtensionID,
					negotiated.MediaSSRC, negotiated.FlexFECSSRC, len(sections),
				)
			}
		}
	}
	if err := session.peer.SetRemoteDescription(engineAnswer); err != nil {
		return fmt.Errorf("set remote answer: %w", err)
	}
	session.markSignalingComplete()
	return nil
}

// AddRemoteICE adds one trickled remote candidate.
//
// The JSON is parsed TOLERANTLY of unknown fields, unlike every other message this bridge
// reads: this one comes from a browser, and RTCIceCandidate.toJSON() carries
// usernameFragment as well as the three fields below. rdev's Swift forwards whatever the
// client sent, verbatim.
//
// An EMPTY candidate string is forwarded rather than rejected — pion reads it as the
// end-of-candidates marker (peerconnection.go:2099 → AddRemoteCandidate(nil)). A MISSING
// candidate key is rejected, which is what keeps the two distinguishable; without the
// pointer, `{}` and a genuine end-of-candidates would both arrive as "".
//
// sdpMid and sdpMLineIndex are accepted and forwarded for shape compatibility only: pion
// v4.2.15's AddICECandidate ignores both, deriving them from the candidate line
// (newICECandidateFromICE(cand, "", 0)).
func (session *Session) AddRemoteICE(candidateJSON string) error {
	if err := session.refuseWhenClosing(); err != nil {
		return err
	}
	var payload struct {
		Candidate     *string `json:"candidate"`
		SDPMid        *string `json:"sdpMid"`
		SDPMLineIndex *uint16 `json:"sdpMLineIndex"`
	}
	if err := json.Unmarshal([]byte(candidateJSON), &payload); err != nil {
		return fmt.Errorf("%w: parse remote ICE candidate: %v", errSession, err)
	}
	if payload.Candidate == nil {
		return fmt.Errorf("%w: remote ICE candidate has no candidate field", errSession)
	}
	if err := session.peer.AddICECandidate(webrtc.ICECandidateInit{
		Candidate:     *payload.Candidate,
		SDPMid:        payload.SDPMid,
		SDPMLineIndex: payload.SDPMLineIndex,
	}); err != nil {
		return fmt.Errorf("add remote ICE candidate: %w", err)
	}
	return nil
}

// refuseWhenClosing is the shared teardown check the three signalling entry points use. See
// CreateOffer's comment for why it exists in all three and why none of them tests it.
func (session *Session) refuseWhenClosing() error {
	session.mutex.Lock()
	closing := session.closing
	session.mutex.Unlock()
	if closing {
		return fmt.Errorf("%w: session is closing", errSession)
	}
	return nil
}

// emitLocalICECandidate publishes one gathered candidate through the session's callback gate,
// so a candidate arriving during teardown cannot outlive Close like any other callback.
//
// The nil candidate — pion's end-of-gathering sentinel — is DROPPED, matching rdev's own
// bridge (host/pion-bridge/peer.go, `if c == nil { return }`): rdev's client has no
// end-of-candidates handling, so publishing it would emit a message nothing consumes.
func (session *Session) emitLocalICECandidate(candidate *webrtc.ICECandidate) {
	if candidate == nil {
		return
	}
	if session.callbacks.OnLocalICECandidate == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	initializer := candidate.ToJSON()
	published := localICECandidate{Candidate: initializer.Candidate}
	if initializer.SDPMid != nil {
		published.SDPMid = *initializer.SDPMid
	}
	if initializer.SDPMLineIndex != nil {
		published.SDPMLineIndex = *initializer.SDPMLineIndex
	}
	encoded, err := json.Marshal(published)
	if err != nil {
		// Unreachable: every field is a string or a uint16. Reported rather than dropped,
		// because a silently dropped candidate presents as an ICE failure with no cause.
		session.fail(fmt.Errorf("%w: marshal local ICE candidate: %v", errSession, err))
		return
	}
	session.callbacks.OnLocalICECandidate(string(encoded))
}
