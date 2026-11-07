package main

import (
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// THE CODEC IS REPORTED WHEN THE ANSWER RESOLVES IT, NOT WHEN THE TRACK IS ADDED.
//
// pion_peer_add_video_track used to report AV1 immediately, and that was CORRECT with one codec
// registered: there was nothing to wait for, and rdev builds the source's ENCODER on this callback,
// so a track whose codec is never reported has no encoder, no sink, and streams nothing at all.
//
// With three codecs the answer decides. Reporting eagerly would build an encoder for a codec the
// remote may not have accepted — and the mismatch is invisible from every vantage point except the
// picture: RTP flows, WriteSample succeeds, every state reads healthy, nothing decodes.
func TestCodecIsReportedAfterTheAnswer(t *testing.T) {
	session := flexFECOfferSession(t)
	reported := make(chan codecID, 4)
	session.SetOnCodecResolved(func(_ int, codec codecID) { reported <- codec })

	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	select {
	case codec := <-reported:
		t.Fatalf("codec %v reported before any answer", codec)
	case <-time.After(150 * time.Millisecond):
	}

	if err := session.SetAnswer(buildRemoteAnswer(t, session)); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	select {
	case codec := <-reported:
		if codec != rdevNegotiatedCodecAV1 {
			t.Fatalf("reported %v, want AV1 from an answerer that accepts it", codec)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no codec reported after the answer — the encoder would never be built")
	}
	// EXACTLY ONE. rdev rebuilds the source's encoder on every report, so a duplicate costs an
	// encoder build and an IDR for nothing.
	//
	// THIS DOES NOT COVER THE ABI, and that limit is worth stating rather than leaving implied:
	// pion_peer_add_video_track used to report eagerly, it is cgo, and no Go test can call it. A
	// mutation restoring that eager report is invisible here. What covers it is the forced-codec
	// browser gate, which asserts the codec rdev REPORTED equals the codec the answer forced — an
	// eager AV1 report on an H.264 session fails there.
	select {
	case extra := <-reported:
		t.Fatalf("codec reported twice (second was %v); each report rebuilds the encoder", extra)
	case <-time.After(250 * time.Millisecond):
	}
}

// codec_pref BIASES ONE TRACK WITHOUT CHANGING WHAT THE SESSION OFFERS. The offer carries every
// registered codec regardless; the preference only decides which of the survivors that track binds.
func TestCodecPreferencePinsOneTrack(t *testing.T) {
	for _, testCase := range []struct {
		wire     int
		expected codecID
	}{
		{1, rdevNegotiatedCodecAV1},
		{2, rdevNegotiatedCodecH265},
		{3, rdevNegotiatedCodecH264},
	} {
		track := NewFrameTrack("video", "desktop")
		track.SetCodecPreference(codecPreferenceFromWire(testCase.wire))
		context := frameTrackContextOffering([]string{
			webrtc.MimeTypeAV1, webrtc.MimeTypeH265, webrtc.MimeTypeH264,
		})
		if _, err := track.Bind(context); err != nil {
			t.Fatalf("pref %d: Bind: %v", testCase.wire, err)
		}
		got, ok := track.NegotiatedCodec()
		if !ok || got != testCase.expected {
			t.Fatalf("pref %d selected %v (ok=%t), want %v", testCase.wire, got, ok, testCase.expected)
		}
	}
}

// AUTO IS rdev's GLOBAL ORDER, and an UNRECOGNISED value must clamp to it rather than to an empty
// list — an empty preference is a track that can never bind, so a version skew would take video
// down instead of degrading.
func TestUnrecognisedCodecPreferenceClampsToAuto(t *testing.T) {
	for _, wire := range []int{0, 4, -1, 99} {
		if got := codecPreferenceFromWire(wire); len(got) != 0 {
			t.Fatalf("codec_pref %d = %v, want the empty (auto) preference", wire, got)
		}
		track := NewFrameTrack("video", "desktop")
		track.SetCodecPreference(codecPreferenceFromWire(wire))
		context := frameTrackContextOffering([]string{webrtc.MimeTypeH264, webrtc.MimeTypeAV1})
		if _, err := track.Bind(context); err != nil {
			t.Fatalf("codec_pref %d: Bind: %v", wire, err)
		}
		got, ok := track.NegotiatedCodec()
		if !ok || got != rdevNegotiatedCodecAV1 {
			t.Fatalf("codec_pref %d selected %v, want AV1 from the global order", wire, got)
		}
	}
}

// A STATS BLOCK THAT SAYS AV1 ON AN H.264 SESSION IS A CONFIDENT WRONG SIGNAL, which is the class
// of thing this project has repeatedly been burned by: every state reads healthy and names the
// wrong thing. Codec, PayloadType and the recovery block's primary payload type all follow what was
// actually negotiated.
func TestStatsReportTheResolvedCodec(t *testing.T) {
	for _, testCase := range []struct {
		name        string
		preference  []codecID
		wantCodec   string
		wantPayload uint8
	}{
		{"default resolves to AV1", nil, "AV1", av1PayloadType},
		{"pinned to H.265", []codecID{rdevNegotiatedCodecH265}, "H265", h265PayloadType},
		{"pinned to H.264", []codecID{rdevNegotiatedCodecH264}, "H264", h264PayloadType},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			session := flexFECOfferSession(t)
			if _, err := session.AddVideoTrackWithPreference("win:1", testCase.preference); err != nil {
				t.Fatalf("AddVideoTrack: %v", err)
			}
			if _, err := session.CreateOffer(); err != nil {
				t.Fatalf("CreateOffer: %v", err)
			}
			if err := session.SetAnswer(buildRemoteAnswer(t, session)); err != nil {
				t.Fatalf("SetAnswer: %v", err)
			}
			stats := session.Stats()
			if stats.Codec != testCase.wantCodec {
				t.Fatalf("stats.Codec = %q, want %q", stats.Codec, testCase.wantCodec)
			}
			if stats.PayloadType != testCase.wantPayload {
				t.Fatalf("stats.PayloadType = %d, want %d", stats.PayloadType, testCase.wantPayload)
			}
			if stats.Recovery.PrimaryPayloadType != testCase.wantPayload {
				t.Fatalf("recovery primary payload = %d, want %d",
					stats.Recovery.PrimaryPayloadType, testCase.wantPayload)
			}
		})
	}
}

// THE RECOVERY MODE MUST REPORT WHAT RUNS, NOT WHAT WAS CONFIGURED. A session configured for
// FlexFEC whose receiver declined it runs NACK/RTX, and reporting the configured mode there would
// be the same confident-wrong-signal failure one field over.
func TestStatsReportTheRecoveryStackThatActuallyRuns(t *testing.T) {
	session := flexFECOfferSession(t)
	if _, err := session.AddVideoTrack("win:1"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	if _, err := session.CreateOffer(); err != nil {
		t.Fatalf("CreateOffer: %v", err)
	}
	if err := session.SetAnswer(stripFlexFEC(t, buildRemoteAnswer(t, session))); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	if got := session.Stats().Recovery.Mode; got != "nack-rtx" {
		t.Fatalf("recovery mode = %q, want nack-rtx — the receiver declined FlexFEC", got)
	}
}
