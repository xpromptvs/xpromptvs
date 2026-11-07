package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// audioOpusPayloadType is rdev's Opus payload type. 111 is what every browser uses for Opus, which
// keeps an offer and its answer readable side by side in a capture.
const audioOpusPayloadType = 111

// audioClockRate is Opus's RTP clock. FIXED AT 48 kHz REGARDLESS OF THE CAPTURE RATE — RFC 7587
// says an Opus RTP timestamp is always in 48 kHz units even when the codec runs narrower.
const audioClockRate = 48_000

// audioOpusFMTP must stay in step with AudioFraming.defaultFramesPerChannel (480 frames at 48 kHz
// = 10 ms). They are ONE decision: changing the frame size without this line understates what rdev
// actually sends, and a receiver sizes its jitter buffer from it.
const audioOpusFMTP = "minptime=10;useinbandfec=1"

// audioStreamID is the MSID an audio track carries, and it is DELIBERATELY NOT the source id.
//
// Browsers form an A/V synchronisation group from tracks that share a MediaStream and delay
// whichever stream is ahead — in practice the video — so the two line up. rdev's whole thesis is
// video latency, so audio gets its own stream and the two are deliberately unsynchronised. The cost
// is drift between picture and sound; the alternative is paying for lip-sync on every session
// whether or not what is being watched needs it.
func audioStreamID(sourceID string) string { return "audio:" + sourceID }

// audioTrackSlot is one source's audio track.
//
// IT IS A TrackLocalStaticRTP, NOT A TrackLocalStaticSample, AND THAT IS NOT A STYLE CHOICE.
// WriteSample computes its RTP timestamp as Duration*clockRate accumulated with a float remainder
// and IGNORES media.Sample.PacketTimestamp entirely (read pkg/media/media.go beside
// track_local_static.go). That is precisely the defect FrameTrack measured on the video side as
// -5.87% media-clock error — a fixed per-frame step against a content-driven source, where the
// error ACCUMULATES rather than cancelling. Audio is content-driven in the same way: SCK stops
// delivering when an app is silent. So rdev owns the timestamp and derives it from capture time.
//
// TrackLocalStaticRTP.writeRTP overwrites SSRC and PayloadType per binding but PRESERVES the
// sequence number and timestamp from the packet handed to it, which is what makes this possible.
type audioTrackSlot struct {
	track    *webrtc.TrackLocalStaticRTP
	sender   *webrtc.RTPSender
	sourceID string

	writeMutex sync.Mutex
	// ANCHORED TO THE FIRST PACKET'S CAPTURE TIME, never summed from per-packet deltas. Guarded by
	// writeMutex.
	anchorNanos    int64
	anchored       bool
	timestampBase  uint32
	sequenceNumber uint16
}

// AddSourceTracks adds this source's video AND audio tracks. The CALLER schedules the single offer
// that carries both.
//
// ONE CALL RATHER THAN TWO, AND THAT IS THE POINT. scheduleOffer drives an offer immediately from
// `stable`, so a separate audio add would land while the peer sat in have-local-offer and emit a
// SECOND offer when the first answer arrived — two full negotiations per subscribe, and the second
// of them is where the documented offer-coalescing defect lives ("the SECOND of two rapid
// subscribes reads as a peer rebuild — measured: zero frames"). Adding both here makes a second
// offer structurally impossible rather than merely unlikely.
//
// EVERY SOURCE GETS AN AUDIO TRACK, including one that will carry no audio. The audio-ownership
// election changes mid-subscription — when the carrying window closes, a sibling needs audio — and
// a conditional track would make that expressible only by removing and re-adding the sibling's
// tracks, interrupting its PICTURE because a DIFFERENT window closed. With the track always
// present, ownership and mute are both sink-level and neither renegotiates.
func (session *Session) AddSourceTracks(sourceID string, preference []codecID) (int, int, error) {
	videoSlot, err := session.AddVideoTrackWithPreference(sourceID, preference)
	if err != nil {
		return -1, -1, err
	}
	audioSlot, err := session.addAudioTrack(sourceID)
	if err != nil {
		// The video track is already added. Take it back out rather than leaving a half-built
		// source: a video track with no audio sibling is a shape nothing downstream expects, and
		// the caller is about to be told this failed.
		_ = session.RemoveVideoTrack(videoSlot)
		return -1, -1, err
	}
	return videoSlot, audioSlot, nil
}

// addAudioTrack does NOT schedule an offer. Its only caller is AddSourceTracks, whose video half
// already accounted for one — see that function's comment for why the two must share it.
func (session *Session) addAudioTrack(sourceID string) (int, error) {
	if sourceID == "" {
		return -1, fmt.Errorf("%w: an audio track needs a source id to carry as its MSID", errSession)
	}
	session.mutex.Lock()
	if session.closing {
		session.mutex.Unlock()
		return -1, fmt.Errorf("%w: session is closing", errSession)
	}
	// Refused for the reason the video path refuses one: a receiver keys by MSID, so a second
	// track carrying one id has its media attributed to the first one's window.
	for existing, entry := range session.audioTracks {
		if entry.sourceID == sourceID {
			session.mutex.Unlock()
			return -1, fmt.Errorf("%w: source %q already has an audio track at slot %d",
				errSession, sourceID, existing)
		}
	}
	slot := session.nextAudioSlot
	session.nextAudioSlot++
	session.mutex.Unlock()

	track, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   audioClockRate,
			Channels:    2,
			SDPFmtpLine: audioOpusFMTP,
		},
		"audio-"+sourceID,
		audioStreamID(sourceID),
	)
	if err != nil {
		return -1, fmt.Errorf("create audio track for %q: %w", sourceID, err)
	}
	sender, err := session.peer.AddTrack(track)
	if err != nil {
		return -1, fmt.Errorf("add audio track for %q: %w", sourceID, err)
	}

	entry := &audioTrackSlot{track: track, sender: sender, sourceID: sourceID}
	// RANDOM STARTING SEQUENCE NUMBER AND TIMESTAMP, which RFC 3550 requires of every SSRC: a
	// predictable start makes a stream trivially spoofable, and pion's own tracks randomise for the
	// same reason.
	entry.sequenceNumber = uint16(randomUint32())
	entry.timestampBase = randomUint32()

	session.mutex.Lock()
	if session.audioTracks == nil {
		session.audioTracks = make(map[int]*audioTrackSlot, 1)
	}
	session.audioTracks[slot] = entry
	session.mutex.Unlock()
	return slot, nil
}

// RemoveSourceTracks removes both of a source's tracks. The CALLER schedules the single offer, for
// the reason AddSourceTracks does not schedule two: two removes would produce two offers in
// reverse.
func (session *Session) RemoveSourceTracks(videoSlot, audioSlot int) error {
	session.mutex.Lock()
	audio := session.audioTracks[audioSlot]
	delete(session.audioTracks, audioSlot)
	session.mutex.Unlock()
	if audio != nil {
		if err := session.peer.RemoveTrack(audio.sender); err != nil {
			return fmt.Errorf("remove audio track at slot %d: %w", audioSlot, err)
		}
	}
	return session.RemoveVideoTrack(videoSlot)
}

// WriteAudio writes one encoded Opus packet to the audio track at `slot`.
//
// ONE PACKET PER RTP PACKET, which is what RFC 7587 specifies for Opus and why no packetizer is
// needed: the payload IS the Opus packet.
func (session *Session) WriteAudio(slot int, payload []byte, ptsNanos int64) error {
	session.mutex.Lock()
	entry := session.audioTracks[slot]
	session.mutex.Unlock()
	if entry == nil {
		return fmt.Errorf("%w: no audio track at slot %d", errSession, slot)
	}
	if len(payload) == 0 {
		return fmt.Errorf("%w: empty audio payload for slot %d", errSession, slot)
	}

	entry.writeMutex.Lock()
	timestamp := entry.stampLocked(ptsNanos)
	entry.sequenceNumber++
	sequence := entry.sequenceNumber
	entry.writeMutex.Unlock()

	return entry.track.WriteRTP(&rtp.Packet{
		Header: rtp.Header{
			Version: 2,
			// The marker bit means "first packet of a talkspurt" for audio. rdev does not track
			// talkspurts — the framer re-anchors on a gap and says nothing about it — so this stays
			// false rather than being set to a value nothing computes.
			Marker:         false,
			PayloadType:    audioOpusPayloadType, // overwritten per binding; set for readability
			SequenceNumber: sequence,
			Timestamp:      timestamp,
		},
		Payload: payload,
	})
}

// stampLocked converts a capture time to this track's RTP clock.
//
// ANCHORED TO AN EPOCH, NEVER SUMMED FROM ROUNDED DELTAS. The first packet fixes the anchor; every
// later one is measured from it, so a rounding error cannot accumulate and a GAP is carried
// honestly instead of being counted through. Caller holds writeMutex.
//
// The multiply is exact for any realistic session: nanoseconds since the anchor times 48,000 stays
// inside int64 for roughly 2.4 million seconds (~28 days) of continuous capture.
func (slot *audioTrackSlot) stampLocked(ptsNanos int64) uint32 {
	if !slot.anchored {
		slot.anchorNanos = ptsNanos
		slot.anchored = true
	}
	elapsed := ptsNanos - slot.anchorNanos
	if elapsed < 0 {
		elapsed = 0
	}
	return slot.timestampBase + uint32(elapsed*audioClockRate/1_000_000_000)
}

// audioTimestampForTest exposes what stampLocked would produce for a capture time, so the
// anchored-not-summed property is testable without a connected peer.
func (session *Session) audioTimestampForTest(slot int, ptsNanos int64) (uint32, bool) {
	session.mutex.Lock()
	entry := session.audioTracks[slot]
	session.mutex.Unlock()
	if entry == nil {
		return 0, false
	}
	entry.writeMutex.Lock()
	defer entry.writeMutex.Unlock()
	return entry.stampLocked(ptsNanos), true
}

func randomUint32() uint32 {
	var buffer [4]byte
	if _, err := rand.Read(buffer[:]); err != nil {
		return 0
	}
	return binary.BigEndian.Uint32(buffer[:])
}
