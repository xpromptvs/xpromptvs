package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
)

// THE H.265 fmtp MUST NOT CARRY level-id, and this is asserted as a LITERAL rather than by
// inspection because its failure mode is a PARTIAL MATCH rather than an error.
//
// pion ships fmtp matchers for H.264/VP9/AV1 and none for H.265, so H.265 falls to the generic
// matcher, which rejects a match when a key appears in BOTH offer and answer with different values.
// level-id is a per-device DECODER capability — Safari answers 93, Chrome 180 — not a stream
// property. Offering it demotes H.265 to a partial match, gets it discarded in favour of an
// exactly-matching H.264, and the host then ships a codec the browser did not expect while every
// state reads healthy. INVISIBLE IN CHROME, which echoes the offered fmtp exactly.
func TestH265FmtpOmitsLevelID(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH265)
	if !ok {
		t.Fatal("no H.265 profile")
	}
	if profile.fmtpLine != "profile-id=1;tier-flag=0;tx-mode=SRST" {
		t.Fatalf("H.265 fmtp = %q, want exactly profile-id=1;tier-flag=0;tx-mode=SRST", profile.fmtpLine)
	}
}

// The order is rdev's PREFERENCE and it decides what a browser that supports several gets. AV1 is
// measurably better per bit on the text and UI rdev streams, so it must come first; H.265 beats
// H.264 per bit and is hardware-decoded on the devices that lack AV1.
func TestProfilesAreInPreferenceOrder(t *testing.T) {
	profiles := videoCodecProfiles()
	want := []codecID{rdevNegotiatedCodecAV1, rdevNegotiatedCodecH265, rdevNegotiatedCodecH264}
	if len(profiles) != len(want) {
		t.Fatalf("profiles = %d, want %d", len(profiles), len(want))
	}
	for i, profile := range profiles {
		if profile.codec != want[i] {
			t.Fatalf("profile %d = %v, want %v", i, profile.codec, want[i])
		}
	}
}

// Every payload type in the table must be distinct, primary and RTX alike. A collision produces an
// offer pion will not build and an answer nothing can parse.
func TestPayloadTypesAreDistinct(t *testing.T) {
	seen := map[uint8]string{}
	for _, profile := range videoCodecProfiles() {
		for _, payloadType := range []uint8{profile.payloadType, profile.rtxPayloadType} {
			if other, clash := seen[payloadType]; clash {
				t.Fatalf("payload type %d used by both %s and %s", payloadType, other, profile.mimeType)
			}
			seen[payloadType] = profile.mimeType
		}
	}
}

// ONLY AV1 EMITS A DEPENDENCY DESCRIPTOR. Browsers negotiate that extension for AV1 and VP9; an
// H.264/H.265 answer carries none, and every site that requires one must consult this flag.
func TestOnlyAV1EmitsADependencyDescriptor(t *testing.T) {
	for _, profile := range videoCodecProfiles() {
		want := profile.codec == rdevNegotiatedCodecAV1
		if profile.emitsDependencyDescriptor != want {
			t.Fatalf("%s emitsDependencyDescriptor = %t, want %t",
				profile.mimeType, profile.emitsDependencyDescriptor, want)
		}
	}
}

// The rtpmap name is what the SDP-scanning helpers match on, lowercased. A mismatch here makes
// recoveryPayloadTypes and descriptionNeedsDependencyDescriptor silently miss a codec.
func TestRtpmapNamesMatchTheWire(t *testing.T) {
	want := map[codecID]string{
		rdevNegotiatedCodecAV1:  "av1/90000",
		rdevNegotiatedCodecH265: "h265/90000",
		rdevNegotiatedCodecH264: "h264/90000",
	}
	for _, profile := range videoCodecProfiles() {
		if profile.rtpmapName != want[profile.codec] {
			t.Fatalf("%s rtpmap = %q, want %q", profile.mimeType, profile.rtpmapName, want[profile.codec])
		}
	}
}

// Each codec must get its own payloader. A wrong one produces RTP that is well-formed at the
// transport layer and undecodable at the codec layer — RTP flows, every state reads healthy, and no
// picture appears, which is this project's signature failure.
func TestPayloaderFollowsTheProfile(t *testing.T) {
	for _, testCase := range []struct {
		codec codecID
		want  string
	}{
		{rdevNegotiatedCodecAV1, "*codecs.AV1Payloader"},
		{rdevNegotiatedCodecH265, "*codecs.H265Payloader"},
		{rdevNegotiatedCodecH264, "*codecs.H264Payloader"},
	} {
		profile, ok := profileForCodecID(testCase.codec)
		if !ok {
			t.Fatalf("no profile for %v", testCase.codec)
		}
		if got := fmt.Sprintf("%T", newPayloaderFor(profile)); got != testCase.want {
			t.Fatalf("%s payloader = %s, want %s", profile.mimeType, got, testCase.want)
		}
	}
}

// THE OFFER MUST CARRY ALL THREE. This is the whole point of the increment: a receiver that cannot
// decode AV1 has to find something it can decode in the offer, or it answers with no video at all
// and the session dies without ever naming a codec as the reason.
func TestOfferAdvertisesEveryProfile(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	offer, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	lowered := strings.ToLower(offer)
	for _, profile := range videoCodecProfiles() {
		if !strings.Contains(lowered, profile.rtpmapName) {
			t.Fatalf("offer does not advertise %s", profile.rtpmapName)
		}
		if profile.fmtpLine != "" && !strings.Contains(offer, profile.fmtpLine) {
			t.Fatalf("offer does not carry %s's fmtp %q", profile.mimeType, profile.fmtpLine)
		}
		// The RTX association has to name THIS codec's payload type, or a repair packet is
		// attributed to the wrong primary and the receiver discards it.
		if !strings.Contains(offer, fmt.Sprintf("apt=%d", profile.payloadType)) {
			t.Fatalf("offer has no RTX association for %s (apt=%d)", profile.mimeType, profile.payloadType)
		}
	}
}

// preparePionRemoteDescription REQUIRED the dependency-descriptor extension in EVERY remote
// description, at the very top, before any codec logic ran. Browsers negotiate that extension for
// AV1 and VP9 — an H.264-only answer carries none — so an AV1-less device's answer failed HERE,
// FIRST, reporting a missing header extension rather than anything about codecs. That is the wrong
// direction to send whoever reads the log.
func TestAnH264OnlyAnswerSurvivesPreparation(t *testing.T) {
	answer := webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: h264OnlyAnswerSDP()}
	if _, err := preparePionRemoteDescription(answer, 30*time.Millisecond, false); err != nil {
		t.Fatalf("H.264-only answer refused: %v", err)
	}
}

// AN AV1 ANSWER THAT DROPPED THE EXTENSION IS STILL REFUSED. AV1 frames carry a dependency
// descriptor, so a receiver that did not negotiate it cannot decode what we would send. Making the
// requirement conditional must not make it permissive.
func TestAnAV1AnswerWithoutTheDescriptorIsStillRefused(t *testing.T) {
	answer := webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: av1AnswerWithoutDescriptorSDP()}
	if _, err := preparePionRemoteDescription(answer, 30*time.Millisecond, false); err == nil {
		t.Fatal("an AV1 answer without the dependency descriptor must be refused")
	}
}

// recoveryPayloadTypes decides which payload types count as PRIMARY for RTX association. It seeded
// itself with av1PayloadType alone, so a valid H.264 association read as invalid — inside
// advertiseRTXTime, whose error text is about rtx-time.
func TestRecoveryPayloadTypesKnowsEveryProfile(t *testing.T) {
	primaries, rtx := recoveryPayloadTypes(strings.Split(h264OnlyAnswerSDP(), "\n"))
	if !primaries[int(h264PayloadType)] {
		t.Fatalf("H.264 payload %d not recognised as primary", h264PayloadType)
	}
	if !rtx[int(h264RTXPayloadType)] {
		t.Fatalf("H.264 RTX payload %d not recognised", h264RTXPayloadType)
	}
}

// A minimal answer of the shape an AV1-less device sends: H.264 and its RTX, no AV1, and NO
// dependency-descriptor extmap. Hand-written on purpose — the point is a description pion would
// never build FOR US, which is what someone else's answer is.
func h264OnlyAnswerSDP() string {
	return "v=0\r\n" +
		"o=- 0 0 IN IP4 127.0.0.1\r\n" +
		"s=-\r\n" +
		"t=0 0\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 102 103\r\n" +
		"c=IN IP4 0.0.0.0\r\n" +
		"a=recvonly\r\n" +
		"a=rtpmap:102 H264/90000\r\n" +
		"a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n" +
		"a=rtpmap:103 rtx/90000\r\n" +
		"a=fmtp:103 apt=102\r\n" +
		"a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay\r\n"
}

// The same shape, but AV1 — and still missing the descriptor, which must remain a refusal.
func av1AnswerWithoutDescriptorSDP() string {
	return "v=0\r\n" +
		"o=- 0 0 IN IP4 127.0.0.1\r\n" +
		"s=-\r\n" +
		"t=0 0\r\n" +
		"m=video 9 UDP/TLS/RTP/SAVPF 45 46\r\n" +
		"c=IN IP4 0.0.0.0\r\n" +
		"a=recvonly\r\n" +
		"a=rtpmap:45 AV1/90000\r\n" +
		"a=rtpmap:46 rtx/90000\r\n" +
		"a=fmtp:46 apt=45\r\n" +
		"a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay\r\n"
}

// annexB builds an access unit the way rdev's encoder does: 4-byte start codes, parameter sets
// ahead of the slice. `LLVCore.VideoEncoder.annexBData` emits exactly this shape.
func annexB(nals ...[]byte) []byte {
	var out []byte
	for _, nal := range nals {
		out = append(out, 0x00, 0x00, 0x00, 0x01)
		out = append(out, nal...)
	}
	return out
}

// filler makes a NAL big enough to force fragmentation past any sane MTU.
func filler(header []byte, size int) []byte {
	nal := append([]byte(nil), header...)
	for len(nal) < size {
		// 0x03 avoids accidentally synthesising a start code inside the payload.
		nal = append(nal, 0x03)
	}
	return nal
}

// IS rdev's H.264 PACKETIZATION SOMETHING A CONFORMANT RECEIVER CAN REASSEMBLE?
//
// NOTHING CHECKED THIS UNTIL NOW. The only existing test asserts we SELECT the right payloader
// (a %T comparison); nothing looked at what it emits. H.264 had indirect cover — the codec gate
// decodes it in a live Chromium — but "a browser decoded it" and "the bytes are right" are
// different claims, and H.265 had no cover at all because Chromium has no HEVC decoder.
//
// Asserted against pion's OWN depacketizer, so this cannot drift from the library that produced
// the packets: a round trip through H264Packet must reconstruct every input NAL.
func TestH264PacketizationRoundTrips(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH264)
	if !ok {
		t.Fatal("no H.264 profile registered")
	}
	sps := []byte{0x67, 0x42, 0x00, 0x1f, 0xac}
	pps := []byte{0x68, 0xce, 0x3c, 0x80}
	idr := filler([]byte{0x65, 0x88, 0x84}, 3000)
	accessUnit := annexB(sps, pps, idr)

	packets := newPayloaderFor(profile).Payload(1200, accessUnit)
	if len(packets) < 2 {
		t.Fatalf("a 3000-byte IDR at MTU 1200 must fragment, got %d packet(s)", len(packets))
	}

	// ONE DEPACKETIZER FOR THE WHOLE FRAME, NOT ONE PER PACKET. H264Packet accumulates FU-A
	// fragments in internal state and returns the reassembled NAL only on the End bit, so a fresh
	// parser per packet discards that state and the IDR never reappears — which is a bug in the
	// TEST, not in the packetization, and it is exactly what the first version of this did.
	depacketizer := &codecs.H264Packet{}
	var reassembled []byte
	for index, payload := range packets {
		out, err := depacketizer.Unmarshal(payload)
		if err != nil {
			t.Fatalf("packet %d is not parseable by pion's own depacketizer: %v", index, err)
		}
		reassembled = append(reassembled, out...)
	}

	// EVERY INPUT NAL MUST COME BACK. A dropped parameter set is the failure that would make a
	// hardware decoder ask for a keyframe on a stream it otherwise received intact.
	for name, nal := range map[string][]byte{"SPS": sps, "PPS": pps, "IDR": idr} {
		if !bytes.Contains(reassembled, nal) {
			t.Fatalf("%s did not survive packetization", name)
		}
	}
}

// THE SAME QUESTION FOR H.265, WHERE IT HAS NEVER BEEN ASKED. Playwright's Chromium cannot decode
// HEVC, so no gate in this repository has ever consumed rdev's H.265 RTP — the maintainer's iPad is
// the only receiver that ever has.
//
// pion exposes no single H265Packet.Unmarshal, so this dispatches on the payload header exactly as
// a receiver must, and validates each packet with the matching parser.
func TestH265PacketizationIsParseableAndComplete(t *testing.T) {
	profile, ok := profileForCodecID(rdevNegotiatedCodecH265)
	if !ok {
		t.Fatal("no H.265 profile registered")
	}
	nalHeader := func(nalType byte) []byte { return []byte{nalType << 1, 0x01} }
	vps := append(nalHeader(32), 0x0c, 0x01, 0xff)
	sps := append(nalHeader(33), 0x01, 0x02, 0x03)
	pps := append(nalHeader(34), 0x04, 0x05)
	idr := filler(nalHeader(19), 3000)
	accessUnit := annexB(vps, sps, pps, idr)

	packets := newPayloaderFor(profile).Payload(1200, accessUnit)
	if len(packets) < 2 {
		t.Fatalf("a 3000-byte IDR at MTU 1200 must fragment, got %d packet(s)", len(packets))
	}

	seen := map[uint8]bool{}
	fragmentStarts, fragmentEnds := 0, 0
	for index, payload := range packets {
		if len(payload) < 2 {
			t.Fatalf("packet %d is %d bytes, too short to carry a NAL header", index, len(payload))
		}
		header := codecs.H265NALUHeader(binary.BigEndian.Uint16(payload[0:2]))
		switch {
		case header.IsFragmentationUnit():
			unit := &codecs.H265FragmentationUnitPacket{}
			if _, err := unit.Unmarshal(payload); err != nil {
				t.Fatalf("fragmentation packet %d does not parse: %v", index, err)
			}
			seen[unit.FuHeader().FuType()] = true
			if unit.FuHeader().S() {
				fragmentStarts++
			}
			if unit.FuHeader().E() {
				fragmentEnds++
			}
		case header.IsAggregationPacket():
			aggregate := &codecs.H265AggregationPacket{}
			if _, err := aggregate.Unmarshal(payload); err != nil {
				t.Fatalf("aggregation packet %d does not parse: %v", index, err)
			}
			first := aggregate.FirstUnit()
			if first == nil {
				t.Fatalf("aggregation packet %d carries no first unit", index)
			}
			record := func(nal []byte) {
				if len(nal) >= 2 {
					seen[codecs.H265NALUHeader(binary.BigEndian.Uint16(nal[0:2])).Type()] = true
				}
			}
			record(first.NalUnit())
			for _, other := range aggregate.OtherUnits() {
				record(other.NalUnit())
			}
		default:
			single := &codecs.H265SingleNALUnitPacket{}
			if _, err := single.Unmarshal(payload); err != nil {
				t.Fatalf("single-NAL packet %d does not parse: %v", index, err)
			}
			seen[header.Type()] = true
		}
	}

	// EVERY INPUT NAL TYPE MUST BE RECOVERABLE. A dropped VPS/SPS/PPS is precisely what would leave a
	// hardware decoder unable to start, and it is invisible from the sending side.
	for _, want := range []uint8{32, 33, 34, 19} {
		if !seen[want] {
			t.Fatalf("NAL type %d did not survive packetization (recovered: %v)", want, seen)
		}
	}

	// A fragmented NAL has exactly one start and one end, or a receiver cannot bound it.
	if fragmentStarts != 1 || fragmentEnds != 1 {
		t.Fatalf("fragmentation flags incoherent: %d start(s), %d end(s)", fragmentStarts, fragmentEnds)
	}
}
