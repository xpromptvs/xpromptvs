package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/nack"
	"github.com/pion/interceptor/pkg/report"
	"github.com/pion/transport/v4"
	"github.com/pion/webrtc/v4"
)

var errInvalidPeerConfig = errors.New("invalid peer configuration")

const (
	av1PayloadType = 45
	rtxPayloadType = 46
	// H.265 and H.264, at rdev's PRE-CUTOVER payload types, so anything remembering the old wire
	// still reads. Distinctness across all six is asserted by TestPayloadTypesAreDistinct.
	h265PayloadType         = 108
	h265RTXPayloadType      = 109
	h264PayloadType         = 102
	h264RTXPayloadType      = 103
	nackInspectionInterval  = 2 * time.Millisecond
	playoutDelayURI         = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
	dependencyDescriptorURI = "https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension"
	receiverRTTAttribute    = "a=rtcp-xr:rcvr-rtt=all"
)

// ICEPolicy selects how reachable a session is. It exists because the two callers are in different
// positions: `capture-host` learns its peer's address from the accepted TCP connection, so naming
// both addresses costs it nothing and asserts a real property; rdev cannot know where its browser is.
type ICEPolicy string

const (
	// ICEPolicyStrict gathers on LocalIP only, accepts remote candidates from RemoteIP only, and
	// disables mDNS. BYTE-IDENTICAL TO THE BEHAVIOUR BEFORE THIS FIELD EXISTED — it is the
	// certification's comparison arm, and a change here invalidates the result recorded on main.
	ICEPolicyStrict ICEPolicy = "strict"
	// ICEPolicyLAN is pion's defaults plus query-only mDNS plus ICE servers. It is NOT a new policy:
	// rdev's deleted bridge configured an inert SettingEngine (host/pion-bridge/peer.go @ 04dbdc8),
	// so this is the behaviour browsers connected to for months before the engine cutover.
	ICEPolicyLAN ICEPolicy = "lan"
)

type PeerConfig struct {
	LocalIP                     net.IP
	RemoteIP                    net.IP
	ICEPolicy                   ICEPolicy
	ICEServersJSON              string
	ICEPort                     uint16
	SignalPort                  uint16
	Recovery                    RecoveryMode
	RTXMaxAge                   time.Duration
	RTXAgeMode                  RTXAgeMode
	RTXAgeMultiplierMilli       uint32
	RTXAgeCap                   time.Duration
	Network                     transport.Net
	Impairment                  *RecoveryImpairmentController
	Trace                       *recoveryTraceRecorder
	TWCCReorderingGrace         time.Duration
	TotalRTPBudgetBitsPerSecond uint32
	FramesPerSecond             uint32
}

func rtxFMTP(associatedPayloadType uint8, maxAge time.Duration) string {
	return fmt.Sprintf(
		"apt=%d;rtx-time=%d",
		associatedPayloadType,
		maxAge/time.Millisecond,
	)
}

// THE DUPLICATE CHECK IS PER M-SECTION, NOT PER DESCRIPTION, and that distinction only started
// mattering when a session could carry more than one video track (AddVideoTrack, session.go). The
// same RTX payload type legitimately appears once in EVERY video m-section — pion assigns payload
// types per description, not per section — so a description with two video tracks tripped
// "duplicate local RTX fmtp" and CreateOffer failed outright. `found` is therefore reset at each
// `m=` line.
//
// BYTE-IDENTICAL FOR EVERY SINGLE-VIDEO-SECTION DESCRIPTION, which is every description the
// ANSWERING path produces — so this is not drift between the two arms. What the check still
// catches is what it was written for: two fmtp lines for the SAME payload type inside ONE
// m-section, i.e. a malformed section. Both halves are asserted in peer_config_test.go.
//
// THE ZERO-SECTION CASE IS UNCHANGED AND STILL FAILS ("missing local RTX fmtp"). That is the
// data-channels-only offer rdev's own bridge sends first, and it stays a live decision for
// whoever removes assembleSession's eager track; failing is deliberate, because the alternative is
// negotiating a retransmission window the remote was never told about.
func advertiseRTXTime(
	description webrtc.SessionDescription,
	maxAge time.Duration,
) (webrtc.SessionDescription, error) {
	lines := strings.Split(description.SDP, "\n")
	primaryPayloads, rtxPayloads := recoveryPayloadTypes(lines)
	found := map[int]bool{}
	// advertised is CUMULATIVE across the whole description while `found` is per-section, and the
	// two must not be merged. The final "missing local RTX fmtp" check needs to know whether ANY
	// section carried one; using the per-section map for that would report "missing" whenever a
	// video section is followed by another m-section (an `m=application` data section, which every
	// offer this session builds has), since the reset would have emptied it by the end.
	advertised := 0
	for index, rawLine := range lines {
		hasCarriageReturn := strings.HasSuffix(rawLine, "\r")
		line := strings.TrimSuffix(rawLine, "\r")
		if strings.HasPrefix(line, "m=") {
			// A new m-section starts here, so the payload types seen so far belong to the previous
			// one.
			found = map[int]bool{}
			continue
		}
		payloadType, parameters, prefix, ok := parseFMTPLine(line)
		if !ok || !rtxPayloads[payloadType] {
			continue
		}
		apt, rtxTime, err := parseRTXParameters(parameters)
		if err != nil || !primaryPayloads[apt] || apt > 127 {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"%w: unexpected local RTX fmtp %q", errInvalidPeerConfig, parameters,
			)
		}
		if found[payloadType] {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"%w: duplicate local RTX fmtp", errInvalidPeerConfig,
			)
		}
		found[payloadType] = true
		advertised++
		expectedMilliseconds := int(maxAge / time.Millisecond)
		if rtxTime >= 0 && rtxTime != expectedMilliseconds {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"%w: unexpected local RTX fmtp %q", errInvalidPeerConfig, parameters,
			)
		}
		lines[index] = prefix + rtxFMTP(uint8(apt), maxAge)
		if hasCarriageReturn {
			lines[index] += "\r"
		}
	}
	if advertised == 0 {
		return webrtc.SessionDescription{}, fmt.Errorf(
			"%w: missing local RTX fmtp", errInvalidPeerConfig,
		)
	}
	description.SDP = strings.Join(lines, "\n")
	return description, nil
}

func negotiateReceiverReferenceTime(
	answer webrtc.SessionDescription,
	offer webrtc.SessionDescription,
) (webrtc.SessionDescription, error) {
	offered, err := videoSectionContainsAttribute(offer.SDP, receiverRTTAttribute)
	if err != nil || !offered {
		return answer, err
	}
	alreadyPresent, err := videoSectionContainsAttribute(answer.SDP, receiverRTTAttribute)
	if err != nil || alreadyPresent {
		return answer, err
	}

	lines := strings.Split(answer.SDP, "\n")
	videoStart := -1
	videoEnd := len(lines)
	for index, rawLine := range lines {
		line := strings.TrimSuffix(rawLine, "\r")
		if strings.HasPrefix(line, "m=video ") {
			if videoStart >= 0 {
				return webrtc.SessionDescription{}, fmt.Errorf(
					"%w: multiple video sections", errInvalidPeerConfig,
				)
			}
			videoStart = index
			continue
		}
		if videoStart >= 0 && strings.HasPrefix(line, "m=") {
			videoEnd = index
			break
		}
	}
	if videoStart < 0 {
		return webrtc.SessionDescription{}, fmt.Errorf(
			"%w: answer has no video section", errInvalidPeerConfig,
		)
	}
	lineEnding := ""
	if strings.HasSuffix(lines[videoStart], "\r") {
		lineEnding = "\r"
	}
	lines = append(lines, "")
	copy(lines[videoEnd+1:], lines[videoEnd:])
	lines[videoEnd] = receiverRTTAttribute + lineEnding
	answer.SDP = strings.Join(lines, "\n")
	return answer, nil
}

func videoSectionContainsAttribute(sdp string, attribute string) (bool, error) {
	inVideo := false
	found := false
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if strings.HasPrefix(line, "m=") {
			inVideo = strings.HasPrefix(line, "m=video ")
			continue
		}
		if inVideo && line == attribute {
			if found {
				return false, fmt.Errorf(
					"%w: duplicate receiver RTT attribute", errInvalidPeerConfig,
				)
			}
			found = true
		}
	}
	return found, nil
}

func preparePionRemoteDescription(
	description webrtc.SessionDescription,
	expectedMaxAge time.Duration,
	requireRTXTime bool,
) (webrtc.SessionDescription, error) {
	// THE DEPENDENCY DESCRIPTOR IS REQUIRED ONLY BY THE CODECS THAT EMIT ONE.
	//
	// This ran unconditionally, at the very top, before any codec logic — so an H.264-only answer,
	// which browsers never carry the extension on, failed HERE FIRST and reported a missing header
	// extension rather than anything about codecs. For the AV1-less device this whole increment
	// exists for, that was the first thing to go wrong and the last thing the message pointed at.
	//
	// AV1 still requires it, and that half must not be relaxed while this is made conditional: AV1
	// frames carry a descriptor, so a receiver that did not negotiate it cannot decode what we send.
	if descriptionNeedsDependencyDescriptor(description.SDP) {
		if _, err := videoHeaderExtensionID(description.SDP, dependencyDescriptorURI); err != nil {
			return webrtc.SessionDescription{}, err
		}
	}
	lines := strings.Split(description.SDP, "\n")
	primaryPayloads, rtxPayloads := recoveryPayloadTypes(lines)
	// foundRTX IS PER M-SECTION and associations is CUMULATIVE, for exactly the reasons spelled out
	// on advertiseRTXTime: the same RTX payload type appears once in every video m-section of a
	// multi-track description, so a description-wide set read the second one as an "invalid RTX
	// association" — and since this function prepares every REMOTE description, that made SetAnswer
	// fail on any answer to a two-track offer. The two counters cannot be merged: the per-section
	// map is emptied at each `m=`, so the final requireRTXTime check would report the fmtp missing
	// whenever a video section is followed by another m-section.
	foundRTX := map[int]bool{}
	associations := 0
	for index, rawLine := range lines {
		hasCarriageReturn := strings.HasSuffix(rawLine, "\r")
		line := strings.TrimSuffix(rawLine, "\r")
		if strings.HasPrefix(line, "m=") {
			foundRTX = map[int]bool{}
			continue
		}
		payloadType, parameters, prefix, ok := parseFMTPLine(line)
		if !ok || !rtxPayloads[payloadType] {
			continue
		}
		apt, rtxTime, err := parseRTXParameters(parameters)
		if err != nil || !primaryPayloads[apt] || foundRTX[payloadType] {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"%w: invalid RTX association", errInvalidPeerConfig,
			)
		}
		foundRTX[payloadType] = true
		associations++
		expectedMilliseconds := int(expectedMaxAge / time.Millisecond)
		if rtxTime < 0 && requireRTXTime || rtxTime >= 0 && rtxTime != expectedMilliseconds {
			return webrtc.SessionDescription{}, fmt.Errorf(
				"%w: invalid negotiated RTX time", errInvalidPeerConfig,
			)
		}
		if rtxTime >= 0 {
			lines[index] = prefix + fmt.Sprintf("apt=%d", apt)
			if hasCarriageReturn {
				lines[index] += "\r"
			}
		}
	}
	if requireRTXTime && associations == 0 {
		return webrtc.SessionDescription{}, fmt.Errorf(
			"%w: missing negotiated RTX fmtp", errInvalidPeerConfig,
		)
	}
	description.SDP = strings.Join(lines, "\n")
	return description, nil
}

// videoHeaderExtensionID returns the id every video m-section maps `uri` to.
//
// "DUPLICATE" IS PER M-SECTION, AND THE ID MUST AGREE ACROSS THEM. Both halves changed when a
// session could carry more than one video track (AddVideoTrack, session.go): a description with two
// video sections repeats each extmap once per section, which this rejected as a duplicate — and
// since preparePionRemoteDescription calls this on every remote description, SetAnswer failed on any
// answer to a two-track offer. The rules are now the two things that are actually true of a valid
// description:
//
//   - Twice for one URI INSIDE one m-section is malformed, which is what the original check was
//     written to catch, and is still refused.
//   - The SAME URI in different sections must carry the SAME id. That is not a convenience for the
//     single int this returns — RFC 8843 requires extmap ids to be consistent across a BUNDLE
//     group, and pion assigns them per MediaEngine, so a disagreement is a genuinely invalid
//     description rather than a shape this function cannot express.
//
// Byte-identical for a single-video-section description, which is every description the ANSWERING
// path handles, so this is not drift between the two arms.
//
// THE MESSAGE NAMES THE URI IT WAS GIVEN. It used to say "dependency-descriptor" unconditionally
// while flexfec_negotiation.go calls this for the TWCC URI, so a TWCC failure reported the wrong
// extension — which sends a reader to the wrong m-section attribute entirely.
func videoHeaderExtensionID(sdp string, uri string) (int, error) {
	inVideo := false
	found := -1
	seenInSection := false
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if strings.HasPrefix(line, "m=") {
			inVideo = strings.HasPrefix(line, "m=video ")
			seenInSection = false
			continue
		}
		if !inVideo || !strings.HasPrefix(line, "a=extmap:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[1] != uri {
			continue
		}
		idText := strings.TrimPrefix(fields[0], "a=extmap:")
		if direction := strings.IndexByte(idText, '/'); direction >= 0 {
			idText = idText[:direction]
		}
		id, err := strconv.Atoi(idText)
		if err != nil || id < 1 || id > 255 || seenInSection || (found >= 0 && id != found) {
			return -1, fmt.Errorf(
				"%w: invalid or duplicate %s extmap", errInvalidPeerConfig, uri,
			)
		}
		seenInSection = true
		found = id
	}
	if found < 0 {
		return -1, fmt.Errorf(
			"%w: missing %s video extmap", errInvalidPeerConfig, uri,
		)
	}
	return found, nil
}

// recoveryPayloadTypes returns the PRIMARY and RTX payload types this description uses.
//
// SEEDED FROM EVERY PROFILE, not from AV1 alone. Its output decides which payload types count as
// primary for RTX association, so an AV1-only seed made a valid H.265 or H.264 association read as
// invalid — and it fails inside advertiseRTXTime, whose error text is about `rtx-time`, which is
// the wrong place to go looking. Registering a second codec reproduces it immediately:
// `unexpected local RTX fmtp "apt=108"`.
// descriptionNeedsDependencyDescriptor reports whether any codec in this description emits one.
//
// It reads the DESCRIPTION rather than a resolved profile because it runs BEFORE resolution — this
// is the function that prepares the very description resolution is derived from.
func descriptionNeedsDependencyDescriptor(sdp string) bool {
	// CONSIDERS BOTH THE rtpmap NAMES AND THE PAYLOAD NUMBERS IN THE m=video LINE, and the second
	// half is not redundant. A description can name rdev's AV1 payload type in its media line
	// without carrying an rtpmap for it — malformed for a dynamic payload type, but it is what an
	// abbreviated or hand-written answer looks like, and reading it as "no AV1 here" would drop the
	// requirement exactly where it matters. Erring toward REQUIRING the descriptor is the safe
	// direction: the cost is refusing a description we could not have decoded anyway.
	numbers := map[string]bool{}
	names := map[string]bool{}
	for _, profile := range videoCodecProfiles() {
		if !profile.emitsDependencyDescriptor {
			continue
		}
		names[profile.rtpmapName] = true
		numbers[strconv.Itoa(int(profile.payloadType))] = true
	}
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSuffix(rawLine, "\r")
		if strings.HasPrefix(line, "m=video ") {
			for index, token := range strings.Fields(line) {
				if index >= 3 && numbers[token] {
					return true
				}
			}
			continue
		}
		if !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		space := strings.IndexByte(line, ' ')
		if space < len("a=rtpmap:") {
			continue
		}
		if names[strings.ToLower(strings.TrimSpace(line[space+1:]))] {
			return true
		}
	}
	return false
}

func recoveryPayloadTypes(lines []string) (map[int]bool, map[int]bool) {
	primaries := map[int]bool{}
	rtx := map[int]bool{}
	names := map[string]bool{}
	for _, profile := range videoCodecProfiles() {
		primaries[int(profile.payloadType)] = true
		rtx[int(profile.rtxPayloadType)] = true
		names[profile.rtpmapName] = true
	}
	for _, rawLine := range lines {
		line := strings.TrimSuffix(rawLine, "\r")
		if !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		space := strings.IndexByte(line, ' ')
		if space < len("a=rtpmap:") {
			continue
		}
		payloadType, err := strconv.Atoi(line[len("a=rtpmap:"):space])
		if err != nil || payloadType < 0 || payloadType > 127 {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(line[space+1:]))
		if names[name] {
			primaries[payloadType] = true
		}
		if name == "rtx/90000" {
			rtx[payloadType] = true
		}
	}
	return primaries, rtx
}

func parseFMTPLine(line string) (int, string, string, bool) {
	const marker = "a=fmtp:"
	if !strings.HasPrefix(line, marker) {
		return 0, "", "", false
	}
	space := strings.IndexByte(line, ' ')
	if space < len(marker) {
		return 0, "", "", false
	}
	payloadType, err := strconv.Atoi(line[len(marker):space])
	if err != nil || payloadType < 0 || payloadType > 127 {
		return 0, "", "", false
	}
	return payloadType, line[space+1:], line[:space+1], true
}

func parseRTXParameters(parameters string) (int, int, error) {
	apt := -1
	rtxTime := -1
	for _, rawParameter := range strings.Split(parameters, ";") {
		parameter := strings.TrimSpace(rawParameter)
		parts := strings.SplitN(parameter, "=", 2)
		if len(parts) != 2 {
			return -1, -1, fmt.Errorf("malformed RTX fmtp parameter %q", parameter)
		}
		value, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || value < 0 {
			return -1, -1, fmt.Errorf("malformed RTX fmtp value %q", parameter)
		}
		switch strings.TrimSpace(parts[0]) {
		case "apt":
			if apt >= 0 {
				return -1, -1, errors.New("duplicate RTX apt")
			}
			apt = value
		case "rtx-time":
			if rtxTime >= 0 {
				return -1, -1, errors.New("duplicate RTX time")
			}
			rtxTime = value
		default:
			return -1, -1, fmt.Errorf("unknown RTX fmtp parameter %q", parameter)
		}
	}
	if apt < 0 {
		return -1, -1, errors.New("missing RTX apt")
	}
	return apt, rtxTime, nil
}

func (config PeerConfig) Validate() error {
	if !validPeerIPv4(config.LocalIP) {
		return fmt.Errorf("%w: local IP must be a specified IPv4 address", errInvalidPeerConfig)
	}
	switch config.ICEPolicy {
	case ICEPolicyStrict:
		if !validPeerIPv4(config.RemoteIP) {
			return fmt.Errorf("%w: remote IP must be a specified IPv4 address under %s",
				errInvalidPeerConfig, config.ICEPolicy)
		}
		if config.ICEServersJSON != "" {
			return fmt.Errorf("%w: %s registers no ICE servers; passing them would be ignored",
				errInvalidPeerConfig, config.ICEPolicy)
		}
	case ICEPolicyLAN:
		// INVERTED DELIBERATELY. Nothing filters on RemoteIP under lan, so a populated one would be
		// silently unenforced — a caller could set it and believe it was doing something. That is the
		// shape of defect this project keeps finding, so it is an error rather than an ignored field.
		if config.RemoteIP != nil {
			return fmt.Errorf("%w: %s filters no remote candidates, so a remote IP would not be enforced",
				errInvalidPeerConfig, config.ICEPolicy)
		}
		if config.ICEServersJSON != "" {
			var servers []webrtc.ICEServer
			if err := json.Unmarshal([]byte(config.ICEServersJSON), &servers); err != nil {
				return fmt.Errorf("%w: ice servers JSON: %v", errInvalidPeerConfig, err)
			}
		}
	default:
		return fmt.Errorf("%w: unknown ICE policy %q", errInvalidPeerConfig, config.ICEPolicy)
	}
	if config.SignalPort == 0 {
		return fmt.Errorf("%w: signal port is zero", errInvalidPeerConfig)
	}
	if (config.Recovery != RecoveryNACKRTX && config.Recovery != RecoveryOff &&
		config.Recovery != RecoveryNACKRTXFlexFEC) ||
		config.RTXMaxAge < time.Millisecond || config.RTXMaxAge > time.Second ||
		config.RTXMaxAge%time.Millisecond != 0 {
		return fmt.Errorf("%w: invalid recovery configuration", errInvalidPeerConfig)
	}
	policyConfig := (SessionConfiguration{
		RTXMaxAge: config.RTXMaxAge, RTXAgeMode: config.RTXAgeMode,
		RTXAgeMultiplierMilli: config.RTXAgeMultiplierMilli, RTXAgeCap: config.RTXAgeCap,
	}).rtxAgePolicyConfig()
	var mediaRTT *mediaRTTEstimator
	if policyConfig.Mode == RTXAgeRTT {
		mediaRTT = &mediaRTTEstimator{}
	}
	if _, err := NewRTXAgePolicy(policyConfig, mediaRTT); err != nil {
		return fmt.Errorf("%w: invalid RTX age policy", errInvalidPeerConfig)
	}
	if config.ICEPort == 0 {
		return fmt.Errorf("%w: host ICE port is zero", errInvalidPeerConfig)
	}
	if config.ICEPort == config.SignalPort {
		return fmt.Errorf("%w: signal and ICE ports are equal", errInvalidPeerConfig)
	}
	if config.TWCCReorderingGrace < 0 ||
		(config.TWCCReorderingGrace > 0 && config.Recovery != RecoveryNACKRTXFlexFEC) {
		return fmt.Errorf("%w: invalid TWCC reordering grace", errInvalidPeerConfig)
	}
	if config.Recovery == RecoveryNACKRTXFlexFEC {
		if config.TotalRTPBudgetBitsPerSecond == 0 || config.FramesPerSecond == 0 ||
			config.FramesPerSecond > 1_000 {
			return fmt.Errorf("%w: total RTP budget and frame rate require FlexFEC recovery", errInvalidPeerConfig)
		}
	} else if config.TotalRTPBudgetBitsPerSecond != 0 || config.FramesPerSecond != 0 {
		return fmt.Errorf("%w: total RTP budget requires FlexFEC recovery", errInvalidPeerConfig)
	}
	return nil
}

func validPeerIPv4(ip net.IP) bool {
	return ip != nil && ip.To4() != nil && !ip.IsUnspecified()
}

func nackRTXEnabled(recovery RecoveryMode) bool {
	return recovery == RecoveryNACKRTX || recovery == RecoveryNACKRTXFlexFEC
}

type PeerConstructionAudit struct {
	CodecMimeType                    string
	CodecClockRate                   uint32
	PayloadType                      uint8
	HeaderExtensionURI               string
	PlayoutDelayExtensionURI         string
	DependencyDescriptorExtensionURI string
	NetworkType                      string
	LocalIP                          string
	RemoteIP                         string
	ICEPolicy                        string
	IncludeLoopback                  bool
	MuxBindAddress                   string
	ICEServers                       int
	NACK                             bool
	RTX                              bool
	RTXMaxAgeMilliseconds            int
	FEC                              bool
	SenderReports                    bool
	TWCC                             bool
	JitterBuffer                     bool
	DefaultInterceptors              bool
	MulticastDNSDisabled             bool
	ActiveTCPDisabled                bool
	ReceiveMTU                       uint
	HostUsesConfiguredMux            bool
	InterceptorOrder                 []string
	RecoveryEgressAdmission          bool
	TotalRTPBudgetBitsPerSecond      uint32
	RecoveryEgressBurstMilliseconds  int
}

type peerAPIResources struct {
	closeOnce sync.Once
	udpMux    ice.UDPMux
	// iceServers is carried rather than re-parsed at the NewPeerConnection call site: the count in
	// the audit and the servers actually registered must come from ONE read of the JSON.
	iceServers              []webrtc.ICEServer
	audit                   PeerConstructionAudit
	closeErr                error
	counters                *RecoveryCounters
	responderCache          *ResponderCacheCounters
	responderFactory        *ageAwareNACKResponderFactory
	observerFactory         *recoveryObserverFactory
	mediaRTT                *mediaRTTEstimator
	rtxAgePolicy            *RTXAgePolicy
	rtxNegotiated           atomic.Bool
	callbackMutex           sync.RWMutex
	requestKeyframe         func(mediaSSRC uint32)
	recoveryRequest         func(uint32, string, bool)
	reportError             func(error)
	observeNACK             func()
	impairment              *RecoveryImpairmentController
	transportAllocator      *TransportSequenceAllocator
	twccHistory             *TWCCPacketHistory
	recoveryBudget          *RecoveryBudgetAllocator
	recoveryEgressBudget    *RecoveryFrameClockBudget
	flexFECOverride         *FlexFECOverrideStore
	scalabilityMode         AV1ScalabilityMode
	deliveredPolicySequence uint64
	flexFECController       *FlexFECController
	flexFECPolicySHA256     string
	flexFECRetainedSHA256   string
	flexFECTier             *FlexFECTierStore
	flexFECCounters         *FlexFECCounters
	flexFECPolicyMutex      sync.Mutex
	flexFECMutex            sync.Mutex
	flexFECDegradedReason   string
	recoveryPolicySequence  uint64
	flexFECPolicy           FlexFECPolicy
	configuredRTPBudget     uint32
	mediaBitrateTarget      uint32
	flexFECNegotiation      flexFECNegotiation
	flexFECNegotiated       bool
	flexFECTransitions      []RecoveryPolicyTransitionStats
}

type RecoveryPolicyTransitionStats struct {
	Sequence                  uint64 `json:"sequence"`
	Tier                      string `json:"tier"`
	MediaBitrateBitsPerSecond uint32 `json:"mediaBitrateBitsPerSecond"`
	Accepted                  bool   `json:"accepted"`
	Error                     string `json:"error,omitempty"`
}

type SessionFlexFECStats struct {
	Negotiated                       bool   `json:"negotiated"`
	PayloadType                      int    `json:"payloadType"`
	RepairWindowMicroseconds         int    `json:"repairWindowMicroseconds"`
	TWCCExtensionID                  int    `json:"twccExtensionID"`
	MediaSSRC                        uint32 `json:"mediaSSRC"`
	RTXSSRC                          uint32 `json:"rtxSSRC"`
	FlexFECSSRC                      uint32 `json:"flexfecSSRC"`
	Policy                           string `json:"policy"`
	CurrentTier                      string `json:"currentTier"`
	ConfiguredRTPBudgetBitsPerSecond uint32 `json:"configuredRTPBudgetBitsPerSecond"`
	MediaBitrateBitsPerSecond        uint32 `json:"mediaBitrateBitsPerSecond"`
	Degraded                         bool   `json:"degraded"`
	// The operator-forced overhead ratio, READ BACK from the store rather than restated by whoever
	// set it — a forced ratio bypasses the tier, so without this a report has no way to tell a
	// silent session from one deliberately sending 50%.
	OverrideBasisPoints uint32                          `json:"overrideBasisPoints,omitempty"`
	Overridden          bool                            `json:"overridden,omitempty"`
	DegradedReason      string                          `json:"degradedReason,omitempty"`
	Transitions         []RecoveryPolicyTransitionStats `json:"transitions"`
	Controller          *SessionFlexFECControllerStats  `json:"controller,omitempty"`
	Budget              *RecoveryBudgetSnapshot         `json:"budget,omitempty"`
	FlexFECStatsSnapshot
}

type SessionFlexFECControllerStats struct {
	ControllerVersion          string                  `json:"controllerVersion"`
	PolicySHA256               string                  `json:"policySha256"`
	RetainedTiersSHA256        string                  `json:"retainedTiersSha256"`
	AllowedTiers               []string                `json:"allowedTiers"`
	RequestedTier              string                  `json:"requestedTier"`
	TransitionSequence         uint64                  `json:"transitionSequence"`
	AcceptedTransitions        uint64                  `json:"acceptedTransitions"`
	RejectedTransitions        uint64                  `json:"rejectedTransitions"`
	LastReason                 string                  `json:"lastReason"`
	LastError                  string                  `json:"lastError,omitempty"`
	LastTransitionAge          time.Duration           `json:"lastTransitionAgeNanoseconds"`
	RTTReady                   bool                    `json:"rttReady"`
	Ready                      bool                    `json:"ready"`
	CompleteWindow             bool                    `json:"completeWindow"`
	LastLossBasisPoints        int                     `json:"lastLossBasisPoints"`
	LastFinalizedPackets       uint64                  `json:"lastFinalizedPackets"`
	RepairLossCapped           bool                    `json:"repairLossCapped"`
	LastRepairLossBasisPoints  int                     `json:"lastRepairLossBasisPoints"`
	LastRepairFinalizedPackets uint64                  `json:"lastRepairFinalizedPackets"`
	Policy                     FlexFECControllerPolicy `json:"policy"`
}

func (resources *peerAPIResources) SetRecoveryCallbacks(
	requestKeyframe func(mediaSSRC uint32),
	reportError func(error),
	observeNACK func(),
) {
	resources.callbackMutex.Lock()
	resources.requestKeyframe = requestKeyframe
	resources.reportError = reportError
	resources.observeNACK = observeNACK
	resources.callbackMutex.Unlock()
}

func (resources *peerAPIResources) requestRecoveryKeyframe(mediaSSRC uint32) {
	resources.callbackMutex.RLock()
	callback := resources.requestKeyframe
	resources.callbackMutex.RUnlock()
	if callback != nil {
		callback(mediaSSRC)
	}
	if resources.impairment != nil {
		resources.impairment.ResolveRecovery()
	}
}

func (resources *peerAPIResources) reportRecoveryError(err error) {
	resources.callbackMutex.RLock()
	callback := resources.reportError
	resources.callbackMutex.RUnlock()
	if callback != nil {
		callback(err)
	}
}

func (resources *peerAPIResources) observeRecoveryNACK() {
	resources.callbackMutex.RLock()
	callback := resources.observeNACK
	resources.callbackMutex.RUnlock()
	resources.flexFECMutex.Lock()
	controller := resources.flexFECController
	resources.flexFECMutex.Unlock()
	if controller != nil {
		controller.ObserveNACK()
	}
	if callback != nil {
		callback()
	}
}

func (resources *peerAPIResources) ActivateAdaptiveFlexFEC(
	assets FlexFECControllerAssets,
	mode AV1ScalabilityMode,
	budget uint32,
	callback func(RecoveryPolicyUpdate) error,
) error {
	if resources == nil || resources.flexFECTier == nil || callback == nil {
		return fmt.Errorf("%w: FlexFEC transport is unavailable", errInvalidPeerConfig)
	}
	resources.flexFECPolicyMutex.Lock()
	defer resources.flexFECPolicyMutex.Unlock()
	if resources.flexFECController != nil {
		return fmt.Errorf("%w: adaptive FlexFEC controller already exists", errInvalidPeerConfig)
	}
	allocator, err := NewRecoveryBudgetAllocator(budget, mode)
	if err != nil {
		return err
	}
	resources.flexFECMutex.Lock()
	resources.flexFECPolicy = FlexFECPolicyAdaptive
	resources.configuredRTPBudget = budget
	resources.scalabilityMode = mode
	resources.mediaBitrateTarget = budget
	resources.flexFECPolicySHA256 = assets.PolicySHA256
	resources.flexFECRetainedSHA256 = assets.RetainedTiersSHA256
	resources.flexFECMutex.Unlock()
	apply := func(update RecoveryPolicyUpdate) error {
		// SUPPRESSED AND ACKNOWLEDGED while an operator has forced a ratio. The acknowledgement is
		// the half that matters: the controller treats a rejected update as a degradation and
		// reports itself unhealthy, so refusing here would make every forced-ratio test look like
		// it had broken FlexFEC. Dropping it INSIDE the engine rather than filtering in Swift means
		// the ABI callback only ever carries an effective policy.
		if resources.recoveryOverrideActive() {
			return nil
		}
		// RENUMBERED, because two sources emit on this one callback and Swift's coordinator
		// validates monotonicity. The controller numbers from its own counter and SetRecoveryOverride
		// from this one; without a single delivered-sequence they interleave and the first update
		// after returning to Auto can go BACKWARDS, which the coordinator rejects as a conflict.
		update.Sequence = resources.nextDeliveredPolicySequence()
		err := callback(update)
		resources.flexFECMutex.Lock()
		resources.recoveryPolicySequence = update.Sequence
		transition := RecoveryPolicyTransitionStats{
			Sequence: update.Sequence, Tier: flexFECTierName(update.Tier),
			MediaBitrateBitsPerSecond: update.MediaBitrateBitsPerSecond,
			Accepted:                  err == nil,
		}
		if err != nil {
			transition.Error = err.Error()
		} else {
			resources.mediaBitrateTarget = update.MediaBitrateBitsPerSecond
		}
		resources.flexFECTransitions = append(resources.flexFECTransitions, transition)
		resources.flexFECMutex.Unlock()
		return err
	}
	controller, err := NewFlexFECController(FlexFECControllerConfig{
		Policy: assets.Policy, AllowedTiers: assets.AllowedTiers,
		Tier: resources.flexFECTier, History: resources.twccHistory,
		MediaRTT: resources.mediaRTT, Budget: allocator, Apply: apply,
	})
	if err != nil {
		return fmt.Errorf("%w: create adaptive FlexFEC controller: %v", errInvalidPeerConfig, err)
	}
	resources.flexFECMutex.Lock()
	resources.recoveryBudget = allocator
	resources.flexFECController = controller
	resources.flexFECMutex.Unlock()
	return nil
}

func (resources *peerAPIResources) Audit() PeerConstructionAudit {
	audit := resources.audit
	audit.InterceptorOrder = append([]string(nil), resources.audit.InterceptorOrder...)
	return audit
}

func flexFECTierForPolicy(policy FlexFECPolicy) (FlexFECTier, error) {
	switch policy {
	case FlexFECPolicyAdaptive, FlexFECPolicyOff:
		return FlexFECTierOff, nil
	case FlexFECPolicyLow:
		return FlexFECTierLow, nil
	case FlexFECPolicyMedium:
		return FlexFECTierMedium, nil
	case FlexFECPolicyHigh:
		return FlexFECTierHigh, nil
	default:
		return FlexFECTierOff, fmt.Errorf("%w: invalid FlexFEC policy", errInvalidPeerConfig)
	}
}

func flexFECTierName(tier FlexFECTier) string {
	switch tier {
	case FlexFECTierOff:
		return "off"
	case FlexFECTierLow:
		return "low"
	case FlexFECTierMedium:
		return "medium"
	case FlexFECTierHigh:
		return "high"
	default:
		return "invalid"
	}
}

func flexFECPolicyName(policy FlexFECPolicy) string {
	switch policy {
	case FlexFECPolicyAdaptive:
		return "adaptive"
	case FlexFECPolicyOff:
		return "off"
	case FlexFECPolicyLow:
		return "low"
	case FlexFECPolicyMedium:
		return "medium"
	case FlexFECPolicyHigh:
		return "high"
	default:
		return "invalid"
	}
}

func (resources *peerAPIResources) ActivateFlexFECPolicy(
	policy FlexFECPolicy,
	mode AV1ScalabilityMode,
	budget uint32,
	callback func(RecoveryPolicyUpdate) error,
) error {
	if resources == nil || resources.flexFECTier == nil || callback == nil {
		return fmt.Errorf("%w: FlexFEC transport is unavailable", errInvalidPeerConfig)
	}
	tier, err := flexFECTierForPolicy(policy)
	if err != nil {
		return err
	}
	resources.flexFECPolicyMutex.Lock()
	defer resources.flexFECPolicyMutex.Unlock()
	if resources.recoveryBudget == nil {
		resources.recoveryBudget, err = NewRecoveryBudgetAllocator(budget, mode)
		if err != nil {
			return err
		}
	} else {
		snapshot := resources.recoveryBudget.Snapshot()
		if snapshot.ConfiguredRTPBudgetBitsPerSecond != budget ||
			snapshot.ScalabilityMode != scalabilityModeName(mode) {
			return fmt.Errorf("%w: recovery budget configuration changed", errInvalidPeerConfig)
		}
	}
	target := resources.recoveryBudget.Target(tier)
	if target == 0 {
		return fmt.Errorf("%w: invalid recovery budget target", errInvalidPeerConfig)
	}
	resources.flexFECMutex.Lock()
	resources.flexFECPolicy = policy
	resources.configuredRTPBudget = budget
	resources.scalabilityMode = mode
	if resources.mediaBitrateTarget == 0 {
		resources.mediaBitrateTarget = budget
	}
	resources.recoveryPolicySequence++
	sequence := resources.recoveryPolicySequence
	resources.flexFECMutex.Unlock()
	update := RecoveryPolicyUpdate{
		Sequence: sequence,
		Tier:     tier, MediaBitrateBitsPerSecond: target,
	}
	if err := callback(update); err != nil {
		resources.flexFECMutex.Lock()
		reason := fmt.Sprintf("recovery policy acknowledgment failed: %v", err)
		resources.flexFECDegradedReason = reason
		resources.flexFECTransitions = append(resources.flexFECTransitions, RecoveryPolicyTransitionStats{
			Sequence: update.Sequence, Tier: flexFECTierName(tier),
			MediaBitrateBitsPerSecond: target, Error: err.Error(),
		})
		resources.flexFECMutex.Unlock()
		return fmt.Errorf("%w: %s", errInvalidPeerConfig, reason)
	}
	resources.recoveryBudget.AcceptTarget(target)
	resources.flexFECTier.Set(tier)
	resources.flexFECMutex.Lock()
	resources.mediaBitrateTarget = target
	resources.flexFECTransitions = append(resources.flexFECTransitions, RecoveryPolicyTransitionStats{
		Sequence: update.Sequence, Tier: flexFECTierName(tier),
		MediaBitrateBitsPerSecond: target, Accepted: true,
	})
	resources.flexFECMutex.Unlock()
	return nil
}

// nextDeliveredPolicySequence hands out the sequence numbers that actually reach Swift, strictly
// increasing across BOTH emitters — the adaptive controller and SetRecoveryOverride.
func (resources *peerAPIResources) nextDeliveredPolicySequence() uint64 {
	resources.flexFECMutex.Lock()
	defer resources.flexFECMutex.Unlock()
	resources.deliveredPolicySequence++
	return resources.deliveredPolicySequence
}

// recoveryOverrideActive reports whether an operator has forced an overhead ratio.
func (resources *peerAPIResources) recoveryOverrideActive() bool {
	if resources == nil {
		return false
	}
	_, set := resources.flexFECOverride.Load()
	return set
}

// applyRecoveryPolicyUpdate is the gate a controller decision passes through. Exported for the
// controller's own apply closure to share; see the comment there for why suppression is
// acknowledged rather than refused.
func (resources *peerAPIResources) applyRecoveryPolicyUpdate(
	update RecoveryPolicyUpdate,
	callback func(RecoveryPolicyUpdate) error,
) error {
	if resources == nil || callback == nil {
		return fmt.Errorf("%w: FlexFEC transport is unavailable", errInvalidPeerConfig)
	}
	if resources.recoveryOverrideActive() {
		return nil
	}
	update.Sequence = resources.nextDeliveredPolicySequence()
	return callback(update)
}

// SetRecoveryOverride forces an FEC overhead ratio, or returns the session to adaptive control.
//
// `bp` is basis points of media, 0..5000; -1 means Auto. It emits exactly ONE RecoveryPolicyUpdate
// carrying the matching media target, through the same callback the controller uses — so rdev's
// existing applyRecoveryPolicy sink, the coordinator's monotonicity validation and the transition
// stats all stay coherent with no second path.
//
// THE STORE IS ARMED BEFORE THE UPDATE IS EMITTED. The repair ratio and the media target have to
// change together, and the callback is synchronous: arming afterwards would leave a window in which
// encoders had already made room for FEC that was not yet being generated.
func (resources *peerAPIResources) SetRecoveryOverride(
	bp int,
	callback func(RecoveryPolicyUpdate) error,
) error {
	if resources == nil || resources.flexFECOverride == nil || callback == nil {
		return fmt.Errorf("%w: FlexFEC transport is unavailable", errInvalidPeerConfig)
	}
	if bp < -1 || bp > int(maximumFlexFECOverrideBasisPoints) {
		return fmt.Errorf(
			"%w: recovery override %d is not -1 (auto) or 0..%d",
			errInvalidPeerConfig, bp, maximumFlexFECOverrideBasisPoints,
		)
	}
	resources.flexFECMutex.Lock()
	budget := resources.configuredRTPBudget
	mode := resources.scalabilityMode
	resources.flexFECMutex.Unlock()
	if budget == 0 {
		return fmt.Errorf("%w: recovery budget is not configured", errInvalidPeerConfig)
	}

	var target uint32
	if bp < 0 {
		resources.flexFECOverride.Clear()
		target = resources.recoveryBudget.Target(resources.flexFECTier.Load())
	} else {
		resources.flexFECOverride.Set(uint32(bp))
		target = overrideRecoveryMediaTarget(budget, mode, uint32(bp))
	}
	if target == 0 {
		return fmt.Errorf("%w: invalid recovery budget target", errInvalidPeerConfig)
	}

	update := RecoveryPolicyUpdate{
		Sequence: resources.nextDeliveredPolicySequence(),
		Tier:     resources.flexFECTier.Load(), MediaBitrateBitsPerSecond: target,
	}
	if err := callback(update); err != nil {
		return fmt.Errorf("%w: recovery override rejected: %v", errInvalidPeerConfig, err)
	}
	resources.flexFECMutex.Lock()
	resources.recoveryPolicySequence = update.Sequence
	resources.mediaBitrateTarget = target
	resources.flexFECTransitions = append(resources.flexFECTransitions, RecoveryPolicyTransitionStats{
		Sequence: update.Sequence, Tier: flexFECTierName(update.Tier),
		MediaBitrateBitsPerSecond: target, Accepted: true,
	})
	resources.flexFECMutex.Unlock()
	return nil
}

func (resources *peerAPIResources) SetFlexFECNegotiation(negotiation flexFECNegotiation) {
	if resources == nil || resources.flexFECTier == nil {
		return
	}
	resources.flexFECMutex.Lock()
	resources.flexFECNegotiation = negotiation
	resources.flexFECNegotiated = negotiation.FlexFECPayloadType > 0 &&
		negotiation.RepairWindowMicroseconds > 0 && negotiation.TWCCExtensionID > 0 &&
		negotiation.MediaSSRC != 0 && negotiation.RTXSSRC != 0 && negotiation.FlexFECSSRC != 0
	negotiated := resources.flexFECNegotiated
	controller := resources.flexFECController
	resources.flexFECMutex.Unlock()
	if negotiated && controller != nil {
		if err := controller.Start(); err != nil {
			resources.reportRecoveryError(err)
		}
	}
	if resources.impairment != nil && negotiation.FlexFECPayloadType > 0 &&
		negotiation.FlexFECPayloadType <= 255 {
		resources.impairment.SetFlexFECIdentity(
			uint8(negotiation.FlexFECPayloadType), negotiation.FlexFECSSRC,
		)
	}
}

func (resources *peerAPIResources) FlexFECSnapshot() (*SessionFlexFECStats, *TWCCSnapshot) {
	if resources == nil || resources.flexFECTier == nil || resources.flexFECCounters == nil ||
		resources.twccHistory == nil {
		return nil, nil
	}
	tier := resources.flexFECTier.Load()
	counters := resources.flexFECCounters.Snapshot(tier)
	twcc := resources.twccHistory.Snapshot()
	resources.flexFECMutex.Lock()
	negotiation := resources.flexFECNegotiation
	transitions := append([]RecoveryPolicyTransitionStats(nil), resources.flexFECTransitions...)
	degradedReason := resources.flexFECDegradedReason
	controller := resources.flexFECController
	policySHA256 := resources.flexFECPolicySHA256
	retainedSHA256 := resources.flexFECRetainedSHA256
	policy := resources.flexFECPolicy
	configuredBudget := resources.configuredRTPBudget
	mediaBitrateTarget := resources.mediaBitrateTarget
	negotiated := resources.flexFECNegotiated
	budget := resources.recoveryBudget
	resources.flexFECMutex.Unlock()
	if degradedReason == "" {
		degradedReason = counters.DisableReason
	}
	var controllerStats *SessionFlexFECControllerStats
	if controller != nil {
		snapshot := controller.Snapshot()
		allowed := make([]string, len(snapshot.AllowedTiers))
		for index, allowedTier := range snapshot.AllowedTiers {
			allowed[index] = flexFECTierName(allowedTier)
		}
		controllerStats = &SessionFlexFECControllerStats{
			ControllerVersion: snapshot.ControllerVersion,
			PolicySHA256:      policySHA256, RetainedTiersSHA256: retainedSHA256,
			AllowedTiers: allowed, RequestedTier: flexFECTierName(snapshot.RequestedTier),
			TransitionSequence:  snapshot.TransitionSequence,
			AcceptedTransitions: snapshot.AcceptedTransitions,
			RejectedTransitions: snapshot.RejectedTransitions,
			LastReason:          snapshot.LastReason, LastError: snapshot.LastError,
			LastTransitionAge: snapshot.LastTransitionAge,
			RTTReady:          snapshot.RTTReady, Ready: snapshot.Ready,
			CompleteWindow:             snapshot.CompleteWindow,
			LastLossBasisPoints:        snapshot.LastLossBasisPoints,
			LastFinalizedPackets:       snapshot.LastFinalizedPackets,
			RepairLossCapped:           snapshot.RepairLossCapped,
			LastRepairLossBasisPoints:  snapshot.LastRepairLossBasisPoints,
			LastRepairFinalizedPackets: snapshot.LastRepairFinalizedPackets,
			Policy:                     snapshot.Policy,
		}
	}
	var budgetSnapshot *RecoveryBudgetSnapshot
	if budget != nil {
		snapshot := budget.Snapshot()
		budgetSnapshot = &snapshot
	}
	overrideBp, overridden := resources.flexFECOverride.Load()
	return &SessionFlexFECStats{
		Negotiated:               negotiated,
		OverrideBasisPoints:      overrideBp,
		Overridden:               overridden,
		PayloadType:              negotiation.FlexFECPayloadType,
		RepairWindowMicroseconds: negotiation.RepairWindowMicroseconds,
		TWCCExtensionID:          negotiation.TWCCExtensionID,
		MediaSSRC:                negotiation.MediaSSRC, RTXSSRC: negotiation.RTXSSRC,
		FlexFECSSRC:                      negotiation.FlexFECSSRC,
		Policy:                           flexFECPolicyName(policy),
		CurrentTier:                      flexFECTierName(tier),
		ConfiguredRTPBudgetBitsPerSecond: configuredBudget,
		MediaBitrateBitsPerSecond:        mediaBitrateTarget,
		Degraded:                         degradedReason != "", DegradedReason: degradedReason,
		Transitions: transitions, Controller: controllerStats,
		Budget:               budgetSnapshot,
		FlexFECStatsSnapshot: counters,
	}, &twcc
}

func (resources *peerAPIResources) disableFlexFEC(err error) {
	if resources == nil || err == nil {
		return
	}
	resources.flexFECMutex.Lock()
	first := resources.flexFECDegradedReason == ""
	if first {
		resources.flexFECDegradedReason = err.Error()
	}
	resources.flexFECMutex.Unlock()
	// FEC TURNING ITSELF OFF WAS COMPLETELY INVISIBLE, and that is why this line exists rather than
	// only the field above. The reason reached the stats JSON and nothing in rdev reads it, so a
	// session could negotiate FlexFEC, log `negotiated=true`, charge its ~5% of the media budget,
	// and protect nothing at all — with the only outward sign being a `recovery policy` line that
	// prints once at construction and never again, which is indistinguishable from a quiet link.
	//
	// Measured on a real iPad, 2026-08-20: H.265 at 5 PLI/s on a STILL window, keyframes exactly
	// equal to keyframe requests, tier never leaving 0. That is what a disabled FEC costs, and it
	// took two separate instruments to infer something one log line states.
	//
	// ONCE PER SESSION, on the first failure only: the callers are interceptor hot paths, and the
	// tier is set to Off on the same call, so a repeat is the same fact rather than a new one.
	if first {
		fmt.Printf("[bridge] recovery: FlexFEC disabled — %v\n", err)
	}
}

// flexFECIsDegraded reports whether FEC has disabled itself on this session.
//
// SEPARATE FROM THE SDP CHOICE, which is what makes it worth having: `activeRecovery` is settled from
// the answer, while `fec.fail` runs inside the interceptor a layer below. They can disagree, and the
// client's `no FEC` cell exists to show exactly that disagreement.
func (resources *peerAPIResources) flexFECIsDegraded() bool {
	if resources == nil {
		return false
	}
	resources.flexFECMutex.Lock()
	defer resources.flexFECMutex.Unlock()
	return resources.flexFECDegradedReason != ""
}

func (resources *peerAPIResources) ResponderCacheSnapshot() ResponderCacheSnapshot {
	if resources.responderCache == nil {
		return ResponderCacheSnapshot{}
	}
	return resources.responderCache.Snapshot()
}

func (resources *peerAPIResources) MediaRTTSnapshot() (time.Duration, uint64, bool) {
	return resources.mediaRTT.Snapshot()
}

func (resources *peerAPIResources) RTXAgePolicySnapshot() *RTXAgePolicySnapshot {
	if resources == nil || resources.rtxAgePolicy == nil {
		return nil
	}
	snapshot := resources.rtxAgePolicy.Snapshot()
	return &snapshot
}

func (resources *peerAPIResources) ActivateImpairment() error {
	if resources.impairment == nil {
		return fmt.Errorf("%w: impairment is not configured", errInvalidPeerConfig)
	}
	return resources.impairment.Activate()
}

func (resources *peerAPIResources) ResetImpairmentMeasurement(timeout time.Duration) error {
	if resources.impairment == nil {
		return fmt.Errorf("%w: impairment is not configured", errInvalidPeerConfig)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return resources.impairment.ResetMeasurement(ctx)
}

func (resources *peerAPIResources) ImpairmentSnapshot() *RecoveryImpairmentSnapshot {
	if resources.impairment == nil {
		return nil
	}
	snapshot := resources.impairment.Snapshot()
	return &snapshot
}

func (resources *peerAPIResources) DrainImpairment(timeout time.Duration) error {
	if resources.impairment != nil {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		if err := resources.impairment.DeactivateAndWaitForDrain(ctx); err != nil {
			return err
		}
		resources.impairment.ReconcileQueueLossAfterDrain()
	}
	if resources.responderFactory != nil {
		resources.responderFactory.DrainCache()
	}
	cache := resources.ResponderCacheSnapshot()
	if cache.PacketsCurrent != 0 || cache.BytesCurrent != 0 {
		return fmt.Errorf("recovery responder cache did not drain: %#v", cache)
	}
	return nil
}

func (resources *peerAPIResources) Close() error {
	resources.closeOnce.Do(func() {
		var closeErrors []error
		resources.flexFECMutex.Lock()
		controller := resources.flexFECController
		resources.flexFECMutex.Unlock()
		if controller != nil {
			closeErrors = appendCloseError(closeErrors, controller.Close())
		}
		if resources.udpMux != nil {
			closeErrors = appendCloseError(closeErrors, resources.udpMux.Close())
		}
		if resources.impairment != nil {
			closeErrors = appendCloseError(closeErrors, resources.impairment.Close())
		}
		if resources.twccHistory != nil {
			closeErrors = appendCloseError(closeErrors, resources.twccHistory.Close())
		}
		resources.closeErr = errors.Join(closeErrors...)
	})
	return resources.closeErr
}

func (resources *peerAPIResources) CloseFlexFECController() error {
	if resources == nil {
		return nil
	}
	resources.flexFECMutex.Lock()
	controller := resources.flexFECController
	resources.flexFECMutex.Unlock()
	if controller == nil {
		return nil
	}
	return controller.Close()
}

// sctpRTOMax CAPS SCTP'S RETRANSMISSION TIMEOUT, and with it the exponential BACKOFF (docs/engine.md,
// "SCTP's backoff is capped"). pion's default ceiling is 60 s: a message outstanding through a few
// seconds of outage waited out the doubled timer AFTER the network came back — the terminal and
// control channels silent behind a connection that read "connected" (an ICE restart keeps the
// association). libwebrtc caps its own backoff at 3 s for the same reason (dcsctp_transport.cc,
// kMaxTimerBackoffDuration). It also caps the RTO itself, so a path whose RTT exceeds it retransmits
// early — harmless at that size.
const sctpRTOMax = 3 * time.Second

// hostPacketConnForTests, when set, wraps the ICE socket every newPeerAPI binds: the one seam a test
// has for cutting a pair's network outright (TestAMessageSentIntoAnOutageArrivesSoonAfterIt). nil in
// production, and never set outside a _test.go file.
var hostPacketConnForTests func(net.PacketConn) net.PacketConn

func newPeerAPI(config PeerConfig) (*webrtc.API, *peerAPIResources, error) {
	if err := config.Validate(); err != nil {
		return nil, nil, err
	}
	localIP := append(net.IP(nil), config.LocalIP.To4()...)
	remoteIP := append(net.IP(nil), config.RemoteIP.To4()...)

	mediaEngine := &webrtc.MediaEngine{}
	// REGISTERED IN rdev's PREFERENCE ORDER. pion emits codecs in registration order, so this IS
	// the offer's order — but the ANSWER's order is the answerer's preference, and rdev re-imposes
	// its own at bind time (FrameTrack.Bind). Registering in order is what makes the offer honest
	// about what rdev would rather send; Bind is what makes it true.
	for _, profile := range videoCodecProfiles() {
		codec := webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    profile.mimeType,
				ClockRate:   90_000,
				SDPFmtpLine: profile.fmtpLine,
			},
			PayloadType: webrtc.PayloadType(profile.payloadType),
		}
		if nackRTXEnabled(config.Recovery) {
			codec.RTCPFeedback = []webrtc.RTCPFeedback{
				{Type: "nack"},
				{Type: "nack", Parameter: "pli"},
			}
			if config.Recovery == RecoveryNACKRTXFlexFEC {
				codec.RTCPFeedback = append(codec.RTCPFeedback, webrtc.RTCPFeedback{
					Type: webrtc.TypeRTCPFBTransportCC,
				})
			}
		}
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, nil, fmt.Errorf("register %s: %w", profile.mimeType, err)
		}
		if nackRTXEnabled(config.Recovery) {
			rtx := webrtc.RTPCodecParameters{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeRTX, ClockRate: 90_000,
					SDPFmtpLine: fmt.Sprintf("apt=%d", profile.payloadType),
				},
				PayloadType: webrtc.PayloadType(profile.rtxPayloadType),
			}
			if err := mediaEngine.RegisterCodec(rtx, webrtc.RTPCodecTypeVideo); err != nil {
				return nil, nil, fmt.Errorf("register %s RTX: %w", profile.mimeType, err)
			}
		}
	}
	if config.Recovery == RecoveryNACKRTXFlexFEC {
		if err := registerFlexFEC03(mediaEngine); err != nil {
			return nil, nil, fmt.Errorf("register FlexFEC-03: %w", err)
		}
	}

	// OPUS, AND WITHOUT RTCP FEEDBACK ON PURPOSE.
	//
	// Registering nack or transport-cc here would put those strings in the AUDIO section of every
	// offer, and validateLegacyRecoverySDP rejects "transport-cc" anywhere in an SDP under the
	// legacy recovery modes — so rdev would fail its own session with a message about FlexFEC, for
	// a fault that is neither FlexFEC's nor video's. Audio needs none of it either way: Opus carries
	// in-band FEC and the receiver's own concealment.
	//
	// REGISTERED UNCONDITIONALLY, not behind a recovery mode. Every source gets an audio track (see
	// AddSourceTracks), so a session that could not offer Opus could not add a source at all.
	if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   audioClockRate,
			Channels:    2,
			SDPFmtpLine: audioOpusFMTP,
		},
		PayloadType: webrtc.PayloadType(audioOpusPayloadType),
	}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, nil, fmt.Errorf("register Opus: %w", err)
	}
	if err := mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: frameMetadataURI},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		return nil, nil, fmt.Errorf("register frame metadata extension: %w", err)
	}
	if err := mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: playoutDelayURI},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		return nil, nil, fmt.Errorf("register playout-delay extension: %w", err)
	}
	if err := mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: dependencyDescriptorURI},
		webrtc.RTPCodecTypeVideo,
	); err != nil {
		return nil, nil, fmt.Errorf("register dependency-descriptor extension: %w", err)
	}
	if config.Recovery == RecoveryNACKRTXFlexFEC {
		if err := mediaEngine.RegisterHeaderExtension(
			webrtc.RTPHeaderExtensionCapability{URI: twccURI},
			webrtc.RTPCodecTypeVideo,
		); err != nil {
			return nil, nil, fmt.Errorf("register TWCC extension: %w", err)
		}
	}

	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settingEngine.SetSCTPRTOMax(sctpRTOMax)
	// Parsed HERE because this is the function that owns the audit, so the count that is recorded and
	// the servers that are registered cannot come from two different reads of the same string.
	// Validate already rejected malformed JSON; the error is returned rather than discarded anyway.
	// The deleted bridge wrote `_ = json.Unmarshal`, so a malformed value silently yielded no servers
	// and surfaced later as "no relay candidates" — a cause one layer away from its symptom.
	var iceServers []webrtc.ICEServer
	if config.ICEServersJSON != "" {
		if err := json.Unmarshal([]byte(config.ICEServersJSON), &iceServers); err != nil {
			return nil, nil, fmt.Errorf("%w: ice servers JSON: %v", errInvalidPeerConfig, err)
		}
	}
	includeLoopback := false
	multicastDNSDisabled := false
	// THE MUX BIND ADDRESS IS PART OF THE POLICY. Removing SetIPFilter without this achieves
	// nothing: SetICEUDPMux makes pion gather on that socket alone, so a mux bound to one address
	// gathers one address whatever the filter says.
	muxBindIP := localIP
	switch config.ICEPolicy {
	case ICEPolicyStrict:
		settingEngine.SetIPFilter(func(candidate net.IP) bool { return candidate.Equal(localIP) })
		settingEngine.SetRemoteIPFilter(func(candidate net.IP) bool { return candidate.Equal(remoteIP) })
		settingEngine.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
		multicastDNSDisabled = true
		includeLoopback = localIP.IsLoopback()
	case ICEPolicyLAN:
		// NO IP FILTERS: gather on every interface, accept a candidate from anywhere. That is what
		// makes an off-machine browser possible at all — its candidates carry ITS address, and every
		// TURN relay candidate carries the RELAY's.
		//
		// QueryOnly RESOLVES Chrome's mDNS-obfuscated host candidate without advertising our own, so
		// the winning pair can be host-to-host instead of peer-reflexive. pion holds ~1s before
		// nominating a prflx pair (defaultPrflxAcceptanceMinWait), so this is a connect-time
		// difference, not a correctness one — if resolution does not work, the prflx path still
		// connects and that is the measured fallback rather than a redesign.
		settingEngine.SetICEMulticastDNSMode(ice.MulticastDNSModeQueryOnly)
		// The mux is KEPT rather than dropped in favour of pion's own gathering, because
		// config.Impairment.wrapHostPacketConn wraps exactly this connection — that is how the
		// certification impairs a session, and dropping the mux would silently disarm it.
		//
		// THREE THINGS ABOUT AN UNSPECIFIED BIND, checked against pion/ice v4.2.7's udp_mux.go
		// rather than assumed, because the library explicitly warns about it:
		//
		//   1. IT WORKS. NewUDPMuxDefault detects the unspecified address, enumerates the real local
		//      interfaces (localInterfaces) and synthesises one candidate address per interface, all
		//      sharing this socket's port. That is exactly what lan needs.
		//   2. IT LOGS A WARNING ON EVERY SESSION — "UDPMuxDefault should not listening on
		//      unspecified address, use NewMultiUDPMuxFromPort instead". Expected, not a defect.
		//   3. THE RECOMMENDED ALTERNATIVE IS UNUSABLE HERE. NewMultiUDPMuxFromPort opens its OWN
		//      socket per interface, so wrapHostPacketConn would have nothing to wrap and the
		//      impairment harness would go inert — the same trap as dropping the mux, one step down.
		//
		// THE REAL RISK IS A MULTI-INTERFACE HOST: with one unspecified socket, outbound packets
		// leave from whatever source address routing picks, which may not match the candidate the
		// peer is probing. ICE tries every pair so the matching one still wins — which is why pion's
		// own comment notes that many applications already do this — but on a machine with Wi-Fi,
		// Ethernet and a VPN some checks fail spuriously and connect slower. FIRST SUSPECT if the
		// manual LAN gate misbehaves on a docked machine.
		muxBindIP = net.IPv4zero
		// lan means pion's defaults, and pion's default excludes loopback. Decided rather than
		// inherited from LocalIP, which no longer restricts gathering under this policy.
		includeLoopback = false
	}
	settingEngine.SetIncludeLoopbackCandidate(includeLoopback)
	settingEngine.DisableActiveTCP(true)
	settingEngine.SetReceiveMTU(1_500)
	if config.Network != nil {
		settingEngine.SetNet(config.Network)
	}

	resources := &peerAPIResources{
		counters:       &RecoveryCounters{},
		responderCache: &ResponderCacheCounters{},
		impairment:     config.Impairment,
	}
	if config.Recovery == RecoveryNACKRTXFlexFEC {
		var egressErr error
		resources.recoveryEgressBudget, egressErr = NewRecoveryFrameClockBudget(
			RecoveryFrameClockBudgetConfig{
				RateBitsPerSecond: config.TotalRTPBudgetBitsPerSecond,
				FramesPerSecond:   config.FramesPerSecond,
				BurstDuration:     defaultRecoveryFrameClockBurstDuration,
			},
		)
		if egressErr != nil {
			return nil, nil, fmt.Errorf("create recovery egress budget: %w", egressErr)
		}
	}
	if nackRTXEnabled(config.Recovery) {
		resources.mediaRTT = &mediaRTTEstimator{}
		var policyErr error
		resources.rtxAgePolicy, policyErr = NewRTXAgePolicy(
			(SessionConfiguration{
				RTXMaxAge: config.RTXMaxAge, RTXAgeMode: config.RTXAgeMode,
				RTXAgeMultiplierMilli: config.RTXAgeMultiplierMilli,
				RTXAgeCap:             config.RTXAgeCap,
			}).rtxAgePolicyConfig(),
			resources.mediaRTT,
		)
		if policyErr != nil {
			return nil, nil, fmt.Errorf("create RTX age policy: %w", policyErr)
		}
	}
	resources.iceServers = iceServers
	resources.audit = PeerConstructionAudit{
		CodecMimeType:                    webrtc.MimeTypeAV1,
		CodecClockRate:                   90_000,
		PayloadType:                      av1PayloadType,
		HeaderExtensionURI:               frameMetadataURI,
		PlayoutDelayExtensionURI:         playoutDelayURI,
		DependencyDescriptorExtensionURI: dependencyDescriptorURI,
		NetworkType:                      webrtc.NetworkTypeUDP4.String(),
		LocalIP:                          localIP.String(),
		RemoteIP:                         remoteIP.String(),
		ICEPolicy:                        string(config.ICEPolicy),
		IncludeLoopback:                  includeLoopback,
		MuxBindAddress:                   muxBindIP.String(),
		ICEServers:                       len(iceServers),
		MulticastDNSDisabled:             multicastDNSDisabled,
		ActiveTCPDisabled:                true,
		ReceiveMTU:                       1_500,
		HostUsesConfiguredMux:            true,
		NACK:                             nackRTXEnabled(config.Recovery),
		RTX:                              nackRTXEnabled(config.Recovery),
		RTXMaxAgeMilliseconds: int((SessionConfiguration{
			RTXMaxAge: config.RTXMaxAge, RTXAgeMode: config.RTXAgeMode,
			RTXAgeMultiplierMilli: config.RTXAgeMultiplierMilli,
			RTXAgeCap:             config.RTXAgeCap,
		}).negotiatedRTXTime() / time.Millisecond),
		FEC:                             config.Recovery == RecoveryNACKRTXFlexFEC,
		TWCC:                            config.Recovery == RecoveryNACKRTXFlexFEC,
		SenderReports:                   true,
		RecoveryEgressAdmission:         resources.recoveryEgressBudget != nil,
		TotalRTPBudgetBitsPerSecond:     config.TotalRTPBudgetBitsPerSecond,
		RecoveryEgressBurstMilliseconds: int(defaultRecoveryFrameClockBurstDuration / time.Millisecond),
	}
	registry := &interceptor.Registry{}
	interceptorOrder := []string{"sender-reports"}
	senderReports, err := report.NewSenderInterceptor()
	if err != nil {
		return nil, nil, fmt.Errorf("create RTCP sender-report interceptor: %w", err)
	}
	registry.Add(senderReports)
	if config.Recovery == RecoveryNACKRTXFlexFEC {
		history, err := NewTWCCPacketHistory(TWCCPacketHistoryConfig{
			ReorderingGrace: config.TWCCReorderingGrace,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("create TWCC history: %w", err)
		}
		resources.twccHistory = history
		resources.transportAllocator = NewTransportSequenceAllocator()
		resources.flexFECCounters = NewFlexFECCounters(nil)
		resources.flexFECTier = NewFlexFECTierStore(FlexFECTierOff, resources.flexFECCounters)
		resources.flexFECOverride = NewFlexFECOverrideStore()
		fecFactory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
			Tier:         resources.flexFECTier,
			Override:     resources.flexFECOverride,
			Allocator:    resources.transportAllocator,
			History:      resources.twccHistory,
			Counters:     resources.flexFECCounters,
			EgressBudget: resources.recoveryEgressBudget,
			Disable:      resources.disableFlexFEC,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("create frame-aware FlexFEC: %w", err)
		}
		registry.Add(fecFactory)
		registry.Add(NewTWCCHeaderInjector(
			resources.transportAllocator, resources.twccHistory,
			resources.recoveryEgressBudget,
		))
		interceptorOrder = append(
			interceptorOrder,
			"twcc-history", "frame-aware-flexfec", "twcc-header-injector",
		)
	}
	if nackRTXEnabled(config.Recovery) {
		responder, err := NewAgeAwareNACKResponder(AgeAwareResponderConfig{
			AgePolicy: resources.rtxAgePolicy, Counters: resources.counters,
			CacheCounters:   resources.responderCache,
			ObserveNACK:     resources.observeRecoveryNACK,
			RequestKeyframe: resources.requestRecoveryKeyframe,
			RequestRecovery: resources.requestReferenceRecoveryWithReason,
			ReportError:     resources.reportRecoveryError,
			Trace:           config.Trace,
			MediaRTT:        resources.mediaRTT,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("create NACK responder: %w", err)
		}
		resources.responderFactory = responder
		generator, err := nack.NewGeneratorInterceptor(
			nack.GeneratorInterval(nackInspectionInterval),
			nack.GeneratorMaxNacksPerPacket(3),
		)
		if err != nil {
			return nil, nil, fmt.Errorf("create NACK generator: %w", err)
		}
		observer := NewRecoveryObserver(resources.counters, func() {
			resources.rtxNegotiated.Store(true)
		}, config.Trace).WithImpairment(config.Impairment)
		resources.observerFactory = observer
		registry.Add(observer)
		interceptorOrder = append(interceptorOrder, "recovery-observer")
		receiverRTTResponder := NewReceiverRTTResponder(ReceiverRTTResponderConfig{
			ReportError: resources.reportRecoveryError,
			Counters:    resources.counters,
			MediaRTT:    resources.mediaRTT,
		})
		settingEngine.BufferFactory = receiverRTTResponder.NewPacketBuffer
		registry.Add(receiverRTTResponder)
		registry.Add(responder)
		registry.Add(generator)
		interceptorOrder = append(
			interceptorOrder, "receiver-rtt", "age-aware-nack-responder", "nack-generator",
		)
	}
	resources.audit.InterceptorOrder = interceptorOrder
	// muxBindIP is policy-decided; see the switch above.
	var connection net.PacketConn
	var listenErr error
	if config.Network == nil {
		connection, listenErr = net.ListenUDP(
			"udp4", &net.UDPAddr{IP: muxBindIP, Port: int(config.ICEPort)},
		)
	} else {
		connection, listenErr = config.Network.ListenPacket(
			"udp4", net.JoinHostPort(muxBindIP.String(), strconv.Itoa(int(config.ICEPort))),
		)
	}
	if listenErr != nil {
		return nil, nil, fmt.Errorf("bind host ICE UDP mux: %w", listenErr)
	}
	if config.Impairment != nil {
		connection = config.Impairment.wrapHostPacketConn(connection)
	}
	if hostPacketConnForTests != nil {
		connection = hostPacketConnForTests(connection)
	}
	// RDEV_TEST_DATA_LINK_* (rdev_test_data_link.go): a TEST link — rate, delay, loss — for the data channels; unset,
	// nothing.
	if testDataLinkSettings.active() {
		connection = newTestDataLink(connection, testDataLinkSettings)
	}
	resources.udpMux = ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: connection})
	settingEngine.SetICEUDPMux(resources.udpMux)

	api := webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithSettingEngine(settingEngine),
		webrtc.WithInterceptorRegistry(registry),
	)
	return api, resources, nil
}

func (resources *peerAPIResources) SetReferenceRecoveryCallback(callback func(uint32, string, bool)) {
	resources.callbackMutex.Lock()
	resources.recoveryRequest = callback
	resources.callbackMutex.Unlock()
}
func (resources *peerAPIResources) requestReferenceRecoveryWithReason(ssrc uint32, reason string, independent bool) {
	resources.callbackMutex.RLock()
	callback := resources.recoveryRequest
	resources.callbackMutex.RUnlock()
	if callback == nil {
		resources.requestRecoveryKeyframe(ssrc)
		return
	}
	callback(ssrc, reason, independent)
	if resources.impairment != nil {
		resources.impairment.ResolveRecovery()
	}
}
