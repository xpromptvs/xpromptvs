package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/pion/webrtc/v4"
)

const (
	flexfecPayloadType              = 47
	flexFECRepairWindowMicroseconds = 10_000_000
	twccURI                         = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
)

type flexFECNegotiation struct {
	// Primaries maps each negotiated primary payload type to the RTX payload type that repairs it.
	//
	// A SET, because rdev offers AV1, H.265 and H.264 and a video section therefore carries three
	// primaries and three RTX. Holding exactly one of each was correct only while rdev offered one
	// codec — and the refusal it produced named `rtx/90000` rather than the codec, which sends the
	// reader to the wrong place entirely.
	//
	// FlexFEC ITSELF IS UNAFFECTED BY THE COUNT: it protects a media stream by SSRC (RFC 8627's
	// FEC-FR group), not by payload type, so one flexfec-03 registration covers every codec.
	Primaries map[int]int
	// PreferredPayloadType is rdev's most-preferred primary present in this section, and its RTX.
	// Identity comparisons use it so that two sections offering the same set agree on one value.
	PreferredPayloadType     int
	RTXPayloadType           int
	FlexFECPayloadType       int
	RepairWindowMicroseconds int
	TWCCExtensionID          int
	MediaSSRC                uint32
	RTXSSRC                  uint32
	FlexFECSSRC              uint32
}

func registerFlexFEC03(mediaEngine *webrtc.MediaEngine) error {
	if mediaEngine == nil {
		return fmt.Errorf("%w: nil media engine", errInvalidPeerConfig)
	}
	return mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypeFlexFEC03, ClockRate: 90_000,
			SDPFmtpLine: "repair-window=10000000",
		},
		PayloadType: flexfecPayloadType,
	}, webrtc.RTPCodecTypeVideo)
}

func validateFlexFECOffer(
	sdp string,
	expectedMaxAge time.Duration,
) (flexFECNegotiation, error) {
	return parseFlexFECNegotiation(sdp, expectedMaxAge, nil, false)
}

func validateFlexFECAnswer(
	sdp string,
	offer flexFECNegotiation,
	expectedMaxAge time.Duration,
) (flexFECNegotiation, error) {
	return parseFlexFECNegotiation(sdp, expectedMaxAge, &offer, true)
}

// THE OFFER PATH'S TWO WRAPPERS, WITH THE ROLES INVERTED — and that inversion is the whole reason
// they exist rather than reusing the pair above.
//
// FlexFEC's identity is carried by the SENDER's FID/FEC-FR SSRC groups. When this engine ANSWERS,
// the sender is us and the groups are in OUR ANSWER, so validateFlexFECAnswer requires them and
// validateFlexFECOffer (reading the viewer's offer) does not. When rdev OFFERS, the sender is still
// us — so the groups are in OUR OFFER, and the remote ANSWER is the receiver's and carries none.
// Chrome confirms that shape: it advertises flexfec-03 on the RECEIVE side only.
//
// Adding wrappers rather than re-pointing the existing two keeps the answering path byte-identical.

// THE OFFER PATH SEES THREE SECTION SHAPES; THE ANSWERING PATH ONLY EVER SEES ONE.
//
// rdev renegotiates on every subscribe and unsubscribe and its source cap is unbounded, so the
// description it is about to send is not the single sending m=video section the answering path's
// pair was written against. Measured against pion v4.2.18:
//
//	one subscribed source   one m=video section, a=sendrecv, its own FID + FEC-FR groups
//	two subscribed sources  TWO such sections (mid:0, mid:1), each complete
//	the last one removed    one section, a=recvonly, and NO a=ssrc lines at all
//
// The last two were REFUSED, and each refusal cost the whole session rather than one
// renegotiation — see createOffer. Neither is malformed: pion gives every track a complete
// FlexFEC identity, and a section we no longer send on has no sender to identify.
//
// SO THE RULE IS PER SECTION, AND IT KEYS OFF DIRECTION. Every section we SEND on must satisfy the
// FlexFEC contract in full, including its own SSRC groups; a section we do not send on carries no
// contract. advertiseRTXTime already reasons this way — its duplicate-fmtp check is per section
// precisely because a session can carry more than one video track (peer_config.go) — and this is
// the one place that had not caught up.

// videoSectionsOf splits a description into its m=video sections, in wire order. A section's index
// here is its position among VIDEO sections, which is what the offer/answer correspondence below
// is keyed on.
func videoSectionsOf(sdp string) [][]string {
	var sections [][]string
	inVideo := false
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if strings.HasPrefix(line, "m=") {
			inVideo = strings.HasPrefix(line, "m=video ")
			if inVideo {
				sections = append(sections, []string{line})
			}
			continue
		}
		if inVideo && line != "" {
			sections[len(sections)-1] = append(sections[len(sections)-1], line)
		}
	}
	return sections
}

// videoSectionSends reports whether the description's author sends media on this section.
//
// The DEFAULT WHEN NO DIRECTION IS PRESENT IS sendrecv, which is RFC 4566's, so an omitted
// attribute is read as sending and gets validated rather than silently skipped. pion always emits
// one; the default matters only if that ever changes, and erring toward validating is the safe
// direction for a check whose job is to catch a dropped FlexFEC.
func videoSectionSends(lines []string) bool {
	for _, line := range lines[1:] {
		switch line {
		case "a=sendrecv", "a=sendonly":
			return true
		case "a=recvonly", "a=inactive":
			return false
		}
	}
	return true
}

// sameFlexFECIdentity compares everything that must agree across a description's video sections.
// The SSRCs are deliberately excluded: they are per track, and differing is what correct looks
// like.
func sameFlexFECIdentity(a, b flexFECNegotiation) bool {
	if len(a.Primaries) != len(b.Primaries) {
		return false
	}
	for primary, rtx := range a.Primaries {
		if other, ok := b.Primaries[primary]; !ok || other != rtx {
			return false
		}
	}
	return a.PreferredPayloadType == b.PreferredPayloadType &&
		a.RTXPayloadType == b.RTXPayloadType &&
		a.FlexFECPayloadType == b.FlexFECPayloadType &&
		a.RepairWindowMicroseconds == b.RepairWindowMicroseconds &&
		a.TWCCExtensionID == b.TWCCExtensionID
}

// answerDeclinesFlexFEC reports that the answer carries NO flexfec-03 at all in the sections we
// offered it on — a receiver declining a capability, rather than one answering it incorrectly.
//
// THE DISTINCTION IS THE WHOLE POINT. Declining must degrade to NACK/RTX and keep the video;
// answering wrongly must still fail, because a malformed FlexFEC description arms the FEC into a
// state its own validators call impossible. Reading "any flexfec-03 rtpmap present" as the test
// keeps that line exactly where it belongs: presence means the receiver is making a claim about
// FlexFEC, and every claim is then validated in full.
func answerDeclinesFlexFEC(sdp string, sections []int) bool {
	videoSections := videoSectionsOf(sdp)
	for _, index := range sections {
		if index >= len(videoSections) {
			continue
		}
		for _, line := range videoSections[index] {
			if strings.HasPrefix(line, "a=rtpmap:") &&
				strings.Contains(strings.ToLower(line), "flexfec-03") {
				return false
			}
		}
	}
	return true
}

// validateFlexFECLocalOffer validates an offer THIS session is about to send, and returns the
// identity it offered plus the indices of the video sections that identity covers.
//
// AN EMPTY INDEX LIST IS SUCCESS, NOT A REFUSAL: it means the offer sends no video, which is what
// unsubscribing the last source produces. The caller must then treat the round as carrying no
// FlexFEC contract at all — including when the answer arrives.
//
// Groups ARE required on every sending section: on this path we are the sender, the inverse of
// what validateFlexFECOffer/validateFlexFECAnswer encode for the answering path.
func validateFlexFECLocalOffer(
	sdp string,
	expectedMaxAge time.Duration,
) (flexFECNegotiation, []int, error) {
	var identity flexFECNegotiation
	var sending []int
	for index, lines := range videoSectionsOf(sdp) {
		if !videoSectionSends(lines) {
			continue
		}
		parsed, err := parseFlexFECVideoSection(lines, sdp, expectedMaxAge, nil, true)
		if err != nil {
			return flexFECNegotiation{}, nil, fmt.Errorf("video section %d: %w", index, err)
		}
		if len(sending) > 0 && !sameFlexFECIdentity(identity, parsed) {
			return flexFECNegotiation{}, nil, fmt.Errorf(
				"%w: video sections disagree on the FlexFEC identity", errInvalidPeerConfig,
			)
		}
		identity = parsed
		sending = append(sending, index)
	}
	return identity, sending, nil
}

// validateFlexFECRemoteAnswer validates the answer to that offer. No groups: the remote receives.
// The identity must match what we offered, which is what the `offer` argument enforces.
//
// IT CHECKS EXACTLY THE SECTIONS THE OFFER SENT ON, BY INDEX, and that is the only correspondence
// that survives every shape above. Filtering the ANSWER by direction would be wrong — the remote
// answers our sendrecv with recvonly — and filtering by "carries flexfec-03" would skip precisely
// the section a browser had stripped it from, which is the failure this check exists to catch.
func validateFlexFECRemoteAnswer(
	sdp string,
	offer flexFECNegotiation,
	sections []int,
	expectedMaxAge time.Duration,
) (flexFECNegotiation, error) {
	all := videoSectionsOf(sdp)
	var negotiated flexFECNegotiation
	for order, index := range sections {
		if index >= len(all) {
			return flexFECNegotiation{}, fmt.Errorf(
				"%w: answer has %d video sections, offer sent on section %d",
				errInvalidPeerConfig, len(all), index,
			)
		}
		parsed, err := parseFlexFECVideoSection(all[index], sdp, expectedMaxAge, &offer, false)
		if err != nil {
			return flexFECNegotiation{}, fmt.Errorf("video section %d: %w", index, err)
		}
		if order == 0 {
			negotiated = parsed
		}
	}
	return negotiated, nil
}

// parseFlexFECNegotiation is the ANSWERING path's entry point and is deliberately unchanged: one
// video section or nothing. That path's descriptions come from LLV's own viewer, which offers a
// single track, and it is the certification's comparison arm — so it keeps the strict shape while
// the offer path below learns rdev's.
func parseFlexFECNegotiation(
	sdp string,
	expectedMaxAge time.Duration,
	offer *flexFECNegotiation,
	requireSSRCGroups bool,
) (flexFECNegotiation, error) {
	lines, err := oneVideoSection(sdp)
	if err != nil {
		return flexFECNegotiation{}, err
	}
	return parseFlexFECVideoSection(lines, sdp, expectedMaxAge, offer, requireSSRCGroups)
}

// parseFlexFECVideoSection judges ONE video m-section. `sdp` is still the whole description
// because the TWCC extmap is a description-wide fact — videoHeaderExtensionID already requires
// every video section to agree on its id, so reading it per section would assert nothing new.
func parseFlexFECVideoSection(
	lines []string,
	sdp string,
	expectedMaxAge time.Duration,
	offer *flexFECNegotiation,
	requireSSRCGroups bool,
) (flexFECNegotiation, error) {
	var err error
	result := flexFECNegotiation{
		PreferredPayloadType: -1, RTXPayloadType: -1, FlexFECPayloadType: -1,
		Primaries:                map[int]int{},
		RepairWindowMicroseconds: -1, TWCCExtensionID: -1,
	}
	payloadsInMediaLine, err := videoMediaPayloads(lines[0])
	if err != nil {
		return flexFECNegotiation{}, err
	}
	codecPayloads := map[string][]int{}
	for _, line := range lines[1:] {
		if !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		space := strings.IndexByte(line, ' ')
		if space <= len("a=rtpmap:") {
			return flexFECNegotiation{}, fmt.Errorf("%w: malformed rtpmap", errInvalidPeerConfig)
		}
		payloadType, parseErr := strconv.Atoi(line[len("a=rtpmap:"):space])
		if parseErr != nil || payloadType < 0 || payloadType > 127 {
			return flexFECNegotiation{}, fmt.Errorf("%w: invalid rtpmap payload", errInvalidPeerConfig)
		}
		codec := strings.ToLower(strings.TrimSpace(line[space+1:]))
		codecPayloads[codec] = append(codecPayloads[codec], payloadType)
	}
	// EXACTLY ONE flexfec-03, whatever the codec count. FlexFEC protects by SSRC, so one
	// registration covers every primary; two would be two repair streams for one media stream.
	flexFECPayloads := codecPayloads["flexfec-03/90000"]
	if len(flexFECPayloads) != 1 || !payloadsInMediaLine[flexFECPayloads[0]] {
		return flexFECNegotiation{}, fmt.Errorf(
			"%w: expected one negotiated flexfec-03/90000 payload", errInvalidPeerConfig,
		)
	}
	result.FlexFECPayloadType = flexFECPayloads[0]

	// EACH REGISTERED PRIMARY AT MOST ONCE, and at least one present. A codec appearing twice is a
	// description nothing can act on; none appearing means this section carries no media rdev sends.
	for _, profile := range videoCodecProfiles() {
		payloads := codecPayloads[profile.rtpmapName]
		if len(payloads) == 0 {
			continue
		}
		if len(payloads) != 1 || !payloadsInMediaLine[payloads[0]] {
			return flexFECNegotiation{}, fmt.Errorf(
				"%w: expected at most one negotiated %s payload", errInvalidPeerConfig, profile.rtpmapName,
			)
		}
		if result.PreferredPayloadType < 0 {
			result.PreferredPayloadType = payloads[0]
		}
		// The RTX partner is filled in from the fmtp apt= associations below.
		result.Primaries[payloads[0]] = -1
	}
	if result.PreferredPayloadType < 0 {
		return flexFECNegotiation{}, fmt.Errorf(
			"%w: no negotiated primary video payload", errInvalidPeerConfig,
		)
	}
	if _, clash := result.Primaries[result.FlexFECPayloadType]; clash {
		return flexFECNegotiation{}, fmt.Errorf("%w: duplicate recovery payload type", errInvalidPeerConfig)
	}

	rtxPayloads := map[int]bool{}
	for _, payloadType := range codecPayloads["rtx/90000"] {
		rtxPayloads[payloadType] = true
	}
	rtxFMTPCount := 0
	flexFECFMTPCount := 0
	for _, line := range lines[1:] {
		payloadType, parameters, _, ok := parseFMTPLine(line)
		if !ok {
			continue
		}
		switch {
		case rtxPayloads[payloadType]:
			// EVERY RTX MUST NAME A PRIMARY PRESENT IN THIS SECTION, and carry the retransmission
			// window we asked for. One RTX per primary is correct (RFC 4588 associates them by
			// apt=), so this counts associations rather than requiring exactly one.
			rtxFMTPCount++
			apt, rtxTime, parseErr := parseRTXParameters(parameters)
			if parseErr != nil || rtxTime != int(expectedMaxAge/time.Millisecond) {
				return flexFECNegotiation{}, fmt.Errorf(
					"%w: invalid FlexFEC-mode RTX fmtp", errInvalidPeerConfig,
				)
			}
			if _, known := result.Primaries[apt]; !known {
				return flexFECNegotiation{}, fmt.Errorf(
					"%w: RTX %d repairs unnegotiated payload %d", errInvalidPeerConfig, payloadType, apt,
				)
			}
			result.Primaries[apt] = payloadType
			if apt == result.PreferredPayloadType {
				result.RTXPayloadType = payloadType
			}
		case payloadType == result.FlexFECPayloadType:
			flexFECFMTPCount++
			repairWindow, parseErr := parseFlexFECRepairWindow(parameters)
			if parseErr != nil {
				return flexFECNegotiation{}, parseErr
			}
			result.RepairWindowMicroseconds = repairWindow
		}
	}
	if rtxFMTPCount != len(result.Primaries) || flexFECFMTPCount != 1 {
		return flexFECNegotiation{}, fmt.Errorf(
			"%w: duplicate or missing recovery fmtp", errInvalidPeerConfig,
		)
	}
	for primary, rtx := range result.Primaries {
		if rtx < 0 {
			return flexFECNegotiation{}, fmt.Errorf(
				"%w: negotiated payload %d has no RTX", errInvalidPeerConfig, primary,
			)
		}
	}

	// COUNTED PER PRIMARY. Every negotiated codec must carry the full feedback set: a codec offered
	// without `nack pli` cannot have a lost keyframe re-requested, and the session would look
	// healthy while never recovering.
	requiredFeedback := map[string]map[int]int{
		"nack": {}, "nack pli": {}, "transport-cc": {},
	}
	for primary := range result.Primaries {
		for _, counts := range requiredFeedback {
			counts[primary] = 0
		}
	}
	for _, line := range lines[1:] {
		if !strings.HasPrefix(line, "a=rtcp-fb:") {
			continue
		}
		space := strings.IndexByte(line, ' ')
		if space <= len("a=rtcp-fb:") {
			continue
		}
		payloadType, parseErr := strconv.Atoi(line[len("a=rtcp-fb:"):space])
		feedback := strings.TrimSpace(line[space+1:])
		if parseErr != nil || payloadType < 0 || payloadType > 127 {
			return flexFECNegotiation{}, fmt.Errorf("%w: invalid RTCP feedback payload", errInvalidPeerConfig)
		}
		if _, isPrimary := result.Primaries[payloadType]; feedback == "transport-cc" && !isPrimary {
			return flexFECNegotiation{}, fmt.Errorf(
				"%w: transport-cc is on payload %d, which is not a negotiated primary",
				errInvalidPeerConfig, payloadType,
			)
		}
		if _, isPrimary := result.Primaries[payloadType]; isPrimary {
			if counts, required := requiredFeedback[feedback]; required {
				counts[payloadType]++
			}
		}
	}
	for feedback, counts := range requiredFeedback {
		for primary, count := range counts {
			if count != 1 {
				return flexFECNegotiation{}, fmt.Errorf(
					"%w: expected one %s feedback on payload %d", errInvalidPeerConfig, feedback, primary,
				)
			}
		}
	}
	result.TWCCExtensionID, err = videoHeaderExtensionID(sdp, twccURI)
	if err != nil {
		return flexFECNegotiation{}, err
	}

	// THE ANSWER MAY NARROW THE CODEC SET. THAT IS WHAT NEGOTIATION IS.
	//
	// This compared the PRIMARY payload type against the offer's, which was correct only while rdev
	// offered one codec: with three, a receiver that cannot decode AV1 answers H.264 and the
	// comparison read the narrowing as tampering. Every AV1-less device — the ones this codec work
	// exists for — was rejected with "answer changed FlexFEC identity", a message about FEC for a
	// failure about codecs.
	//
	// WHAT MUST STILL MATCH IS THE FEC'S OWN IDENTITY: its payload type, its repair window and the
	// TWCC extension id. Those are ours, we offered them, and an answer that alters them is
	// describing a FEC configuration we never proposed.
	//
	// AND THE NARROWING MUST BE A SUBSET, not an invention: every primary the answer keeps has to
	// be one we offered, with the RTX partner we paired it with. Without that second half this
	// check would accept a codec rdev never registered and cannot encode.
	if offer != nil {
		if result.FlexFECPayloadType != offer.FlexFECPayloadType ||
			result.RepairWindowMicroseconds != offer.RepairWindowMicroseconds ||
			result.TWCCExtensionID != offer.TWCCExtensionID {
			return flexFECNegotiation{}, fmt.Errorf(
				"%w: answer changed FlexFEC identity", errInvalidPeerConfig)
		}
		for primary, rtx := range result.Primaries {
			offeredRTX, offered := offer.Primaries[primary]
			if !offered {
				return flexFECNegotiation{}, fmt.Errorf(
					"%w: answer negotiated payload %d, which was never offered",
					errInvalidPeerConfig, primary)
			}
			if rtx != offeredRTX {
				return flexFECNegotiation{}, fmt.Errorf(
					"%w: answer paired payload %d with RTX %d, offered %d",
					errInvalidPeerConfig, primary, rtx, offeredRTX)
			}
		}
	}
	if requireSSRCGroups {
		if err := parseFlexFECSSRCGroups(lines, &result); err != nil {
			return flexFECNegotiation{}, err
		}
	}
	return result, nil
}

func parseFlexFECRepairWindow(parameters string) (int, error) {
	parts := strings.Split(parameters, ";")
	if len(parts) != 1 {
		return -1, fmt.Errorf("%w: invalid FlexFEC fmtp", errInvalidPeerConfig)
	}
	keyValue := strings.SplitN(strings.TrimSpace(parts[0]), "=", 2)
	if len(keyValue) != 2 || strings.TrimSpace(keyValue[0]) != "repair-window" {
		return -1, fmt.Errorf("%w: invalid FlexFEC repair window", errInvalidPeerConfig)
	}
	value, err := strconv.Atoi(strings.TrimSpace(keyValue[1]))
	if err != nil || value != flexFECRepairWindowMicroseconds {
		return -1, fmt.Errorf("%w: invalid FlexFEC repair window", errInvalidPeerConfig)
	}
	return value, nil
}

func oneVideoSection(sdp string) ([]string, error) {
	var result []string
	inVideo := false
	found := false
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if strings.HasPrefix(line, "m=") {
			if strings.HasPrefix(line, "m=video ") {
				if found {
					return nil, fmt.Errorf("%w: multiple video sections", errInvalidPeerConfig)
				}
				found = true
				inVideo = true
				result = append(result, line)
				continue
			}
			inVideo = false
		}
		if inVideo && line != "" {
			result = append(result, line)
		}
	}
	if !found || len(result) == 0 {
		return nil, fmt.Errorf("%w: missing video section", errInvalidPeerConfig)
	}
	return result, nil
}

func videoMediaPayloads(line string) (map[int]bool, error) {
	fields := strings.Fields(line)
	if len(fields) < 4 || fields[0] != "m=video" {
		return nil, fmt.Errorf("%w: malformed video media line", errInvalidPeerConfig)
	}
	result := map[int]bool{}
	for _, field := range fields[3:] {
		payloadType, err := strconv.Atoi(field)
		if err != nil || payloadType < 0 || payloadType > 127 || result[payloadType] {
			return nil, fmt.Errorf("%w: invalid video payload list", errInvalidPeerConfig)
		}
		result[payloadType] = true
	}
	return result, nil
}

func parseFlexFECSSRCGroups(lines []string, result *flexFECNegotiation) error {
	var fidMedia uint32
	var fecMedia uint32
	fidCount := 0
	fecCount := 0
	for _, line := range lines {
		kind := ""
		switch {
		case strings.HasPrefix(line, "a=ssrc-group:FID "):
			kind = "FID"
		case strings.HasPrefix(line, "a=ssrc-group:FEC-FR "):
			kind = "FEC-FR"
		default:
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 3 {
			return fmt.Errorf("%w: malformed %s SSRC group", errInvalidPeerConfig, kind)
		}
		media, mediaErr := strconv.ParseUint(fields[1], 10, 32)
		repair, repairErr := strconv.ParseUint(fields[2], 10, 32)
		if mediaErr != nil || repairErr != nil || media == 0 || repair == 0 || media == repair {
			return fmt.Errorf("%w: invalid %s SSRC group", errInvalidPeerConfig, kind)
		}
		if kind == "FID" {
			fidCount++
			fidMedia = uint32(media)
			result.RTXSSRC = uint32(repair)
		} else {
			fecCount++
			fecMedia = uint32(media)
			result.FlexFECSSRC = uint32(repair)
		}
	}
	if fidCount != 1 || fecCount != 1 || fidMedia == 0 || fidMedia != fecMedia ||
		result.RTXSSRC == 0 || result.FlexFECSSRC == 0 ||
		result.RTXSSRC == result.FlexFECSSRC {
		return fmt.Errorf("%w: answer needs matching FID and FEC-FR groups", errInvalidPeerConfig)
	}
	result.MediaSSRC = fidMedia
	return nil
}

// validateLegacyRecoverySDP proves a legacy-recovery session negotiated no FlexFEC and no TWCC.
//
// SCOPED TO EVERYTHING EXCEPT THE AUDIO SECTION SINCE AUDIO LANDED. This always MEANT "for video" —
// it was written as a whole-SDP substring scan because every description this path had ever seen was
// video plus a data channel, and there was nothing else for the scan to reach. rdev offers Opus with
// NO RTCP feedback at all (see newPeerAPI), so a transport-cc inside an m=audio section can only
// have come from the remote's answer, and failing the whole session over it reports FlexFEC for a
// fault that is neither FlexFEC's nor video's — a cause one layer away from its symptom, on a path
// rdev cannot fix from its own end.
//
// SESSION-LEVEL LINES STAY IN SCOPE. A line before the first m= belongs to no media section, so
// exempting it would exempt the entire description by writing one line higher up.
//
// THE VIDEO ARM IS UNCHANGED AND MUST STAY THAT WAY — TestLegacyRecoveryStillRejectsVideoTransportCC
// and its flexfec sibling are what stop this becoming "accept everything", which is the shape a
// scoping change fails into.
func validateLegacyRecoverySDP(sdp string, recovery RecoveryMode) error {
	if recovery != RecoveryNACKRTX && recovery != RecoveryOff {
		return fmt.Errorf("%w: invalid legacy recovery mode", errInvalidPeerConfig)
	}
	inAudio := false
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(rawLine, "\r")))
		if strings.HasPrefix(line, "m=") {
			inAudio = strings.HasPrefix(line, "m=audio ")
			continue
		}
		if inAudio {
			continue
		}
		if strings.Contains(line, "flexfec") || strings.Contains(line, "fec-fr") ||
			strings.Contains(line, "transport-cc") || strings.Contains(line, strings.ToLower(twccURI)) {
			return fmt.Errorf("%w: legacy SDP contains FlexFEC/TWCC", errInvalidPeerConfig)
		}
	}
	return nil
}

// describeVideoSectionForDiagnosis renders every video m-section of an SDP as the few facts this
// parser actually judges: the payload types the m= line admits, and each rtpmap with its codec.
//
// IT DELIBERATELY DOES NOT REUSE oneVideoSection. That helper refuses a multi-section SDP, and a
// diagnosis is needed most exactly when the input is a shape the parser did not expect — a
// describer that fails on the same input as the thing it is describing is useless.
func describeVideoSectionForDiagnosis(sdp string) string {
	var out strings.Builder
	inVideo := false
	section := 0
	for _, rawLine := range strings.Split(sdp, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if strings.HasPrefix(line, "m=") {
			inVideo = strings.HasPrefix(line, "m=video ")
			if inVideo {
				// ZERO-BASED, matching the indices the offer-path validators report and the ones
				// offeredFlexFECSections stores. It was 1-based, which put a log line's "section 1"
				// one off from the "video section 0" in the error printed directly above it.
				fmt.Fprintf(&out, "  video section %d: %s\n", section, line)
				section++
			}
			continue
		}
		if !inVideo {
			continue
		}
		switch {
		case strings.HasPrefix(line, "a=rtpmap:"),
			strings.HasPrefix(line, "a=ssrc-group:"),
			strings.HasPrefix(line, "a=fmtp:"),
			line == "a=inactive", line == "a=sendonly",
			line == "a=recvonly", line == "a=sendrecv":
			fmt.Fprintf(&out, "    %s\n", line)
		}
	}
	if section == 0 {
		return "  (no video section at all)"
	}
	return strings.TrimRight(out.String(), "\n")
}
