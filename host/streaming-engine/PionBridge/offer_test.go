package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// LOAD-BEARING that this equals the RTXMaxAge startSessionPair configures its host with
// (session_test.go). PeerConstructionAudit.RTXMaxAgeMilliseconds is inside the DeepEqual in
// TestOfferSessionAssemblesTheSamePeerAndTrackAsTheAnsweringPath, so changing either value
// alone fails that test with "peer construction differs" — a message that would send the
// reader hunting for drift that is not there.
const testOfferRTXMaxAge = 30 * time.Millisecond

// A syntactically valid host candidate. Its ADDRESS does not matter: pion's AddICECandidate
// parses the candidate line and ignores sdpMid/sdpMLineIndex entirely
// (peerconnection.go:2128 calls newICECandidateFromICE(cand, "", 0)), so this exercises the
// parse-and-forward path without depending on anything the two ends actually gathered.
const testRemoteICECandidate = `{"candidate":"candidate:1 1 udp 2130706431 127.0.0.1 50000 typ host",` +
	`"sdpMid":"0","sdpMLineIndex":0,"usernameFragment":"abcd"}`

// rdev's FIRST offer carries DATA CHANNELS ONLY, and the RTX window is advertised on the
// renegotiation that brings the first video m-section. Both halves are asserted here, in one
// test, because the interesting property is the TRANSITION: an implementation that always
// advertised would fail the first half and one that never did would fail the second, and each
// alone reads as an ordinary missing feature rather than as the rule.
//
// Deliberately does NOT build an answerer: newTestOfferPair's answerer applies
// preparePionRemoteDescription, which would reject or accept the offer before a test body
// could look at the SDP — so these assertions would never be the thing that fires, and could
// rot into decoration.
func TestOfferSessionAdvertisesTheRTXWindowOnlyOnceItOffersVideo(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	first, err := session.CreateOffer()
	if err != nil {
		// This is the whole reason the video-section condition exists: advertiseRTXTime fails
		// with "missing local RTX fmtp" on a description that has no RTX fmtp to rewrite, and
		// rdev's first offer is exactly that description.
		t.Fatalf("CreateOffer with no video track: %v", err)
	}
	if strings.Contains(first, "m=video") {
		t.Fatalf("the first offer carries a video m-section with nothing subscribed:\n%s", first)
	}
	if strings.Contains(first, "rtx-time") {
		t.Fatalf("the first offer advertises an RTX window with no video to retransmit:\n%s", first)
	}

	// A SECOND SESSION, not a second offer on the first one: pion refuses
	// SetLocalDescription(offer) while already in have-local-offer (`invalid proposed signaling
	// state transition: have-local-offer->SetLocal(offer)->have-local-offer`), so re-offering here
	// would fail for a reason that has nothing to do with RTX. Going through a real answer instead
	// would put the answerer's own preparePionRemoteDescription between this test and the SDP,
	// which is what the note above says to avoid.
	withVideo := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	if _, err := withVideo.AddVideoTrack("win:rtx"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	// The answering path advertises the negotiated RTX time on every local description it
	// puts on the wire (newHostSession's advertiseRTXTime call). The offer path has to as
	// well, or the remote never learns the retransmission window this session's responder
	// enforces and the two arms negotiate different recovery.
	second, err := withVideo.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer after AddVideoTrack: %v", err)
	}
	if !strings.Contains(second, "m=video") {
		t.Fatalf("offer has no video m-section after AddVideoTrack:\n%s", second)
	}
	if !strings.Contains(second, "rtx-time=30") {
		t.Fatalf("offer does not advertise the negotiated RTX time:\n%s", second)
	}
}

func TestOfferSessionProducesAnOfferAndAcceptsAnAnswer(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.waitConnected(t)
}

// The offer path exists so rdev can trickle. Both directions are asserted DIRECTLY rather
// than through "the connection came up": either end can learn the other peer-reflexively
// from an inbound connectivity check, so ICE reaching connected proves neither that local
// candidates were published nor that remote ones were consumed.
func TestOfferSessionTricklesLocalCandidates(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}

	var payload struct {
		Candidate     string  `json:"candidate"`
		SDPMid        *string `json:"sdpMid"`
		SDPMLineIndex *uint16 `json:"sdpMLineIndex"`
	}
	select {
	case encoded := <-pair.localICE:
		if err := json.Unmarshal([]byte(encoded), &payload); err != nil {
			t.Fatalf("local candidate is not the JSON shape rdev's ABI carries: %v (%s)", err, encoded)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no local ICE candidate was published — check newOfferSession's OnICECandidate wiring")
	}
	// NIL IS NOT THE ONLY WAY THIS GOES WRONG, and a nil-check alone could not see the other one:
	// shipping `"sdpMid": ""` is well-formed JSON with a non-nil pointer, and rdev's client feeds
	// the mid straight into `RTCIceCandidate`, where an empty one addresses no m-section. The
	// VALUES are asserted, not merely their presence.
	if !strings.HasPrefix(payload.Candidate, "candidate:") {
		t.Fatalf("local candidate = %+v, want a candidate: line", payload)
	}
	if payload.SDPMid == nil || *payload.SDPMid == "" {
		t.Fatalf("local candidate has no usable sdpMid (%+v); an empty mid addresses no m-section",
			payload)
	}
	if payload.SDPMLineIndex == nil {
		t.Fatalf("local candidate has no sdpMLineIndex (%+v)", payload)
	}
	// The session's only m-sections at this point are the data channel and, later, video. Index 0
	// is what a candidate for the first one carries; anything else means the candidate is being
	// attributed to a section that does not exist yet.
	if *payload.SDPMLineIndex != 0 {
		t.Fatalf("local candidate sdpMLineIndex = %d, want 0", *payload.SDPMLineIndex)
	}
}

func TestOfferSessionAcceptsRemoteICEOnlyAfterTheAnswer(t *testing.T) {
	pair := newTestOfferPair(t)

	// This is what pins AddRemoteICE to pion rather than to a well-formed no-op: pion
	// refuses a candidate before the remote description exists (ErrNoRemoteDescription), so
	// an implementation that parsed the JSON and returned nil would pass "accepts a
	// candidate" and fail here.
	if err := pair.session.AddRemoteICE(testRemoteICECandidate); err == nil {
		t.Fatal("a remote candidate was accepted before the answer was set")
	}
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	if err := pair.session.AddRemoteICE(testRemoteICECandidate); err != nil {
		t.Fatalf("AddRemoteICE after the answer: %v", err)
	}
}

func TestOfferSessionRejectsMalformedRemoteICE(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	for name, candidateJSON := range map[string]string{
		"not JSON":         `candidate:1 1 udp 2130706431 127.0.0.1 50000 typ host`,
		"no candidate key": `{"sdpMid":"0","sdpMLineIndex":0}`,
		"wrong type":       `{"candidate":7}`,
		"unparseable line": `{"candidate":"totally not a candidate","sdpMid":"0","sdpMLineIndex":0}`,
	} {
		if err := pair.session.AddRemoteICE(candidateJSON); err == nil {
			t.Fatalf("%s: malformed remote candidate was accepted", name)
		}
	}
}

// An offer session with no way to publish its candidates cannot signal, and the failure
// presents as an ICE connection that mysteriously does not form — or worse, one that forms
// anyway by peer reflexion on a LAN and fails on a real network. Refused at construction.
func TestOfferSessionRequiresALocalCandidateCallback(t *testing.T) {
	_, err := newOfferSession(testOfferConfiguration(t), SessionCallbacks{})
	if err == nil {
		t.Fatal("an offer session without a local ICE candidate callback was accepted")
	}
	if !strings.Contains(err.Error(), "local ICE candidate") {
		t.Fatalf("error = %q, want it to name the missing callback", err)
	}
}

// FlexFEC identifies the SENDER by its FID/FEC-FR SSRC groups, and on the offer path the sender's
// description is the OFFER, not the ANSWER — the inverse of what validateFlexFECOffer and
// validateFlexFECAnswer encode. This used to be REFUSED outright; it is implemented now, by two
// wrappers with the boolean flipped, so the answering path's pair is untouched.
func TestOfferSessionAcceptsFlexFEC(t *testing.T) {
	configuration := testOfferConfiguration(t)
	configuration.Recovery = RecoveryNACKRTXFlexFEC
	configuration.FlexFECPolicy = FlexFECPolicyAdaptive
	configuration.ScalabilityMode = AV1ScalabilityL1T1
	configuration.TotalRTPBudgetBitsPerSecond = 8_000_000
	configuration.FramesPerSecond = 60
	if err := validateSessionConfiguration(configuration); err != nil {
		t.Fatalf("test FlexFEC configuration is invalid: %v", err)
	}
	session, err := newOfferSession(configuration, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnChannelMessage:    func(string, []byte) {},
		OnChannelOpen:       func(string) {},
		OnRecoveryPolicy:    func(RecoveryPolicyUpdate) error { return nil },
	})
	if err != nil {
		t.Fatalf("an offer session refused FlexFEC recovery: %v", err)
	}
	defer func() { _ = session.Close() }()

	// AND THE FIRST OFFER MUST STILL WORK. It is data-channels-only, so it carries no video and
	// therefore no AV1/RTX/flexfec-03 payloads to validate — the condition that makes every FlexFEC
	// check conditional on a video section. Without it, every rdev session would fail at its first
	// offer, which is a far worse failure than the refusal this replaced.
	offer, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("first (data-channels-only) offer failed under FlexFEC: %v", err)
	}
	if sdpHasVideoSection(offer) {
		t.Fatal("the first offer carried video; this test no longer covers the no-video case")
	}
}

// THE INVERSION ITSELF, asserted on one SDP so the two wrappers cannot quietly become the same
// function. The offer-path pair requires groups on OUR offer and not on the remote answer, which is
// exactly the opposite of the answering-path pair.
func TestFlexFECOfferPathWrappersInvertTheSSRCGroupRequirement(t *testing.T) {
	const age = 30 * time.Millisecond
	// flexFECAnswerSDP carries the SSRC groups (it is a sender's description in the answering
	// path's world); flexFECOfferSDP does not.
	sender := flexFECAnswerSDP()
	receiver := flexFECOfferSDP()

	// NEITHER FIXTURE CARRIES A DIRECTION ATTRIBUTE, so both default to sendrecv and both are
	// judged as sending sections. That is what keeps this test about the SSRC-group inversion
	// rather than about the direction rule videoSectionSends added — a recvonly fixture would be
	// skipped for having no sender, and the refusal below would pass for the wrong reason.
	offered, sections, err := validateFlexFECLocalOffer(sender, age)
	if err != nil {
		t.Fatalf("a local offer WITH groups must validate: %v", err)
	}
	if len(sections) != 1 {
		t.Fatalf("sending sections = %v, want exactly one", sections)
	}
	if _, _, err := validateFlexFECLocalOffer(receiver, age); err == nil {
		t.Fatal("a local offer with NO SSRC groups must be refused: we are the sender")
	}
	if _, err := validateFlexFECRemoteAnswer(receiver, offered, sections, age); err != nil {
		t.Fatalf("a remote answer WITHOUT groups must validate: the remote receives: %v", err)
	}
}

// The certification's comparison arm is stock `llv capture-host`, which is the ANSWERING
// path. If the two entry points drifted in peer construction or track wiring, that
// comparison would be between two engines differing by more than rdev's wiring — so this
// asserts the shared assembly is genuinely shared, and would fail if someone re-copied
// newHostSession's body into offer.go and edited one copy.
//
// IT IS EQUAL-BY-CONSTRUCTION FOR ANY EDIT INSIDE assembleSession, since both paths call it —
// removing a wiring there breaks both sides and this still passes. That does not make it
// vacuous: it is a tripwire for DRIFT, i.e. exactly the future refactor above. Falsify it by
// simulating drift in one half (mutate the session AFTER assembly), never by editing the
// shared function.
//
// WHAT IT IS BLIND TO, stated because a partial guard read as a total one is worse than none:
//
//   - SDP. It compares construction, not the descriptions the two paths produce — and there
//     is ALREADY one such asymmetry, negotiateReceiverReferenceTime, which is answerer-only
//     and dormant on both arms. See CreateOffer's comment in offer.go.
//   - The DATA CHANNELS, and that is now by design rather than by omission. They left
//     assembleSession when rdev's three arrived: the answering path installs peer.OnDataChannel
//     and receives LLV's two, the offer path creates rdev's three, and the whole point is that
//     they differ. What must stay shared is what this test compares — peer construction,
//     apiResources and track wiring. (peer.OnDataChannel was never reachable from here anyway:
//     the handler is unexported state on webrtc.PeerConnection, in another package.)
//   - The identity of onBound, onFrameStart and onKeyframeSent. Go func values are not
//     comparable, so trackWiringOf can only report non-nil, and a drifted copy wiring one of
//     them to a DIFFERENT session's closure would pass. onKeyframeRequest is checked below by
//     invoking it, because it is the one with an observable effect; the other three have no
//     equivalent hook.
//
// THE TRACKS COMPARED ARE NOW OF DIFFERENT KINDS, AND THAT IS THE COMPARISON WORTH MAKING. The
// answering path's is its eager `desktop` track; the offer path has none, so this adds one through
// AddVideoTrack — which is the track that actually carries rdev's video. Both come from
// wireVideoTrack, so this also subsumes what
// TestAddVideoTrackWiresEverythingTheEagerTrackHas used to check with the two kinds inside ONE
// session, which the eager track's removal made impossible to express there.
func TestOfferSessionAssemblesTheSamePeerAndTrackAsTheAnsweringPath(t *testing.T) {
	answeringKeyframes := make(chan uint64, 2)
	answering, viewer := startSessionPair(t, SessionCallbacks{
		OnRecoveryKeyframe: func(streamID uint64) { answeringKeyframes <- streamID },
	}, SessionCallbacks{})
	defer answering.Close()
	defer viewer.Close()
	if err := answering.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	offeringKeyframes := make(chan uint64, 2)
	offering := newTestOfferSession(t, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnRecoveryKeyframe:  func(streamID uint64) { offeringKeyframes <- streamID },
	})
	slot, err := offering.AddVideoTrack("win:drift")
	if err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	offeringTrack := offering.videoTrackForTest(slot)

	// Explicit, because trackWiringOf returns the ZERO value for a nil track — without this,
	// two sessions that both failed to build a track would compare equal and pass.
	if offeringTrack == nil || answering.track == nil {
		t.Fatalf("missing track: offering %p, answering %p", offeringTrack, answering.track)
	}
	// The offer path must NOT have built an eager track of its own — that is the decision this
	// increment made, and without checking it here the comparison below would silently be
	// eager-vs-eager again if someone reinstated it.
	if offering.track != nil {
		t.Fatalf("the offer path built an eager track (%p); it must add tracks per source", offering.track)
	}
	// DeepEqual rather than ==: PeerConstructionAudit carries InterceptorOrder, a slice, so
	// the struct is not comparable — and the interceptor chain is exactly the kind of thing
	// a drifted copy would get wrong.
	if got, want := offering.apiResources.Audit(), answering.apiResources.Audit(); !reflect.DeepEqual(got, want) {
		t.Fatalf("peer construction differs:\noffering  %+v\nanswering %+v", got, want)
	}
	// ABSOLUTE VALUES FIRST, BECAUSE EQUALITY ALONE IS BLIND TO A FLAG THAT IS FALSE ON BOTH SIDES.
	// `SetPLIHandledByInterceptor(true)` is called from one place (session.go, when a responder
	// factory exists), so if it stopped being called BOTH tracks would report false and the
	// comparison below would still pass — leaving the call with no coverage at all. The NACK/RTX
	// path this test builds always has a responder factory, so `true` is the only correct reading.
	for label, wiring := range map[string]testTrackWiring{
		"offering": trackWiringOf(offeringTrack), "answering": trackWiringOf(answering.track),
	} {
		if !wiring.pliHandledByInterceptor {
			t.Fatalf("%s track has pliHandledByInterceptor=false; the NACK/RTX path installs a "+
				"responder factory, so SetPLIHandledByInterceptor(true) must have run", label)
		}
		if !wiring.onKeyframeRequest || !wiring.onKeyframeSent || !wiring.onBound {
			t.Fatalf("%s track is missing a callback: %+v", label, wiring)
		}
	}
	got, want := trackWiringOf(offeringTrack), trackWiringOf(answering.track)
	// id and streamID are SUPPOSED to differ — a per-source track names its source and the eager
	// one names `desktop`. Blanked by name at the assertion rather than dropped from
	// trackWiringOf, so the exclusion is visible where it is claimed.
	got.id, want.id = "", ""
	got.streamID, want.streamID = "", ""
	if got != want {
		t.Fatalf("track wiring differs:\noffering  %+v\nanswering %+v", got, want)
	}

	// Non-nil is not enough for the one callback whose target is observable: fire each track's
	// keyframe request and require it to reach ITS OWN session. A copy that wired the offer
	// path's track to the answering session's emitter satisfies every check above.
	fireKeyframeRequest(t, offeringTrack)
	requireRecoveryStream(t, offeringKeyframes, videoKeyframeStreamID(slot))
	select {
	case streamID := <-answeringKeyframes:
		t.Fatalf("the offering track's keyframe request reached the ANSWERING session (%d)", streamID)
	default:
	}
	fireKeyframeRequest(t, answering.track)
	requireRecoveryStream(t, answeringKeyframes, eagerVideoKeyframeStreamID)
	select {
	case streamID := <-offeringKeyframes:
		t.Fatalf("the answering track's keyframe request reached the OFFERING session (%d)", streamID)
	default:
	}
}

// fireKeyframeRequest invokes the track's keyframe-request closure. The func value is read
// under the track's mutex and called OUTSIDE it — the closure reaches into the session, and
// holding a lock across a callback is how this file's neighbours deadlock.
func fireKeyframeRequest(t *testing.T, track *FrameTrack) {
	t.Helper()
	track.mutex.Lock()
	request := track.onKeyframeRequest
	track.mutex.Unlock()
	if request == nil {
		t.Fatal("track has no keyframe-request callback")
	}
	request()
}

type testTrackWiring struct {
	id                      string
	streamID                string
	onBound                 bool
	onFrameStart            bool
	onKeyframeRequest       bool
	onKeyframeSent          bool
	pliHandledByInterceptor bool
	trace                   bool
}

func trackWiringOf(track *FrameTrack) testTrackWiring {
	if track == nil {
		return testTrackWiring{}
	}
	track.mutex.Lock()
	defer track.mutex.Unlock()
	return testTrackWiring{
		id: track.id, streamID: track.streamID,
		onBound: track.onBound != nil, onFrameStart: track.onFrameStart != nil,
		onKeyframeRequest:       track.onKeyframeRequest != nil,
		onKeyframeSent:          track.onKeyframeSent != nil,
		pliHandledByInterceptor: track.pliHandledByInterceptor,
		trace:                   track.trace != nil,
	}
}

func testOfferConfiguration(t *testing.T) SessionConfiguration {
	t.Helper()
	icePort := reserveUDPPort(t)
	signalPort := reserveTCPPort(t)
	for signalPort == icePort {
		signalPort = reserveTCPPort(t)
	}
	return SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		// RemoteIP is required on this path and is NOT discovered for us: the answering path
		// learns it from the accepted TCP connection, and an offer session has no socket to
		// learn it from. SignalPort likewise stays a validated field with nothing listening
		// on it — see newOfferSession's doc comment.
		LocalIP: net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: signalPort, ICEPort: icePort,
		Recovery: RecoveryNACKRTX, RTXMaxAge: testOfferRTXMaxAge,
		// The SCTP baseline: these tests speak rdev's channels as SCTP to a plain pion answerer. The lane's
		// tests (rdev_lane_session_test.go) turn it off through newTestOfferPairConfigured.
		RdevSCTPChannels: true,
	}
}

// A caller that does not care about inbound channel payloads gets a no-op, so that the tests
// about SDP and ICE are not rewritten every time the offer path grows a required callback. The
// requirement itself is asserted on its own, by
// TestOfferSessionRequiresAChannelMessageCallback — never here, where a default would hide it.
func newTestOfferSession(t *testing.T, callbacks SessionCallbacks) *Session {
	t.Helper()
	if callbacks.OnChannelMessage == nil {
		callbacks.OnChannelMessage = func(string, []byte) {}
	}
	if callbacks.OnChannelOpen == nil {
		callbacks.OnChannelOpen = func(string) {}
	}
	session, err := newOfferSession(testOfferConfiguration(t), callbacks)
	if err != nil {
		t.Fatalf("newOfferSession: %v", err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session
}

// offerPair is an offer session plus a plain pion peer that answers it, built by the SAME
// newPeerAPI the session uses. There is no socket anywhere: the offer, the answer and the
// session's local candidates are handed across in process.
type offerPair struct {
	session  *Session
	offer    string
	answer   string
	localICE chan string
	states   chan string
	// inbound carries what the SESSION received on its own channels, keyed by label, so a test
	// can assert the per-label callback rather than infer it.
	inbound chan offerPairMessage
	// opens carries the labels the SESSION reported open, in the order it reported them.
	opens chan string

	mutex sync.Mutex
	// remoteChannels are the channels the ANSWERER saw arrive, i.e. what this session actually
	// put on the wire. Recorded by label; a channel is added the moment OnDataChannel fires and
	// the waiter below blocks until then, because a created channel does not reach the remote
	// until SCTP is up.
	remoteChannels map[string]*webrtc.DataChannel
	remoteChannel  chan string
	answerer       *webrtc.PeerConnection
	pending        []string
}

type offerPairMessage struct {
	label string
	data  []byte
}

func newTestOfferPair(t *testing.T) *offerPair { return newTestOfferPairConfigured(t, nil) }

// newTestOfferPairConfigured is newTestOfferPair with the session's configuration adjusted first — the lane tests
// turn RdevSCTPChannels off.
func newTestOfferPairConfigured(t *testing.T, configure func(*SessionConfiguration)) *offerPair {
	t.Helper()
	pair := &offerPair{
		localICE: make(chan string, 64), states: make(chan string, 64),
		inbound:        make(chan offerPairMessage, 64),
		opens:          make(chan string, 8),
		remoteChannels: map[string]*webrtc.DataChannel{},
		remoteChannel:  make(chan string, 8),
	}
	configuration := testOfferConfiguration(t)
	if configure != nil {
		configure(&configuration)
	}
	session, err := newOfferSession(configuration, SessionCallbacks{
		OnLocalICECandidate: func(candidateJSON string) {
			select {
			case pair.localICE <- candidateJSON:
			default:
			}
			pair.forwardLocalCandidate(candidateJSON)
		},
		OnChannelMessage: func(label string, data []byte) {
			select {
			case pair.inbound <- offerPairMessage{label: label, data: data}:
			default:
			}
		},
		OnChannelOpen: func(label string) {
			select {
			case pair.opens <- label:
			default:
			}
		},
		OnState: func(state []byte) {
			select {
			case pair.states <- string(state):
			default:
			}
		},
	})
	if err != nil {
		t.Fatalf("newOfferSession: %v", err)
	}
	pair.session = session

	answererICEPort := reserveUDPPort(t)
	for answererICEPort == configuration.ICEPort {
		answererICEPort = reserveUDPPort(t)
	}
	answererSignalPort := reserveTCPPort(t)
	for answererSignalPort == answererICEPort {
		answererSignalPort = reserveTCPPort(t)
	}
	api, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: answererICEPort, SignalPort: answererSignalPort,
		Recovery: configuration.Recovery, RTXMaxAge: configuration.RTXMaxAge,
	})
	if err != nil {
		_ = session.Close()
		t.Fatalf("build answerer API: %v", err)
	}
	answerer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		_ = session.Close()
		_ = resources.Close()
		t.Fatalf("build answerer peer: %v", err)
	}
	// Registered before SetRemoteDescription, which is when the answerer learns the offer's data
	// m-section: a handler installed afterwards can miss a channel that opens immediately.
	answerer.OnDataChannel(func(channel *webrtc.DataChannel) {
		pair.mutex.Lock()
		pair.remoteChannels[channel.Label()] = channel
		pair.mutex.Unlock()
		select {
		case pair.remoteChannel <- channel.Label():
		default:
		}
	})
	// LIFO: the session closes first, so the answerer going away is never mistaken for a
	// remote failure of a live session.
	t.Cleanup(func() {
		_ = answerer.Close()
		_ = resources.Close()
	})
	t.Cleanup(func() { _ = session.Close() })

	pair.offer, err = session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	// THE ANSWERER APPLIES THE SAME VIDEO-SECTION RULE THE SESSION DOES, because the pair's first
	// exchange is rdev's real first exchange: DATA CHANNELS ONLY, no video until something
	// subscribes. preparePionRemoteDescription requires a dependency-descriptor extmap and
	// advertiseRTXTime requires an RTX fmtp, and neither can exist without a video m-section — so
	// applying them unconditionally here would fail on a correct implementation, which is a harness
	// asserting its own stale assumption. Every test that adds a track goes through `renegotiate`,
	// which reaches both with the video section present.
	if err := answerer.SetRemoteDescription(
		prepareTestRemoteOffer(t, pair.offer, configuration.RTXMaxAge),
	); err != nil {
		t.Fatalf("answerer SetRemoteDescription: %v", err)
	}
	// The ANSWERER gathers fully, so its candidates ride in the answer and this helper only
	// has to carry the session's own candidates across. Trickle in the other direction is
	// asserted on its own, in TestOfferSessionAcceptsRemoteICEOnlyAfterTheAnswer.
	answer, err := gatherPeerDescription(answerer, false)
	if err != nil {
		t.Fatalf("answerer gather: %v", err)
	}
	pair.answer = advertiseTestAnswerRTXTime(t, answer, configuration.RTXMaxAge)
	pair.attachAnswerer(answerer)
	return pair
}

// prepareTestRemoteOffer is the answerer half of the video-section rule: it validates an offer the
// way the ANSWERING path validates a remote description, but only when there is a video m-section
// for those checks to be about. requireRTXTime is true, which is what makes a video-carrying offer
// that forgot to advertise its window fail here rather than quietly negotiate.
func prepareTestRemoteOffer(
	t *testing.T, offer string, maxAge time.Duration,
) webrtc.SessionDescription {
	t.Helper()
	description := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}
	if !sdpHasVideoSection(offer) {
		return description
	}
	prepared, err := preparePionRemoteDescription(description, maxAge, true)
	if err != nil {
		t.Fatalf("answerer could not accept the offer: %v", err)
	}
	return prepared
}

// advertiseTestAnswerRTXTime mirrors prepareTestRemoteOffer for the answer the harness sends back.
func advertiseTestAnswerRTXTime(
	t *testing.T, answer webrtc.SessionDescription, maxAge time.Duration,
) string {
	t.Helper()
	if !sdpHasVideoSection(answer.SDP) {
		return answer.SDP
	}
	advertised, err := advertiseRTXTime(answer, maxAge)
	if err != nil {
		t.Fatalf("answerer advertiseRTXTime: %v", err)
	}
	return advertised.SDP
}

func (pair *offerPair) attachAnswerer(answerer *webrtc.PeerConnection) {
	pair.mutex.Lock()
	pair.answerer = answerer
	pending := pair.pending
	pair.pending = nil
	pair.mutex.Unlock()
	for _, candidateJSON := range pending {
		pair.addToAnswerer(answerer, candidateJSON)
	}
}

func (pair *offerPair) forwardLocalCandidate(candidateJSON string) {
	pair.mutex.Lock()
	answerer := pair.answerer
	if answerer == nil {
		pair.pending = append(pair.pending, candidateJSON)
	}
	pair.mutex.Unlock()
	if answerer != nil {
		pair.addToAnswerer(answerer, candidateJSON)
	}
}

func (pair *offerPair) addToAnswerer(answerer *webrtc.PeerConnection, candidateJSON string) {
	var payload struct {
		Candidate     string  `json:"candidate"`
		SDPMid        *string `json:"sdpMid"`
		SDPMLineIndex *uint16 `json:"sdpMLineIndex"`
	}
	if json.Unmarshal([]byte(candidateJSON), &payload) != nil {
		return
	}
	_ = answerer.AddICECandidate(webrtc.ICECandidateInit{
		Candidate: payload.Candidate, SDPMid: payload.SDPMid,
		SDPMLineIndex: payload.SDPMLineIndex,
	})
}

// awaitRemoteChannel blocks until the ANSWERER has been handed a channel with this label, and
// returns it. It BLOCKS rather than sampling because a one-shot "did the answerer see it" check
// is a race dressed as an assertion: a channel created before the offer still does not reach the
// remote until SCTP is up, which is well after the answer is applied — so sampling would fail on
// a correct implementation, and worse, its inverse ("no other channel arrived") would PASS on a
// broken one. The map is re-read at the top of every iteration, so a wakeup for some other
// label's arrival costs nothing.
func (pair *offerPair) awaitRemoteChannel(t *testing.T, label string) *webrtc.DataChannel {
	t.Helper()
	deadline := time.After(15 * time.Second)
	for {
		pair.mutex.Lock()
		channel := pair.remoteChannels[label]
		seen := make([]string, 0, len(pair.remoteChannels))
		for existing := range pair.remoteChannels {
			seen = append(seen, existing)
		}
		pair.mutex.Unlock()
		if channel != nil {
			return channel
		}
		select {
		case <-pair.remoteChannel:
		case <-deadline:
			sort.Strings(seen)
			t.Fatalf("the answerer never received a %q DataChannel; it received %v", label, seen)
		}
	}
}

func (pair *offerPair) waitConnected(t *testing.T) {
	t.Helper()
	deadline := time.After(15 * time.Second)
	var seen []string
	for {
		select {
		case state := <-pair.states:
			seen = append(seen, state)
			if strings.Contains(state, `"connected"`) {
				return
			}
		case <-deadline:
			t.Fatalf("offer session never connected; states seen: %v", seen)
		}
	}
}

// A RECOVERY-STACK FATAL MUST REACH OnError EVEN AFTER THE SESSION HAS ALREADY FAILED, because
// `Session.fail` wraps emitError in a sync.Once, and OnError is the C ABI's only error observable,
// so a swallowed recovery fatal is invisible.
//
// UPDATED 2026-08-18: the one shot used to be ALWAYS already spent, because maybeReady failed the
// session over a peer-reflexive candidate pair on every same-machine session. That is fixed — an
// unmet readiness precondition is a blocker now — so this test spends the once SYNTHETICALLY below.
// It always did, which is why the fix does not change what it proves.
//
// THE ORDER OF THE TWO HALVES IS THE ASSERTION. Reporting a fatal on a fresh session proves nothing —
// `fail` would emit that one anyway. What discriminates is a fatal reported AFTER an unrelated
// failure has consumed the once, which is why the first error is forced first and asserted to have
// arrived before the second is reported.
func TestRecoveryFailuresReachOnErrorAfterTheSessionHasFailed(t *testing.T) {
	errors := make(chan error, 8)
	session := newTestOfferSession(t, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnError:             func(err error) { errors <- err },
	})

	// Spend the once on something else, the way maybeReady's candidate rejection does in production.
	first := fmt.Errorf("%w: synthetic first failure", errSession)
	session.fail(first)
	select {
	case got := <-errors:
		if got.Error() != first.Error() {
			t.Fatalf("first error = %q, want %q", got, first)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the session's first failure did not reach OnError at all")
	}
	// Guard, not decoration: if `fail` ever stops being once-only this test would pass for the wrong
	// reason, since the second error would arrive through `fail` rather than through the wrapper.
	session.fail(fmt.Errorf("%w: a second fail must be swallowed", errSession))
	select {
	case got := <-errors:
		t.Fatalf("a second session failure reached OnError (%v) — this test no longer discriminates", got)
	case <-time.After(200 * time.Millisecond):
	}

	// Now the recovery stack reports a fatal, which is what publishEveryRecoveryFailure covers.
	session.apiResources.callbackMutex.Lock()
	report := session.apiResources.reportError
	session.apiResources.callbackMutex.Unlock()
	if report == nil {
		t.Fatal("the recovery error reporter is not wired, so this test cannot mean anything")
	}
	fatal := fmt.Errorf("%w: synthetic recovery stack fatal", errSession)
	report(fatal)
	select {
	case got := <-errors:
		if got.Error() != fatal.Error() {
			t.Fatalf("recovery fatal reported as %q, want %q", got, fatal)
		}
	case <-time.After(2 * time.Second):
		t.Fatal(
			"a recovery-stack fatal did not reach OnError after the session had already failed — " +
				"it is the C ABI's only error observable",
		)
	}
}

// The wrapper must PRESERVE the other two recovery callbacks rather than reconstruct them: a copy of
// createSession's wiring is the drift this task is arranged to avoid, and the keyframe callback is the
// one with an observable effect, so it is the one asserted.
func TestPublishingRecoveryFailuresKeepsTheOtherRecoveryCallbacks(t *testing.T) {
	keyframes := make(chan uint64, 2)
	session := newTestOfferSession(t, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnRecoveryKeyframe:  func(streamID uint64) { keyframes <- streamID },
	})
	session.apiResources.callbackMutex.Lock()
	requestKeyframe := session.apiResources.requestKeyframe
	observeNACK := session.apiResources.observeNACK
	session.apiResources.callbackMutex.Unlock()
	if requestKeyframe == nil || observeNACK == nil {
		t.Fatalf(
			"the wrapper dropped a recovery callback: requestKeyframe %v, observeNACK %v",
			requestKeyframe != nil, observeNACK != nil,
		)
	}
	// Non-nil is not enough — it has to still reach THIS session's emitter. The argument is the
	// MEDIA SSRC the responder is asking on behalf of; this session has no video track carrying
	// it, so it resolves to the eager stream id, which rdev reads as "all of this client's
	// sources". That fallback is the behaviour every request had before the gate was keyed per
	// stream, so this assertion is unchanged in value as well as in text.
	requestKeyframe(12_345)
	requireRecoveryStream(t, keyframes, eagerVideoKeyframeStreamID)
}

// THE PEER-CONNECTION FAILURE TEXT MUST SURVIVE `fail`'s SPENT ONE-SHOT. handlePeerState reports
// disconnected/failed/closed through session.fail, whose sync.Once is already consumed on this path,
// so the text is swallowed and only the state NUMBER reaches rdev. The ABI logs it from that number
// instead — and this is what proves the log exists rather than being asserted in a comment.
//
// It lives in offer_test.go rather than a new rdev_abi_test.go deliberately: a new test FILE moves
// ROOT_COUNTS in scripts/llv_certification_scope.py and the generated certification-scope.md with it,
// which is the pin that left test-all.sh red for two tasks running. The subject belongs to the offer
// path either way — the ABI is its only consumer.
func TestABILogsPeerConnectionFailureStates(t *testing.T) {
	peer := &rdevPeer{events: make(chan func(), 8), done: make(chan struct{})}
	for _, testCase := range []struct {
		state  string
		logged bool
	}{
		{state: "failed", logged: true},
		{state: "disconnected", logged: true},
		{state: "closed", logged: true},
		// The control arm, and it is what makes the three above mean something: a handler that
		// logged every state would satisfy them all and say nothing.
		{state: "connected", logged: false},
	} {
		output := captureStdout(t, func() {
			peer.handleState([]byte(`{"state":"` + testCase.state + `"}`))
		})
		mentions := strings.Contains(output, "peer connection "+testCase.state)
		if mentions != testCase.logged {
			t.Fatalf(
				"state %q logged=%v, want %v (output %q)",
				testCase.state, mentions, testCase.logged, output,
			)
		}
	}
}

// captureStdout runs body with os.Stdout replaced by a pipe and returns what it wrote. The ABI logs
// with fmt.Printf, which resolves os.Stdout at call time, so this is enough — and it is the only way
// to assert a diagnostic whose whole purpose is to be printed.
func captureStdout(t *testing.T, body func()) string {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	saved := os.Stdout
	os.Stdout = writer
	done := make(chan string, 1)
	go func() {
		var builder strings.Builder
		_, _ = io.Copy(&builder, reader)
		done <- builder.String()
	}()
	body()
	os.Stdout = saved
	_ = writer.Close()
	captured := <-done
	_ = reader.Close()
	return captured
}
