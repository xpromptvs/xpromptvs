package main

import (
	"strings"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
)

// codecID is the resolved-codec value that crosses the ABI. Its constants live beside
// pion_on_codec_resolved in rdev_abi.go, because that is the contract they belong to.
type codecID = int

// videoCodecProfile is EVERYTHING codec-specific in one place, so adding a fourth codec is a table
// entry rather than an edit at each of the seven sites that used to hardcode AV1.
//
// IT EXISTS BECAUSE SCATTERING THE DECISION IS WHAT PRODUCED THIS PROJECT'S TWO SILENT FlexFEC
// FAILURES: each seam looked locally correct, and the set of seams was never written down anywhere.
// The seven were, in the end: codec registration, FrameTrack.Bind, FrameTrack.WriteVideo,
// preparePionRemoteDescription, recoveryPayloadTypes, parseFlexFECNegotiation and SessionStats.
type videoCodecProfile struct {
	codec codecID
	// mimeType is pion's spelling, and it is what the negotiated CodecParameters carry.
	mimeType string
	// rtpmapName is the SDP spelling, LOWERCASED, which is how the SDP-scanning helpers match. It
	// is stored rather than derived from mimeType because those helpers lowercase what they read
	// and comparing against a derived value at every site invites one of them to forget.
	rtpmapName     string
	payloadType    uint8
	rtxPayloadType uint8
	// fmtpLine is the format parameters offered for this codec. EMPTY means none are offered, which
	// is not the same as offering an empty one.
	fmtpLine string
	// emitsDependencyDescriptor is whether frames on this codec carry the AV1 dependency descriptor.
	// Browsers negotiate that extension for AV1; an H.264/H.265 answer carries none, so every site
	// that requires the extension must consult this rather than assume.
	emitsDependencyDescriptor bool
}

// videoCodecProfiles returns rdev's PREFERENCE ORDER, which is what decides the codec for a browser
// that accepts several. The answer's own order is the ANSWERER's preference and is deliberately not
// honoured: Chrome decodes AV1 and H.265 both, and AV1 is measurably better per bit on the text and
// UI rdev actually streams.
//
// H.265 ahead of H.264 for the same reason one rung down — better per bit, and hardware-decoded on
// the devices that lack AV1 in the first place.
func videoCodecProfiles() []videoCodecProfile {
	return []videoCodecProfile{
		{
			codec: rdevNegotiatedCodecAV1, mimeType: webrtc.MimeTypeAV1, rtpmapName: "av1/90000",
			payloadType: av1PayloadType, rtxPayloadType: rtxPayloadType,
			fmtpLine: "", emitsDependencyDescriptor: true,
		},
		{
			codec: rdevNegotiatedCodecH265, mimeType: webrtc.MimeTypeH265, rtpmapName: "h265/90000",
			payloadType: h265PayloadType, rtxPayloadType: h265RTXPayloadType,
			// NO level-id, AND THAT IS LOAD-BEARING. pion ships fmtp matchers for H.264/VP9/AV1 and
			// NONE for H.265, so H.265 falls to the GENERIC matcher, which rejects a match when a
			// key is present in both offer and answer with DIFFERENT values. level-id is a
			// per-device DECODER capability — Safari answers 93, Chrome 180 — not a stream
			// property. Offering it conflicts with almost every answer, demotes H.265 to a partial
			// match, and gets it discarded in favour of an exactly-matching H.264 — after which the
			// host ships a codec the browser did not expect and video stalls while every state
			// reads healthy. INVISIBLE IN CHROME, which echoes the offered fmtp exactly. This cost
			// the project a day before the cutover; TestH265FmtpOmitsLevelID pins it.
			fmtpLine: "profile-id=1;tier-flag=0;tx-mode=SRST", emitsDependencyDescriptor: false,
		},
		{
			codec: rdevNegotiatedCodecH264, mimeType: webrtc.MimeTypeH264, rtpmapName: "h264/90000",
			payloadType: h264PayloadType, rtxPayloadType: h264RTXPayloadType,
			// Constrained Baseline. 640c1f (ConstrainedHigh) measured better on both axes — 72/90
			// frames out against 65/90, and fewer bytes — but changing it needs a real non-Chrome
			// browser matrix and is a separate measured change rather than a rider on this one.
			fmtpLine:                  "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
			emitsDependencyDescriptor: false,
		},
	}
}

// preferredProfiles returns the profiles to try, in order, for a caller's preference.
//
// AN EMPTY PREFERENCE MEANS rdev's GLOBAL ORDER, which is what `auto` maps to. A preference naming
// codecs rdev does not register falls through to that same order rather than yielding an empty list.
//
// THIS COMMENT USED TO ARGUE THE OPPOSITE — that a pin which cannot be honoured should refuse rather
// than "silently get another one". The reasoning was sound and the consequence was not: refusing
// means Bind fails the track, and a failed track is not a message, it is a dead stream. Nor is the
// fallback silent — the client renders a refused pin as amber `data-unmet`, machinery that exists
// for precisely this case and was unreachable while the refusal killed the video first.
func preferredProfiles(preference []codecID) []videoCodecProfile {
	all := videoCodecProfiles()
	if len(preference) == 0 {
		return all
	}
	// A PIN ORDERS THE SURVIVORS; IT MUST NOT ELIMINATE THEM. This used to return ONLY the pinned
	// profiles, which made a preference a hard filter on the ANSWER too: pin a codec the receiver
	// cannot negotiate and Bind had nothing left to select, so it failed the track with "none of
	// rdev's codecs were negotiated" and video stopped for good. Reported from macOS Safari, whose
	// WebRTC answers H.265 and H.264 but not AV1 — hardware AV1 decode is a different thing from
	// WebRTC negotiation, so the machine having it says nothing.
	//
	// The remainder is appended in rdev's OWN order, not the caller's, because that is what the rest
	// of the preference means once the pin is unavailable.
	out := make([]videoCodecProfile, 0, len(all))
	pinned := make(map[codecID]bool, len(preference))
	for _, id := range preference {
		if profile, ok := profileForCodecID(id); ok && !pinned[id] {
			out = append(out, profile)
			pinned[id] = true
		}
	}
	for _, profile := range all {
		if !pinned[profile.codec] {
			out = append(out, profile)
		}
	}
	return out
}

// statsName is the codec's spelling in SessionStats, which LLVCore.CaptureTransport decodes and a
// frozen test asserts against for AV1. Derived from the mime type so a new codec cannot be added
// without one.
func (profile videoCodecProfile) statsName() string {
	return strings.TrimPrefix(profile.mimeType, "video/")
}

func profileForMimeType(mime string) (videoCodecProfile, bool) {
	for _, profile := range videoCodecProfiles() {
		if strings.EqualFold(profile.mimeType, mime) {
			return profile, true
		}
	}
	return videoCodecProfile{}, false
}

func profileForCodecID(id codecID) (videoCodecProfile, bool) {
	for _, profile := range videoCodecProfiles() {
		if profile.codec == id {
			return profile, true
		}
	}
	return videoCodecProfile{}, false
}

// newPayloaderFor returns a FRESH payloader per frame. H264Payloader carries per-call state across
// Payload invocations, so sharing one between frames is not safe; the AV1 path has always
// constructed one per frame for the same reason.
func newPayloaderFor(profile videoCodecProfile) rtp.Payloader {
	switch profile.codec {
	case rdevNegotiatedCodecH265:
		return &codecs.H265Payloader{}
	case rdevNegotiatedCodecH264:
		return &codecs.H264Payloader{}
	default:
		return &codecs.AV1Payloader{}
	}
}

// keyframeFromPayload reports whether this RTP payload STARTS a keyframe.
//
// Asked only of a frame's FIRST packet, and only when no dependency descriptor was negotiated —
// which is every H.264 and H.265 browser session. A payload too short to classify is NOT a keyframe:
// a truncated read must degrade protection, never fail a session.
//
// A WRONG ANSWER CANNOT CRASH ANYTHING, which is exactly why it needs tests. It protects a keyframe
// at the normal ratio instead of the pinned 2/5 — worse recovery, no error, no log, and invisible on
// a link with no loss.
func (profile videoCodecProfile) keyframeFromPayload(payload []byte) bool {
	switch profile.codec {
	case rdevNegotiatedCodecH264:
		return h264PayloadStartsKeyframe(payload)
	case rdevNegotiatedCodecH265:
		return h265PayloadStartsKeyframe(payload)
	default:
		// AV1 carries a dependency descriptor and never reaches here. Guessing from an OBU would be
		// a second source of truth for a question the descriptor already answers exactly.
		return false
	}
}

func h264NALTypeIsKeyframe(nalType byte) bool {
	// 5 IDR, 7 SPS, 8 PPS. THE PARAMETER SETS ARE THE PRIMARY PATH: pion's H264Payloader emits them
	// as a STAP-A ahead of the IDR, so the first packet of a keyframe never contains type 5.
	return nalType == 5 || nalType == 7 || nalType == 8
}

func h264PayloadStartsKeyframe(payload []byte) bool {
	if len(payload) < 1 {
		return false
	}
	switch nalType := payload[0] & 0x1f; nalType {
	case 28, 29: // FU-A / FU-B: the real type is in the FU header.
		if len(payload) < 2 {
			return false
		}
		return h264NALTypeIsKeyframe(payload[1] & 0x1f)
	case 24: // STAP-A: walk the aggregated units.
		for offset := 1; offset+2 <= len(payload); {
			size := int(payload[offset])<<8 | int(payload[offset+1])
			offset += 2
			if size <= 0 || offset+size > len(payload) {
				return false
			}
			if h264NALTypeIsKeyframe(payload[offset] & 0x1f) {
				return true
			}
			offset += size
		}
		return false
	default:
		return h264NALTypeIsKeyframe(nalType)
	}
}

func h265NALTypeIsKeyframe(nalType byte) bool {
	// 16-21 BLA_W_LP..CRA_NUT, and 32/33/34 VPS/SPS/PPS for the same reason H.264's 7/8 count.
	return (nalType >= 16 && nalType <= 21) || (nalType >= 32 && nalType <= 34)
}

func h265PayloadStartsKeyframe(payload []byte) bool {
	if len(payload) < 2 {
		return false
	}
	switch nalType := (payload[0] >> 1) & 0x3f; nalType {
	case 49: // Fragmentation unit: the real type is in the FU header.
		if len(payload) < 3 {
			return false
		}
		return h265NALTypeIsKeyframe(payload[2] & 0x3f)
	case 48: // Aggregation packet: walk the aggregated units.
		// THE FIRST PACKET OF EVERY H.265 KEYFRAME IS ONE OF THESE, which is the whole reason this
		// arm exists — it is the exact counterpart of H.264's STAP-A above, and it was missing.
		// pion's H265Payloader aggregates by default (SkipAggregation is false, as DisableStapA is),
		// so the VPS/SPS/PPS the encoder prepends arrive bundled and the IDR follows in its own
		// fragments. Measured against pion v1.10.2: a keyframe access unit packetizes to
		// `60 01 | 0005 | 40 01 0c 01 ff | 0005 | 42 01 01 02 03 | 0004 | 44 01 04 05` and three FUs.
		//
		// Layout after the 2-byte payload header: per unit a 2-byte size, then the unit INCLUDING
		// its own 2-byte NAL header — hence a size below 2 is malformed rather than merely empty.
		// There is no DONL to skip: pion's payloader emits none, and rdev's fmtp advertises no
		// sprop-max-don-diff, so a receiver may not expect one either.
		for offset := 2; offset+2 <= len(payload); {
			size := int(payload[offset])<<8 | int(payload[offset+1])
			offset += 2
			if size < 2 || offset+size > len(payload) {
				return false
			}
			if h265NALTypeIsKeyframe((payload[offset] >> 1) & 0x3f) {
				return true
			}
			offset += size
		}
		return false
	default:
		return h265NALTypeIsKeyframe(nalType)
	}
}

// profileForPayloadType finds the registered profile a negotiated payload type belongs to.
func profileForPayloadType(payloadType uint8) (videoCodecProfile, bool) {
	for _, profile := range videoCodecProfiles() {
		if profile.payloadType == payloadType {
			return profile, true
		}
	}
	return videoCodecProfile{}, false
}
