package main

import (
	"strings"
	"testing"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

// audioSectionOf returns the m=audio section of an SDP, so an assertion cannot accidentally match a
// line in the video or application section.
func audioSectionOf(t *testing.T, sdp string) string {
	t.Helper()
	var out []string
	in := false
	for _, line := range strings.Split(sdp, "\n") {
		trimmed := strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(trimmed, "m=") {
			in = strings.HasPrefix(trimmed, "m=audio ")
		}
		if in {
			out = append(out, trimmed)
		}
	}
	if len(out) == 0 {
		t.Fatalf("no audio section in:\n%s", sdp)
	}
	return strings.Join(out, "\n")
}

func countAudioSections(sdp string) int {
	count := 0
	for _, raw := range strings.Split(sdp, "\n") {
		if strings.HasPrefix(strings.TrimSuffix(raw, "\r"), "m=audio ") {
			count++
		}
	}
	return count
}

// THE GUARD FOR THE WHOLE ABI DECISION. Two AddTrack calls produce two offers per subscribe,
// because scheduleOffer drives immediately from `stable` and the second add lands while the peer is
// in have-local-offer. That is slower, churns m-lines, and lands on the documented coalescing
// defect ("the SECOND of two rapid subscribes reads as a peer rebuild — measured: zero frames").
//
// IT MUST FAIL IF THE ADDS ARE SPLIT BACK APART. A test that cannot see that split is not testing
// this decision — so it asserts that ONE CreateOffer carries BOTH sections.
func TestAddSourceTracksPutsBothSectionsInOneOffer(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("win:1", nil); err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if got := countVideoSections(sdp); got != 1 {
		t.Fatalf("video m-sections = %d, want 1", got)
	}
	if got := countAudioSections(sdp); got != 1 {
		t.Fatalf("audio m-sections = %d, want 1 — both tracks must ride ONE offer", got)
	}
}

// Opus is offered, with the exact fmtp the client half assumes. minptime=10 matches
// AudioFraming.defaultFramesPerChannel (480 frames at 48 kHz); they are one decision.
func TestOfferCarriesOpus(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("win:1", nil); err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if !strings.Contains(sdp, "opus/48000/2") {
		t.Fatalf("offer carries no Opus:\n%s", sdp)
	}
	if !strings.Contains(sdp, "minptime=10;useinbandfec=1") {
		t.Fatalf("offer carries the wrong Opus fmtp:\n%s", sdp)
	}
}

// NO RTCP FEEDBACK ON THE AUDIO SECTION. transport-cc on audio is what would trip
// validateLegacyRecoverySDP under RDEV_LLV_RECOVERY=nack-rtx, and rdev must not be the end that
// introduces the string.
func TestAudioSectionCarriesNoFeedback(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("win:1", nil); err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	audio := audioSectionOf(t, sdp)
	for _, forbidden := range []string{"transport-cc", "rtcp-fb", "goog-remb", "flexfec"} {
		if strings.Contains(audio, forbidden) {
			t.Fatalf("audio section carries %q:\n%s", forbidden, audio)
		}
	}
}

// THE AUDIO MSID IS DIFFERENT FROM THE VIDEO'S, AND THAT IS THE NO-SYNC-GROUP DECISION ON THE WIRE.
// Browsers form an A/V synchronisation group from tracks sharing a MediaStream and delay whichever
// is ahead — in practice the video — to match. Sharing the MSID would silently cost video latency,
// which is the product.
func TestAudioUsesItsOwnStreamID(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("win:1", nil); err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	sdp, err := session.CreateOffer()
	if err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	audio := audioSectionOf(t, sdp)
	found := false
	for _, line := range strings.Split(audio, "\n") {
		if !strings.HasPrefix(line, "a=msid:") {
			continue
		}
		found = true
		if !strings.Contains(line, "audio:win:1") {
			t.Fatalf("audio msid is not its own stream: %q", line)
		}
	}
	if !found {
		t.Fatalf("audio section carries no msid:\n%s", audio)
	}
}

// SEPARATE SLOT NAMESPACES. The keyframe callback's slot is video-only and -1 means "every source";
// a shared counter would let an audio slot address a video track in that path.
func TestAudioAndVideoSlotsAreIndependent(t *testing.T) {
	session := flexFECOfferSession(t)
	v1, a1, err := session.AddSourceTracks("win:1", nil)
	if err != nil {
		t.Fatalf("AddSourceTracks(win:1): %v", err)
	}
	v2, a2, err := session.AddSourceTracks("win:2", nil)
	if err != nil {
		t.Fatalf("AddSourceTracks(win:2): %v", err)
	}
	if v1 != v2-1 || a1 != a2-1 {
		t.Fatalf("slots did not advance by one each: video %d,%d audio %d,%d", v1, v2, a1, a2)
	}
	// The namespaces must START at the same place and advance independently — if audio shared
	// video's counter, a1 would be v1+1 rather than equal to it.
	if a1 != v1 || a2 != v2 {
		t.Fatalf("audio slots %d,%d are not their own namespace (video %d,%d)", a1, a2, v1, v2)
	}
}

func TestDuplicateSourceIsRefused(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("win:1", nil); err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	if _, _, err := session.AddSourceTracks("win:1", nil); err == nil {
		t.Fatal("a duplicate source id was accepted; its media would be attributed to the first")
	}
}

func TestEmptySourceIsRefused(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, _, err := session.AddSourceTracks("", nil); err == nil {
		t.Fatal("an empty source id was accepted")
	}
}

// Removing both slots is ONE renegotiation, for the reason adding them is one.
func TestRemoveSourceTracksRemovesBothSections(t *testing.T) {
	session := flexFECOfferSession(t)
	v, a, err := session.AddSourceTracks("win:1", nil)
	if err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.RemoveSourceTracks(v, a); err != nil {
		t.Fatalf("RemoveSourceTracks: %v", err)
	}
	if err := session.WriteAudio(a, []byte{0xfc, 0x00}, 0); err == nil {
		t.Fatal("the audio slot still accepted a write after removal")
	}
}

// Writing to a slot that was never added must error rather than panic — WriteVideo's contract.
func TestWriteAudioToUnknownSlotIsAnError(t *testing.T) {
	session := flexFECOfferSession(t)
	if err := session.WriteAudio(7, []byte{1, 2, 3}, 0); err == nil {
		t.Fatal("writing to an unknown audio slot was accepted")
	}
}

// The slot AddSourceTracks hands back is the slot WriteAudio accepts. They are separate integers
// that cross the C ABI in opposite directions and nothing but a test relates them.
func TestAudioSlotRoundTrips(t *testing.T) {
	session := flexFECOfferSession(t)
	_, audioSlot, err := session.AddSourceTracks("win:1", nil)
	if err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	if err := session.WriteAudio(audioSlot, []byte{0xfc, 0x00, 0x00}, 0); err != nil {
		t.Fatalf("WriteAudio to the slot AddSourceTracks returned: %v", err)
	}
}

// THE RTP TIMESTAMP IS DERIVED FROM CAPTURE TIME, NOT SUMMED FROM PER-PACKET DURATIONS.
//
// pion's TrackLocalStaticSample.WriteSample computes ticks as Duration*clockRate with a float
// remainder and IGNORES Sample.PacketTimestamp entirely — which is exactly the defect FrameTrack
// measured on the video side as -5.87% media-clock error. This asserts the property that made
// rdev use an RTP-level track instead: two packets 10 ms apart in capture time are 480 ticks
// apart, and a 250 ms gap is 12,000 ticks rather than another 480.
func TestAudioRTPTimestampFollowsCaptureTime(t *testing.T) {
	session := flexFECOfferSession(t)
	_, slot, err := session.AddSourceTracks("win:1", nil)
	if err != nil {
		t.Fatalf("AddSourceTracks: %v", err)
	}
	base, ok := session.audioTimestampForTest(slot, 0)
	if !ok {
		t.Fatal("no audio slot to stamp")
	}
	tenMs, _ := session.audioTimestampForTest(slot, 10_000_000)
	if tenMs-base != 480 {
		t.Fatalf("10 ms advanced %d ticks, want 480", tenMs-base)
	}
	gap, _ := session.audioTimestampForTest(slot, 250_000_000)
	if gap-base != 12_000 {
		t.Fatalf("a 250 ms gap advanced %d ticks, want 12000 — a summing impl would say 960", gap-base)
	}
}

// Under RDEV_LLV_RECOVERY=nack-rtx, validateLegacyRecoverySDP rejects "transport-cc" ANYWHERE in an
// SDP — a rule about how VIDEO negotiated its recovery, written as a whole-SDP substring scan only
// because every SDP this path had ever seen was video plus data. A browser that puts transport-cc on
// the AUDIO section would kill the session with a message about FlexFEC: a cause one layer away
// from its symptom, and rdev cannot be the end that fixes it, since the answer is the remote's.
func TestLegacyRecoveryIgnoresTheAudioSection(t *testing.T) {
	answer := strings.Join([]string{
		"v=0",
		"m=video 9 UDP/TLS/RTP/SAVPF 96 97",
		"a=rtpmap:96 AV1/90000",
		"a=rtcp-fb:96 nack",
		"m=audio 9 UDP/TLS/RTP/SAVPF 111",
		"a=rtpmap:111 opus/48000/2",
		"a=rtcp-fb:111 transport-cc",
		"",
	}, "\r\n")
	if err := validateLegacyRecoverySDP(answer, RecoveryNACKRTX); err != nil {
		t.Fatalf("an audio-section transport-cc was rejected: %v", err)
	}
}

// THE OTHER HALF, AND IT IS WHAT STOPS THE FIX BECOMING "ACCEPT EVERYTHING". transport-cc on the
// VIDEO section still fails: that is the misconfiguration this check exists to catch.
func TestLegacyRecoveryStillRejectsVideoTransportCC(t *testing.T) {
	answer := strings.Join([]string{
		"v=0",
		"m=video 9 UDP/TLS/RTP/SAVPF 96",
		"a=rtpmap:96 AV1/90000",
		"a=rtcp-fb:96 transport-cc",
		"",
	}, "\r\n")
	if err := validateLegacyRecoverySDP(answer, RecoveryNACKRTX); err == nil {
		t.Fatal("a video-section transport-cc was accepted")
	}
}

// FlexFEC anywhere in the VIDEO half still fails, and so does a session-level line: only the audio
// section is exempt, and only because rdev offers Opus with no feedback at all.
func TestLegacyRecoveryStillRejectsVideoFlexFEC(t *testing.T) {
	answer := strings.Join([]string{
		"v=0",
		"m=video 9 UDP/TLS/RTP/SAVPF 96 98",
		"a=rtpmap:98 flexfec-03/90000",
		"",
	}, "\r\n")
	if err := validateLegacyRecoverySDP(answer, RecoveryNACKRTX); err == nil {
		t.Fatal("a video-section flexfec was accepted")
	}
}

// A SESSION-LEVEL line — before any m= — is still in scope. It belongs to no media section, so
// exempting it would be exempting the whole description by writing one line higher up.
func TestLegacyRecoveryStillRejectsSessionLevelTWCC(t *testing.T) {
	answer := strings.Join([]string{
		"v=0",
		"a=rtcp-fb:* transport-cc",
		"m=audio 9 UDP/TLS/RTP/SAVPF 111",
		"",
	}, "\r\n")
	if err := validateLegacyRecoverySDP(answer, RecoveryNACKRTX); err == nil {
		t.Fatal("a session-level transport-cc was accepted")
	}
}

// ADDING AN AUDIO TRACK MUST NOT DEGRADE FlexFEC, AND THIS IS A REGRESSION TEST FOR A DEFECT THAT
// REACHED A RUNNING HOST.
//
// The frame-aware FlexFEC interceptor binds EVERY local stream, and it failed the whole session on
// any stream with no FEC association: `missing negotiated media or repair stream`. An Opus track has
// none by design — rdev registers FlexFEC for video only — so the first audio track bound turned
// FlexFEC off for the video that needed it, permanently, via a one-shot `sync.Once`.
//
// It was observed on a real host as `[bridge] fec: DEGRADED to nack-rtx` repeating every five
// seconds while video streamed perfectly. Nothing else showed it: the picture was fine, the client
// was fine, and the only symptom was a recovery stack quietly downgraded on the one path that
// carries the frames FEC exists to protect.
func TestFrameAwareFlexFECIgnoresAudioStreams(t *testing.T) {
	var disabled []error
	counters := NewFlexFECCounters(nil)
	factory, err := NewFrameAwareFlexFEC(FrameAwareFlexFECConfig{
		Tier:           NewFlexFECTierStore(FlexFECTierOff, counters),
		Override:       NewFlexFECOverrideStore(),
		Allocator:      newTransportSequenceAllocator(1),
		History:        mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{}),
		Counters:       counters,
		EncoderFactory: recordingFlexEncoderFactory{encoder: &recordingFlexEncoder{nextFEC: 700}},
		Disable:        func(err error) { disabled = append(disabled, err) },
	})
	if err != nil {
		t.Fatalf("NewFrameAwareFlexFEC: %v", err)
	}
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatalf("NewInterceptor: %v", err)
	}
	child := interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
		return h.MarshalSize() + len(p), nil
	})
	// An Opus stream: a real SSRC, no FEC association, and no video header extensions.
	audio := &interceptor.StreamInfo{
		SSRC: 900, PayloadType: audioOpusPayloadType, MimeType: "audio/opus", ClockRate: 48_000,
	}
	writer := bound.BindLocalStream(audio, child)
	if len(disabled) != 0 {
		t.Fatalf("binding an audio stream degraded FlexFEC: %v", disabled)
	}
	if writer == nil {
		t.Fatal("audio stream got no writer back")
	}
	// AND IT MUST STILL PASS AUDIO THROUGH. Ignoring the stream must not mean dropping it.
	n, err := writer.Write(&rtp.Header{Version: 2, SSRC: 900, PayloadType: audioOpusPayloadType},
		[]byte{0xfc, 0x00, 0x00}, nil)
	if err != nil || n == 0 {
		t.Fatalf("audio write through the interceptor failed: n=%d err=%v", n, err)
	}
}

// AN INTERCEPTOR WRITTEN FOR VIDEO MUST NOT FAIL EVERY AUDIO WRITE, and this is the second defect of
// exactly that shape on this branch — the first turned FlexFEC off for the session
// (TestFrameAwareFlexFECIgnoresAudioStreams).
//
// twccHeaderInjector returns a writer that ALWAYS errors when a stream carries no TWCC header
// extension. rdev registers that extension for VIDEO ONLY, so every Opus packet was rejected with
// "TWCC RTP header extension was not negotiated" — while the encoder's own counter went on reporting
// 501 packets and 96.8 kbps, because it counts ENCODES and cannot see the wire. Observed on a real
// host: SDP negotiated correctly (offer m=audio sendrecv, Chrome answered recvonly opus/48000/2), an
// <audio> element with a live track existed in the browser, and getStats had NO audio inbound-rtp at
// all, because not one packet ever arrived.
func TestTWCCInjectorPassesAudioThroughUntouched(t *testing.T) {
	injector := &twccHeaderInjector{
		allocator: newTransportSequenceAllocator(1),
		history:   mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{}),
	}
	written := 0
	child := interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
		written++
		return h.MarshalSize() + len(p), nil
	})
	audio := &interceptor.StreamInfo{
		SSRC: 900, PayloadType: audioOpusPayloadType, MimeType: "audio/opus", ClockRate: audioClockRate,
	}
	writer := injector.BindLocalStream(audio, child)
	n, err := writer.Write(&rtp.Header{Version: 2, SSRC: 900}, []byte{0xfc, 0x00, 0x00}, nil)
	if err != nil {
		t.Fatalf("an audio write was refused: %v", err)
	}
	if n == 0 || written != 1 {
		t.Fatalf("the audio packet did not reach the wire: n=%d writes=%d", n, written)
	}
}

// THE OTHER HALF: a VIDEO stream with no TWCC extension is still a real misconfiguration and must
// still fail. Without this, "pass everything through" would satisfy the test above.
func TestTWCCInjectorStillRefusesVideoWithoutTheExtension(t *testing.T) {
	injector := &twccHeaderInjector{
		allocator: newTransportSequenceAllocator(1),
		history:   mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{}),
	}
	child := interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
		return h.MarshalSize() + len(p), nil
	})
	video := &interceptor.StreamInfo{SSRC: 100, PayloadType: 45, MimeType: "video/AV1"}
	writer := injector.BindLocalStream(video, child)
	if _, err := writer.Write(&rtp.Header{Version: 2, SSRC: 100}, []byte{1}, nil); err == nil {
		t.Fatal("a video stream with no TWCC extension was accepted")
	}
}

// THE RECEIVER-RTT RESPONDER MUST NOT ADOPT THE AUDIO SSRC. It remembers ONE senderSSRC and reports
// receiver RTT against it; audio binds after video, so without a guard the RTT the video recovery
// stack depends on would be measured against the audio stream instead.
func TestReceiverRTTResponderKeepsTheVideoSSRC(t *testing.T) {
	responder := &receiverRTTResponder{}
	child := interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
		return h.MarshalSize() + len(p), nil
	})
	responder.BindLocalStream(&interceptor.StreamInfo{SSRC: 100, MimeType: "video/AV1"}, child)
	responder.BindLocalStream(&interceptor.StreamInfo{SSRC: 900, MimeType: "audio/opus"}, child)
	responder.mutex.Lock()
	got := responder.senderSSRC
	responder.mutex.Unlock()
	if got != 100 {
		t.Fatalf("senderSSRC = %d, want the VIDEO ssrc 100 — audio must not take it over", got)
	}
}
