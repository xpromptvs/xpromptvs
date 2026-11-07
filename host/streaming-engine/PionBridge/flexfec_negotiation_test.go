package main

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func flexFECOfferSDP() string {
	return "v=0\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45 46 47\r\n" +
		"a=extmap:4 " + dependencyDescriptorURI + "\r\n" +
		"a=extmap:5 " + twccURI + "\r\n" +
		"a=rtpmap:45 AV1/90000\r\n" +
		"a=rtpmap:46 rtx/90000\r\n" +
		"a=fmtp:46 apt=45;rtx-time=30\r\n" +
		"a=rtpmap:47 flexfec-03/90000\r\n" +
		"a=fmtp:47 repair-window=10000000\r\n" +
		"a=rtcp-fb:45 nack\r\n" +
		"a=rtcp-fb:45 nack pli\r\n" +
		"a=rtcp-fb:45 transport-cc\r\n"
}

func flexFECAnswerSDP() string {
	return flexFECOfferSDP() +
		"a=ssrc-group:FID 1001 1002\r\n" +
		"a=ssrc-group:FEC-FR 1001 1003\r\n"
}

func TestFlexFECNegotiationAcceptsExactOfferAndAnswer(t *testing.T) {
	offer, err := validateFlexFECOffer(flexFECOfferSDP(), 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if offer.PreferredPayloadType != 45 || offer.RTXPayloadType != 46 ||
		offer.FlexFECPayloadType != 47 || offer.RepairWindowMicroseconds != 10_000_000 ||
		offer.TWCCExtensionID != 5 {
		t.Fatalf("offer negotiation = %#v", offer)
	}
	answer, err := validateFlexFECAnswer(
		flexFECAnswerSDP(), offer, 30*time.Millisecond,
	)
	if err != nil {
		t.Fatal(err)
	}
	// FIELD BY FIELD rather than a struct comparison: flexFECNegotiation carries a map of primaries
	// now (rdev offers three codecs), and Go cannot compare a struct containing one.
	if answer.PreferredPayloadType != 45 || answer.RTXPayloadType != 46 ||
		answer.FlexFECPayloadType != 47 || answer.RepairWindowMicroseconds != 10_000_000 ||
		answer.TWCCExtensionID != 5 ||
		answer.MediaSSRC != 1001 || answer.RTXSSRC != 1002 || answer.FlexFECSSRC != 1003 {
		t.Fatalf("answer negotiation = %#v", answer)
	}
	if len(answer.Primaries) != 1 || answer.Primaries[45] != 46 {
		t.Fatalf("answer primaries = %#v, want {45: 46}", answer.Primaries)
	}
}

func TestFlexFECNegotiationRejectsMalformedOffer(t *testing.T) {
	valid := flexFECOfferSDP()
	tests := []struct {
		name string
		old  string
		new  string
	}{
		{name: "missing FEC", old: "a=rtpmap:47 flexfec-03/90000\r\n"},
		{name: "duplicate FEC", old: "a=rtpmap:47 flexfec-03/90000\r\n",
			new: "a=rtpmap:47 flexfec-03/90000\r\na=rtpmap:48 flexfec-03/90000\r\n"},
		{name: "wrong repair window", old: "repair-window=10000000", new: "repair-window=1"},
		{name: "cross-associated RTX", old: "apt=45;rtx-time=30", new: "apt=44;rtx-time=30"},
		{name: "unknown RTX fmtp", old: "apt=45;rtx-time=30", new: "apt=45;rtx-time=30;x=1"},
		{name: "missing AV1 transport cc", old: "a=rtcp-fb:45 transport-cc\r\n",
			new: "a=rtcp-fb:47 transport-cc\r\n"},
		{name: "duplicate TWCC", old: "a=extmap:5 " + twccURI + "\r\n",
			new: "a=extmap:5 " + twccURI + "\r\na=extmap:6 " + twccURI + "\r\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			mutated := strings.Replace(valid, test.old, test.new, 1)
			if mutated == valid {
				t.Fatal("test mutation did not change fixture")
			}
			if _, err := validateFlexFECOffer(mutated, 30*time.Millisecond); err == nil {
				t.Fatalf("invalid offer accepted:\n%s", mutated)
			}
		})
	}
}

func TestFlexFECNegotiationRejectsInvalidAnswerGroups(t *testing.T) {
	offer, err := validateFlexFECOffer(flexFECOfferSDP(), 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	valid := flexFECAnswerSDP()
	for _, test := range []struct {
		name string
		old  string
		new  string
	}{
		{name: "missing FID", old: "a=ssrc-group:FID 1001 1002\r\n"},
		{name: "missing FEC-FR", old: "a=ssrc-group:FEC-FR 1001 1003\r\n"},
		{name: "mismatched media", old: "a=ssrc-group:FEC-FR 1001 1003\r\n",
			new: "a=ssrc-group:FEC-FR 999 1003\r\n"},
		{name: "duplicate FID", old: "a=ssrc-group:FID 1001 1002\r\n",
			new: "a=ssrc-group:FID 1001 1002\r\na=ssrc-group:FID 1001 1004\r\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			mutated := strings.Replace(valid, test.old, test.new, 1)
			if _, err := validateFlexFECAnswer(
				mutated, offer, 30*time.Millisecond,
			); err == nil {
				t.Fatalf("invalid answer accepted:\n%s", mutated)
			}
		})
	}
}

func TestLegacyNegotiationRejectsFlexFECAndTWCC(t *testing.T) {
	for _, recovery := range []RecoveryMode{RecoveryNACKRTX, RecoveryOff} {
		if err := validateLegacyRecoverySDP(flexFECOfferSDP(), recovery); err == nil {
			t.Fatalf("legacy recovery %d accepted FlexFEC/TWCC", recovery)
		}
	}
}

func TestFlexFECRegistrationAllocatesRepairSSRCWithoutStockInterceptor(t *testing.T) {
	port := reserveUDPPort(t)
	api, resources, err := newPeerAPI(PeerConfig{
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
	peer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.Close() })
	track, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000},
		"video", "desktop",
	)
	if err != nil {
		t.Fatal(err)
	}
	sender, err := peer.AddTrack(track)
	if err != nil {
		t.Fatal(err)
	}
	offer, err := peer.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	encodings := sender.GetParameters().Encodings
	if len(encodings) != 1 || encodings[0].SSRC == 0 || encodings[0].RTX.SSRC == 0 ||
		encodings[0].FEC.SSRC == 0 {
		t.Fatalf("sender encodings = %#v", encodings)
	}
	want := fmt.Sprintf(
		"a=ssrc-group:FEC-FR %d %d", encodings[0].SSRC, encodings[0].FEC.SSRC,
	)
	if !strings.Contains(offer.SDP, want) {
		t.Fatalf("offer missing %q:\n%s", want, offer.SDP)
	}
}
