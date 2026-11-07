package main

import (
	"bytes"
	"errors"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestPeerPolicyRejectsInvalidConfiguration(t *testing.T) {
	validHost := PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"),
		RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: 57_00, SignalPort: 57_01,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	}
	tests := []struct {
		name   string
		mutate func(*PeerConfig)
	}{
		{"IPv6 local", func(config *PeerConfig) { config.LocalIP = net.ParseIP("::1") }},
		{"unspecified local", func(config *PeerConfig) { config.LocalIP = net.IPv4zero }},
		{"IPv6 remote", func(config *PeerConfig) { config.RemoteIP = net.ParseIP("::1") }},
		{"unspecified remote", func(config *PeerConfig) { config.RemoteIP = net.IPv4zero }},
		{"zero signal port", func(config *PeerConfig) { config.SignalPort = 0 }},
		{"zero host ICE port", func(config *PeerConfig) { config.ICEPort = 0 }},
		{"equal host ports", func(config *PeerConfig) { config.ICEPort = config.SignalPort }},
		{"missing recovery", func(config *PeerConfig) { config.Recovery = 0 }},
		{"zero RTX age", func(config *PeerConfig) { config.RTXMaxAge = 0 }},
		{"sub-millisecond RTX age", func(config *PeerConfig) { config.RTXMaxAge = time.Microsecond }},
		{"fractional RTX age", func(config *PeerConfig) { config.RTXMaxAge = 30*time.Millisecond + time.Microsecond }},
		{"large RTX age", func(config *PeerConfig) { config.RTXMaxAge = time.Second + time.Millisecond }},
		{"unknown RTX age mode", func(config *PeerConfig) { config.RTXAgeMode = 3 }},
		{"RTT age missing cap", func(config *PeerConfig) {
			config.RTXAgeMode = RTXAgeRTT
			config.RTXAgeMultiplierMilli = 1_250
		}},
		{"RTT age cap below floor", func(config *PeerConfig) {
			config.RTXAgeMode = RTXAgeRTT
			config.RTXAgeMultiplierMilli = 1_250
			config.RTXAgeCap = 20 * time.Millisecond
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := validHost
			test.mutate(&config)
			if config.Impairment != nil {
				t.Cleanup(func() { _ = config.Impairment.Close() })
			}
			if err := config.Validate(); err == nil {
				t.Fatalf("invalid config unexpectedly passed: %#v", config)
			}
		})
	}

	if err := validHost.Validate(); err != nil {
		t.Fatalf("valid loopback host config failed: %v", err)
	}
	invalidFlex := validHost
	invalidFlex.Recovery = RecoveryNACKRTXFlexFEC
	if err := invalidFlex.Validate(); err == nil {
		t.Fatal("FlexFEC peer without a total RTP budget passed")
	}
	invalidLegacy := validHost
	invalidLegacy.TotalRTPBudgetBitsPerSecond = 8_000_000
	if err := invalidLegacy.Validate(); err == nil {
		t.Fatal("non-FlexFEC peer with a total RTP budget passed")
	}
}

func TestRecoveryTraceHooksPeerConfigThreadsOneRecorder(t *testing.T) {
	port := reserveUDPPort(t)
	recorder := newIncrementingRecoveryTraceRecorder(16)
	_, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"),
		RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
		Trace: recorder,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	if resources.responderFactory == nil || resources.responderFactory.config.Trace != recorder {
		t.Fatal("responder did not receive the peer recorder")
	}
	if resources.observerFactory == nil || resources.observerFactory.trace != recorder {
		t.Fatal("receiver observer did not receive the peer recorder")
	}
}

func TestPeerRTTAgePolicySharesEstimatorAndAdvertisesCap(t *testing.T) {
	port := reserveUDPPort(t)
	_, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: port, SignalPort: port + 1, Recovery: RecoveryNACKRTX,
		RTXMaxAge: 30 * time.Millisecond, RTXAgeMode: RTXAgeRTT,
		RTXAgeMultiplierMilli: 1_250, RTXAgeCap: 300 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	if resources.rtxAgePolicy == nil || resources.rtxAgePolicy.mediaRTT != resources.mediaRTT {
		t.Fatal("RTX age policy does not share the peer media RTT estimator")
	}
	if resources.responderFactory.config.AgePolicy != resources.rtxAgePolicy {
		t.Fatal("responder does not use the peer RTX age policy")
	}
	if resources.audit.RTXMaxAgeMilliseconds != 300 {
		t.Fatalf("negotiated audit RTX time = %d", resources.audit.RTXMaxAgeMilliseconds)
	}
}

func TestRTXFMTPAdvertisesExactRetentionMilliseconds(t *testing.T) {
	for _, test := range []struct {
		age  time.Duration
		want string
	}{
		{age: time.Millisecond, want: "apt=45;rtx-time=1"},
		{age: 30 * time.Millisecond, want: "apt=45;rtx-time=30"},
		{age: 125 * time.Millisecond, want: "apt=45;rtx-time=125"},
		{age: time.Second, want: "apt=45;rtx-time=1000"},
	} {
		if got := rtxFMTP(av1PayloadType, test.age); got != test.want {
			t.Fatalf("rtxFMTP(45, %s) = %q, want %q", test.age, got, test.want)
		}
	}
}

func TestDependencyDescriptorHeaderExtensionIsOfferedAndRequired(t *testing.T) {
	const uri = "https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension"
	port := reserveUDPPort(t)
	api, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	peer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.Close() })
	if _, err := peer.AddTransceiverFromKind(
		webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		t.Fatal(err)
	}
	offer, err := peer.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(offer.SDP, uri) {
		t.Fatalf("dependency descriptor missing from offer:\n%s", offer.SDP)
	}

	without := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:0\r\n",
	}
	if _, err := preparePionRemoteDescription(without, 30*time.Millisecond, false); err == nil {
		t.Fatal("answer without dependency descriptor unexpectedly accepted")
	}
	with := without
	with.SDP += "a=extmap:7 " + uri + "\r\n"
	if _, err := preparePionRemoteDescription(with, 30*time.Millisecond, false); err != nil {
		t.Fatalf("answer with dependency descriptor rejected: %v", err)
	}
}

func TestPionRemoteDescriptionValidatesWireRTXTimeAndNormalizesEngineCopy(t *testing.T) {
	original := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: dependencyDescriptorTestSDP("a=fmtp:45 profile=main\r\n" +
			"a=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45;rtx-time=30\r\n",
		),
	}
	prepared, err := preparePionRemoteDescription(original, 30*time.Millisecond, true)
	if err != nil {
		t.Fatal(err)
	}
	if prepared.SDP != dependencyDescriptorTestSDP("a=fmtp:45 profile=main\r\n"+
		"a=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n") {
		t.Fatalf("Pion engine SDP = %q", prepared.SDP)
	}
	if !strings.Contains(original.SDP, "apt=45;rtx-time=30") {
		t.Fatalf("wire SDP was mutated: %q", original.SDP)
	}

	aptOnlyOffer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: dependencyDescriptorTestSDP(
			"a=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n",
		),
	}
	prepared, err = preparePionRemoteDescription(aptOnlyOffer, 30*time.Millisecond, false)
	if err != nil || prepared != aptOnlyOffer {
		t.Fatalf("apt-only offer preparation = %#v, %v", prepared, err)
	}
}

func TestAdvertiseRTXTimeLeavesPionLocalDescriptionUntouched(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  "v=0\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n",
	}
	wire, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if wire.SDP != "v=0\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45;rtx-time=30\r\n" {
		t.Fatalf("wire SDP = %q", wire.SDP)
	}
	if strings.Contains(local.SDP, "rtx-time") {
		t.Fatalf("Pion local SDP was mutated: %q", local.SDP)
	}
}

// Two video m-sections carrying the SAME RTX payload type is what a session with more than one
// video track produces, because pion assigns payload types per description and not per section.
// advertiseRTXTime used to track its duplicate set across the whole description and rejected it as
// `duplicate local RTX fmtp`, which made CreateOffer fail the moment a second track existed — and
// at N=1 through rdev's slot-keyed collection there are already two (assembleSession's eager track
// plus one AddVideoTrack).
func TestAdvertiseRTXTimeAcceptsTheSameRTXPayloadTypeInEachMSection(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: "v=0\r\n" +
			"m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n" +
			"m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n",
	}
	wire, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("two video m-sections were rejected: %v", err)
	}
	if got := strings.Count(wire.SDP, "apt=45;rtx-time=30"); got != 2 {
		t.Fatalf("rtx-time advertised %d times, want once per section:\n%s", got, wire.SDP)
	}
}

// The other half of the same change: making the duplicate check per-section must not disarm it.
// Two fmtp lines for ONE payload type INSIDE one m-section is a malformed section, which is what
// the check was written for, and it is still refused.
func TestAdvertiseRTXTimeStillRejectsADuplicateWithinOneMSection(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: "v=0\r\n" +
			"m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\n" +
			"a=fmtp:46 apt=45\r\na=fmtp:46 apt=45\r\n",
	}
	_, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err == nil {
		t.Fatal("a duplicate RTX fmtp inside one m-section was accepted")
	}
	if !strings.Contains(err.Error(), "duplicate local RTX fmtp") {
		t.Fatalf("error = %q, want it to name the duplicate", err)
	}
}

// The per-section reset must NOT be the thing the final "missing local RTX fmtp" check reads, or a
// video section followed by any other m-section — an `m=application` data section, which every
// offer this session builds has — would report the RTX fmtp missing after it had been applied.
// That is a bug the reset introduces if `found` is reused for both jobs.
func TestAdvertiseRTXTimeAcceptsAVideoSectionFollowedByADataSection(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: "v=0\r\n" +
			"m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45\r\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n",
	}
	wire, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("a video section followed by a data section was rejected: %v", err)
	}
	if !strings.Contains(wire.SDP, "apt=45;rtx-time=30") {
		t.Fatalf("rtx-time was not advertised:\n%s", wire.SDP)
	}
}

// A description with no RTX fmtp at all is STILL refused, unchanged. That is the data-channels-only
// offer rdev's own bridge sends first, and the deliberate default is to fail rather than negotiate a
// retransmission window the remote was never told about — see advertiseRTXTime's comment.
func TestAdvertiseRTXTimeStillRejectsADescriptionWithNoRTXFMTP(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: "v=0\r\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n",
	}
	_, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err == nil {
		t.Fatal("a description with no RTX fmtp was accepted")
	}
	if !strings.Contains(err.Error(), "missing local RTX fmtp") {
		t.Fatalf("error = %q, want it to name the missing fmtp", err)
	}
}

// The dependency-descriptor extmap repeats once per video m-section in a two-track description, and
// videoHeaderExtensionID used to read the second occurrence as a duplicate. Because
// preparePionRemoteDescription calls it on EVERY remote description, that made SetAnswer fail on any
// answer to a two-track offer — the same N=1 blocker as the RTX fmtp above, on the inbound side.
// The inbound counterpart of TestAdvertiseRTXTimeAcceptsTheSameRTXPayloadTypeInEachMSection.
// preparePionRemoteDescription tracked its RTX associations across the whole description, so an
// ANSWER to a two-track offer failed with `invalid RTX association` — which is what SetAnswer would
// have reported at N=1 through rdev's slot-keyed collection.
func TestPreparePionRemoteDescriptionAcceptsRTXInEachMSection(t *testing.T) {
	section := "m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
		"a=extmap:11 " + dependencyDescriptorURI + "\r\n" +
		"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45;rtx-time=30\r\n"
	remote := webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: "v=0\r\n" + section + section}
	prepared, err := preparePionRemoteDescription(remote, 30*time.Millisecond, true)
	if err != nil {
		t.Fatalf("an answer with two video m-sections was rejected: %v", err)
	}
	// rtx-time is pion-invisible and must be stripped from BOTH sections, not just the first.
	if strings.Contains(prepared.SDP, "rtx-time") {
		t.Fatalf("rtx-time survived into the prepared description:\n%s", prepared.SDP)
	}
	if got := strings.Count(prepared.SDP, "a=fmtp:46 apt=45"); got != 2 {
		t.Fatalf("apt survived in %d sections, want 2:\n%s", got, prepared.SDP)
	}
}

// Making the association set per-section must not disarm the duplicate check inside one section.
func TestPreparePionRemoteDescriptionStillRejectsADuplicateRTXWithinOneMSection(t *testing.T) {
	remote := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=extmap:11 " + dependencyDescriptorURI + "\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\n" +
			"a=fmtp:46 apt=45;rtx-time=30\r\na=fmtp:46 apt=45;rtx-time=30\r\n",
	}
	_, err := preparePionRemoteDescription(remote, 30*time.Millisecond, true)
	if err == nil {
		t.Fatal("two RTX fmtp lines for one payload type inside one m-section were accepted")
	}
	if !strings.Contains(err.Error(), "invalid RTX association") {
		t.Fatalf("error = %q, want it to name the association", err)
	}
}

// requireRTXTime must still fire when NO section carries an association, which is what the
// per-section reset would break if the same map were used for both jobs. The data section after the
// video one is what makes the reset observable.
func TestPreparePionRemoteDescriptionStillRequiresRTXWhenAsked(t *testing.T) {
	remote := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\n" +
			"a=extmap:11 " + dependencyDescriptorURI + "\r\na=rtpmap:45 AV1/90000\r\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n",
	}
	if _, err := preparePionRemoteDescription(remote, 30*time.Millisecond, true); err == nil {
		t.Fatal("an answer with no RTX association was accepted while RTX was required")
	}
}

// And it must NOT fire when a video section DID carry one and another m-section follows it — the
// false-negative the reset introduces if the cumulative count is dropped.
func TestPreparePionRemoteDescriptionAcceptsRTXBeforeADataSection(t *testing.T) {
	remote := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
			"a=extmap:11 " + dependencyDescriptorURI + "\r\n" +
			"a=rtpmap:45 AV1/90000\r\na=rtpmap:46 rtx/90000\r\na=fmtp:46 apt=45;rtx-time=30\r\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n",
	}
	if _, err := preparePionRemoteDescription(remote, 30*time.Millisecond, true); err != nil {
		t.Fatalf("a video section carrying RTX followed by a data section was rejected: %v", err)
	}
}

func TestVideoHeaderExtensionIDAcceptsTheSameIDInEachMSection(t *testing.T) {
	sdp := "v=0\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45\r\na=extmap:11 " + dependencyDescriptorURI + "\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45\r\na=extmap:11 " + dependencyDescriptorURI + "\r\n"
	id, err := videoHeaderExtensionID(sdp, dependencyDescriptorURI)
	if err != nil {
		t.Fatalf("two video m-sections were rejected: %v", err)
	}
	if id != 11 {
		t.Fatalf("extension id = %d, want 11", id)
	}
}

// The check must not be disarmed by making it per-section: twice for one URI INSIDE one section is
// what it was written to catch.
//
// BOTH EXTMAPS CARRY THE SAME ID, DELIBERATELY, and that is the whole value of this test. An
// earlier version used ids 11 and 12, which the CROSS-SECTION agreement check catches on its own —
// so it passed with the per-section duplicate flag entirely dead (proved by deleting the line that
// sets it). With the same id twice, the per-section flag is the only thing that can refuse it.
func TestVideoHeaderExtensionIDStillRejectsADuplicateWithinOneMSection(t *testing.T) {
	sdp := "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\n" +
		"a=extmap:11 " + dependencyDescriptorURI + "\r\n" +
		"a=extmap:11 " + dependencyDescriptorURI + "\r\n"
	if _, err := videoHeaderExtensionID(sdp, dependencyDescriptorURI); err == nil {
		t.Fatal("two extmaps for one URI inside one m-section were accepted")
	}
}

// The same duplicate with DIFFERENT ids inside one section, which the cross-section agreement check
// also refuses. Kept as its own case because the two branches are independent and either could be
// removed without the other noticing.
func TestVideoHeaderExtensionIDRejectsDisagreeingIDsWithinOneMSection(t *testing.T) {
	sdp := "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\n" +
		"a=extmap:11 " + dependencyDescriptorURI + "\r\n" +
		"a=extmap:12 " + dependencyDescriptorURI + "\r\n"
	if _, err := videoHeaderExtensionID(sdp, dependencyDescriptorURI); err == nil {
		t.Fatal("two extmaps with different ids for one URI inside one m-section were accepted")
	}
}

// Sections that DISAGREE on the id are refused, which is what keeps a single return value honest.
// RFC 8843 requires extmap ids to be consistent across a BUNDLE group, so this is an invalid
// description and not a shape the single int cannot express.
func TestVideoHeaderExtensionIDRejectsDisagreeingIDsAcrossMSections(t *testing.T) {
	sdp := "v=0\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45\r\na=extmap:11 " + dependencyDescriptorURI + "\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45\r\na=extmap:12 " + dependencyDescriptorURI + "\r\n"
	if _, err := videoHeaderExtensionID(sdp, dependencyDescriptorURI); err == nil {
		t.Fatal("two video m-sections mapping the URI to different ids were accepted")
	}
}

// The diagnostic names the URI it was ASKED about. It used to say "dependency-descriptor"
// unconditionally, while flexfec_negotiation.go calls this for the TWCC URI — so a TWCC failure sent
// the reader to the wrong m-section attribute.
func TestVideoHeaderExtensionIDNamesTheURIItWasGiven(t *testing.T) {
	sdp := "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=rtpmap:45 AV1/90000\r\n"
	_, err := videoHeaderExtensionID(sdp, twccURI)
	if err == nil {
		t.Fatal("a description with no TWCC extmap was accepted")
	}
	if !strings.Contains(err.Error(), twccURI) {
		t.Fatalf("error = %q, want it to name %q", err, twccURI)
	}
	if strings.Contains(err.Error(), dependencyDescriptorURI) {
		t.Fatalf("error = %q names the dependency-descriptor URI it was not asked about", err)
	}
}

func TestAdvertiseRTXTimeUsesNegotiatedDynamicPayloadTypes(t *testing.T) {
	local := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: dependencyDescriptorTestSDP("a=rtpmap:35 AV1/90000\r\n" +
			"a=rtpmap:36 rtx/90000\r\na=fmtp:36 apt=35\r\n",
		),
	}
	wire, err := advertiseRTXTime(local, 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(wire.SDP, "a=fmtp:36 apt=35;rtx-time=30") {
		t.Fatalf("dynamic RTX time missing from wire SDP:\n%s", wire.SDP)
	}
	prepared, err := preparePionRemoteDescription(wire, 30*time.Millisecond, true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(prepared.SDP, "a=fmtp:36 apt=35\r\n") ||
		strings.Contains(prepared.SDP, "rtx-time") {
		t.Fatalf("dynamic Pion engine SDP was not normalized:\n%s", prepared.SDP)
	}
}

func TestHostAnswerNegotiatesOfferedReceiverReferenceTime(t *testing.T) {
	offer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 35\r\n" +
			"a=mid:0\r\na=rtcp-xr:rcvr-rtt=all\r\n" +
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:1\r\n",
	}
	answer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\n" +
			"a=mid:0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" +
			"a=mid:1\r\n",
	}
	negotiated, err := negotiateReceiverReferenceTime(answer, offer)
	if err != nil {
		t.Fatal(err)
	}
	wantVideo := "m=video 9 UDP/TLS/RTP/SAVPF 45\r\n" +
		"a=mid:0\r\na=rtcp-xr:rcvr-rtt=all\r\n" +
		"m=application 9 UDP/DTLS/SCTP webrtc-datachannel"
	if !strings.Contains(negotiated.SDP, wantVideo) {
		t.Fatalf("receiver RTT was not negotiated in the video section:\n%s", negotiated.SDP)
	}
	if strings.Contains(answer.SDP, "rcvr-rtt") {
		t.Fatalf("Pion local description was mutated:\n%s", answer.SDP)
	}
}

func TestHostAnswerDoesNotInventReceiverReferenceTime(t *testing.T) {
	offer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 35\r\na=mid:0\r\n",
	}
	answer := webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:0\r\n",
	}
	negotiated, err := negotiateReceiverReferenceTime(answer, offer)
	if err != nil {
		t.Fatal(err)
	}
	if negotiated != answer {
		t.Fatalf("unoffered receiver RTT changed answer: %#v", negotiated)
	}
}

func TestPionRemoteDescriptionRejectsInvalidRequiredRTXTime(t *testing.T) {
	for _, test := range []struct {
		name string
		fmtp string
	}{
		{name: "missing", fmtp: "apt=45"},
		{name: "mismatch", fmtp: "apt=45;rtx-time=31"},
		{name: "zero", fmtp: "apt=45;rtx-time=0"},
		{name: "fractional", fmtp: "apt=45;rtx-time=30.5"},
		{name: "duplicate", fmtp: "apt=45;rtx-time=30;rtx-time=30"},
	} {
		t.Run(test.name, func(t *testing.T) {
			description := webrtc.SessionDescription{
				Type: webrtc.SDPTypeAnswer,
				SDP: dependencyDescriptorTestSDP(
					"a=rtpmap:46 rtx/90000\r\na=fmtp:46 " + test.fmtp + "\r\n",
				),
			}
			if _, err := preparePionRemoteDescription(
				description, 30*time.Millisecond, true,
			); err == nil {
				t.Fatalf("invalid RTX time unexpectedly accepted: %q", test.fmtp)
			}
		})
	}
}

func TestPeerPolicyOfferNegotiatesConfiguredRecovery(t *testing.T) {
	for _, test := range []struct {
		name     string
		recovery RecoveryMode
		nackRTX  bool
		flexFEC  bool
	}{
		{name: "NACK RTX", recovery: RecoveryNACKRTX, nackRTX: true},
		{name: "NACK RTX FlexFEC", recovery: RecoveryNACKRTXFlexFEC, nackRTX: true, flexFEC: true},
		{name: "off", recovery: RecoveryOff},
	} {
		t.Run(test.name, func(t *testing.T) {
			port := reserveUDPPort(t)
			config := PeerConfig{
				ICEPolicy: ICEPolicyStrict,
				LocalIP:   net.ParseIP("127.0.0.1"),
				RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: port, SignalPort: port + 1,
				Recovery: test.recovery, RTXMaxAge: 30 * time.Millisecond,
			}
			if test.flexFEC {
				config.TotalRTPBudgetBitsPerSecond = 8_000_000
				config.FramesPerSecond = 60
			}
			api, resources, err := newPeerAPI(config)
			if err != nil {
				t.Fatal(err)
			}
			defer resources.Close()
			if snapshot := resources.ResponderCacheSnapshot(); snapshot != (ResponderCacheSnapshot{}) {
				t.Fatalf("initial responder cache = %#v", snapshot)
			}
			audit := resources.Audit()
			if audit.CodecMimeType != webrtc.MimeTypeAV1 || audit.CodecClockRate != 90_000 || audit.PayloadType != 45 {
				t.Fatalf("codec audit = %#v", audit)
			}
			if audit.HeaderExtensionURI != frameMetadataURI ||
				audit.PlayoutDelayExtensionURI != playoutDelayURI {
				t.Fatalf("extension audit = %#v", audit)
			}
			if audit.NACK != test.nackRTX || audit.RTX != test.nackRTX ||
				audit.FEC != test.flexFEC || audit.TWCC != test.flexFEC ||
				!audit.SenderReports || audit.JitterBuffer ||
				audit.DefaultInterceptors {
				t.Fatalf("recovery/buffering audit = %#v", audit)
			}
			if audit.RTXMaxAgeMilliseconds != 30 {
				t.Fatalf("RTX age audit = %#v", audit)
			}
			if test.flexFEC {
				if !audit.RecoveryEgressAdmission ||
					audit.TotalRTPBudgetBitsPerSecond != 8_000_000 ||
					audit.RecoveryEgressBurstMilliseconds != 20 ||
					resources.recoveryEgressBudget == nil {
					t.Fatalf("recovery egress audit = %#v", audit)
				}
				wantOrder := "sender-reports,twcc-history,frame-aware-flexfec,twcc-header-injector,recovery-observer,receiver-rtt,age-aware-nack-responder,nack-generator"
				if got := strings.Join(audit.InterceptorOrder, ","); got != wantOrder {
					t.Fatalf("interceptor order = %q, want %q", got, wantOrder)
				}
			}
			if test.nackRTX {
				if resources.mediaRTT == nil ||
					resources.responderFactory.config.MediaRTT != resources.mediaRTT {
					t.Fatal("recovery peer did not share one media-RTT estimator")
				}
				observations := 0
				resources.SetRecoveryCallbacks(func(uint32) {}, func(error) {}, func() {
					observations++
				})
				resources.responderFactory.config.ObserveNACK()
				if observations != 1 {
					t.Fatalf("sender NACK observations = %d, want 1", observations)
				}
			} else if resources.mediaRTT != nil {
				t.Fatal("recovery-off peer allocated a media-RTT estimator")
			}
			if audit.LocalIP != "127.0.0.1" || audit.RemoteIP != "127.0.0.1" || audit.ICEServers != 0 {
				t.Fatalf("candidate audit = %#v", audit)
			}

			peer, err := api.NewPeerConnection(webrtc.Configuration{})
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			if _, err := peer.AddTransceiverFromKind(
				webrtc.RTPCodecTypeVideo,
				webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
			); err != nil {
				t.Fatal(err)
			}
			offer, err := peer.CreateOffer(nil)
			if err != nil {
				t.Fatal(err)
			}
			gathered := webrtc.GatheringCompletePromise(peer)
			if err := peer.SetLocalDescription(offer); err != nil {
				t.Fatal(err)
			}
			select {
			case <-gathered:
			case <-time.After(5 * time.Second):
				t.Fatal("ICE gathering timed out")
			}
			sdp := peer.LocalDescription().SDP
			if test.nackRTX {
				wire, err := advertiseRTXTime(*peer.LocalDescription(), config.RTXMaxAge)
				if err != nil {
					t.Fatal(err)
				}
				sdp = wire.SDP
			}
			if strings.Count(sdp, "a=rtpmap:45 AV1/90000") != 1 {
				t.Fatalf("AV1 codec missing or duplicated:\n%s", sdp)
			}
			if !strings.Contains(sdp, frameMetadataURI) {
				t.Fatalf("metadata extension missing from SDP:\n%s", sdp)
			}
			if !strings.Contains(sdp, playoutDelayURI) {
				t.Fatalf("playout-delay extension missing from SDP:\n%s", sdp)
			}
			if !strings.Contains(sdp, "https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension") {
				t.Fatalf("dependency-descriptor extension missing from SDP:\n%s", sdp)
			}
			if test.nackRTX {
				for _, required := range []string{
					"a=rtcp-fb:45 nack", "a=rtcp-fb:45 nack pli",
					"a=rtpmap:46 rtx/90000", "a=fmtp:46 apt=45;rtx-time=30",
				} {
					if !strings.Contains(sdp, required) {
						t.Fatalf("required %q missing from SDP:\n%s", required, sdp)
					}
				}
			}
			if test.flexFEC {
				for _, required := range []string{
					"a=rtpmap:47 flexfec-03/90000",
					"a=fmtp:47 repair-window=10000000",
					"a=rtcp-fb:45 transport-cc", twccURI,
				} {
					if strings.Count(sdp, required) != 1 {
						t.Fatalf("required FlexFEC/TWCC %q missing or duplicated:\n%s", required, sdp)
					}
				}
			} else if test.recovery == RecoveryOff {
				// ONE rtpmap PER OFFERED CODEC AND NO RTX. Derived from the table rather than
				// hardcoded, so registering a fourth codec does not need this edited — the
				// property under test is "recovery off means no repair codecs", not "one codec".
				if want := len(videoCodecProfiles()); strings.Count(sdp, "a=rtpmap:") != want {
					t.Fatalf("recovery-off codec count is not %d:\n%s", want, sdp)
				}
				for _, line := range strings.Split(sdp, "\n") {
					lower := strings.ToLower(strings.TrimSpace(line))
					mediaAttribute := strings.HasPrefix(lower, "a=rtpmap:") ||
						strings.HasPrefix(lower, "a=rtcp-fb:") ||
						strings.HasPrefix(lower, "a=fmtp:") ||
						strings.HasPrefix(lower, "a=extmap:")
					for _, forbidden := range []string{
						"rtx/", " red/", "ulpfec", "flexfec", "transport-cc", "nack",
					} {
						if mediaAttribute && strings.Contains(lower, forbidden) {
							t.Fatalf("forbidden %q in recovery-off SDP line %q:\n%s", forbidden, line, sdp)
						}
					}
				}
			} else {
				for _, forbidden := range []string{"flexfec", "transport-cc", twccURI} {
					if strings.Contains(strings.ToLower(sdp), strings.ToLower(forbidden)) {
						t.Fatalf("legacy NACK/RTX offer contains %q:\n%s", forbidden, sdp)
					}
				}
			}
			for _, forbidden := range []string{" typ srflx", " typ relay", " TCP "} {
				if strings.Contains(strings.ToLower(sdp), strings.ToLower(forbidden)) {
					t.Fatalf("forbidden %q in SDP:\n%s", forbidden, sdp)
				}
			}
			for _, line := range strings.Split(sdp, "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "a=candidate:") {
					lower := strings.ToLower(line)
					if !strings.Contains(lower, " udp ") || !strings.Contains(line, " 127.0.0.1 ") || !strings.Contains(lower, " typ host") {
						t.Fatalf("unexpected candidate line %q", line)
					}
				}
			}
		})
	}
}

func TestPeerPolicyActivatesStaticFlexFECAfterAcknowledgment(t *testing.T) {
	port := reserveUDPPort(t)
	_, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	var updates []RecoveryPolicyUpdate
	if err := resources.ActivateFlexFECPolicy(
		FlexFECPolicyLow, AV1ScalabilityL1T3, 8_000_000,
		func(update RecoveryPolicyUpdate) error {
			updates = append(updates, update)
			return nil
		},
	); err != nil {
		t.Fatal(err)
	}
	want := RecoveryPolicyUpdate{
		Sequence: 1, Tier: FlexFECTierLow, MediaBitrateBitsPerSecond: 7_414_634,
	}
	if len(updates) != 1 || updates[0] != want || resources.flexFECTier.Load() != FlexFECTierLow {
		t.Fatalf("updates=%+v tier=%d, want %+v", updates, resources.flexFECTier.Load(), want)
	}

	port = reserveUDPPort(t)
	_, rejected, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = rejected.Close() })
	callbackErr := assertionError("encoder rejected bitrate")
	if err := rejected.ActivateFlexFECPolicy(
		FlexFECPolicyHigh, AV1ScalabilityL1T3, 8_000_000,
		func(RecoveryPolicyUpdate) error { return callbackErr },
	); err == nil || rejected.flexFECTier.Load() != FlexFECTierOff || rejected.flexFECDegradedReason == "" {
		t.Fatalf("rejected activation err=%v tier=%d degraded=%q", err, rejected.flexFECTier.Load(), rejected.flexFECDegradedReason)
	}
}

type topologyRecordingEncoder struct {
	delegate flexfec.FlexEncoder
	groups   [][]rtp.Packet
}

func (encoder *topologyRecordingEncoder) EncodeFec(media []rtp.Packet, count uint32) []rtp.Packet {
	group := make([]rtp.Packet, len(media))
	copy(group, media)
	encoder.groups = append(encoder.groups, group)
	return encoder.delegate.EncodeFec(media, count)
}

type topologyEncoderFactory struct{ encoder *topologyRecordingEncoder }

func (factory topologyEncoderFactory) NewEncoder(payloadType uint8, ssrc uint32) flexfec.FlexEncoder {
	factory.encoder.delegate = flexfec.NewFlexEncoder03(payloadType, ssrc)
	return factory.encoder
}

func TestFlexFECInterceptorTopologySharesTWCCAcrossMediaFECAndRTX(t *testing.T) {
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{})
	counters := NewFlexFECCounters(nil)
	tier := NewFlexFECTierStore(FlexFECTierHigh, counters)
	allocator := newTransportSequenceAllocator(100)
	recorder := &topologyRecordingEncoder{}
	fecFactory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
		Tier: tier, Override: NewFlexFECOverrideStore(), Allocator: allocator, History: history, Counters: counters,
		EncoderFactory: topologyEncoderFactory{encoder: recorder},
	})
	if err != nil {
		t.Fatal(err)
	}
	injectorFactory := NewTWCCHeaderInjector(allocator, history)
	responderFactory, err := NewAgeAwareNACKResponder(AgeAwareResponderConfig{MaxAge: 30 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	fecInterceptor, _ := fecFactory.NewInterceptor("fec")
	injectorInterceptor, _ := injectorFactory.NewInterceptor("twcc")
	responderInterceptor, _ := responderFactory.NewInterceptor("rtx")
	chain := interceptor.NewChain([]interceptor.Interceptor{
		fecInterceptor, injectorInterceptor, responderInterceptor,
	})
	t.Cleanup(func() { _ = chain.Close() })
	info := &interceptor.StreamInfo{
		SSRC: 100, SSRCRetransmission: 300, SSRCForwardErrorCorrection: 200,
		PayloadType: 45, PayloadTypeRetransmission: 46, PayloadTypeForwardErrorCorrection: 47,
		RTCPFeedback: []interceptor.RTCPFeedback{{Type: "nack"}},
		RTPHeaderExtensions: []interceptor.RTPHeaderExtension{
			{URI: frameMetadataURI, ID: 3}, {URI: dependencyDescriptorURI, ID: 4},
			{URI: twccURI, ID: 5},
		},
	}
	var written []rtp.Packet
	writer := chain.BindLocalStream(info, interceptor.RTPWriterFunc(func(
		header *rtp.Header, payload []byte, _ interceptor.Attributes,
	) (int, error) {
		written = append(written, rtp.Packet{Header: header.Clone(), Payload: append([]byte(nil), payload...)})
		return header.MarshalSize() + len(payload), nil
	}))
	for index := 0; index < 5; index++ {
		packet := frameAwarePacket(1, uint16(10+index), 90_000, index, 5, false, 1)
		if _, err := writer.Write(&packet.Header, packet.Payload, nil); err != nil {
			t.Fatal(err)
		}
	}
	if len(recorder.groups) != 1 || len(recorder.groups[0]) != 5 {
		t.Fatalf("protected groups = %v", recorder.groups)
	}
	for index := 0; index < 5; index++ {
		protectedPacket := recorder.groups[0][index]
		var protectedTWCC rtp.TransportCCExtension
		if err := protectedTWCC.Unmarshal(protectedPacket.GetExtension(5)); err != nil {
			t.Fatalf("protected media %d TWCC: %v", index, err)
		}
		if protectedTWCC.TransportSequence != 0 {
			t.Fatalf("protected media %d TWCC=%d, want mutable bytes zeroed", index, protectedTWCC.TransportSequence)
		}
		normalizedWire := written[index].Clone()
		if err := normalizedWire.SetExtension(5, []byte{0, 0}); err != nil {
			t.Fatal(err)
		}
		protected, _ := protectedPacket.Marshal()
		normalized, _ := normalizedWire.Marshal()
		if !bytes.Equal(protected, normalized) {
			t.Fatalf("protected media %d differs beyond mutable TWCC bytes", index)
		}
	}

	nack := &rtcp.TransportLayerNack{MediaSSRC: 100, Nacks: []rtcp.NackPair{{PacketID: 10}}}
	raw, err := rtcp.Marshal([]rtcp.Packet{nack})
	if err != nil {
		t.Fatal(err)
	}
	reader := chain.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte, attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		copy(buffer, raw)
		return len(raw), attributes, nil
	}))
	if _, _, err := reader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}
	if len(written) != 8 {
		t.Fatalf("written packets = %d, want 5 media + 2 FEC + 1 RTX", len(written))
	}
	for index, packet := range written {
		var extension rtp.TransportCCExtension
		if err := extension.Unmarshal(packet.GetExtension(5)); err != nil {
			t.Fatalf("packet %d TWCC: %v", index, err)
		}
		if extension.TransportSequence != uint16(100+index) {
			t.Fatalf("packet %d TWCC=%d", index, extension.TransportSequence)
		}
	}
	snapshot := history.Snapshot()
	if snapshot.ByClass[TWCCMedia].SentPackets != 5 || snapshot.ByClass[TWCCFEC].SentPackets != 2 ||
		snapshot.ByClass[TWCCRTX].SentPackets != 1 {
		t.Fatalf("history classes = %+v", snapshot.ByClass)
	}
}

func dependencyDescriptorTestSDP(attributes string) string {
	return "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
		"a=extmap:7 " + dependencyDescriptorURI + "\r\n" + attributes
}

func reserveUDPPort(t *testing.T) uint16 {
	t.Helper()
	connection, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	port := connection.LocalAddr().(*net.UDPAddr).Port
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}
	if port >= 65_535 {
		return reserveUDPPort(t)
	}
	return uint16(port)
}

// ─── ICE reachability policy ────────────────────────────────────────────────────────────────────
//
// The two callers are in different positions and that is why a policy exists at all: `capture-host`
// learns its peer's address from the accepted TCP connection, so naming both addresses costs it
// nothing and asserts a real property; rdev cannot know where its browser is.

func validTestPeerConfig() PeerConfig {
	return PeerConfig{
		LocalIP: net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: 57_00, SignalPort: 57_01,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
		ICEPolicy: ICEPolicyStrict,
	}
}

func TestValidateRequiresRemoteIPUnderStrict(t *testing.T) {
	config := validTestPeerConfig()
	config.RemoteIP = nil
	if err := config.Validate(); err == nil {
		t.Fatal("strict must require a remote IP; it filters remote candidates on it")
	}
}

// THE INVERSION IS THE POINT: under lan there is no remote address to name, so a POPULATED one is
// rejected. Accepting-and-ignoring would let a caller set it and believe it was enforced.
func TestValidateRejectsAPopulatedRemoteIPUnderLAN(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPolicy = ICEPolicyLAN
	config.RemoteIP = net.ParseIP("192.168.1.5")
	if err := config.Validate(); err == nil {
		t.Fatal("lan must reject a populated remote IP: nothing would enforce it")
	}
}

func TestValidateAcceptsLANWithoutARemoteIP(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPolicy, config.RemoteIP = ICEPolicyLAN, nil
	if err := config.Validate(); err != nil {
		t.Fatalf("lan must not require a remote IP: %v", err)
	}
}

func TestValidateRejectsMalformedICEServersJSON(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPolicy, config.RemoteIP = ICEPolicyLAN, nil
	config.ICEServersJSON = "{not json"
	if err := config.Validate(); err == nil {
		t.Fatal("malformed ICE JSON must be an error, not a silent zero relay candidates")
	}
}

func TestValidateRejectsICEServersUnderStrict(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEServersJSON = `[{"urls":["turn:example.test:3478"]}]`
	if err := config.Validate(); err == nil {
		t.Fatal("strict registers no ICE servers, so passing them must be refused, not ignored")
	}
}

func TestValidateRejectsAnUnknownPolicy(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPolicy = ICEPolicy("open")
	if err := config.Validate(); err == nil {
		t.Fatal("an unrecognised policy must be refused, not defaulted")
	}
}

// THE TWO POLICIES MUST ACTUALLY DIFFER. A policy that is plumbed everywhere and applies nothing
// passes every other test in this package, because they all build ONE session and assert it works.
// This is the only test that can see that failure.
func TestTheTwoICEPoliciesProduceDifferentConstruction(t *testing.T) {
	strictConfig := validTestPeerConfig()
	lanConfig := validTestPeerConfig()
	// A DISTINCT PORT: this test is the only one that builds two peers at once, and each binds its
	// own host ICE UDP mux.
	lanConfig.ICEPolicy, lanConfig.RemoteIP, lanConfig.ICEPort = ICEPolicyLAN, nil, 57_10

	_, strictResources, err := newPeerAPI(strictConfig)
	if err != nil {
		t.Fatalf("strict: %v", err)
	}
	_, lanResources, err := newPeerAPI(lanConfig)
	if err != nil {
		t.Fatalf("lan: %v", err)
	}
	strictAudit, lanAudit := strictResources.Audit(), lanResources.Audit()
	if reflect.DeepEqual(strictAudit, lanAudit) {
		t.Fatal("the two policies constructed identical peers; the policy applies nothing")
	}
	if !strictAudit.MulticastDNSDisabled {
		t.Fatal("strict must keep mDNS disabled")
	}
	if lanAudit.MulticastDNSDisabled {
		t.Fatal("lan must enable query-only mDNS, or Chrome's host candidate stays unresolvable")
	}
	// lan means pion's defaults, and pion excludes loopback. Recorded so the answer comes from a
	// decision rather than from a field (LocalIP) that stopped meaning what it meant.
	if lanAudit.IncludeLoopback {
		t.Fatal("lan means pion's defaults, and pion excludes loopback")
	}
	// THE MUX BIND ADDRESS IS THE ONE THAT ACTUALLY DECIDES REACHABILITY. SetICEUDPMux makes pion
	// gather on that socket alone, so a mux pinned to one address gathers one address no matter what
	// the IP filter allows — dropping the filter without this would look right and change nothing.
	if lanAudit.MuxBindAddress != "0.0.0.0" {
		t.Fatalf("lan must bind the mux unspecified, got %q; a pinned mux gathers one interface",
			lanAudit.MuxBindAddress)
	}
	if strictAudit.MuxBindAddress != "127.0.0.1" {
		t.Fatalf("strict must still pin its mux, got %q", strictAudit.MuxBindAddress)
	}
	if strictAudit.ICEPolicy != string(ICEPolicyStrict) || lanAudit.ICEPolicy != string(ICEPolicyLAN) {
		t.Fatalf("the audit must record which policy built the peer: %q vs %q",
			strictAudit.ICEPolicy, lanAudit.ICEPolicy)
	}
}

func TestLANRegistersTheICEServersItWasGiven(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPolicy, config.RemoteIP, config.ICEPort = ICEPolicyLAN, nil, 57_20
	config.ICEServersJSON = `[{"urls":["turn:example.test:3478"],"username":"u","credential":"c"}]`
	_, resources, err := newPeerAPI(config)
	if err != nil {
		t.Fatalf("newPeerAPI: %v", err)
	}
	if got := resources.Audit().ICEServers; got != 1 {
		t.Fatalf("ICEServers = %d, want 1 — the JSON reached nothing", got)
	}
}

// strict must stay byte-identical: it is the certification's comparison arm.
func TestStrictRegistersNoICEServers(t *testing.T) {
	config := validTestPeerConfig()
	config.ICEPort = 57_21
	_, resources, err := newPeerAPI(config)
	if err != nil {
		t.Fatalf("newPeerAPI: %v", err)
	}
	if got := resources.Audit().ICEServers; got != 0 {
		t.Fatalf("ICEServers = %d, want 0 — strict must stay byte-identical", got)
	}
}

// FEC TURNING ITSELF OFF USED TO BE COMPLETELY INVISIBLE. The reason reached the stats JSON, which
// nothing in rdev reads, so a session could negotiate FlexFEC, log negotiated=true, charge its ~5%
// of the media budget and protect nothing — the only outward sign being a `recovery policy` line
// that prints once at construction and never again, indistinguishable from a quiet link. Measured
// on a real iPad: H.265 at 5 PLI/s on a still window with the tier never leaving 0.
//
// disableFlexFEC now prints, and prints ONCE. This pins the decision behind that: the FIRST reason
// wins and later failures neither overwrite it nor re-announce. The callers are interceptor hot
// paths — a per-failure line would be the drop-spam defect again, in a different costume.
func TestDisableFlexFECRecordsOnlyTheFirstReason(t *testing.T) {
	resources := &peerAPIResources{}

	resources.disableFlexFEC(errors.New("first failure"))
	if got := resources.flexFECDegradedReason; got != "first failure" {
		t.Fatalf("after first disable, reason = %q, want %q", got, "first failure")
	}

	// A LATER failure is the same fact, not a new one: the tier was set to Off on the first call.
	resources.disableFlexFEC(errors.New("second failure"))
	if got := resources.flexFECDegradedReason; got != "first failure" {
		t.Fatalf("a later failure overwrote the reason: %q — the FIRST cause is the diagnostic one", got)
	}

	// nil is not a failure and must not arm the degraded state, or every healthy session would
	// report itself degraded.
	fresh := &peerAPIResources{}
	fresh.disableFlexFEC(nil)
	if got := fresh.flexFECDegradedReason; got != "" {
		t.Fatalf("nil error armed the degraded state: %q", got)
	}
}

// `activeRecovery` IS DECIDED FROM THE SDP AND FEC DISABLES ITSELF FROM INSIDE THE INTERCEPTOR, a
// layer below — so the two can disagree, and increment 2's `no FEC` footer cell exists precisely to
// surface a silent recovery downgrade. Reading the SDP choice would make it report the opposite.
func TestFlexFECIsDegradedTracksTheDisableCall(t *testing.T) {
	resources := &peerAPIResources{}
	if resources.flexFECIsDegraded() {
		t.Fatal("a fresh session must not report itself degraded")
	}
	resources.disableFlexFEC(errors.New("bind refused"))
	if !resources.flexFECIsDegraded() {
		t.Fatal("after disableFlexFEC the session IS degraded, and activeRecovery must say so")
	}
}
