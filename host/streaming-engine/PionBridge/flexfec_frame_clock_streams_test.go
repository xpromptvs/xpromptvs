package main

import (
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// THE EGRESS BUDGET IS PER SESSION AND THE FRAME COUNTER IS PER TRACK, AND THAT COMBINATION IS
// FATAL THE MOMENT rdev SUBSCRIBES A SECOND SOURCE.
//
// RecoveryFrameClockBudget.AdvanceFrame required frame ids to be strictly consecutive across the
// WHOLE session, while videoTrackSlot.frameID counts from zero per slot. So the first subscribed
// window streams, and the next one — whether it is subscribed alongside the first or after the
// first was closed — starts its own numbering at 1 and every write fails forever with
// `frame-start callback: invalid recovery frame-clock budget`.
//
// session.go's own comment predicted this ("two tracks each counting from their own base would
// interleave into an invalid progression") and dismissed it on the grounds that the budget "is only
// BUILT for RecoveryNACKRTXFlexFEC, which newOfferSession refuses outright". That premise stopped
// being true when FlexFEC became the default on 2026-08-18; the comment did not.
//
// The invariant it is protecting — "did this stream skip a frame" — is inherently PER STREAM. It
// only ever read as session-wide because there was only ever one stream to read it on.

func TestFrameClockBudgetTracksProgressionPerStream(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 20_000_000, FramesPerSecond: 60,
		BurstDuration: defaultRecoveryFrameClockBurstDuration,
	})
	if err != nil {
		t.Fatalf("NewRecoveryFrameClockBudget: %v", err)
	}
	// Stream 1 is the first subscribed window; it runs a while.
	for frameID := uint64(1); frameID <= 5; frameID++ {
		if err := budget.AdvanceStreamFrame(1, frameID); err != nil {
			t.Fatalf("stream 1 frame %d: %v", frameID, err)
		}
	}
	// Stream 2 is the next one — a second window, or the replacement for a closed one. Its own
	// counter starts at 1, which is CORRECT for it and was an "invalid progression" for the budget.
	for frameID := uint64(1); frameID <= 5; frameID++ {
		if err := budget.AdvanceStreamFrame(2, frameID); err != nil {
			t.Fatalf("stream 2 frame %d: %v — a second source cannot send a single frame", frameID, err)
		}
	}
	// And interleaved, which is what two concurrently subscribed windows actually produce.
	for frameID := uint64(6); frameID <= 9; frameID++ {
		if err := budget.AdvanceStreamFrame(1, frameID); err != nil {
			t.Fatalf("interleaved stream 1 frame %d: %v", frameID, err)
		}
		if err := budget.AdvanceStreamFrame(2, frameID); err != nil {
			t.Fatalf("interleaved stream 2 frame %d: %v", frameID, err)
		}
	}
	if got := budget.Snapshot().InvalidFrameProgressions; got != 0 {
		t.Fatalf("invalid progressions = %d, want 0", got)
	}
}

// THE INVARIANT MUST NOT BE WEAKENED INTO NOTHING. Per-stream is the point; per-stream-and-also-
// tolerant-of-gaps would be a check that cannot fail. A skipped frame WITHIN a stream is still the
// fault this exists to catch — it means a frame id was consumed by a frame that never went out,
// which is exactly the "commit only on success" rule in WriteVideo.
func TestFrameClockBudgetStillRejectsAGapWithinOneStream(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 20_000_000, FramesPerSecond: 60,
		BurstDuration: defaultRecoveryFrameClockBurstDuration,
	})
	if err != nil {
		t.Fatalf("NewRecoveryFrameClockBudget: %v", err)
	}
	if err := budget.AdvanceStreamFrame(1, 1); err != nil {
		t.Fatalf("stream 1 frame 1: %v", err)
	}
	if err := budget.AdvanceStreamFrame(1, 3); err == nil {
		t.Fatal("a skipped frame within one stream was accepted")
	}
	// A different stream's independent numbering must not have been disturbed by that rejection.
	if err := budget.AdvanceStreamFrame(2, 1); err != nil {
		t.Fatalf("stream 2 after stream 1's rejection: %v", err)
	}
}

// AdvanceFrame is the single-stream spelling the ANSWERING path uses, and it must stay exactly
// what it was: stock `llv capture-host` sends one track, and it is the certification's comparison
// arm. Asserted rather than assumed, because the two now share an implementation.
func TestAdvanceFrameIsAdvanceStreamFrameOnOneStream(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000, FramesPerSecond: 60,
		BurstDuration: 20 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("NewRecoveryFrameClockBudget: %v", err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatalf("AdvanceFrame(1): %v", err)
	}
	if err := budget.AdvanceFrame(3); err == nil {
		t.Fatal("AdvanceFrame accepted a gap; the single-stream contract changed")
	}
	if err := budget.AdvanceFrame(2); err != nil {
		t.Fatalf("AdvanceFrame(2) after a rejected 3: %v", err)
	}
}

// THE WIRING: a frame's StreamID must reach the callback, or keying by stream achieves nothing.
// FrameTrack is what carries it, and this is the seam where a per-track budget callback would
// otherwise silently receive a constant.
func TestFrameTrackPassesTheStreamIDToOnFrameStart(t *testing.T) {
	track := NewFrameTrack("video-win:1", "win:1", nil)
	var gotStream, gotFrame uint64
	track.SetOnFrameStart(func(streamID, frameID uint64) error {
		gotStream, gotFrame = streamID, frameID
		return nil
	})
	// Bound so WriteAccessUnit reaches the callback rather than refusing for want of bindings.
	if _, err := track.Bind(&fakeTrackLocalContext{
		id: "binding", ssrc: 41, writer: &recordingTrackWriter{},
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
			},
			PayloadType: 45,
		}},
		extensions: []webrtc.RTPHeaderExtensionParameter{
			{URI: playoutDelayURI, ID: 8},
			{URI: dependencyDescriptorURI, ID: 9},
		},
	}); err != nil {
		t.Fatalf("Bind: %v", err)
	}
	if err := track.WriteAccessUnit(OutboundFrame{
		StreamID: 7, FrameID: 42, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4_000),
	}); err != nil {
		t.Fatalf("WriteAccessUnit: %v", err)
	}
	if gotStream != 7 || gotFrame != 42 {
		t.Fatalf("onFrameStart got (stream %d, frame %d), want (7, 42)", gotStream, gotFrame)
	}
}

// THE SEAM AS rdev ACTUALLY WIRES IT: wireVideoTrack gives EVERY track the same session-scoped
// budget callback, so two tracks share one clock. This is the shape the unit tests above cannot
// see — that the stream id reaching the budget is the one FrameTrack put on the frame, from the
// track that wrote it — and it is the shape that failed in the field.
//
// Two tracks, one budget, each numbering its own frames from 1, exactly as two videoTrackSlots do.
func TestTwoFrameTracksShareOneBudgetWithoutColliding(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 20_000_000, FramesPerSecond: 60,
		BurstDuration: defaultRecoveryFrameClockBurstDuration,
	})
	if err != nil {
		t.Fatalf("NewRecoveryFrameClockBudget: %v", err)
	}
	newBoundTrack := func(id string, ssrc uint32) *FrameTrack {
		t.Helper()
		track := NewFrameTrack(id, id, nil)
		// The one line wireVideoTrack runs for every track.
		track.SetOnFrameStart(budget.AdvanceStreamFrame)
		if _, bindErr := track.Bind(&fakeTrackLocalContext{
			id: id, ssrc: webrtc.SSRC(ssrc), writer: &recordingTrackWriter{},
			codecs: []webrtc.RTPCodecParameters{{
				RTPCodecCapability: webrtc.RTPCodecCapability{
					MimeType: webrtc.MimeTypeAV1, ClockRate: 90_000,
				},
				PayloadType: 45,
			}},
			extensions: []webrtc.RTPHeaderExtensionParameter{
				{URI: playoutDelayURI, ID: 8},
				{URI: dependencyDescriptorURI, ID: 9},
			},
		}); bindErr != nil {
			t.Fatalf("Bind %s: %v", id, bindErr)
		}
		return track
	}
	// videoKeyframeStreamID(slot) is slot+1, so the first two slots carry stream ids 1 and 2.
	first := newBoundTrack("win:56", 41)
	second := newBoundTrack("win:7128", 42)

	write := func(track *FrameTrack, streamID, frameID uint64) error {
		return track.WriteAccessUnit(OutboundFrame{
			StreamID: streamID, FrameID: frameID, Keyframe: frameID == 1,
			Dependency: l1t1Dependency(frameID == 1), Data: testAV1AccessUnit(2_000),
		})
	}
	for frameID := uint64(1); frameID <= 4; frameID++ {
		if err := write(first, videoKeyframeStreamID(0), frameID); err != nil {
			t.Fatalf("first window frame %d: %v", frameID, err)
		}
	}
	// The second window. Its slot counter starts at 1 — this is the write that failed forever.
	for frameID := uint64(1); frameID <= 4; frameID++ {
		if err := write(second, videoKeyframeStreamID(1), frameID); err != nil {
			t.Fatalf("second window frame %d: %v — the reported failure", frameID, err)
		}
	}
	// And both sending at once, which is two subscribed windows.
	for frameID := uint64(5); frameID <= 8; frameID++ {
		if err := write(first, videoKeyframeStreamID(0), frameID); err != nil {
			t.Fatalf("concurrent first window frame %d: %v", frameID, err)
		}
		if err := write(second, videoKeyframeStreamID(1), frameID); err != nil {
			t.Fatalf("concurrent second window frame %d: %v", frameID, err)
		}
	}
	if got := budget.Snapshot().InvalidFrameProgressions; got != 0 {
		t.Fatalf("invalid progressions = %d, want 0", got)
	}
}
