package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
)

var errSession = errors.New("Pion session failed")

const gracefulCloseTimeout = 5 * time.Second
const defaultRecoveryFrameLimit = 64

type SessionConfiguration struct {
	LocalIP                     net.IP
	RemoteIP                    net.IP
	ICEPolicy                   ICEPolicy
	ICEServersJSON              string
	SignalPort                  uint16
	ICEPort                     uint16
	Recovery                    RecoveryMode
	RTXMaxAge                   time.Duration
	RTXAgeMode                  RTXAgeMode
	RTXAgeMultiplierMilli       uint32
	RTXAgeCap                   time.Duration
	FlexFECPolicy               FlexFECPolicy
	ScalabilityMode             AV1ScalabilityMode
	TotalRTPBudgetBitsPerSecond uint32
	FramesPerSecond             uint32
	FlexFECControllerPolicyJSON []byte
	Impairment                  *RecoveryImpairmentConfiguration
	DiagnosticRecoveryTrace     bool
	// RdevSCTPChannels: the offer path creates rdev's three channels as SCTP (plus bulk) instead of the lane — the
	// baseline the lossy-link gate measures the lane against (RDEV_TEST_SCTP_CHANNELS, rdev_abi.go). TEST-ONLY.
	RdevSCTPChannels bool
}

type RecoveryMode uint8

const (
	RecoveryNACKRTX RecoveryMode = iota + 1
	RecoveryOff
	RecoveryNACKRTXFlexFEC
)

type FlexFECPolicy uint8

const (
	FlexFECPolicyAdaptive FlexFECPolicy = iota + 1
	FlexFECPolicyOff
	FlexFECPolicyLow
	FlexFECPolicyMedium
	FlexFECPolicyHigh
)

type FlexFECTier uint8

const (
	FlexFECTierOff FlexFECTier = iota
	FlexFECTierLow
	FlexFECTierMedium
	FlexFECTierHigh
)

type RecoveryPolicyUpdate struct {
	Sequence                  uint64
	Tier                      FlexFECTier
	MediaBitrateBitsPerSecond uint32
}

type SessionCallbacks struct {
	OnState func([]byte)
	// OnMessage publishes one inbound LLV1 frame from one of LLV's two DataChannels. It is the
	// ANSWERING path's, and only the answering path's: those channels are classified by label
	// and every payload is validated as an LLV1 frame before it gets here.
	OnMessage func(ChannelKind, []byte)
	// OnChannelMessage publishes one inbound payload from one of rdev's three DataChannels,
	// keyed by its LABEL, unexamined. It is used by — and REQUIRED by — the offer path only.
	//
	// UNEXAMINED IS DELIBERATE. rdev's channels carry JSON and raw PTY bytes, not LLV1 frames,
	// so there is nothing here for validateChannelMessage to check; it would reject every one of
	// them, and a JSON control message on the first byte it looks at. The label, not a
	// ChannelKind, is what crosses this callback because rdev's own protocol is keyed by label
	// the whole way out to the client.
	//
	// TEXT AND BINARY ARRIVE IDENTICALLY, as bytes, matching rdev's own bridge
	// (host/pion-bridge/peer.go passes m.Data regardless of m.IsString). rdev sends control and
	// input as JSON text and the terminal as binary, and the distinction is not carried because
	// nothing downstream of the ABI has ever had it.
	OnChannelMessage func(label string, data []byte)
	// OnChannelOpen reports that one of rdev's three DataChannels reached open, by LABEL. It is
	// used by — and REQUIRED by — the offer path only; the answering path's channel opens are
	// observable through readiness, which is all LLV's own callers ever asked for.
	//
	// IT IS NOT READINESS AND MUST NOT BE CONFUSED WITH IT. `terminal` deliberately gates nothing
	// (rdevReadinessTerm), yet its open is exactly what rdev's ChannelHub waits for before it
	// starts the first shell — so a notification that fired only for the two readiness channels
	// would leave the terminal permanently blank with every other signal healthy. Every created
	// channel reports here; which of them gate readiness is a separate question answered in one
	// place, in channels.go.
	OnChannelOpen      func(label string)
	OnError            func(error)
	OnRecoveryKeyframe func(uint64)
	OnRecoveryRequest  func(uint64, string, bool)
	OnImpairmentNACK   func()
	OnRecoveryPolicy   func(RecoveryPolicyUpdate) error
	// OnLocalICECandidate publishes one locally gathered ICE candidate, as the JSON object
	// rdev's signalling already carries: {"candidate","sdpMid","sdpMLineIndex"}. It is used
	// by — and REQUIRED by — the offer path only; the answering path signals over a socket
	// it owns and gathers to completion before it answers, so it never trickles. See
	// newOfferSession and emitLocalICECandidate in offer.go.
	OnLocalICECandidate func(candidateJSON string)
}

type SelectedCandidateStats struct {
	LocalAddress  string `json:"localAddress"`
	LocalPort     uint16 `json:"localPort"`
	LocalType     string `json:"localType"`
	RemoteAddress string `json:"remoteAddress"`
	RemotePort    uint16 `json:"remotePort"`
	RemoteType    string `json:"remoteType"`
	Protocol      string `json:"protocol"`
}

type SessionChannelStats struct {
	Label            string  `json:"label"`
	Ordered          bool    `json:"ordered"`
	MaxRetransmits   *uint16 `json:"maxRetransmits"`
	BufferedAmount   uint64  `json:"bufferedAmount"`
	MessagesSent     uint64  `json:"messagesSent"`
	MessagesReceived uint64  `json:"messagesReceived"`
	MessagesDropped  uint64  `json:"messagesDropped"`
}

type SessionRecoveryStats struct {
	Mode                               string `json:"mode"`
	NACKInspectionIntervalMilliseconds int    `json:"nackInspectionIntervalMilliseconds"`
	RTXMaxAgeMilliseconds              int    `json:"rtxMaxAgeMilliseconds"`
	// PrimaryPayloadType is the payload type of the codec this session actually negotiated — AV1's
	// 45, H.265's 108 or H.264's 102.
	//
	// THE WIRE TAG STAYS `av1PayloadType` AND THAT MISMATCH IS DELIBERATE. LLVCore.CaptureTransport
	// decodes this JSON, and Tests/LLVWebRTCTests/PionTypesTests.swift asserts the key by name
	// against a recorded fixture — a test in the G1-FROZEN tree, which cannot be edited. Renaming
	// the tag would break it; renaming only the Go field makes the name honest on the side that can
	// change. Rename the tag only in a change that can also update that frozen test.
	PrimaryPayloadType             uint8                 `json:"av1PayloadType"`
	RTXPayloadType                 *uint8                `json:"rtxPayloadType"`
	RTXSSRCNegotiated              bool                  `json:"rtxSSRCNegotiated"`
	MediaRoundTripTimeSeconds      *float64              `json:"mediaRoundTripTimeSeconds,omitempty"`
	MediaRoundTripTimeMeasurements uint64                `json:"mediaRoundTripTimeMeasurements"`
	RTXAgePolicy                   *RTXAgePolicySnapshot `json:"rtxAgePolicy,omitempty"`
	RecoverySnapshot
}

type SessionStats struct {
	Role                      string                            `json:"role"`
	Ready                     bool                              `json:"ready"`
	ReadyDurationMilliseconds float64                           `json:"readyDurationMilliseconds"`
	PionWebRTCVersion         string                            `json:"pionWebRTCVersion"`
	GoVersion                 string                            `json:"goVersion"`
	Codec                     string                            `json:"codec"`
	ClockRate                 uint32                            `json:"clockRate"`
	PayloadType               uint8                             `json:"payloadType"`
	HeaderExtensionURI        string                            `json:"headerExtensionURI"`
	HeaderExtensionURIs       []string                          `json:"headerExtensionURIs"`
	RTCPFeedback              []string                          `json:"rtcpFeedback"`
	SelectedCandidate         SelectedCandidateStats            `json:"selectedCandidate"`
	JitterBufferMilliseconds  int                               `json:"jitterBufferMilliseconds"`
	FrameAssemblyCapacity     int                               `json:"frameAssemblyCapacity"`
	NACK                      bool                              `json:"nack"`
	RTX                       bool                              `json:"rtx"`
	FEC                       bool                              `json:"fec"`
	InputChannel              SessionChannelStats               `json:"inputChannel"`
	ControlChannel            SessionChannelStats               `json:"controlChannel"`
	VideoFramesSent           uint64                            `json:"videoFramesSent"`
	VideoFramesReceived       uint64                            `json:"videoFramesReceived"`
	KeyframeRequests          uint64                            `json:"keyframeRequests"`
	Recovery                  SessionRecoveryStats              `json:"recovery"`
	FlexFEC                   *SessionFlexFECStats              `json:"flexfec,omitempty"`
	FrameClockBudget          *RecoveryFrameClockBudgetSnapshot `json:"frameClockBudget,omitempty"`
	TWCC                      *TWCCSnapshot                     `json:"twcc,omitempty"`
	ResponderCache            ResponderCacheSnapshot            `json:"responderCache"`
	Impairment                *RecoveryImpairmentSnapshot       `json:"impairment,omitempty"`
	RecoveryTrace             *recoveryTraceSnapshot            `json:"recoveryTrace,omitempty"`
	StateTransitions          []string                          `json:"stateTransitions"`
}

type Session struct {
	mutex           sync.Mutex
	config          SessionConfiguration
	callbacks       SessionCallbacks
	startedAt       time.Time
	readyAt         time.Time
	ready           bool
	closing         bool
	failure         error
	readyCh         chan struct{}
	failedCh        chan struct{}
	doneCh          chan struct{}
	failOnce        sync.Once
	closeOnce       sync.Once
	remoteCloseOnce sync.Once
	closeError      error

	apiResources *peerAPIResources
	peer         *webrtc.PeerConnection
	track        *FrameTrack
	// videoTracks are the SLOT-KEYED tracks AddVideoTrack creates, and they are ADDITIVE to
	// `track` above rather than a replacement for it. Empty on the answering path, which adds no
	// track after assembly. nextVideoSlot only ever counts up; a slot is never reused, so a stale
	// write from a caller that missed a removal is refused by slot rather than delivered to
	// whatever took the number over. Both guarded by `mutex`.
	videoTracks map[int]*videoTrackSlot
	// playoutDelayMinimumMilliseconds is the floor this session's client has asked for, remembered so
	// a track added by a later subscribe starts there instead of reverting to the default.
	// playoutDelayMaximumMilliseconds is the ceiling it asked for, or -1 for the configured one.
	playoutDelayMinimumMilliseconds int
	playoutDelayMaximumMilliseconds int
	nextVideoSlot                   int
	// audioTracks are the audio half of AddSourceTracks, in their OWN slot namespace. Separate from
	// nextVideoSlot deliberately: the keyframe callback's `slot` is video-only and -1 there means
	// "every source on this client", so a shared counter would let an audio slot silently address a
	// video track in that path. Both guarded by `mutex`.
	audioTracks   map[int]*audioTrackSlot
	nextAudioSlot int
	// inputChannel and controlChannel are LLV's, and stay nil on the offer path. SendInput and
	// SendControl therefore refuse on an offer session rather than mis-sending: both validate
	// their argument as an LLV1 frame, which no rdev payload is. Sending on rdev's channels is
	// Task 7's, with the C ABI it belongs to.
	inputChannel   *webrtc.DataChannel
	controlChannel *webrtc.DataChannel
	// rdevChannels are the offer path's, keyed by label, and stay nil on the answering path.
	rdevChannels map[string]*webrtc.DataChannel
	// lane carries terminal, input and control (rdev_lane.go); nil on the SCTP baseline and the answering path.
	lane *rdevLane
	// DataChannel video delivery (rdev_dc_channels.go). Nil until createRdevDataChannels runs.
	//
	// ATOMIC, NOT MUTEX-GUARDED. The reader is on the video write path, which must not take the
	// session mutex — a future caller that writes video while holding it would invert this file's
	// lock order. WriteVideo happens to release session.mutex first today, which makes a lock correct
	// BY ACCIDENT; an atomic makes it correct by construction.
	dcDelivery atomic.Pointer[dcDelivery]

	candidateObstacle error
	// The FlexFEC identity this session last OFFERED, carried to SetAnswer so the answer can be
	// required to match it. Per offer/answer round; rdev renegotiates on every track change.
	offeredFlexFEC flexFECNegotiation
	// offeredFlexFECSections are the indices of the video m-sections that identity covers — the
	// ones the offer SENDS on. The answer is checked at exactly those indices, which is the only
	// offer/answer correspondence that holds for all of rdev's offer shapes (see
	// validateFlexFECRemoteAnswer).
	offeredFlexFECSections []int
	offeredFlexFECValid    bool
	signalingComplete      bool
	mediaReady             bool
	// activeRecovery is the stack this connection actually runs, decided from the answer. Empty
	// until it resolves — absent means UNKNOWN, never "degraded", the same rule activeCodec follows.
	activeRecovery string
	// onCodecResolved reports a track's negotiated codec, set by SetOnCodecResolved and invoked
	// from the bind. Guarded by session.mutex like every other field here.
	onCodecResolved func(slot int, codec codecID)
	peerConnected   bool
	// inputOpen and controlOpen are maybeReady's two channel terms, and they are set from
	// WHICHEVER channel set the entry point installed — LLV's llv-input-v1/llv-control-v1 on the
	// answering path, rdev's input/control on the offer path. Both go through markChannelOpen, so
	// the names are the ROLE, not the label.
	inputOpen          bool
	controlOpen        bool
	remoteStopReceived bool
	localStopSent      bool
	remoteClosedCh     chan struct{}
	selectedCandidate  SelectedCandidateStats
	stateTransitions   []string
	inputSent          uint64
	inputReceived      uint64
	inputDropped       uint64
	controlSent        uint64
	controlReceived    uint64
	videoSent          uint64
	keyframeRequests   uint64

	callbackGate  *callbackGate
	recoveryTrace *recoveryTraceRecorder
}

func newHostSession(configuration SessionConfiguration, callbacks SessionCallbacks) (*Session, error) {
	if err := validateSessionConfiguration(configuration); err != nil {
		return nil, err
	}
	if err := validateSessionCallbacks(configuration, callbacks); err != nil {
		return nil, err
	}
	signalConnection, remoteIP, err := acceptSignalTCP(configuration.LocalIP, configuration.SignalPort)
	if err != nil {
		return nil, err
	}
	defer signalConnection.Close()
	configuration.RemoteIP = remoteIP
	session, err := assembleSession(configuration, callbacks)
	if err != nil {
		return nil, err
	}
	failed := true
	defer func() {
		if failed {
			_ = session.Close()
		}
	}()
	// The channel set is a property of the ENTRY POINT, not of the shared assembly: this path
	// RECEIVES LLV's two channels from the remote, and the offer path CREATES rdev's three
	// (createRdevDataChannels). Installing this in assembleSession would put LLV's classifier on
	// the offer path too, where a remote-created channel it does not recognise would fail the
	// whole session — and rdev's clients create none, so it would only ever fire wrongly.
	session.peer.OnDataChannel(func(channel *webrtc.DataChannel) {
		if err := session.attachDataChannel(channel); err != nil {
			session.fail(err)
		}
	})
	// THE EAGER `desktop` TRACK IS THE ANSWERING PATH'S, AND IT MOVED HERE FROM assembleSession
	// FOR THE SAME REASON THE DATA CHANNELS DID. Stock `llv capture-host` sends on exactly this
	// track and SendVideo is the only thing that writes to it, so it belongs to the entry point
	// that has a sender — not to the shared assembly. The offer path adds its tracks through
	// AddVideoTrack instead, and adding this one there shipped a video m-section carrying MSID
	// `desktop` that never carried a frame; see newOfferSession for the three separate ways that
	// was wrong. Byte-identical here: same wireVideoTrack call, same arguments, same keyframe
	// stream 0, and still before serveAnswer, which is what puts it in the answer.
	session.track = session.wireVideoTrack("video", "desktop", eagerVideoKeyframeStreamID)
	if _, err := session.peer.AddTrack(session.track); err != nil {
		return nil, fmt.Errorf("add AV1 track: %w", err)
	}
	if err := serveAnswer(signalConnection, func(offer webrtc.SessionDescription) (webrtc.SessionDescription, error) {
		var offeredFlexFEC flexFECNegotiation
		if configuration.Recovery == RecoveryNACKRTXFlexFEC {
			var validationErr error
			offeredFlexFEC, validationErr = validateFlexFECOffer(
				offer.SDP, configuration.negotiatedRTXTime(),
			)
			if validationErr != nil {
				return webrtc.SessionDescription{}, fmt.Errorf(
					"validate viewer FlexFEC offer: %w", validationErr,
				)
			}
		} else if err := validateLegacyRecoverySDP(
			offer.SDP, configuration.Recovery,
		); err != nil {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"validate legacy viewer offer: %w", err,
			)
		}
		engineOffer, err := preparePionRemoteDescription(
			offer,
			configuration.negotiatedRTXTime(),
			false,
		)
		if err != nil {
			return webrtc.SessionDescription{}, fmt.Errorf("validate viewer offer: %w", err)
		}
		if err := session.peer.SetRemoteDescription(engineOffer); err != nil {
			return webrtc.SessionDescription{}, fmt.Errorf("set viewer offer: %w", err)
		}
		answer, err := gatherPeerDescription(session.peer, false)
		if err != nil {
			return answer, err
		}
		if nackRTXEnabled(configuration.Recovery) {
			answer, err = advertiseRTXTime(answer, configuration.negotiatedRTXTime())
			if err != nil {
				return webrtc.SessionDescription{}, err
			}
		}
		answer, err = negotiateReceiverReferenceTime(answer, offer)
		if err != nil {
			return webrtc.SessionDescription{}, err
		}
		if configuration.Recovery == RecoveryNACKRTXFlexFEC {
			negotiated, err := validateFlexFECAnswer(
				answer.SDP, offeredFlexFEC, configuration.negotiatedRTXTime(),
			)
			if err != nil {
				return webrtc.SessionDescription{}, fmt.Errorf(
					"validate host FlexFEC answer: %w", err,
				)
			}
			session.apiResources.SetFlexFECNegotiation(negotiated)
		} else if err := validateLegacyRecoverySDP(
			answer.SDP, configuration.Recovery,
		); err != nil {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"validate legacy host answer: %w", err,
			)
		}
		return answer, nil
	}); err != nil {
		return nil, err
	}
	session.markSignalingComplete()
	failed = false
	return session, nil
}

// assembleSession builds everything a session needs EXCEPT its signalling, its DATA CHANNELS and
// its TRACKS: the peer and its apiResources. It is newHostSession's body between acceptSignalTCP
// and serveAnswer, minus the two things that belong to an entry point rather than to both.
//
// THE DATA CHANNELS AND THE EAGER TRACK ARE DELIBERATELY NOT HERE, and both used to be. The two
// paths do opposite things with each: the answering path RECEIVES LLV's two channels and SENDS on
// one eager `desktop` track, while the offer path CREATES rdev's three channels and adds a track
// per subscribed source through AddVideoTrack. A shared arrangement could only ever be one of them
// wearing the other's clothes. What must not drift is peer construction, apiResources and the
// wiring a track gets — the first two are here, and the third is wireVideoTrack, which BOTH paths
// call, so it is shared by construction rather than by copy.
//
// LOAD-BEARING that both entry points go through this one function rather than each keeping
// its own copy. newHostSession answers over a TCP socket it owns; newOfferSession (offer.go)
// offers through a channel its caller owns. Stock `llv capture-host` drives the ANSWERING
// path, and it is the comparison arm of the certification this integration exists to
// produce — so if the two paths drifted in peer construction, apiResources or track wiring,
// that certification would be comparing two engines that differ by more than rdev's wiring,
// and its central claim would quietly stop meaning anything.
//
// IT NO LONGER OWNS A FAILURE DEFER, because nothing in it can fail after createSession returns.
// Both callers register their own immediately, so a partially built session is still closed
// exactly once on every path; the one that used to be here covered the eager AddTrack, which now
// sits inside newHostSession's defer instead.
func assembleSession(
	configuration SessionConfiguration,
	callbacks SessionCallbacks,
) (*Session, error) {
	session, err := createSession(configuration, callbacks)
	if err != nil {
		return nil, err
	}
	return session, nil
}

// videoTrackSlot is one entry in the session's slot-keyed video track collection: a wired
// FrameTrack, the sender it was added on (needed to remove it), the source id it carries as its
// MSID, and its own frame counter.
//
// frameID IS PER TRACK, and the reason matters beyond bookkeeping. FrameTrack's onFrameStart —
// which is RecoveryFrameClockBudget.AdvanceStreamFrame when FlexFEC is on — requires frame ids to
// be STRICTLY CONSECUTIVE, and that budget lives on apiResources, i.e. ONE per SESSION.
//
// THE FIRST OF THE TWO NOTES BELOW WAS WRONG BY 2026-08-19, AND IT WAS WRONG BECAUSE ITS PREMISE
// EXPIRED RATHER THAN BECAUSE ITS REASONING WAS. It said recoveryEgressBudget is "only BUILT for
// RecoveryNACKRTXFlexFEC, which newOfferSession refuses outright" — true when written, and untrue
// from the moment FlexFEC became the default on 2026-08-18. The consequence was exactly what the
// paragraph above predicts: the first subscribed window streamed, and the next one — whether
// alongside it or replacing a closed one — started its own numbering at 1 and every write failed
// forever with `frame-start callback: invalid recovery frame-clock budget`. Reported from real use
// one day after the default flipped.
//
// It is fixed in the BUDGET, not here: the progression invariant is per STREAM, and it only ever
// read as session-wide because there was only ever one stream to read it on. Frame ids stay per
// track, which is what lets each source keep its own commit-on-success counter under its own
// writeMutex.
//
// TWO SESSION-SCOPED RESOURCES ARE SHARED BY EVERY TRACK. BOTH ARE HANDLED NOW; ONE KEEPS A
// RECORDED RESIDUE:
//
//   - recoveryEgressBudget (onFrameStart) is LIVE on this path. Its progression check is
//     per-stream; its CREDIT is still earned once per advance, so N concurrently sending sources
//     earn N x the intended rate and the egress bound is that much looser. Recorded on
//     AdvanceStreamFrame — a looser guard, on a bucket already sized to rdev's bitrate CAP rather
//     than to what a source actually sends. STILL OPEN, deliberately: tightening it needs a clock
//     that is not "a frame started", which changes what the certification harness reproduces.
//   - responderFactory (onKeyframeSent) is live on the NACK/RTX path this session runs, and its
//     keyframe gate was the standing trap this comment used to name. FIXED 2026-08-19: the gate
//     lives on ageAwareLocalStream beside keyframeStart, and requestKeyframe takes the media SSRC
//     — see age_aware_nack_responder.go. It was reachable with one extra AddVideoTrack, which is
//     one click in the client.
//
// THE FIX HAD TO BE BOTH HALVES, and that is the part worth carrying forward. Keying the gate
// alone would have let the responder ask once per damaged window while the REQUEST still named
// none of them, so rdev would answer each ask by re-keying every source — N times the IDRs, on a
// path where an IDR is a large fraction of a second's budget. A request that names no stream
// cannot be gated per stream OR answered per stream; naming it is what makes both possible.
// keyframeStreamIDForSSRC is that seam, and an SSRC it cannot resolve still fans out.
//
// writeMutex ORDERS THE WRITES TO THIS ONE SLOT, and it is what makes frameID's
// commit-on-success invariant hold rather than merely be intended. See WriteVideo.
// LOCK ORDER: writeMutex is taken AFTER session.mutex has been released, never while holding it.
// frameID is guarded by writeMutex alone (not by session.mutex), which is why frameIDForTest
// takes writeMutex too.
type videoTrackSlot struct {
	track    *FrameTrack
	sender   *webrtc.RTPSender
	sourceID string

	writeMutex sync.Mutex
	frameID    uint64
}

// eagerVideoKeyframeStreamID is the keyframe stream id assembleSession's eager track reports, and
// it is 0 because that is the ANSWERING path's contract: stock `llv capture-host` and its viewer
// both carry stream 0, and the task-4 drift test asserts 0 on both arms. videoKeyframeStreamID
// therefore starts dynamic tracks at 1, so a PLI on rdev's slot 0 is distinguishable from a PLI
// on the eager track.
const eagerVideoKeyframeStreamID = uint64(0)

// videoKeyframeStreamID maps a slot to the stream id its keyframe requests report, and it is the
// ONE place the mapping is defined so the emitter and Task 7's consumer cannot disagree.
//
// It is deliberately NOT the identity: 0 belongs to the eager track (above). The offset is +1 and
// nothing more, so `slot = streamID - 1` is the whole inverse — the same reasoning that kept the
// data channels free of a translation table (rdevChannelLabels' index IS the ABI slot), applied
// where an identity mapping was not available.
func videoKeyframeStreamID(slot int) uint64 { return uint64(slot) + 1 }

// keyframeStreamIDForSSRC resolves the RTP layer's identity for a stream back to the keyframe
// stream id the caller understands, and it is the other half of keying the responder's keyframe
// gate per stream. Without it the gate could ask once per damaged window while the REQUEST still
// named none of them, so every ask re-keyed every source -- turning a fix for a starved window
// into N times the IDRs, on a path where an IDR is a large fraction of a second's budget.
//
// AN UNRESOLVED SSRC FALLS BACK TO THE EAGER STREAM ID, which is what rdev reads as "all of this
// client's sources" -- exactly today's behaviour. That is the safe direction and it is deliberate:
// the answering path's eager track is not in videoTracks and must keep resolving to 0, and a track
// that has not finished binding must not be silently denied a keyframe. So this can only ever
// NARROW a fan-out to the correct track; it can never misroute one.
func (session *Session) keyframeStreamIDForSSRC(mediaSSRC uint32) uint64 {
	// Snapshot under session.mutex, then ask the tracks OUTSIDE it: CarriesSSRC takes the track's
	// own lock, and this session never holds two locks at once.
	session.mutex.Lock()
	slots := make([]int, 0, len(session.videoTracks))
	tracks := make([]*FrameTrack, 0, len(session.videoTracks))
	for slot, entry := range session.videoTracks {
		slots = append(slots, slot)
		tracks = append(tracks, entry.track)
	}
	session.mutex.Unlock()
	for index, track := range tracks {
		if track.CarriesSSRC(mediaSSRC) {
			return videoKeyframeStreamID(slots[index])
		}
	}
	return eagerVideoKeyframeStreamID
}

// wireVideoTrack builds ONE video track with every callback this session gives a track. It is the
// single definition of "a wired track", and that is the point: assembleSession's eager track and
// AddVideoTrack's slot-keyed tracks both come from here, so a wiring added for one is added for
// both by construction rather than by a reviewer noticing.
//
// WHY THAT MATTERS HERE SPECIFICALLY. The certification's comparison arm is stock `llv
// capture-host`, which is the ANSWERING path, and the claim it rests on is that the two entry
// points differ by rdev's wiring and nothing else. Before this function the five wirings existed
// once, inline; a second track would have needed them copied, and a copy that drifted is exactly
// the failure TestOfferSessionAssemblesTheSamePeerAndTrackAsTheAnsweringPath exists to catch —
// except that test compares the two paths' EAGER tracks, so it would never have looked at the
// copy. TestAddVideoTrackWiresEverythingTheEagerTrackHas is what covers that gap.
//
// EACH TRACK GETS ITS OWN CLOSURES, not a shared one. onKeyframeRequest closes over the stream id
// passed in, so a PLI on one track cannot be reported as another's — the per-track callback
// identity the drift test cannot see, since Go func values are not comparable and trackWiringOf
// can only report non-nil.
func (session *Session) wireVideoTrack(id, streamID string, keyframeStreamID uint64) *FrameTrack {
	track := NewFrameTrack(id, streamID, session.recoveryTrace)
	// A TRACK ADDED LATER INHERITS THE SESSION'S FLOOR. Without this, subscribing to a second window
	// mid-session would give it the default floor while the first kept the client's — one window
	// smooth and the next one not, from one setting.
	if session.playoutDelayMinimumMilliseconds > 0 || session.playoutDelayMaximumMilliseconds >= 0 {
		if err := track.SetPlayoutDelayBoundsMilliseconds(
			session.playoutDelayMinimumMilliseconds, session.playoutDelayMaximumMilliseconds); err != nil {
			fmt.Printf("[bridge] playout-delay bounds for a new track: %v\n", err)
		}
	}
	if session.apiResources.recoveryEgressBudget != nil {
		track.SetOnFrameStart(session.apiResources.recoveryEgressBudget.AdvanceStreamFrame)
	}
	// RECEIVER-DRIVEN KEYFRAMES ARE IGNORED WHEN RECOVERY IS OFF.
	//
	// NOT NEGOTIATING `nack pli` turned out to REDUCE rather than eliminate: with the feedback absent
	// from the SDP entirely, Safari still sent PLIs — measured 1-2 per five seconds against 8-9 with
	// it negotiated, and the host answered every one. So the SDP is a request, not an enforcement, and
	// a receiver that has been told nothing can still ask.
	//
	// In `off` mode nothing on the far side is entitled to an answer: there is no recovery stack for a
	// keyframe to repair, and on the carrier path the browser's decoder is deliberately starved and
	// its complaints are noise. Answering them cost 18-24% of the bitrate in IDRs, which made the rate
	// controller shed 6-10% of frames — the judder, arriving as a consequence of a decoder whose
	// picture nobody was ever going to look at.
	//
	// `readFrameTrackRTCP` already skips when this callback is nil, and it covers FIR as well as PLI —
	// FIR is honoured UNCONDITIONALLY there, so leaving the callback installed would keep the same
	// hole open under a different RTCP type.
	//
	// rdev's OWN keyframe requests are unaffected: those arrive as a `request-keyframe` control
	// message and reach the encoder through ChannelHub, never through this path. The WebCodecs decoder
	// asking for a keyframe after a gap still works, which is the one requester that matters here.
	if session.config.Recovery != RecoveryOff {
		track.SetOnKeyframeRequest(func() { session.emitRecoveryKeyframe(keyframeStreamID) })
	}
	if session.apiResources.responderFactory != nil {
		track.SetPLIHandledByInterceptor(true)
		track.SetFIRHandledByInterceptor(true)
		track.SetOnKeyframeSent(session.apiResources.responderFactory.MarkKeyframeSent)
	}
	// WHAT mediaReady MEANS, decided here: the FIRST track to bind satisfies it, and it never goes
	// back. It is a session-level gate answering "can this session carry media at all" — one bound
	// track proves the video m-section negotiated, that AV1/90000 was accepted, and that the
	// playout-delay and dependency-descriptor extensions were negotiated, which is the whole of
	// what readinessBlockersLocked is testing when it says "video track not bound".
	//
	// "ALL TRACKS BOUND" WOULD BE UNREACHABLE, not merely stricter. rdev adds tracks AFTER the
	// session is ready — subscribe follows connect — and there is no path in maybeReady that takes
	// readiness away, so a session that became ready and then added a track would either have to
	// go un-ready (which nothing implements) or hold readiness hostage to a track the caller has
	// not renegotiated yet. Both are worse than a monotonic gate.
	//
	// SO READINESS SAYS NOTHING ABOUT ANY rdev SOURCE, AND THAT IS THE PART TO CARRY FORWARD.
	// Because assembleSession's eager `desktop` track deliberately stays on the offer path, the
	// first track to bind is ALWAYS the eager one — which never carries an rdev frame. Measured,
	// not reasoned: an offer session that connects with ZERO AddVideoTrack calls reports
	// mediaReady == true with an empty videoTracks map, which is what
	// TestMediaReadyIsSatisfiedByTheEagerTrackAlone pins so this cannot quietly become untrue. An
	// earlier version of this comment claimed "at N=1 first is THE, so this is exact"; that was
	// false, and it was false in the same file that keeps the eager track on purpose.
	//
	// CONSEQUENCE FOR TASK 7: any readiness getter its C ABI exposes reports "this session can
	// carry media" while proving nothing about the subscribed window's track — so it must not be
	// used as "the source is streaming". This is now an argument FOR removing the eager track
	// rather than a free choice: removing it would make readiness mean what it appears to mean.
	// Increment 3's note either way: the question a client actually asks is per-SOURCE ("is this
	// window streaming"), which belongs in rdev's own view-set/source-status and not in the
	// engine's one session-wide readiness gate.
	track.SetOnBound(func() {
		session.mutex.Lock()
		session.mediaReady = true
		session.mutex.Unlock()
		session.maybeReady()
		// THE CODEC IS REPORTED HERE, WHICH IS THE FIRST MOMENT IT IS KNOWN. Bind runs inside
		// SetRemoteDescription, so this fires once the answer has settled the codec — not when the
		// track was added, which is when it used to be reported and was correct only while exactly
		// one codec was registered.
		//
		// rdev builds the source's ENCODER from this callback, so the ordering is load-bearing in
		// both directions: report too early and the encoder is built for a codec the remote may not
		// have accepted; never report and the track has no encoder and no sink and streams nothing.
		session.emitCodecResolved(keyframeStreamID, track)
	})
	return track
}

// ActiveRecovery reports the recovery stack this connection actually runs: "nack-rtx-flexfec",
// "nack-rtx", or "" before the answer settles it.
//
// IT IS NOT THE SAME AS THE CONFIGURED MODE. A session configured for FlexFEC whose receiver
// declined it runs NACK/RTX, and the difference is a real difference in resilience rather than a
// detail — which is why it reaches the client rather than only the log.
// FlexFECIsDegraded reports whether FEC disabled itself on this session.
//
// EXPOSED ON THE SESSION rather than reached through `apiResources` from the ABI, because the ABI has
// no business knowing that the peer API owns this state — and because the answer belongs to the
// session as a whole, not to the resources object that happens to record it.
func (session *Session) FlexFECIsDegraded() bool {
	if session == nil || session.apiResources == nil {
		return false
	}
	return session.apiResources.flexFECIsDegraded()
}

func (session *Session) ActiveRecovery() string {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	if session.activeRecovery != "" {
		return session.activeRecovery
	}
	// A session NOT configured for FlexFEC has nothing to resolve, so its stack is known from the
	// configuration alone. Only the FlexFEC case waits for an answer.
	if session.config.Recovery != RecoveryNACKRTXFlexFEC {
		if nackRTXEnabled(session.config.Recovery) {
			return "nack-rtx"
		}
		return "off"
	}
	return ""
}

func (session *Session) setActiveRecovery(value string) {
	session.mutex.Lock()
	session.activeRecovery = value
	session.mutex.Unlock()
}

// resolvedVideoProfile is the codec this session negotiated, or rdev's most-preferred one before
// any track has bound.
//
// THE FALLBACK IS THE PREFERENCE, NOT AV1-BY-NAME: before an answer there is nothing to report, and
// naming the codec rdev would rather send is the only honest guess available.
func (session *Session) resolvedVideoProfile() videoCodecProfile {
	session.mutex.Lock()
	tracks := make([]*FrameTrack, 0, len(session.videoTracks))
	for _, entry := range session.videoTracks {
		tracks = append(tracks, entry.track)
	}
	session.mutex.Unlock()
	for _, track := range tracks {
		if codec, ok := track.NegotiatedCodec(); ok {
			if profile, found := profileForCodecID(codec); found {
				return profile
			}
		}
	}
	return videoCodecProfiles()[0]
}

// SetOnCodecResolved registers the callback that reports which codec a track's bind selected. It
// is invoked once per track, from the bind, with the slot the caller was handed by AddVideoTrack.
func (session *Session) SetOnCodecResolved(callback func(slot int, codec codecID)) {
	session.mutex.Lock()
	session.onCodecResolved = callback
	session.mutex.Unlock()
}

// emitCodecResolved reports a bound track's codec, translating the keyframe stream id back to the
// caller's slot.
//
// THE EAGER TRACK IS DELIBERATELY SILENT. It carries eagerVideoKeyframeStreamID and belongs to the
// answering path's contract rather than to any rdev source, so reporting it would name a slot no
// caller owns — videoKeyframeStreamID is slot+1 precisely so 0 stays distinguishable.
func (session *Session) emitCodecResolved(keyframeStreamID uint64, track *FrameTrack) {
	if keyframeStreamID == eagerVideoKeyframeStreamID {
		return
	}
	codec, ok := track.NegotiatedCodec()
	if !ok {
		return
	}
	session.mutex.Lock()
	callback := session.onCodecResolved
	session.mutex.Unlock()
	if callback == nil {
		return
	}
	if !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	callback(int(keyframeStreamID)-1, codec)
}

// AddVideoTrack adds a sendonly AV1 track carrying sourceID as its MSID, and returns the slot it
// occupies. -1 with an error on failure.
//
// THE STREAM ID IS THE SOURCE ID AND NOTHING ELSE. rdev maps a track back to the source it
// captures through the SDP MSID: ChannelHub keys videoSlots[clientId][sourceID], the web client
// keys streamsBySource by stream.id, and RdevViewer routes by the msid its session reports. A
// decorated or prefixed stream id would deliver video attributed to the WRONG WINDOW, which
// presents as a client bug with nothing host-side looking broken. The TRACK id is
// unique per slot, so a reference binding after replacement cannot name the old receiver.
// The second argument remains the unchanged source identity.
//
// THE CALLER RENEGOTIATES. This does not offer, because on this path the session owns no
// signalling — CreateOffer/SetAnswer are the caller's to drive (rdev's own bridge calls
// scheduleOffer here, and re-pointing that at this session is Task 7's). Until an offer carrying
// the new m-section is answered, WriteVideo on this slot fails with "no negotiated bindings",
// which is deliberately a legible error and not a dropped frame.
//
// SLOT ALLOCATION IS ATOMIC AND SLOTS ARE NEVER REUSED. The number is taken under the mutex before
// the track is built, so two concurrent callers cannot collide; a failed AddTrack burns the slot
// rather than rolling back, which costs nothing and avoids a rollback racing a concurrent
// allocation. peer.AddTrack is called OUTSIDE the mutex, because Bind's onBound callback takes it
// and Go's sync.Mutex is not reentrant.
func (session *Session) AddVideoTrack(sourceID string) (int, error) {
	return session.AddVideoTrackWithPreference(sourceID, nil)
}

// AddVideoTrackWithPreference is AddVideoTrack with a per-track codec preference. A nil or empty
// preference means rdev's global order; AddVideoTrack is exactly that case, kept as its own name
// because every existing caller means it.
func (session *Session) AddVideoTrackWithPreference(
	sourceID string,
	preference []codecID,
) (int, error) {
	if sourceID == "" {
		// Refused rather than allowed through as an empty MSID: RdevViewer keys its decoders by
		// msid, and CLAUDE.md already records a real data-race residue for two streams that both
		// resolve to "". An unnamed source cannot be routed anywhere.
		return -1, fmt.Errorf("%w: a video track needs a source id to carry as its MSID", errSession)
	}
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return -1, fmt.Errorf("%w: session is closing", errSession)
	}
	// A DUPLICATE source id is refused for the SAME reason an empty one is, and it is the sharper
	// case of the two. Two tracks carrying one msid are not merely unroutable — the receiver keys by
	// msid, so the second one's frames are attributed to the FIRST one's window, which is the
	// wrong-window failure this whole MSID contract exists to prevent, and it presents as a client
	// bug with nothing host-side looking broken. Refused rather than deduplicated: a caller
	// subscribing the same source twice has a bug of its own, and silently handing back the existing
	// slot would let it believe it owns a track that another caller can remove underneath it.
	for existing, entry := range session.videoTracks {
		if entry.sourceID == sourceID {
			session.mutex.Unlock()
			return -1, fmt.Errorf(
				"%w: source %q already has a video track at slot %d", errSession, sourceID, existing,
			)
		}
	}
	slot := session.nextVideoSlot
	session.nextVideoSlot++
	session.mutex.Unlock()

	track := session.wireVideoTrack(fmt.Sprintf("video-%d-%s", slot, sourceID), sourceID, videoKeyframeStreamID(slot))
	track.SetCodecPreference(preference)
	sender, err := session.peer.AddTrack(track)
	if err != nil {
		return -1, fmt.Errorf("add video track for %q: %w", sourceID, err)
	}

	session.mutex.Lock()
	if session.videoTracks == nil {
		session.videoTracks = make(map[int]*videoTrackSlot, 1)
	}
	session.videoTracks[slot] = &videoTrackSlot{track: track, sender: sender, sourceID: sourceID}
	session.mutex.Unlock()
	return slot, nil
}

// SetRecoveryOverride forces the FEC overhead ratio for this session, or returns it to adaptive
// control. `bp` is basis points of media, 0..5000; -1 is Auto.
//
// IT NEEDS NO RENEGOTIATION at any value, including 0: FlexFEC stays negotiated, so the payload
// type, the SSRCs and the media stream are untouched and switching ratios costs no IDR. That is
// what makes it usable as a live A/B on one stream rather than a restart-and-compare — and it is
// why a forced 0% is a different thing from RDEV_LLV_RECOVERY=nack-rtx, which does not negotiate
// FlexFEC at all and needs a host restart.
func (session *Session) SetRecoveryOverride(bp int) error {
	if err := session.refuseWhenClosing(); err != nil {
		return err
	}
	if session.config.Recovery != RecoveryNACKRTXFlexFEC {
		return fmt.Errorf("%w: recovery override needs FlexFEC; this session runs %v",
			errSession, session.config.Recovery)
	}
	return session.apiResources.SetRecoveryOverride(bp, session.callbacks.OnRecoveryPolicy)
}

// SetPlayoutDelayMinimum sets the playout-delay FLOOR on every video track of this session, in
// milliseconds. Zero restores "play this out as soon as you can", which is the default.
//
// PER SESSION, NOT PER PROCESS. rdev runs many sessions in one host, and this answers a client
// control — one viewer must never be able to retune another's stream. The value lives on each
// FrameTrack rather than in a package global for exactly that reason.
//
// APPLIED SYNCHRONOUSLY, unlike SetRecoveryOverride. That one defers to a goroutine because applying
// it emits the ordered recovery-policy callback, and blocking on the dispatcher from the dispatcher
// self-deadlocks. This emits no callback, so there is nothing to wait on and the caller gets a real
// answer rather than "accepted".
//
// A LATER TRACK PICKS THIS UP TOO: the value is recorded on the session so a track added by a
// subsequent subscribe starts at the same floor, rather than silently reverting to the default and
// leaving one window smooth and the next one not.
func (session *Session) SetPlayoutDelayMinimum(milliseconds int) error {
	return session.SetPlayoutDelayBounds(milliseconds, -1)
}

// SetPlayoutDelayBounds sets the floor AND the ceiling on every video track of this session, in
// milliseconds; `maximumMilliseconds < 0` keeps the configured ceiling (raised to the floor). See
// FrameTrack.SetPlayoutDelayBoundsMilliseconds for why a client may own the ceiling at all.
func (session *Session) SetPlayoutDelayBounds(minimumMilliseconds, maximumMilliseconds int) error {
	if err := session.refuseWhenClosing(); err != nil {
		return err
	}
	session.mutex.Lock()
	tracks := make([]*FrameTrack, 0, len(session.videoTracks)+1)
	for _, entry := range session.videoTracks {
		if entry != nil && entry.track != nil {
			tracks = append(tracks, entry.track)
		}
	}
	if session.track != nil {
		tracks = append(tracks, session.track)
	}
	session.playoutDelayMinimumMilliseconds = minimumMilliseconds
	session.playoutDelayMaximumMilliseconds = maximumMilliseconds
	session.mutex.Unlock()

	// OUTSIDE session.mutex: each track takes its own, and WriteAccessUnit holds that one for its
	// whole body. Holding the session lock across it would put this call behind every in-flight
	// frame write on every track.
	for _, track := range tracks {
		if err := track.SetPlayoutDelayBoundsMilliseconds(minimumMilliseconds, maximumMilliseconds); err != nil {
			return err
		}
	}
	return nil
}

// PlayoutDelayBoundsUnits reports the floor/ceiling the FIRST video track now stamps on every packet,
// in the extension's 10ms units, and whether there was a track to ask at all.
//
// For a log line that states what the WIRE carries rather than what was requested. Those differ by
// design (a floor raises the ceiling to meet it), and without the resolved pair a report of "the
// picture is still late after returning to Auto" cannot be told apart from "that build predates the
// fix" — which cost a full round trip with a reporter.
func (session *Session) PlayoutDelayBoundsUnits() (minUnits uint16, maxUnits uint16, ok bool) {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	for _, entry := range session.videoTracks {
		if entry != nil && entry.track != nil {
			min, max := entry.track.PlayoutDelayBoundsUnits()
			return min, max, true
		}
	}
	if session.track != nil {
		min, max := session.track.PlayoutDelayBoundsUnits()
		return min, max, true
	}
	return 0, 0, false
}

// RemoveVideoTrack removes the track at slot. An unknown slot is an ERROR rather than a no-op —
// rdev's own removeVideoTrack returns silently, and a caller that removed the wrong slot would
// then be told nothing while the source it meant to stop kept streaming.
//
// The slot is dropped from the map BEFORE peer.RemoveTrack, so a concurrent WriteVideo is refused
// from the moment the removal starts rather than writing into a sender being torn down. As with
// AddVideoTrack, peer.RemoveTrack is called outside the mutex.
func (session *Session) RemoveVideoTrack(slot int) error {
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	if entry == nil {
		session.mutex.Unlock()
		return fmt.Errorf("%w: no video track at slot %d", errSession, slot)
	}
	delete(session.videoTracks, slot)
	session.mutex.Unlock()
	if err := session.peer.RemoveTrack(entry.sender); err != nil {
		// THE ERROR NAMES THE CONSEQUENCE, because the slot is already gone and retrying is
		// impossible: the map entry — and with it the only reference to this sender — was dropped
		// above, on purpose, so that a concurrent write is refused from the moment removal starts.
		// So the caller must not read this as "nothing happened and I can try again". What is
		// actually true is that writes to the slot are refused while the sender is STILL ATTACHED,
		// which means the next offer keeps carrying the m-section for a source nobody is sending.
		// Benign in practice (RemoveTrack fails essentially only on a closed peer, where the whole
		// session is going away), and stated rather than left for someone to infer from silence.
		return fmt.Errorf(
			"remove video track at slot %d (%q): %w — the slot is forgotten and its sender is "+
				"still attached to the peer, so this cannot be retried and the next offer will "+
				"still carry its m-section",
			slot, entry.sourceID, err,
		)
	}
	return nil
}

// WriteVideo writes one encoded AV1 temporal unit to the track at slot.
//
// ptsNanoseconds SETS THE RTP TIMESTAMP, which is what the receiver schedules playout from. It used
// to be accepted and discarded, with FrameTrack pacing every frame on a fixed step of 1500 ticks at
// 90 kHz — exactly 60 fps — and that was a real defect rather than a cosmetic gap.
//
// WHY IT MATTERED: a window source is CONTENT-DRIVEN. ScreenCaptureKit delivers on change, so the
// true cadence is irregular and averages below 60 (this repo's own `[encode]` line has recorded
// 58.2 fps). Stamping 60 anyway makes the media clock run fast against the wall clock, measured at
// 3.3%, and the error accumulates without bound. A receiver's jitter buffer is the only thing that
// absorbs it — and rdev caps that buffer at 10 ms deliberately, so it is exhausted in under a third
// of a second, after which every frame is permanently late and renders on arrival. The picture then
// moves at the raw capture cadence instead of a scheduled one, which is visible as judder.
//
// THE SYMPTOM WAS BACKWARDS, WHICH IS WHY IT SURVIVED SO LONG: a far-away host looked SMOOTHER than
// one on loopback. Real network jitter forces the receiver to hold a large buffer, and that buffer
// hid the lie. The faster the path, the less cover, so the defect was worst exactly where the
// project cares most.
//
// A ZERO IS ABSENT AND KEEPS THE FIXED STEP, which is what leaves SendVideo — the ANSWERING path,
// and the certification's comparison arm — byte-identical. Only rdev's own path has a real capture
// timestamp to give.
//
// IT DOES NOT FAIL THE SESSION, unlike SendVideo, which calls session.fail on a write error. The
// difference is that SendVideo's track is bound before the session is ever ready, so a write error
// there really is fatal; here "no negotiated bindings" is a NORMAL transient — the caller drives
// renegotiation asynchronously, so a write can legitimately land in the window between
// AddVideoTrack and the answer. Failing the session on that would tear down a healthy connection
// because one frame was early.
//
// IT DOES NOT REQUIRE session.ready EITHER, and that is deliberate rather than an omission.
// Readiness mixes in the two DataChannel terms, which have nothing to do with whether a video
// track can be written; the track's own binding check is the exact precondition, and it produces
// the more informative message of the two.
// presentationNanos converts the ABI's signed capture timestamp to FrameTrack's unsigned one,
// mapping anything non-positive to "absent".
func presentationNanos(ptsNanoseconds int64) uint64 {
	if ptsNanoseconds <= 0 {
		return 0
	}
	return uint64(ptsNanoseconds)
}

func (session *Session) WriteVideo(slot int, payload []byte, ptsNanoseconds int64, isKeyframe bool) error {
	return session.writeVideo(slot, payload, ptsNanoseconds, isKeyframe, nil, nil)
}
func (session *Session) WriteVideoReference(slot int, payload []byte, ptsNanoseconds int64, isKeyframe bool, metadata referenceFrameMetadata) (referenceSendResult, error) {
	var result referenceSendResult
	err := session.writeVideo(slot, payload, ptsNanoseconds, isKeyframe, &metadata, &result)
	return result, err
}
func (session *Session) writeVideo(
	slot int,
	payload []byte,
	ptsNanoseconds int64,
	isKeyframe bool,
	reference *referenceFrameMetadata, result *referenceSendResult,
) error {
	if len(payload) == 0 {
		// Caught at the SESSION boundary rather than in WriteAccessUnit, which would report
		// "invalid access-unit byte count 0" — the symptom, naming neither the slot nor the caller.
		// The error deliberately wraps errSession and never errFrameTrack, which is how a caller can
		// tell "I passed nothing" from "the track refused what I passed".
		return fmt.Errorf("%w: empty video payload for slot %d", errSession, slot)
	}
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return fmt.Errorf("%w: video session is not writable", errSession)
	}
	entry := session.videoTracks[slot]
	if entry == nil {
		session.mutex.Unlock()
		return fmt.Errorf("%w: no video track at slot %d", errSession, slot)
	}
	track := entry.track
	session.mutex.Unlock()

	// THE PER-SLOT WRITE LOCK IS WHAT MAKES THE FRAME-ID INVARIANT BELOW TRUE, rather than merely
	// intended. It spans read-compute-write-commit, because splitting those is precisely the bug:
	// two concurrent writers to one slot would both read frameID, both compute the same successor,
	// and both emit and commit it — two frames sharing an id, which is the same corruption
	// commit-on-success exists to prevent, reached from the other direction.
	//
	// IT COSTS NO CONTENTION THAT WAS NOT ALREADY THERE: WriteAccessUnit already takes the track's
	// own mutex for its whole body, so same-track writes were serialised anyway. This only extends
	// that critical section to cover the id bookkeeping around it. Two DIFFERENT slots are still
	// fully parallel, since the lock is per entry.
	//
	// It SERIALISES rather than refusing, so a caller that does write concurrently loses no frame.
	// The alternative considered was documenting a single-writer obligation; an invariant a comment
	// asks callers to preserve is one this project has repeatedly found broken, and enforcing it
	// here is three lines.
	entry.writeMutex.Lock()
	defer entry.writeMutex.Unlock()

	// A refused binding or dependency does not consume a frame-clock identity.
	// Once the frame clock accepts it, even a partial packet write consumes it.
	nextFrameID := entry.frameID + 1
	started := false
	frame := OutboundFrame{
		Started:   &started,
		Reference: reference, ReferenceResult: result,
		// A ZERO StreamID is rejected by WriteAccessUnit, so this cannot be the slot itself. It is
		// the same +1 mapping the keyframe path uses, deliberately: LLV's viewer echoes a frame's
		// stream id back in its keyframe requests, so the id a frame carries and the id a keyframe
		// request reports have to be the same number or the two halves name different streams.
		StreamID:   videoKeyframeStreamID(slot),
		FrameID:    nextFrameID,
		Keyframe:   isKeyframe,
		Dependency: l1t1Dependency(isKeyframe),
		Data:       payload,
		// NEGATIVE IS TREATED AS ABSENT rather than wrapped into a huge uint64. The encoder ships
		// pts 0 when its frame-id bookkeeping misses an entry (a picture with a wrong timestamp
		// beats no picture), and that already lands on the fixed step; a negative can only be a
		// caller bug and must degrade the same way instead of jumping the timeline.
		PresentationNanos: presentationNanos(ptsNanoseconds),
	}
	err := track.WriteAccessUnit(frame)
	// The FEC frame clock advances before packet writes. A partial send consumes
	// that identity too; repeating it would permanently wedge subsequent recovery.
	if started {
		entry.frameID = nextFrameID
	}
	if err != nil {
		return fmt.Errorf("write video to slot %d: %w", slot, err)
	}
	// A CONCURRENT RemoveVideoTrack IS NOT RE-CHECKED HERE, deliberately. An earlier version
	// re-resolved the slot and skipped the commit when the entry had been removed, to stop "a
	// re-added slot's counter starting from a stale value" — but nextVideoSlot only ever counts up,
	// so a removed slot is never handed out again and that condition could not fire. Committing onto
	// a removed entry writes to an object nothing can reach.
	session.mutex.Lock()
	session.videoSent++
	session.mutex.Unlock()
	return nil
}

// createRdevDataChannels creates the offer path's channels: `bulk` and the LANE that carries terminal, input and
// control (rdev_lane.go) — or, on the TEST-ONLY SCTP baseline (`sctpChannels`), the three as SCTP channels beside
// bulk and no lane. Called BEFORE the caller's first CreateOffer, because a data m-section only appears in an offer
// if a channel exists when it is built — and a channel created afterwards needs a renegotiation nobody would know to
// drive.
//
// Only OnOpen and OnMessage are wired, which is rdev's own bridge exactly (host/pion-bridge/
// peer.go startOffer). In particular there is NO OnClose that fails the session, unlike LLV's
// attachDataChannel: rdev's recovery model puts that detection in the CLIENT (web/src, the
// control-channel close handler), and a host that tore its session down on a channel close would
// pre-empt the reconnect the client is built to perform. The cost is recorded rather than
// hidden: a channel that dies while the peer stays up is invisible from the host side.
func (session *Session) createRdevDataChannels(sctpChannels bool) error {
	ordered := true
	labels := []string{rdevBulkChannelLabel}
	if sctpChannels {
		labels = rdevChannelLabels
	}
	created := make(map[string]*webrtc.DataChannel, len(labels))
	for _, label := range labels {
		channel, err := session.peer.CreateDataChannel(
			label, &webrtc.DataChannelInit{Ordered: &ordered},
		)
		if err != nil {
			for _, opened := range created {
				_ = opened.Close()
			}
			return fmt.Errorf("create %q DataChannel: %w", label, err)
		}
		created[label] = channel
		channel.OnOpen(func() { session.rdevChannelOpened(label) })
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			// Copied before it crosses the callback, as everywhere else here: pion reuses the
			// read buffer, and the consumer is rdev's ABI on another thread.
			session.emitChannelMessage(label, append([]byte(nil), message.Data...))
		})
	}
	// THE LANE: unordered and RELIABLE (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, "The carrier").
	// UNORDERED, so nothing waits behind a hole: a lost packet costs the lane's own repair (rdev_lane_engine.go), never a
	// retransmission timeout behind which every later message waits. RELIABLE, because a never-retransmitted carrier
	// (`maxRetransmits: 0`) failed the slow link: the browser's SCTP abandoned the lane chunks whose SACKs sat behind
	// this end's queue and stormed FORWARD-TSN with pion until that owned the link (term-slow-link-check's E 1.5–2.1 s
	// against its 1.5 s bound; reliable, 0.9–1.4 s). The lane's repair usually delivers first; SCTP's later copy then
	// brings a symbol the decoder already has, and no copy that late moves the engine's loss or round-trip estimates
	// (laneEngine.receive). The page creates nothing — it collects the lane by label, and DCEP carries this init to it.
	// Its three streams open together when it opens and are published under their channels' labels, so the ABI's
	// slots 0–2 are unchanged for Swift.
	var lane *rdevLane
	if !sctpChannels {
		unordered := false
		laneChannel, err := session.peer.CreateDataChannel(laneChannelLabel,
			&webrtc.DataChannelInit{Ordered: &unordered})
		if err != nil {
			for _, opened := range created {
				_ = opened.Close()
			}
			return fmt.Errorf("create %q DataChannel: %w", laneChannelLabel, err)
		}
		lane = newRdevLane(laneChannel, rand.Uint32(),
			func() bool { return session.peer.ConnectionState() == webrtc.PeerConnectionStateConnected },
			session.rdevChannelOpened, session.emitChannelMessage)
	}

	// DataChannel video delivery. Both channels are created UNCONDITIONALLY and cost nothing until a
	// source is routed to them: creating a channel after SCTP is up needs no renegotiation, so
	// creating them here rather than on demand keeps the first subscribe free of an offer/answer.
	//
	// UNORDERED + MaxRetransmits:0 on the video channel. Unordered is what makes multiplexing every
	// source onto one channel safe — there is no head-of-line blocking to isolate — and no
	// retransmission is what keeps a late symbol from arriving after its deadline and displacing a
	// live one. Recovery is the sliding-window code's job, not SCTP's.
	unordered, noRetransmits := false, uint16(0)
	videoChannel, err := session.peer.CreateDataChannel(dcVideoChannelLabel,
		&webrtc.DataChannelInit{Ordered: &unordered, MaxRetransmits: &noRetransmits})
	if err != nil {
		return fmt.Errorf("create %q DataChannel: %w", dcVideoChannelLabel, err)
	}
	// FEEDBACK IS UNORDERED TOO, AND NOT THE `control` CHANNEL. `control` is reliable-ordered, so a
	// deadline-bearing message queued behind a terminal burst arrives after its deadline — and the
	// deadline is the entire point. Increment 1 carries reports and keyframe requests here;
	// increment 3 adds NACK, which is then a message type rather than a new channel.
	feedbackChannel, err := session.peer.CreateDataChannel(dcFeedbackChannelLabel,
		&webrtc.DataChannelInit{Ordered: &unordered})
	if err != nil {
		return fmt.Errorf("create %q DataChannel: %w", dcFeedbackChannelLabel, err)
	}
	session.dcDelivery.Store(newDCDelivery(videoChannel, feedbackChannel))
	session.mutex.Lock()
	session.rdevChannels = created
	session.lane = lane
	session.mutex.Unlock()
	return nil
}

// rdevChannelOpened publishes one channel's open — a real channel's, or a lane stream's when the lane opens — and
// sets the readiness term input and control carry.
//
// PUBLISHED FIRST, AND FOR EVERY LABEL. The readiness term is about the ENGINE; the open is about the
// CHANNEL, and rdev needs the second for `terminal`, which deliberately has no readiness term at all.
func (session *Session) rdevChannelOpened(label string) {
	session.emitChannelOpen(label)
	if term, gates := rdevReadinessTerm(label); gates {
		session.markChannelOpen(term)
	}
}

func validateSessionConfiguration(configuration SessionConfiguration) error {
	if !validPeerIPv4(configuration.LocalIP) || configuration.SignalPort == 0 {
		return fmt.Errorf("%w: invalid local IP or signal port", errSession)
	}
	if (configuration.Recovery != RecoveryNACKRTX && configuration.Recovery != RecoveryOff &&
		configuration.Recovery != RecoveryNACKRTXFlexFEC) ||
		configuration.RTXMaxAge < time.Millisecond || configuration.RTXMaxAge > time.Second ||
		configuration.RTXMaxAge%time.Millisecond != 0 {
		return fmt.Errorf("%w: invalid recovery configuration", errSession)
	}
	if _, err := NewRTXAgePolicy(configuration.rtxAgePolicyConfig(), func() *mediaRTTEstimator {
		if configuration.normalizedRTXAgeMode() == RTXAgeRTT {
			return &mediaRTTEstimator{}
		}
		return nil
	}()); err != nil {
		return fmt.Errorf("%w: invalid RTX age policy", errSession)
	}
	if configuration.ICEPort == 0 || configuration.ICEPort == configuration.SignalPort {
		return fmt.Errorf("%w: invalid host ICE port", errSession)
	}
	if configuration.Recovery == RecoveryNACKRTXFlexFEC {
		if configuration.FlexFECPolicy < FlexFECPolicyAdaptive ||
			configuration.FlexFECPolicy > FlexFECPolicyHigh ||
			configuration.ScalabilityMode < AV1ScalabilityL1T1 ||
			configuration.ScalabilityMode > AV1ScalabilityL1T3 ||
			configuration.TotalRTPBudgetBitsPerSecond == 0 ||
			configuration.FramesPerSecond == 0 || configuration.FramesPerSecond > 1_000 ||
			(len(configuration.FlexFECControllerPolicyJSON) > 0 &&
				configuration.FlexFECPolicy != FlexFECPolicyAdaptive) {
			return fmt.Errorf("%w: invalid FlexFEC configuration", errSession)
		}
	} else if (configuration.FlexFECPolicy != 0 &&
		configuration.FlexFECPolicy != FlexFECPolicyOff) ||
		configuration.ScalabilityMode != 0 ||
		configuration.TotalRTPBudgetBitsPerSecond != 0 ||
		configuration.FramesPerSecond != 0 ||
		len(configuration.FlexFECControllerPolicyJSON) != 0 {
		return fmt.Errorf("%w: FlexFEC configuration requires FlexFEC recovery", errSession)
	}
	return nil
}

func validateSessionCallbacks(
	configuration SessionConfiguration,
	callbacks SessionCallbacks,
) error {
	if configuration.Recovery == RecoveryNACKRTXFlexFEC && callbacks.OnRecoveryPolicy == nil {
		return fmt.Errorf("%w: missing FlexFEC recovery policy callback", errSession)
	}
	return nil
}

func createSession(
	configuration SessionConfiguration,
	callbacks SessionCallbacks,
) (*Session, error) {
	if err := validateSessionCallbacks(configuration, callbacks); err != nil {
		return nil, err
	}
	var recoveryTrace *recoveryTraceRecorder
	if configuration.DiagnosticRecoveryTrace {
		recoveryTrace = newRecoveryTraceRecorder(true, 32_768, nil)
	}
	var impairment *RecoveryImpairmentController
	var controllerAssets *FlexFECControllerAssets
	var err error
	if configuration.Recovery == RecoveryNACKRTXFlexFEC &&
		configuration.FlexFECPolicy == FlexFECPolicyAdaptive {
		assets, loadErr := loadFlexFECControllerAssets(configuration.FlexFECControllerPolicyJSON)
		if loadErr != nil {
			return nil, loadErr
		}
		controllerAssets = &assets
	}
	if configuration.Impairment != nil {
		impairmentConfiguration := *configuration.Impairment
		impairmentConfiguration.Trace = recoveryTrace
		impairment, err = NewRecoveryImpairmentController(impairmentConfiguration)
		if err != nil {
			return nil, err
		}
	}
	api, resources, err := newPeerAPI(PeerConfig{
		LocalIP: configuration.LocalIP, RemoteIP: configuration.RemoteIP,
		// LOAD-BEARING: without these two the policy is silently dropped for every REAL session,
		// while every unit test that calls newPeerAPI directly keeps passing.
		ICEPolicy: configuration.ICEPolicy, ICEServersJSON: configuration.ICEServersJSON,
		ICEPort: configuration.ICEPort, SignalPort: configuration.SignalPort,
		Recovery: configuration.Recovery, RTXMaxAge: configuration.RTXMaxAge,
		RTXAgeMode:                  configuration.RTXAgeMode,
		RTXAgeMultiplierMilli:       configuration.RTXAgeMultiplierMilli,
		RTXAgeCap:                   configuration.RTXAgeCap,
		TotalRTPBudgetBitsPerSecond: configuration.TotalRTPBudgetBitsPerSecond,
		FramesPerSecond:             configuration.FramesPerSecond,
		Impairment:                  impairment, Trace: recoveryTrace,
		TWCCReorderingGrace: func() time.Duration {
			if controllerAssets == nil {
				return 0
			}
			return time.Duration(controllerAssets.Policy.ReorderingGraceMilliseconds) * time.Millisecond
		}(),
	})
	if err != nil {
		if impairment != nil {
			_ = impairment.Close()
		}
		return nil, err
	}
	// The servers newPeerAPI parsed and audited. Empty under strict, which registers none.
	peer, err := api.NewPeerConnection(webrtc.Configuration{ICEServers: resources.iceServers})
	if err != nil {
		_ = resources.Close()
		return nil, fmt.Errorf("create PeerConnection: %w", err)
	}
	session := &Session{
		config: configuration, callbacks: callbacks,
		startedAt: time.Now(), readyCh: make(chan struct{}),
		failedCh: make(chan struct{}), doneCh: make(chan struct{}),
		remoteClosedCh: make(chan struct{}),
		apiResources:   resources, peer: peer, callbackGate: newCallbackGate(),
		recoveryTrace: recoveryTrace,
		// -1 is "the configured ceiling"; 0 would be the gaming MODE, and a zero value must never
		// mean that by accident.
		playoutDelayMaximumMilliseconds: -1,
	}
	resources.SetReferenceRecoveryCallback(func(ssrc uint32, reason string, independent bool) {
		session.emitRecoveryRequest(session.keyframeStreamIDForSSRC(ssrc), reason, independent)
	})
	resources.SetRecoveryCallbacks(
		func(mediaSSRC uint32) {
			session.emitRecoveryKeyframe(session.keyframeStreamIDForSSRC(mediaSSRC))
		},
		session.fail,
		session.emitImpairmentNACK,
	)
	if configuration.Recovery == RecoveryNACKRTXFlexFEC {
		if controllerAssets != nil {
			if err := resources.ActivateAdaptiveFlexFEC(
				*controllerAssets, configuration.ScalabilityMode,
				configuration.TotalRTPBudgetBitsPerSecond, callbacks.OnRecoveryPolicy,
			); err != nil {
				_ = peer.Close()
				_ = resources.Close()
				return nil, err
			}
		} else {
			_ = resources.ActivateFlexFECPolicy(
				configuration.FlexFECPolicy,
				configuration.ScalabilityMode,
				configuration.TotalRTPBudgetBitsPerSecond,
				callbacks.OnRecoveryPolicy,
			)
		}
	}
	if impairment != nil {
		impairment.SetNACKAttemptCallback(func() {})
	}
	peer.OnConnectionStateChange(session.handlePeerState)
	return session, nil
}

func (configuration SessionConfiguration) normalizedRTXAgeMode() RTXAgeMode {
	if configuration.RTXAgeMode == 0 {
		return RTXAgeFixed
	}
	return configuration.RTXAgeMode
}

func (configuration SessionConfiguration) rtxAgePolicyConfig() RTXAgePolicyConfig {
	mode := configuration.normalizedRTXAgeMode()
	cap := configuration.RTXAgeCap
	multiplier := configuration.RTXAgeMultiplierMilli
	if mode == RTXAgeFixed {
		if cap == 0 {
			cap = configuration.RTXMaxAge
		}
		if multiplier == 0 {
			multiplier = 1_000
		}
	}
	return RTXAgePolicyConfig{
		Mode: mode, Floor: configuration.RTXMaxAge, Cap: cap,
		MultiplierMilli: multiplier,
	}
}

func (configuration SessionConfiguration) negotiatedRTXTime() time.Duration {
	return configuration.rtxAgePolicyConfig().Cap
}

func gatherPeerDescription(peer *webrtc.PeerConnection, offer bool) (webrtc.SessionDescription, error) {
	var description webrtc.SessionDescription
	var err error
	if offer {
		description, err = peer.CreateOffer(nil)
	} else {
		description, err = peer.CreateAnswer(nil)
	}
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	complete := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(description); err != nil {
		return webrtc.SessionDescription{}, err
	}
	select {
	case <-complete:
		return *peer.LocalDescription(), nil
	case <-time.After(signalIOTimeout):
		return webrtc.SessionDescription{}, fmt.Errorf("%w: ICE gathering timed out", errSession)
	}
}

// attachDataChannel adopts one channel the REMOTE created, classifying it by LLV's labels and
// validating every payload as an LLV1 frame. It belongs to the answering path — newHostSession
// installs it as the peer's OnDataChannel handler — and the offer path never reaches it: that
// path creates rdev's three channels itself (createRdevDataChannels) and installs no handler at
// all, so a channel a remote created there is simply not adopted.
func (session *Session) attachDataChannel(channel *webrtc.DataChannel) error {
	kind, err := classifyChannelLabel(channel.Label())
	if err != nil {
		_ = channel.Close()
		return err
	}
	if kind == ChannelInput {
		retransmits := channel.MaxRetransmits()
		if channel.Ordered() || retransmits == nil || *retransmits != 0 {
			_ = channel.Close()
			return fmt.Errorf("%w: invalid input reliability", errSession)
		}
		channel.SetBufferedAmountLowThreshold(inputBufferedAmountLowThreshold)
	} else if !channel.Ordered() || channel.MaxRetransmits() != nil {
		_ = channel.Close()
		return fmt.Errorf("%w: invalid control reliability", errSession)
	}

	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		_ = channel.Close()
		return fmt.Errorf("%w: session is closing", errSession)
	}
	if kind == ChannelInput {
		if session.inputChannel != nil {
			session.mutex.Unlock()
			_ = channel.Close()
			return fmt.Errorf("%w: duplicate input channel", errSession)
		}
		session.inputChannel = channel
	} else {
		if session.controlChannel != nil {
			session.mutex.Unlock()
			_ = channel.Close()
			return fmt.Errorf("%w: duplicate control channel", errSession)
		}
		session.controlChannel = channel
	}
	session.mutex.Unlock()

	channel.OnOpen(func() { session.markChannelOpen(kind) })
	channel.OnMessage(func(message webrtc.DataChannelMessage) {
		if err := validateChannelMessage(kind, message.IsString, message.Data); err != nil {
			session.fail(err)
			return
		}
		data := append([]byte(nil), message.Data...)
		session.mutex.Lock()
		if kind == ChannelInput {
			session.inputReceived++
		} else {
			session.controlReceived++
			if data[5] == wireKindKeyframe {
				session.keyframeRequests++
			} else if data[5] == wireKindStop {
				session.remoteStopReceived = true
			}
		}
		session.mutex.Unlock()
		session.emitMessage(kind, data)
	})
	channel.OnError(func(channelError error) {
		if session.remoteClosureExpected() {
			session.signalRemoteClosure()
			return
		}
		session.fail(channelError)
	})
	channel.OnClose(func() {
		if session.remoteClosureExpected() {
			session.signalRemoteClosure()
			return
		}
		session.fail(fmt.Errorf("%w: remote DataChannel closed", errSession))
	})
	if channel.ReadyState() == webrtc.DataChannelStateOpen {
		session.markChannelOpen(kind)
	}
	return nil
}

// markChannelOpen records that the channel carrying one of maybeReady's two channel terms is
// open, and re-evaluates readiness. BOTH paths funnel through here — the answering path from
// LLV's labels, the offer path from rdev's — so the readiness gate has one meaning and one
// place that sets it, whichever channel set is in play.
//
// AN UNRECOGNISED KIND FAILS THE SESSION rather than falling through to control. The two inline
// copies this replaced each used `if input {…} else {…}`, which was sound where it stood because
// each was reached through one gate that could only produce two values (classifyChannelLabel on
// one path, rdevReadinessTerm on the other). As one shared helper the blast radius is wider, and
// a third ChannelKind arriving here would silently set controlOpen — a readiness term satisfied
// by the wrong channel, which is this task's whole failure class rather than a typo.
//
// Loud, not silent, and not a panic: doing nothing would leave readiness un-gated by a channel
// that exists, and a panic crosses a C ABI into rdev's host process. fail() surfaces through
// WaitReady and OnError, where a caller can see it. Unreachable today, kept honest by a test.
func (session *Session) markChannelOpen(kind ChannelKind) {
	session.mutex.Lock()
	switch kind {
	case ChannelInput:
		session.inputOpen = true
	case ChannelControl:
		session.controlOpen = true
	default:
		session.mutex.Unlock()
		// Outside the lock: fail takes the same mutex, and NSLock's Go equivalent is no more
		// reentrant than NSLock.
		session.fail(fmt.Errorf(
			"%w: a DataChannel opened with unrecognised channel kind %d", errSession, kind,
		))
		return
	}
	session.mutex.Unlock()
	session.maybeReady()
}

func (session *Session) handlePeerState(state webrtc.PeerConnectionState) {
	session.mutex.Lock()
	session.stateTransitions = append(session.stateTransitions, state.String())
	if state == webrtc.PeerConnectionStateConnected {
		session.peerConnected = true
	}
	closureExpected := session.closing || session.remoteStopReceived || session.localStopSent
	lane := session.lane
	session.mutex.Unlock()
	session.emitState(state.String())
	if lane != nil && state == webrtc.PeerConnectionStateConnected {
		lane.connectedAgain()
	} else if lane != nil && (state == webrtc.PeerConnectionStateDisconnected || state == webrtc.PeerConnectionStateFailed) {
		lane.linkLost()
	}
	if state == webrtc.PeerConnectionStateConnected {
		session.maybeReady()
	} else if state == webrtc.PeerConnectionStateFailed ||
		state == webrtc.PeerConnectionStateDisconnected ||
		state == webrtc.PeerConnectionStateClosed {
		if closureExpected {
			session.signalRemoteClosure()
		} else {
			session.fail(fmt.Errorf("%w: PeerConnection %s", errSession, state))
		}
	}
}

func (session *Session) markRemoteStopReceived() {
	session.mutex.Lock()
	session.remoteStopReceived = true
	session.mutex.Unlock()
}

func (session *Session) remoteClosureExpected() bool {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	return session.closing || session.remoteStopReceived || session.localStopSent
}

func (session *Session) signalRemoteClosure() {
	if session.remoteClosedCh == nil {
		return
	}
	session.remoteCloseOnce.Do(func() { close(session.remoteClosedCh) })
}

func (session *Session) markSignalingComplete() {
	session.mutex.Lock()
	session.signalingComplete = true
	session.mutex.Unlock()
	session.maybeReady()
}

// maybeReady promotes the session to ready once every precondition holds, and RETURNS SILENTLY
// when one does not. That silence is structural and cannot be removed: this is called on every
// state change, channel open and signalling step, so the overwhelmingly common case is "not yet".
//
// It is also the branch that hides a genuine failure. A session whose input or control channel
// never opens simply never becomes ready, readyCh never closes, and nothing anywhere says why —
// which is why readinessBlockersLocked exists and why WaitReady's timeout reports it. Whoever
// changes what readiness MEANS must change readinessBlockersLocked in the same edit, or the
// timeout will name a condition that is no longer the one being waited on.
func (session *Session) maybeReady() {
	session.mutex.Lock()
	if session.ready || len(session.readinessBlockersLocked()) != 0 {
		session.mutex.Unlock()
		return
	}
	selected, err := session.selectedCandidateLocked()
	if err != nil {
		// NOT session.fail. `fail` wraps its body in a sync.Once and OnError is the C ABI's only
		// error observable, so a precondition that fires on every same-machine session spends the one
		// shot before anything real can use it. And readiness can arrive LATER as candidate pairs
		// change, so treating an unmet precondition as terminal is wrong independently of the once.
		// Recorded so readinessBlockersLocked — and therefore WaitReady — can still name it.
		session.candidateObstacle = err
		session.mutex.Unlock()
		return
	}
	session.candidateObstacle = nil
	session.selectedCandidate = selected
	session.ready = true
	session.readyAt = time.Now()
	close(session.readyCh)
	session.mutex.Unlock()
	session.emitState("ready")
}

// readinessBlockersLocked names every precondition maybeReady is still waiting on. It is the
// single definition of what readiness means: maybeReady branches on it and WaitReady reports it,
// so the gate and the diagnostic cannot disagree.
//
// The two CHANNEL terms are set by markChannelOpen from whichever channel set the entry point
// installed — LLV's llv-input-v1/llv-control-v1 on the answering path, rdev's input/control on
// the offer path. rdev's `terminal` sets NEITHER and appears nowhere here; see rdevReadinessTerm
// in channels.go for why a PTY channel must not be able to hold the engine back.
//
// Not called on the hot path: maybeReady fires a handful of times per session (peer state,
// signalling, track bound, channel opens), so naming the conditions costs a slice nobody counts.
func (session *Session) readinessBlockersLocked() []string {
	var blockers []string
	if session.closing {
		blockers = append(blockers, "session is closing")
	}
	if session.failure != nil {
		blockers = append(blockers, "session already failed")
	}
	if !session.signalingComplete {
		blockers = append(blockers, "signalling incomplete")
	}
	if !session.mediaReady {
		blockers = append(blockers, "video track not bound")
	}
	if !session.peerConnected {
		blockers = append(blockers, "PeerConnection not connected")
	}
	if !session.inputOpen {
		blockers = append(blockers, "input DataChannel not open")
	}
	if !session.controlOpen {
		blockers = append(blockers, "control DataChannel not open")
	}
	if session.candidateObstacle != nil {
		blockers = append(blockers, "selected candidate pair not usable: "+session.candidateObstacle.Error())
	}
	return blockers
}

// selectedPairFacts is what a selected candidate pair looks like to the readiness rule. It exists so
// the rule is a PURE function: fabricating a real peer-reflexive pair needs a live connection, and
// the thing worth testing exhaustively is the rule, not pion's plumbing.
type selectedPairFacts struct {
	localProtocolUDP  bool
	remoteProtocolUDP bool
	localHost         bool
	remoteHost        bool
	localAddress      string
	remoteAddress     string
	wantLocalAddress  string
	wantRemoteAddress string
}

// selectedPairUsable reports why a pair cannot serve as evidence of readiness under the given
// policy, or nil.
//
// UNDER STRICT this is a real assertion: capture-host was configured for ONE direct path, so proving
// THAT pair formed says something. UNDER LAN the same check can never be met — rdev's peer is a
// browser whose address and candidate type are unknowable in advance — so lan asserts only that the
// pair is usable at all. A peer-reflexive pair is a legitimate outcome there, not a fault.
func selectedPairUsable(policy ICEPolicy, facts selectedPairFacts) error {
	if !facts.localProtocolUDP || !facts.remoteProtocolUDP {
		return fmt.Errorf("%w: selected candidate is not UDP", errSession)
	}
	if policy != ICEPolicyStrict {
		return nil
	}
	if !facts.localHost || !facts.remoteHost ||
		facts.localAddress != facts.wantLocalAddress ||
		facts.remoteAddress != facts.wantRemoteAddress {
		return fmt.Errorf("%w: selected candidate is not the direct configured UDP pair "+
			"(local %s/%v want %s, remote %s/%v want %s)", errSession,
			facts.localAddress, facts.localHost, facts.wantLocalAddress,
			facts.remoteAddress, facts.remoteHost, facts.wantRemoteAddress)
	}
	return nil
}

func (session *Session) selectedCandidateLocked() (SelectedCandidateStats, error) {
	if session.peer.SCTP() == nil || session.peer.SCTP().Transport() == nil ||
		session.peer.SCTP().Transport().ICETransport() == nil {
		return SelectedCandidateStats{}, fmt.Errorf("%w: missing ICE transport", errSession)
	}
	pair, err := session.peer.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return SelectedCandidateStats{}, fmt.Errorf("%w: selected candidate unavailable: %v", errSession, err)
	}
	// LocalIP/RemoteIP are only meaningful under strict — lan leaves RemoteIP nil, so this must not
	// dereference it. Guarded by the policy check inside selectedPairUsable.
	wantLocal, wantRemote := "", ""
	if session.config.ICEPolicy == ICEPolicyStrict {
		wantLocal = session.config.LocalIP.To4().String()
		wantRemote = session.config.RemoteIP.To4().String()
	}
	if err := selectedPairUsable(session.config.ICEPolicy, selectedPairFacts{
		localProtocolUDP:  pair.Local.Protocol == webrtc.ICEProtocolUDP,
		remoteProtocolUDP: pair.Remote.Protocol == webrtc.ICEProtocolUDP,
		localHost:         pair.Local.Typ == webrtc.ICECandidateTypeHost,
		remoteHost:        pair.Remote.Typ == webrtc.ICECandidateTypeHost,
		localAddress:      pair.Local.Address, remoteAddress: pair.Remote.Address,
		wantLocalAddress: wantLocal, wantRemoteAddress: wantRemote,
	}); err != nil {
		return SelectedCandidateStats{}, fmt.Errorf("%w: %s", err, pair)
	}
	return SelectedCandidateStats{
		LocalAddress: pair.Local.Address, LocalPort: pair.Local.Port,
		LocalType: pair.Local.Typ.String(), RemoteAddress: pair.Remote.Address,
		RemotePort: pair.Remote.Port, RemoteType: pair.Remote.Typ.String(),
		Protocol: pair.Local.Protocol.String(),
	}, nil
}

func (session *Session) WaitReady(timeout time.Duration) error {
	select {
	case <-session.readyCh:
		return nil
	case <-session.failedCh:
		session.mutex.Lock()
		defer session.mutex.Unlock()
		return session.failure
	case <-session.doneCh:
		return fmt.Errorf("%w: closed before ready", errSession)
	case <-time.After(timeout):
		// Names what it was still waiting on. Without this the one observable symptom of a
		// channel that never opened is "readiness timed out", which is indistinguishable from
		// an ICE failure, a track that never bound, or signalling that never finished — four
		// unrelated causes behind one sentence.
		session.mutex.Lock()
		blockers := session.readinessBlockersLocked()
		session.mutex.Unlock()
		if len(blockers) == 0 {
			// THE EMPTY LIST IS ITS OWN DIAGNOSIS, and it must say so. A message reading
			// "still waiting on:" with nothing after the colon names no cause at all, which is
			// the silent-return gate this whole mechanism exists to expose, wearing a different
			// hat. Two ways to get here, and the sentence has to serve both: the select
			// committed to this branch just as the last precondition landed (benign, retry), or
			// every precondition is met and NOTHING CALLED maybeReady afterwards — a real bug,
			// and one that is otherwise invisible because every individual condition reads fine.
			return fmt.Errorf(
				"%w: readiness timed out with no unmet precondition left — either readiness "+
					"raced the timeout, or nothing called maybeReady after the last one was "+
					"satisfied", errSession,
			)
		}
		return fmt.Errorf(
			"%w: readiness timed out, still waiting on: %s",
			errSession, strings.Join(blockers, ", "),
		)
	}
}

func (session *Session) SendVideo(frame OutboundFrame) error {
	session.mutex.Lock()
	if session.closing || !session.ready {
		session.mutex.Unlock()
		return fmt.Errorf("%w: video session is not writable", errSession)
	}
	track := session.track
	session.mutex.Unlock()
	// NIL ON THE OFFER PATH, WHICH HAS NO EAGER TRACK — and a nil *FrameTrack would panic inside
	// WriteAccessUnit on its own mutex, across the C ABI, taking rdev's host process down for what
	// is really a caller using the wrong API. Refused with a name instead: SendVideo is the
	// ANSWERING path's single-track write; the offer path writes per slot through WriteVideo.
	if track == nil {
		return fmt.Errorf(
			"%w: this session has no eager video track — SendVideo is the answering path's; "+
				"use WriteVideo(slot, …) with a slot from AddVideoTrack", errSession,
		)
	}
	if err := track.WriteAccessUnit(frame); err != nil {
		session.fail(err)
		return err
	}
	session.mutex.Lock()
	session.videoSent++
	session.mutex.Unlock()
	return nil
}

func (session *Session) SendInput(data []byte) (SendDisposition, error) {
	if err := validateChannelMessage(ChannelInput, false, data); err != nil {
		return SendDispositionDropped, err
	}
	session.mutex.Lock()
	if session.remoteStopReceived {
		session.inputDropped++
		session.mutex.Unlock()
		return SendDispositionDropped, nil
	}
	if session.closing || !session.ready || session.inputChannel == nil {
		session.mutex.Unlock()
		return SendDispositionDropped, fmt.Errorf("%w: input session is not writable", errSession)
	}
	channel := session.inputChannel
	session.mutex.Unlock()
	disposition := inputSendDisposition(channel.ReadyState(), channel.BufferedAmount())
	if disposition == SendDispositionDropped {
		session.mutex.Lock()
		session.inputDropped++
		session.mutex.Unlock()
		return disposition, nil
	}
	if err := channel.Send(append([]byte(nil), data...)); err != nil {
		if session.remoteClosureExpected() {
			session.mutex.Lock()
			session.inputDropped++
			session.mutex.Unlock()
			return SendDispositionDropped, nil
		}
		return SendDispositionDropped, err
	}
	session.mutex.Lock()
	session.inputSent++
	session.mutex.Unlock()
	return SendDispositionSent, nil
}

func (session *Session) SendControl(data []byte) error {
	if err := validateChannelMessage(ChannelControl, false, data); err != nil {
		return err
	}
	session.mutex.Lock()
	if session.closing || !session.ready || session.controlChannel == nil {
		session.mutex.Unlock()
		return fmt.Errorf("%w: control session is not writable", errSession)
	}
	channel := session.controlChannel
	session.mutex.Unlock()
	if channel.ReadyState() != webrtc.DataChannelStateOpen {
		return fmt.Errorf("%w: control DataChannel is not open", errSession)
	}
	if data[5] == wireKindStop {
		session.mutex.Lock()
		session.localStopSent = true
		session.mutex.Unlock()
	}
	if err := channel.Send(append([]byte(nil), data...)); err != nil {
		return err
	}
	session.mutex.Lock()
	session.controlSent++
	session.mutex.Unlock()
	return nil
}

// SendChannelData sends one payload on one of rdev's three DataChannels, by LABEL. It is the
// offer path's counterpart to SendInput/SendControl, and it deliberately shares nothing with them.
//
// NO validateChannelMessage, BY DESIGN. That validator reads every payload as an LLV1 binary
// frame; rdev's channels carry JSON on `control` and `input` and raw PTY bytes on `terminal`, so
// it would refuse all three — a control message dies at its first check, before the magic is even
// looked at. The payload is opaque here for exactly the reason it is opaque inbound.
//
// IT DOES NOT REQUIRE session.ready, AND THAT IS LOAD-BEARING RATHER THAN LAX. Readiness includes
// "a video track is bound", and on this path no track exists until a client subscribes to a
// source — so gating sends on readiness would make the terminal, the control channel and the whole
// subscribe/focus protocol unreachable until video was already running, which is a deadlock: the
// subscribe that would start the video arrives on `control`. The channel's own open state is the
// exact precondition, and it is what is checked.
//
// A CLOSED-OR-MISSING CHANNEL IS AN ERROR, not a silent drop. rdev's own bridge dropped here
// (`if dc := p.chans[ch]; dc != nil`), which is how a dead control channel presented as an app
// that simply stopped responding — the failure CLAUDE.md records as taking a live debugging
// session to find. The ABI above decides what to do with the error; it does not get to not know.
// ChannelBufferedAmount is how many bytes the offer path's channel `label` holds and the peer has not yet
// acknowledged — pion's BufferedAmount (bytes until SCTP acknowledges them), or for terminal, input and control on the
// lane that stream's UNACKNOWLEDGED payload bytes (laneEngine.buffered: pending, plus those in symbols the page's
// cumulative acknowledgement has not reached — the meaning TermPacer reads, handed − buffered never decreasing) — and
// false when there is no such channel or it is not open. The host paces on it: the terminal (TermPacer) and a large
// reply on `bulk` (an image, FileFetcher).
func (session *Session) ChannelBufferedAmount(label string) (uint64, bool) {
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return 0, false
	}
	lane := session.lane
	channel := session.rdevChannels[label]
	session.mutex.Unlock()
	if stream, ok := laneStreamIndex(label); ok && lane != nil {
		return lane.buffered(stream)
	}
	if channel == nil || channel.ReadyState() != webrtc.DataChannelStateOpen {
		return 0, false
	}
	return channel.BufferedAmount(), true
}

func (session *Session) SendChannelData(label string, data []byte) error {
	if len(data) == 0 {
		return fmt.Errorf("%w: empty payload for %q DataChannel", errSession, label)
	}
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return fmt.Errorf("%w: session is closing", errSession)
	}
	lane := session.lane
	channel := session.rdevChannels[label]
	session.mutex.Unlock()
	if stream, ok := laneStreamIndex(label); ok && lane != nil {
		return lane.send(stream, data)
	}
	if channel == nil {
		return fmt.Errorf("%w: no %q DataChannel on this session", errSession, label)
	}
	if state := channel.ReadyState(); state != webrtc.DataChannelStateOpen {
		return fmt.Errorf("%w: %q DataChannel is %s, not open", errSession, label, state)
	}
	if err := channel.Send(append([]byte(nil), data...)); err != nil {
		return fmt.Errorf("send on %q DataChannel: %w", label, err)
	}
	// NO COUNTER IS INCREMENTED, AND Stats() IS DELIBERATELY LEFT REPORTING NOTHING FOR THIS PATH.
	// Its InputChannel/ControlChannel blocks are built only when session.inputChannel /
	// controlChannel are non-nil, and those are LLV's two, which the offer path never has — so a
	// counter bumped here would be one no reader can reach. It is unreachable rather than merely
	// unread: rdev's C ABI has no stats call at all, and llv_pion_copy_stats resolves handles in
	// export.go's registry, which an rdev session is never in. Filling the blocks in from
	// rdevChannels would also put `"label":"input"` where LLV's Swift decoders — pinned against
	// frozen Tests/ fixtures — expect `"llv-input-v1"`. If rdev ever wants per-channel counters
	// they belong in a stats call of its own, with the labels rdev uses.
	return nil
}

// VideoPayloadType is the negotiated payload type for one video slot, or 0 when unknown.
func (session *Session) VideoPayloadType(slot int) uint8 {
	session.mutex.Lock()
	entry := session.videoTracks[slot]
	session.mutex.Unlock()
	if entry == nil || entry.track == nil {
		return 0
	}
	return entry.track.NegotiatedPayloadType()
}

func (session *Session) Stats() SessionStats {
	mediaRTT, mediaRTTObservations, hasMediaRTT := session.apiResources.MediaRTTSnapshot()
	recoverySnapshot := session.apiResources.counters.Snapshot()
	responderCache := session.apiResources.ResponderCacheSnapshot()
	impairment := session.apiResources.ImpairmentSnapshot()
	recoveryTrace := session.recoveryTrace.Snapshot("pion-host")
	flexFEC, twcc := session.apiResources.FlexFECSnapshot()
	var frameClockBudget *RecoveryFrameClockBudgetSnapshot
	if session.apiResources.recoveryEgressBudget != nil {
		snapshot := session.apiResources.recoveryEgressBudget.Snapshot()
		frameClockBudget = &snapshot
	}
	// READ BEFORE TAKING THE LOCK. Both of these take session.mutex themselves, and Go's mutex is
	// not reentrant — calling either below would self-deadlock, which is exactly what happened when
	// they were first written inline. Neither needs to be consistent with the rest of the snapshot
	// at a single instant: both settle once, at the answer, and never change again.
	resolvedProfile := session.resolvedVideoProfile()
	activeRecovery := session.ActiveRecovery()

	session.mutex.Lock()
	defer session.mutex.Unlock()
	readyDuration := 0.0
	if !session.readyAt.IsZero() {
		readyDuration = float64(session.readyAt.Sub(session.startedAt)) / float64(time.Millisecond)
	}
	// resolvedProfile is WHAT THIS SESSION ACTUALLY NEGOTIATED, not what it offered. A stats block
	// naming AV1 on an H.264 session is a confident wrong signal — the class of failure this
	// project has repeatedly been caught by, where every state reads healthy and names the wrong
	// thing. Read above, with activeRecovery, for the reentrancy reason given there.
	recoveryEnabled := nackRTXEnabled(session.config.Recovery)
	mode := "off"
	inspectionMilliseconds := 0
	frameAssemblyCapacity := 1
	var repairPayloadType *uint8
	var rtcpFeedback []string
	if recoveryEnabled {
		mode = "nack-rtx"
		inspectionMilliseconds = int(nackInspectionInterval / time.Millisecond)
		frameAssemblyCapacity = defaultRecoveryFrameLimit
		payloadType := uint8(rtxPayloadType)
		repairPayloadType = &payloadType
		rtcpFeedback = []string{"nack", "nack pli"}
	}
	if session.config.Recovery == RecoveryNACKRTXFlexFEC {
		mode = "nack-rtx-flexfec"
		if flexFEC != nil && flexFEC.Negotiated {
			rtcpFeedback = append(rtcpFeedback, "transport-cc")
		}
		// THE MODE REPORTS WHAT RUNS, NOT WHAT WAS CONFIGURED. A receiver that declined FlexFEC runs
		// NACK/RTX, and saying otherwise here would be the same wrong-but-confident signal one
		// field over. Empty means the answer has not settled it yet, so the configured mode stands.
		if activeRecovery != "" {
			mode = activeRecovery
		}
	}
	var mediaRoundTripTimeSeconds *float64
	var mediaRoundTripTimeMeasurements uint64
	if hasMediaRTT {
		seconds := float64(mediaRTT) / float64(time.Second)
		mediaRoundTripTimeSeconds = &seconds
		mediaRoundTripTimeMeasurements = mediaRTTObservations
	}
	headerExtensionURIs := []string{frameMetadataURI, playoutDelayURI, dependencyDescriptorURI}
	flexFECNegotiated := flexFEC != nil && flexFEC.Negotiated
	if flexFECNegotiated {
		headerExtensionURIs = append(headerExtensionURIs, twccURI)
	}
	stats := SessionStats{
		Role:  "host",
		Ready: session.ready, ReadyDurationMilliseconds: readyDuration,
		PionWebRTCVersion: pionWebRTCVersion, GoVersion: runtime.Version(),
		Codec: resolvedProfile.statsName(), ClockRate: 90_000,
		PayloadType:              resolvedProfile.payloadType,
		HeaderExtensionURI:       frameMetadataURI,
		HeaderExtensionURIs:      headerExtensionURIs,
		RTCPFeedback:             rtcpFeedback,
		SelectedCandidate:        session.selectedCandidate,
		JitterBufferMilliseconds: 0, FrameAssemblyCapacity: frameAssemblyCapacity,
		NACK: recoveryEnabled, RTX: recoveryEnabled, FEC: flexFECNegotiated,
		VideoFramesSent: session.videoSent, VideoFramesReceived: 0,
		KeyframeRequests: session.keyframeRequests,
		Recovery: SessionRecoveryStats{
			Mode:                               mode,
			NACKInspectionIntervalMilliseconds: inspectionMilliseconds,
			RTXMaxAgeMilliseconds:              int(session.config.RTXMaxAge / time.Millisecond),
			PrimaryPayloadType:                 resolvedProfile.payloadType,
			RTXPayloadType:                     repairPayloadType,
			RTXSSRCNegotiated:                  session.apiResources.rtxNegotiated.Load(),
			MediaRoundTripTimeSeconds:          mediaRoundTripTimeSeconds,
			MediaRoundTripTimeMeasurements:     mediaRoundTripTimeMeasurements,
			RTXAgePolicy:                       session.apiResources.RTXAgePolicySnapshot(),
			RecoverySnapshot:                   recoverySnapshot,
		},
		FlexFEC: flexFEC, FrameClockBudget: frameClockBudget, TWCC: twcc,
		ResponderCache:   responderCache,
		Impairment:       impairment,
		RecoveryTrace:    recoveryTrace,
		StateTransitions: append([]string(nil), session.stateTransitions...),
	}
	if session.inputChannel != nil {
		stats.InputChannel = SessionChannelStats{
			Label: session.inputChannel.Label(), Ordered: session.inputChannel.Ordered(),
			MaxRetransmits: copyUint16(session.inputChannel.MaxRetransmits()),
			BufferedAmount: session.inputChannel.BufferedAmount(),
			MessagesSent:   session.inputSent, MessagesReceived: session.inputReceived,
			MessagesDropped: session.inputDropped,
		}
	}
	if session.controlChannel != nil {
		stats.ControlChannel = SessionChannelStats{
			Label: session.controlChannel.Label(), Ordered: session.controlChannel.Ordered(),
			MaxRetransmits: copyUint16(session.controlChannel.MaxRetransmits()),
			BufferedAmount: session.controlChannel.BufferedAmount(),
			MessagesSent:   session.controlSent, MessagesReceived: session.controlReceived,
		}
	}
	return stats
}

func (session *Session) ActivateImpairment() error {
	session.mutex.Lock()
	if session.closing || !session.ready {
		session.mutex.Unlock()
		return fmt.Errorf("%w: impairment activation requires a ready host", errSession)
	}
	resources := session.apiResources
	session.mutex.Unlock()
	return resources.ActivateImpairment()
}

func (session *Session) ResetImpairmentMeasurement() error {
	session.mutex.Lock()
	if session.closing || !session.ready {
		session.mutex.Unlock()
		return fmt.Errorf("%w: impairment reset requires a ready host", errSession)
	}
	resources := session.apiResources
	session.mutex.Unlock()
	if err := resources.ResetImpairmentMeasurement(5 * time.Second); err != nil {
		session.fail(err)
		return err
	}
	return nil
}

func (session *Session) DrainImpairment() error {
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return fmt.Errorf("%w: impairment drain requires a host", errSession)
	}
	resources := session.apiResources
	session.mutex.Unlock()
	if err := resources.DrainImpairment(5 * time.Second); err != nil {
		session.fail(err)
		return err
	}
	return nil
}

func copyUint16(value *uint16) *uint16 {
	if value == nil {
		return nil
	}
	result := *value
	return &result
}

func (session *Session) Close() error {
	session.closeOnce.Do(func() {
		session.mutex.Lock()
		waitForRemote := session.localStopSent && session.remoteClosedCh != nil
		remoteClosedCh := session.remoteClosedCh
		session.mutex.Unlock()
		remoteClosed := false
		if waitForRemote {
			select {
			case <-remoteClosedCh:
				remoteClosed = true
			case <-time.After(gracefulCloseTimeout):
			}
		}
		session.mutex.Lock()
		session.closing = true
		input := session.inputChannel
		control := session.controlChannel
		rdevChannels := session.rdevChannels
		lane := session.lane
		peer := session.peer
		resources := session.apiResources
		session.mutex.Unlock()
		session.callbackGate.startClose()
		var closeErrors []error
		if resources != nil {
			closeErrors = appendCloseError(closeErrors, resources.CloseFlexFECController())
		}
		if !remoteClosed {
			if input != nil {
				closeErrors = appendCloseError(closeErrors, input.Close())
			}
			if control != nil {
				closeErrors = appendCloseError(closeErrors, control.Close())
			}
			// Closed in the same breath and under the same !remoteClosed condition: exactly one
			// of the two channel sets is ever populated, so this loop is empty on the answering
			// path and the two above are nil on the offer path.
			for _, label := range rdevChannelLabels {
				if channel := rdevChannels[label]; channel != nil {
					closeErrors = appendCloseError(closeErrors, channel.Close())
				}
			}
			if lane != nil {
				closeErrors = appendCloseError(closeErrors, lane.close())
			}
		} else if lane != nil {
			lane.stop() // its channel is the remote's to have closed, but its sender and timer are ours
		}
		if peer != nil {
			closeErrors = appendCloseError(closeErrors, peer.Close())
		}
		if resources != nil {
			closeErrors = appendCloseError(closeErrors, resources.Close())
		}
		session.callbackGate.wait()
		session.closeError = errors.Join(closeErrors...)
		close(session.doneCh)
	})
	return session.closeError
}

func appendCloseError(errors []error, err error) []error {
	if err != nil {
		return append(errors, err)
	}
	return errors
}

func (session *Session) fail(err error) {
	if err == nil {
		return
	}
	session.failOnce.Do(func() {
		session.mutex.Lock()
		session.failure = err
		session.mutex.Unlock()
		close(session.failedCh)
		session.emitError(err)
	})
}

func (session *Session) emitState(state string) {
	if session.callbacks.OnState == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	encoded, _ := json.Marshal(struct {
		State string `json:"state"`
	}{State: state})
	session.callbacks.OnState(encoded)
}

func (session *Session) emitMessage(kind ChannelKind, data []byte) {
	if session.callbacks.OnMessage == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.callbacks.OnMessage(kind, append([]byte(nil), data...))
}

// emitChannelMessage publishes one inbound rdev DataChannel payload through the callback gate,
// so a message in flight during teardown cannot outlive Close — the same discipline every other
// emit* here follows.
func (session *Session) emitChannelMessage(label string, data []byte) {
	if session.callbacks.OnChannelMessage == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.callbacks.OnChannelMessage(label, data)
}

// emitChannelOpen publishes one rdev DataChannel's open through the callback gate, so an open
// racing teardown cannot outlive Close — the same discipline every other emit* here follows.
func (session *Session) emitChannelOpen(label string) {
	if session.callbacks.OnChannelOpen == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.callbacks.OnChannelOpen(label)
}

func (session *Session) emitError(err error) {
	if session.callbacks.OnError == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.callbacks.OnError(err)
}

func (session *Session) emitRecoveryKeyframe(streamID uint64) {
	if session.callbacks.OnRecoveryKeyframe == nil || !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.apiResources.counters.addRecoveryKeyframeRequest()
	session.callbacks.OnRecoveryKeyframe(streamID)
}

func (session *Session) emitImpairmentNACK() {
	if !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	if callback := session.callbacks.OnImpairmentNACK; callback != nil {
		callback()
	}
}

type callbackGate struct {
	mutex   sync.Mutex
	cond    *sync.Cond
	closing bool
	active  int
}

func newCallbackGate() *callbackGate {
	gate := &callbackGate{}
	gate.cond = sync.NewCond(&gate.mutex)
	return gate
}

func (gate *callbackGate) begin() bool {
	gate.mutex.Lock()
	defer gate.mutex.Unlock()
	if gate.closing {
		return false
	}
	gate.active++
	return true
}

func (gate *callbackGate) end() {
	gate.mutex.Lock()
	gate.active--
	if gate.active == 0 {
		gate.cond.Broadcast()
	}
	gate.mutex.Unlock()
}

func (gate *callbackGate) startClose() {
	gate.mutex.Lock()
	gate.closing = true
	gate.mutex.Unlock()
}

func (gate *callbackGate) wait() {
	gate.mutex.Lock()
	for gate.active != 0 {
		gate.cond.Wait()
	}
	gate.mutex.Unlock()
}

func (gate *callbackGate) closeAndWait() {
	gate.startClose()
	gate.wait()
}

func (session *Session) emitRecoveryRequest(streamID uint64, reason string, independent bool) {
	if session.callbacks.OnRecoveryRequest == nil {
		session.emitRecoveryKeyframe(streamID)
		return
	}
	if !session.callbackGate.begin() {
		return
	}
	defer session.callbackGate.end()
	session.apiResources.counters.addRecoveryKeyframeRequest()
	session.callbacks.OnRecoveryRequest(streamID, reason, independent)
}
