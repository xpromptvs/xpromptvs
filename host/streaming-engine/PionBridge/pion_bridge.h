#ifndef PION_BRIDGE_H
#define PION_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

/* rdev's C ABI. Implemented over LLV's Session in rdev_abi.go; see that file's header for what
   the swap did and did not change. Every name and signature below is what rdev's Swift already
   calls, which is what makes this a transport swap rather than a host rewrite.

   GONE, and gone with callers rather than ahead of them:
     - pion_av1_encoder_* and pion_free. Encoding moved into Swift (LLVEncoderAdapter, libaom), so
       the SVT-AV1 handle API had no callers left.
     - codec negotiation as a BUILD-TIME choice. The engine registers AV1, H.265 and H.264 and the
       real SDP offer/answer settles it PER CONNECTION; video_codec_profile.go is the only place a
       codec is described. (This paragraph said "the engine registers AV1 and nothing else" long
       after that stopped being true — a header that lies about its own ABI is how the next reader
       gets the wrong answer.) */

enum { PION_CH_TERMINAL = 0, PION_CH_INPUT = 1, PION_CH_CONTROL = 2 };

typedef void (*pion_on_local_description)(uintptr_t ctx, const char* sdp);
typedef void (*pion_on_ice_candidate)(uintptr_t ctx, const char* cand_json);
typedef void (*pion_on_datachannel_open)(uintptr_t ctx, int channel);
typedef void (*pion_on_datachannel_message)(uintptr_t ctx, int channel, const uint8_t* data, int len);
typedef void (*pion_on_connection_state)(uintptr_t ctx, int state);
/* slot -1 means EVERY source on this client, which is what a keyframe request that names no track
   resolves to: the engine's stream 0 belongs to the answering path's eager track and to the
   interceptor-level request, neither of which identifies an rdev source. */
typedef void (*pion_on_keyframe_request)(uintptr_t ctx, int slot);
/* codec: 0 = H.264, 1 = H.265, 2 = AV1 (matches Swift's RdevCore.NegotiatedCodec). Fired when the
   ANSWER resolves the codec, not when the track is added — rdev builds a source's encoder in
   response to this, and an eager report would build one for a codec the remote never accepted. */
typedef void (*pion_on_codec_resolved)(uintptr_t ctx, int slot, int codec);
/* The adaptive FlexFEC controller's decision. RETURNS A STATUS, unlike every other callback here:
   the engine acts on the error, and CaptureRecoveryBitrateCoordinator rejects an invalid sequence,
   a zero bitrate or a sequence conflict. Swallowing it would leave the controller believing an
   update was applied that was not, after which the total exceeds the very budget the controller
   exists to respect. 0 = applied, non-zero = rejected.

   media_bitrate_bps is an ABSOLUTE figure against the session's total RTP budget. rdev uses it as a
   RATIO against each source's own client-requested bitrate — see SimManager. */
typedef int (*pion_on_recovery_policy)(uintptr_t ctx, uint64_t sequence, int tier,
                                       uint32_t media_bitrate_bps);

void    pion_init(void);
void    pion_set_callbacks(pion_on_local_description, pion_on_ice_candidate,
                           pion_on_datachannel_open, pion_on_datachannel_message,
                           pion_on_connection_state, pion_on_keyframe_request,
                           pion_on_codec_resolved, pion_on_recovery_policy);
/* ice_servers_json IS PARSED AND REGISTERED as of 2026-08-18. It was accepted and ignored from the
   engine cutover until then, when the remote-IP filter would have dropped a relay candidate anyway
   (it carries the relay's address, not the peer's); ICEPolicyLAN installs no such filter. Malformed
   JSON fails the session rather than yielding zero relay candidates to diagnose a layer away.

   total_rtp_budget_bps is the CAP a client may request, passed from Swift because that is where
   HostConfig.bitrateCapBps is computed. Go does NOT re-read RDEV_VIDEO_BITRATE_CAP_BPS: two readers
   with two copies of the default could diverge, and the ratio's denominator would then differ from
   the real cap, making every applied bitrate silently wrong in proportion. (Go also snapshots the
   environment at runtime init — before Swift's main runs — so a value Swift exported could not be
   seen here at all.) Pass 0 when FlexFEC is off; a non-zero budget outside FlexFEC mode is refused.

   Returns 0 on failure. */
int64_t pion_peer_create(uintptr_t ctx, const char* ice_servers_json,
                         uint32_t total_rtp_budget_bps);
void    pion_peer_start_offer(int64_t h);
void    pion_peer_restart_ice(int64_t h);
void    pion_peer_set_answer(int64_t h, const char* sdp);
void    pion_peer_add_ice(int64_t h, const char* cand_json);
/* Add this source's tracks — video AND audio — and schedule ONE offer. Returns the video slot
   (>= 0) or -1 on failure; writes the audio slot to *audio_slot_out.

   ONE CALL RATHER THAN TWO, AND THAT IS LOAD-BEARING. scheduleOffer drives an offer immediately
   from `stable`, so a separate audio add would emit a SECOND offer when the first answer arrived —
   two full negotiations per subscribe, and the second of two rapid offers reads to a client as a
   peer rebuild (measured: zero frames). Adding both here makes a second offer structurally
   impossible rather than merely unlikely.

   EVERY SOURCE GETS AN AUDIO TRACK, including one that will carry no audio: the ownership election
   changes mid-subscription, and a conditional track would make that expressible only by tearing
   down the sibling's VIDEO. Ownership and mute are sink-level and renegotiate nothing.

   codec_pref is the VIDEO preference: 0 auto · 1 av1 · 2 h265 · 3 h264. Unrecognised → auto. */
int     pion_peer_add_source_tracks(int64_t h, const char* source_id, int codec_pref,
                                    int* audio_slot_out);
/* Remove both of a source's tracks under ONE renegotiation, for the same reason. */
void    pion_peer_remove_source_tracks(int64_t h, int video_slot, int audio_slot);
/* Force this session's FEC overhead, in basis points of media (0..5000), or -1 for adaptive
   control. Returns 0 on success and negative on refusal. Needs no renegotiation at any value:
   FlexFEC stays negotiated even at 0, so switching ratios costs no SSRC change and no IDR. */
int     pion_peer_set_recovery_override(int64_t h, int override_bp);
/* Playout-delay FLOOR in milliseconds for every video track on this peer; 0 restores the default
   "play out as soon as you can". Unlike the ceiling this FORCES a receiver to buffer, which is the
   only lever that works on a receiver honouring the sender's extension over its own
   jitterBufferTarget. Applied synchronously: 0 on success, -1 refused. */
int     pion_peer_set_playout_delay_min(int64_t h, int min_ms);
/* BOTH bounds of the playout-delay extension, in milliseconds. max_ms < 0 keeps the configured
   ceiling (raised to the floor); max_ms >= 0 is an explicit ceiling, refused below the floor.
   min == max is a fixed WINDOW from capture — what a Chromium receiver on a clean path measures
   best on (27 ms g2g against 57 with the permissive ceiling, every frame in phase); 0/0 is the
   gaming MODE. Applied synchronously: 0 on success, -1 refused. */
int     pion_peer_set_playout_delay(int64_t h, int min_ms, int max_ms);
/* Which recovery stack this connection ACTUALLY runs, decided from the answer:
   0 unresolved (no answer yet) · 1 nack-rtx · 2 nack-rtx-flexfec.
   A receiver that declines FlexFEC degrades to 1 rather than failing the session, so this is not
   the same as the CONFIGURED mode and is the only way to tell the two apart. Returns 0 for an
   unknown handle, which is indistinguishable from unresolved by design: both mean "do not report a
   stack to the client yet". */
int     pion_peer_active_recovery(int64_t h);
/* pts_ns is ACCEPTED AND DOES NOT REACH THE WIRE: RTP timestamps are paced on a fixed 60 fps
   step, which is the answering path's wire behaviour and must not drift. rdev's fps is fixed at
   60, so the two agree today. */
void    pion_peer_write_track_video(int64_t h, int slot, const uint8_t* payload, int len, int64_t pts_ns, int is_keyframe);
/* One encoded Opus packet. pts_ns is REAL CAPTURE TIME and DOES reach the wire — unlike
   pion_peer_write_track_video's, which is paced on a fixed step. Audio slots are their OWN
   namespace; a slot from pion_peer_add_source_tracks' audio_slot_out is the only valid argument. */
void    pion_peer_write_track_audio(int64_t h, int slot, const uint8_t* payload, int len, int64_t pts_ns);
void    pion_peer_send_data(int64_t h, int channel, const uint8_t* data, int len);
/* The bytes `channel` holds unsent (pion's BufferedAmount), or -1 when it is not open. A sender of
   something LARGE paces on it — an image on `control` (FileFetcher) — so what is queued behind waits
   for little. */
int64_t pion_peer_channel_buffered(int64_t h, int channel);

// Route one video slot: 0 = RTP (default), 1 = DataChannel. Returns the APPLIED routing, encoded as
// (dc_index << 1) | is_dc, or -1 for an unknown handle. The caller reports the return value as
// `activeDelivery`/`dcIndex` -- never the value it asked for, so a refusal is visible.
int     pion_peer_set_video_delivery(int64_t h, int slot, int delivery, const char* source_id);

// Mark a discontinuity on one video slot: a codec change or encoder rebuild. The client discards its
// decoder state for that source rather than solving equations against a stream that no longer exists.
void    pion_peer_bump_video_delivery(int64_t h, int slot);

// Pause or resume DataChannel emission for every routed source. Session-scoped, like the RTP path's
// visibility pause: routing survives, so the tab coming back is not a renegotiation.
void    pion_peer_set_video_hidden(int64_t h, int hidden);
void    pion_peer_close(int64_t h);

typedef void (*pion_on_reference_request)(uintptr_t ctx, int slot, const char* reason, int independent);
void pion_set_reference_request_callback(pion_on_reference_request callback);
int32_t pion_peer_reference_recovery_outcome(int64_t h, int32_t slot,
    const char* epoch, const char* recovery_id, const char* outcome);

/* Additive AV1 reference metadata path. Success means all packet writes completed. */
typedef void (*pion_on_reference_sent)(uintptr_t ctx, int slot, const char* result_json);
void pion_set_reference_callbacks(pion_on_reference_sent on_sent);
int32_t pion_peer_reference_track_id(int64_t h, int32_t slot, char* output, int32_t capacity);
int32_t pion_peer_next_reference_frame(int64_t h, int32_t slot, uint64_t* result);
int32_t pion_peer_write_track_video_reference(int64_t h, int32_t slot,
    const uint8_t* payload, int32_t length, int64_t pts_ns, int32_t keyframe,
    const char* metadata_json);

#endif
