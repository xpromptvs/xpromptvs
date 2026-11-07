package main

// rdev's C ABI, implemented over LLV's Session.
//
// THIS FILE IS A TRANSPORT SWAP, NOT A HOST REWRITE, AND THAT IS ITS WHOLE DESIGN CONSTRAINT.
// Every `pion_*` symbol keeps the name and signature rdev's Swift already calls
// (`PionBridge.swift`, `PionPeer.swift`), so nothing above the seam moves in the same commit that
// replaces everything below it. What used to be `host/pion-bridge/` — peer.go's PeerConnection,
// its own codec registry, its PT-aware RTX responder, its SVT-AV1 encoder handles — is deleted;
// what answers each call now is `newOfferSession` and the operations on it.
//
// EXACTLY ONE GO ARCHIVE MAY LINK INTO A BINARY, which is why this is a hard cutover rather than a
// runtime flag: rdev's bridge and this one each embed a complete Go runtime.
//
// THREE THINGS THE OLD BRIDGE DID THAT ARE GONE, deliberately:
//
//   - CODEC NEGOTIATION. The engine registers AV1 and nothing else, so `codec_pref` is accepted
//     and IGNORED (see pion_peer_add_video_track), and `pion_on_codec_resolved` always reports
//     AV1. The parameter stays so that no Swift call site changes in this commit.
//   - THE SVT-AV1 ENCODER HANDLES (`pion_av1_encoder_*`, `pion_free`). Encoding moved into Swift
//     (`LLVEncoderAdapter`, libaom) before this, so those symbols had no callers left.
//   - CODEC NEGOTIATION and the SVT encoder handles, above. ICE SERVERS ARE NO LONGER ONE OF THEM
//     (2026-08-18): `pion_peer_create`'s `ice_servers_json` is parsed and registered, and malformed
//     JSON is an error rather than a silent zero servers. Until then it was accepted and discarded,
//     and the reason was not laziness — a TURN relay candidate carries the RELAY's address, which
//     the remote-IP filter dropped, so TURN could not have worked whatever was passed. rdev's
//     sessions run ICEPolicyLAN now, which applies no such filter; `capture-host` keeps
//     ICEPolicyStrict and still registers none.
//
// CONCURRENCY: EVERY CALLBACK GOES OUT ON ONE ORDERED GOROUTINE PER PEER, and that is a contract
// the Swift side depends on rather than a tidiness choice. `PionPeer.close()` calls
// `pion_peer_close` and then RELEASES the retained `ctx` on the next line, on the stated grounds
// that "no callback can fire after close" — so `pion_peer_close` must not return until every
// pending callback has been delivered, or the next one dereferences freed memory. The dispatcher
// plus `<-dispatcherDone` is what makes that true, exactly as rdev's own bridge did it.

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*pion_on_reference_request)(uintptr_t ctx, int slot, const char* reason, int independent);
static pion_on_reference_request g_on_reference_request;
static void rdev_set_reference_request_cb(pion_on_reference_request cb) {g_on_reference_request=cb;}
typedef void (*pion_on_reference_sent)(uintptr_t ctx, int slot, const char* result_json);
static pion_on_reference_sent g_on_reference_sent;
static void rdev_set_reference_cb(pion_on_reference_sent cb) { g_on_reference_sent=cb; }
static void rdev_cb_reference_sent(uintptr_t ctx,int slot,const char* json) { if(g_on_reference_sent) g_on_reference_sent(ctx,slot,json); }
// Callback typedefs — must match pion_bridge.h exactly.
typedef void (*pion_on_local_description)(uintptr_t ctx, const char* sdp);
typedef void (*pion_on_ice_candidate)(uintptr_t ctx, const char* cand_json);
typedef void (*pion_on_datachannel_open)(uintptr_t ctx, int channel);
typedef void (*pion_on_datachannel_message)(uintptr_t ctx, int channel, const uint8_t* data, int len);
typedef void (*pion_on_connection_state)(uintptr_t ctx, int state);
typedef void (*pion_on_keyframe_request)(uintptr_t ctx, int slot);
typedef void (*pion_on_codec_resolved)(uintptr_t ctx, int slot, int codec);
// RETURNS A STATUS, unlike every other callback here — see pion_bridge.h for why.
typedef int (*pion_on_recovery_policy)(uintptr_t ctx, uint64_t sequence, int tier,
                                       uint32_t media_bitrate_bps);

// Every declaration in this preamble is `static`, which is LOAD-BEARING and not style: a file that
// uses //export has its preamble copied into TWO generated C files, so a non-static definition
// here would be a duplicate symbol at link time. Statics get one private copy per translation
// unit, and only the one in this file's unit is ever reached from Go.
static pion_on_local_description   g_on_local;
static pion_on_ice_candidate       g_on_ice;
static pion_on_datachannel_open    g_on_open;
static pion_on_datachannel_message g_on_msg;
static pion_on_connection_state    g_on_state;
static pion_on_keyframe_request    g_on_keyframe;
static pion_on_codec_resolved      g_on_codec;
static pion_on_recovery_policy     g_on_policy;

static void rdev_set_cbs(pion_on_local_description a, pion_on_ice_candidate b,
                         pion_on_datachannel_open c, pion_on_datachannel_message d,
                         pion_on_connection_state e, pion_on_keyframe_request f,
                         pion_on_codec_resolved g, pion_on_recovery_policy h) {
    g_on_local = a; g_on_ice = b; g_on_open = c; g_on_msg = d; g_on_state = e; g_on_keyframe = f; g_on_codec = g;
    g_on_policy = h;
}
static void rdev_cb_local(uintptr_t ctx, const char* s)            { if (g_on_local) g_on_local(ctx, s); }
static void rdev_cb_ice(uintptr_t ctx, const char* s)              { if (g_on_ice)   g_on_ice(ctx, s); }
static void rdev_cb_open(uintptr_t ctx, int ch)                    { if (g_on_open)  g_on_open(ctx, ch); }
static void rdev_cb_msg(uintptr_t ctx, int ch, const uint8_t* d, int n) { if (g_on_msg) g_on_msg(ctx, ch, d, n); }
static void rdev_cb_state(uintptr_t ctx, int st)                   { if (g_on_state) g_on_state(ctx, st); }
static void rdev_cb_keyframe(uintptr_t ctx, int slot)              { if (g_on_keyframe) g_on_keyframe(ctx, slot); }
static void rdev_cb_reference_request(uintptr_t ctx,int slot,const char* reason,int independent) {
 if(g_on_reference_request) g_on_reference_request(ctx,slot,reason,independent);
 else if(g_on_keyframe) g_on_keyframe(ctx,slot);
}
static void rdev_cb_codec(uintptr_t ctx, int slot, int codec)      { if (g_on_codec) g_on_codec(ctx, slot, codec); }
static int rdev_cb_policy(uintptr_t ctx, uint64_t seq, int tier, uint32_t bps) {
    if (!g_on_policy) { return -1; }
    return g_on_policy(ctx, seq, tier, bps);
}
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/pion/webrtc/v4"
)

// The values pion_on_codec_resolved reports.
//
// This is Swift's `RdevCore.NegotiatedCodec` wire numbering (h264=0, h265=1, av1=2), which is
// DELIBERATELY NOT the `codec_pref` numbering on the way in. The two cross the same ABI in
// opposite directions — a preference in, a resolved codec out — so sharing a numbering would make
// 0 mean two different things.
const (
	rdevNegotiatedCodecH264 codecID = 0
	rdevNegotiatedCodecH265 codecID = 1
	rdevNegotiatedCodecAV1  codecID = 2
)

// rdevAllSlotsKeyframe is the slot value that means "every source on this client". rdev's own
// bridge used -1 for the connection-level keyframe request it pushes on connect, and ChannelHub
// reads it that way (`if slot < 0 { for (source, _) in entries … }`).
const rdevAllSlotsKeyframe = -1

// rdevDummySignalPort satisfies a validator that has nothing to validate on this path.
// validateSessionConfiguration and PeerConfig.Validate both require SignalPort to be non-zero and
// different from ICEPort; both are SHARED with the answering path, where the port is a real TCP
// listener, and relaxing either would change what THAT path accepts. Nothing binds it here.
const rdevDummySignalPort = uint16(1)

// rdevICEPortAttempts bounds the retry when the ICE port is probed rather than pinned. Probing
// asks the kernel for a free port, closes it, and hands the number to newPeerAPI, which binds it
// again — a window another process can win. One retry would usually do; five is cheap and covers a
// machine that is genuinely churning ports.
const rdevICEPortAttempts = 5

// rdevFlexFECFramesPerSecond is what the session tells the FlexFEC controller to expect, and it
// matches the encoder: 60, fixed in code since RDEV_VIDEO_FPS was deleted.
const rdevFlexFECFramesPerSecond = uint32(60)

// rdevWriteLogInterval throttles the per-slot write-failure log. See rdevPeer.logWriteFailure.
const rdevWriteLogInterval = time.Second

// The recovery-impairment knob, and it exists for ONE caller: the certification's rdev arm.
//
// WHY IT HAS TO EXIST AT ALL. scripts/gate-input-to-decode.sh measures both arms under the SAME
// impairment profile, and stock `llv capture-host` takes one on its command line. Without an
// equivalent here the rdev arm could only be measured unimpaired — after which eight of the nine
// profiles would compare an impaired stock run against an unimpaired rdev one and report an
// enormous "difference between the arms" that is entirely an artefact of the harness.
//
// IT IS AN ENVIRONMENT VARIABLE AND NOT AN ABI ADDITION, deliberately: `pion_peer_create` takes
// what rdev's Swift already passes, and a measurement-only control has no business widening the
// surface the product calls. Same reasoning as RDEV_LLV_LOCAL_IP / RDEV_LLV_ICE_PORT beside it.
//
//	RDEV_LLV_IMPAIRMENT_PROFILE  path to ONE impairment profile object (not the catalogue)
//	RDEV_LLV_IMPAIRMENT_SEED     that profile's seed; required whenever a profile is given
//
// UNSET IS THE PRODUCT PATH AND IS BYTE-FOR-BYTE UNCHANGED: rdevSessionConfiguration leaves
// SessionConfiguration.Impairment nil, which is what createSession already receives today, so no
// controller is constructed and wrapHostPacketConn is never reached.
const (
	rdevImpairmentProfileVariable = "RDEV_LLV_IMPAIRMENT_PROFILE"
	rdevImpairmentSeedVariable    = "RDEV_LLV_IMPAIRMENT_SEED"
)

// rdevReportInterval paces the periodic `[impairment]` and `[bridge] fec:` lines. See
// rdevPeer.reportImpairment for why a report is periodic AND emitted on close rather than only on
// close, and runPeriodicReporter for why it is on its own goroutine.
//
// IT ALSO MATCHES `[encode]`'s WINDOW, which is what makes the two readable together: a keyframe
// burst and the repair packets that did or did not protect it land in the same 5 s bucket.
//
// FIVE SECONDS, NOT ONE, BECAUSE THE SNAPSHOT IS O(DECISIONS). `Snapshot()` JSON-marshals and hashes
// EVERY decision the controller has taken, and that count grows through the run — 34,696 of them on
// one recorded `congested-wifi` reference run. Cheap per decision and not cheap in total, so the
// interval is set where four or five reports over a 19 s measurement cost background CPU that cannot
// be mistaken for the engine's. The gate waits up to 15 s for one, so this has ample margin.
const rdevReportInterval = 5 * time.Second

// rdevPeerStateWire maps LLV's state STRINGS back to pion's numeric PeerConnectionState, which is
// what `pion_on_connection_state` has always carried and what rdev's Swift compares against
// (`stateDidChange`: `if state == 3` is PeerConnectionStateConnected).
//
// Built FROM pion's own enum rather than written out as literals, so it cannot drift from the
// numbers the old bridge emitted — those were `int(webrtc.PeerConnectionState)` too. "ready" is
// LLV's own synthetic state and is absent on purpose: it is not a PeerConnectionState, and
// reporting it as one would tell rdev the connection had changed state when it had not.
var rdevPeerStateWire = func() map[string]int {
	out := map[string]int{}
	for _, state := range []webrtc.PeerConnectionState{
		webrtc.PeerConnectionStateNew,
		webrtc.PeerConnectionStateConnecting,
		webrtc.PeerConnectionStateConnected,
		webrtc.PeerConnectionStateDisconnected,
		webrtc.PeerConnectionStateFailed,
		webrtc.PeerConnectionStateClosed,
	} {
		out[state.String()] = int(state)
	}
	return out
}()

// rdevPeer is one client's session plus the ordered callback dispatcher the ABI promises.
type rdevPeer struct {
	ctx     uintptr
	session *Session

	events               chan func()
	done                 chan struct{}
	dispatcherDone       chan struct{}
	closeOnce            sync.Once
	referenceTestFIROnce sync.Once

	// offerMutex guards pendingOffer across scheduleOffer/driveOffer/setAnswer, mirroring
	// peer.videoMu in rdev's own bridge. See driveOffer for why coalescing is required.
	offerMutex   sync.Mutex
	pendingOffer bool

	// onRecoveryPolicy is the sink the adaptive FlexFEC controller's decisions reach. Production
	// sets it to the C trampoline in newRdevPeer; tests replace it. It is written once before the
	// session exists and only read afterwards, so it needs no lock — unlike everything below
	// impairmentMutex, which the encode thread touches.
	onRecoveryPolicy func(RecoveryPolicyUpdate) error

	logMutex     sync.Mutex
	lastWriteLog map[int]time.Time

	// impairmentMutex guards every field below it. All four are touched from
	// pion_peer_write_track_video, which rdev calls from its encode thread, and from close().
	impairmentMutex sync.Mutex
	// impairmentWarmupFrames is the profile's own `warmupFrames`, or 0 when no profile was
	// configured — which is what makes 0 the "nothing to arm" sentinel. See maybeArmImpairment
	// for why it is never treated as "arm immediately": the controller cannot classify a stream
	// it has not seen a packet of.
	impairmentWarmupFrames uint64
	impairmentWrites       uint64
	impairmentArmed        bool
	impairmentArmFailures  uint64

	// The periodic reporter's own lifecycle, mirroring dispatcherDone: `close()` stops it and WAITS
	// for it before touching the session, so no snapshot can be in flight across Session.Close.
	//
	// UNCONDITIONAL SINCE THE FEC REPORT JOINED THE IMPAIRMENT ONE. These used to be nil unless an
	// impairment profile was configured — which is every rdev host except the certification arm —
	// but `[bridge] fec:` has to run everywhere, so the lifecycle is now always present and each
	// report gates ITSELF on having something to say.
	reporterStop chan struct{}
	reporterDone chan struct{}

	// The previous FlexFEC sample, so the report is a WINDOW rather than a running total. Touched
	// only from runPeriodicReporter's goroutine, and from close() after it has been stopped and
	// waited for — which is what makes it safe without a mutex.
	lastRecovery recoverySample
}

var (
	rdevRegistryMutex sync.Mutex
	rdevRegistryNext  int64
	rdevRegistry      = map[int64]*rdevPeer{}
)

func rdevRegister(peer *rdevPeer) int64 {
	rdevRegistryMutex.Lock()
	defer rdevRegistryMutex.Unlock()
	rdevRegistryNext++
	rdevRegistry[rdevRegistryNext] = peer
	return rdevRegistryNext
}

func rdevLookup(handle int64) *rdevPeer {
	rdevRegistryMutex.Lock()
	defer rdevRegistryMutex.Unlock()
	return rdevRegistry[handle]
}

func rdevUnregister(handle int64) {
	rdevRegistryMutex.Lock()
	defer rdevRegistryMutex.Unlock()
	delete(rdevRegistry, handle)
}

// enqueue hands one callback to this peer's ordered dispatcher.
//
// IT CAN BLOCK, AND THAT IS INHERITED BEHAVIOUR RATHER THAN AN OVERSIGHT. rdev's own bridge used
// the identical `select { case events <- fn: case <-done: }` on a 64-deep buffer. The dispatcher
// goroutine itself reaches back into Go through the ABI — a channel-open callback ends up calling
// pion_peer_send_data, and a connection-state callback ends up calling pion_peer_add_video_track —
// so it is a producer as well as the consumer, and a full buffer would stall it against itself.
// 64 pending callbacks with a live consumer has never been observed; the escape hatch is `done`,
// so a close unblocks it rather than leaking the goroutine.
func (peer *rdevPeer) enqueue(callback func()) {
	select {
	case peer.events <- callback:
	case <-peer.done:
	}
}

func (peer *rdevPeer) dispatch() {
	defer close(peer.dispatcherDone)
	for {
		select {
		case callback := <-peer.events:
			callback()
		case <-peer.done:
			return
		}
	}
}

// scheduleOffer marks a renegotiation as wanted and tries to emit it now, and driveOffer emits at
// most one. Ported from rdev's bridge, which is where the requirement comes from: pion refuses
// CreateOffer while signalling is not stable (`have-local-offer`), and rdev adds and removes tracks
// whenever a client subscribes — so an offer per operation would fail whenever two arrived close
// together. A pending offer is emitted later, from setAnswer, once the in-flight one settles.
//
// AddVideoTrack does not renegotiate on its own — the engine has no signalling of its own on this
// path, and its doc comment says the caller owns it. THIS is that caller, and this pair is where
// that obligation lives.
func (peer *rdevPeer) scheduleOffer() {
	peer.offerMutex.Lock()
	peer.pendingOffer = true
	peer.offerMutex.Unlock()
	peer.driveOffer()
}

func (peer *rdevPeer) driveOffer() {
	peer.offerMutex.Lock()
	defer peer.offerMutex.Unlock()
	if !peer.pendingOffer || peer.session.peer.SignalingState() != webrtc.SignalingStateStable {
		return
	}
	peer.pendingOffer = false
	sdp, err := peer.session.CreateOffer()
	if err != nil {
		// Left pending so the next drive retries, which is rdev's own behaviour. A renegotiation
		// that is dropped instead of retried leaves a subscribed source with a track the remote
		// never learned about, and WriteVideo then fails with "no negotiated bindings" forever.
		//
		// THAT WAS TRUE OF THE FLAG AND FALSE OF THE PEER UNTIL 2026-08-19, and the gap is what
		// turned one bad renegotiation into a dead session. createOffer used to SetLocalDescription
		// before validating, so a refusal left the peer in have-local-offer — and the guard above
		// emits only from `stable`, while the only thing that restores `stable` is the answer to an
		// offer the remote never received. So every later drive returned early, silently, and the
		// log carried exactly one line for the whole failure. createOffer now validates before it
		// commits, which is what makes this retry a retry.
		//
		// The retry still waits for the next scheduleOffer or setAnswer rather than spinning: a
		// refusal is deterministic in the description that caused it, so re-offering the SAME
		// description could only fail the same way. What makes it recoverable is that the next
		// subscribe or unsubscribe produces a DIFFERENT one — which is precisely the sequence
		// (close a window, open another) that was reported broken.
		peer.pendingOffer = true
		fmt.Printf("[bridge] renegotiation offer failed: %v\n", err)
		return
	}
	peer.emitLocalDescription(sdp)
}

// sdpCodecSummary names the video codecs an SDP advertises, RTX and FEC excluded, for the offer and
// answer logs. A substring scan rather than a parse: it runs on the signalling path and must not be
// able to fail in its own right.
func sdpCodecSummary(sdp string) string {
	names := make([]string, 0, 4)
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		payload := strings.TrimPrefix(line, "a=rtpmap:")
		lowered := strings.ToLower(payload)
		if strings.Contains(lowered, "rtx/") || strings.Contains(lowered, "flexfec") ||
			strings.Contains(lowered, "red/") || strings.Contains(lowered, "ulpfec") {
			continue
		}
		if fields := strings.Fields(payload); len(fields) == 2 {
			names = append(names, fields[1]+"/"+fields[0])
		}
	}
	if len(names) == 0 {
		return "(no video codecs)"
	}
	return strings.Join(names, " ")
}

// deliverRecoveryPolicy hands one controller decision to Swift and reports whether it was applied.
//
// IT IS THE ONLY CALLBACK ON THIS ABI THAT IS BOTH ORDERED AND SYNCHRONOUS, and the two requirements
// pull against each other. Ordered, because PionPeer.close releases the retained ctx on the line
// after pion_peer_close returns: a callback that bypassed the dispatcher could fire after that and
// dereference freed memory, and the controller's evaluation timer keeps firing while a session
// closes. Synchronous, because the engine acts on the returned error — CaptureRecoveryBitrateCoordinator
// rejects an invalid sequence, a zero bitrate or a sequence conflict, and a controller that believed a
// rejected update had been applied would let the total exceed the budget it exists to respect.
//
// The resolution is to enqueue a closure carrying a reply channel and wait on it. LLV's own ABI calls
// its equivalent inline (abiCallbacks.callRecoveryPolicy), which is safe THERE only because that ABI
// makes no ordering promise to its caller; copying it here would reintroduce the use-after-free.
//
// THE `done` ESCAPE IS NOT DEFENSIVE PADDING. Waiting on a dispatcher that has already stopped is a
// permanent block, so a torn-down peer reports failure instead — which is also the truth: the update
// was discarded.
//
// ASSUMPTION, stated because enqueue's own comment warns about this shape: the dispatcher is a
// producer as well as a consumer, so blocking on it FROM the dispatcher goroutine would self-deadlock.
// The controller calls this from its own evaluation-interval timer, never from a dispatched callback,
// so that cannot happen today. A future caller inside a dispatched callback would wedge here.
func (peer *rdevPeer) deliverRecoveryPolicy(update RecoveryPolicyUpdate) error {
	reply := make(chan error, 1)
	select {
	case peer.events <- func() {
		if peer.onRecoveryPolicy == nil {
			reply <- fmt.Errorf("no recovery policy sink installed")
			return
		}
		reply <- peer.onRecoveryPolicy(update)
	}:
	case <-peer.done:
		return fmt.Errorf("peer is closed; recovery policy update %d discarded", update.Sequence)
	}
	select {
	case err := <-reply:
		return err
	case <-peer.done:
		return fmt.Errorf("peer closed while applying recovery policy update %d", update.Sequence)
	}
}

// emitRecoveryPolicy is the production sink: the C trampoline, which returns a non-zero status when
// Swift has installed no callback, so an unheard update is never reported as applied.
func (peer *rdevPeer) emitRecoveryPolicy(update RecoveryPolicyUpdate) error {
	status := C.rdev_cb_policy(C.uintptr_t(peer.ctx), C.uint64_t(update.Sequence),
		C.int(update.Tier), C.uint32_t(update.MediaBitrateBitsPerSecond))
	if status != 0 {
		return fmt.Errorf("recovery policy update %d rejected: %d", update.Sequence, int(status))
	}
	return nil
}

func (peer *rdevPeer) emitLocalDescription(sdp string) {
	// WHAT rdev OFFERED, so it can be read beside what the answer comes back with (the bind log).
	//
	// HERE RATHER THAN AT THE THREE CALL SITES, so the INITIAL offer is covered as well as every
	// renegotiation — the initial one is the interesting case for "why did this session start on
	// H.265", and instrumenting driveOffer alone would have missed it.
	//
	// Registration is unconditional and nothing calls SetCodecPreferences, so on paper this cannot
	// vary. "On paper" is what produced two wrong conclusions about which side dropped AV1 — and a
	// log showing only the ANSWER cannot tell an answer that omitted a codec from an offer that never
	// carried one. One line makes that comparison direct instead of inferred.
	fmt.Printf("[bridge] local description: %s\n", sdpCodecSummary(sdp))
	peer.enqueue(func() {
		text := C.CString(sdp)
		defer C.free(unsafe.Pointer(text))
		C.rdev_cb_local(C.uintptr_t(peer.ctx), text)
	})
}

func (peer *rdevPeer) emitICECandidate(candidateJSON string) {
	peer.enqueue(func() {
		text := C.CString(candidateJSON)
		defer C.free(unsafe.Pointer(text))
		C.rdev_cb_ice(C.uintptr_t(peer.ctx), text)
	})
}

func (peer *rdevPeer) emitChannelOpen(channel int) {
	peer.enqueue(func() { C.rdev_cb_open(C.uintptr_t(peer.ctx), C.int(channel)) })
}

func (peer *rdevPeer) emitChannelMessage(channel int, data []byte) {
	peer.enqueue(func() {
		var pointer *C.uint8_t
		if len(data) > 0 {
			pointer = (*C.uint8_t)(unsafe.Pointer(&data[0]))
		}
		C.rdev_cb_msg(C.uintptr_t(peer.ctx), C.int(channel), pointer, C.int(len(data)))
	})
}

func (peer *rdevPeer) emitConnectionState(state int) {
	peer.enqueue(func() { C.rdev_cb_state(C.uintptr_t(peer.ctx), C.int(state)) })
}

func (peer *rdevPeer) emitKeyframeRequest(slot int) {
	peer.enqueue(func() { C.rdev_cb_keyframe(C.uintptr_t(peer.ctx), C.int(slot)) })
}

func (peer *rdevPeer) emitCodecResolved(slot int, codec int) {
	peer.enqueue(func() { C.rdev_cb_codec(C.uintptr_t(peer.ctx), C.int(slot), C.int(codec)) })
}

// logWriteFailure reports a write or send failure AT MOST ONCE PER SECOND PER SLOT.
//
// THE THROTTLE IS THE POINT, IN BOTH DIRECTIONS. Video writes arrive at 60 Hz per source, so an
// unthrottled log would produce 60 identical lines a second and train a reader to ignore the one
// place that knows what is really being sent — and rdev's own bridge went the other way and
// dropped these silently, which is how "no video, every state healthy" became this project's
// signature failure. One line per slot per second is legible and still names the FIRST failure
// immediately, which is the one that says what went wrong.
//
// "no negotiated bindings" is the expected transient here: a write can legitimately land between
// AddVideoTrack and the answer that negotiates it, and it stops as soon as the renegotiation
// completes. A line that KEEPS repeating is the real signal.
func (peer *rdevPeer) logWriteFailure(slot int, err error) {
	now := time.Now()
	peer.logMutex.Lock()
	last, seen := peer.lastWriteLog[slot]
	if seen && now.Sub(last) < rdevWriteLogInterval {
		peer.logMutex.Unlock()
		return
	}
	peer.lastWriteLog[slot] = now
	peer.logMutex.Unlock()
	fmt.Printf("[bridge] slot %d write failed: %v\n", slot, err)
}

// noteVideoWrite counts one SUCCESSFUL video write, arms the impairment once enough have gone past,
// and periodically publishes what the controller has done.
//
// COUNTING SUCCESSES AND NOT CALLS IS THE WHOLE POINT. The controller learns which stream carries
// the original media from the first RTP packet it sees while INACTIVE
// (RecoveryImpairmentController.observePassthrough sets hasOriginalStream; nothing else ever does).
// A write that FAILED — the ordinary transient between AddVideoTrack and the answer that negotiates
// it — produced no packet, so counting it could arm a controller that has never seen the stream, at
// which point classifyDatagram files everything under `other` and nothing is impaired. That failure
// is silent in every other signal: the profile validates, the controller counts thousands of
// decisions, and drops zero packets.
func (peer *rdevPeer) noteVideoWrite() {
	if !referenceTestImpairmentReady() {
		return
	}
	arm, writes := peer.nextVideoWriteAction()
	if arm {
		// RETRIED ON LATER WRITES RATHER THAN ONCE, because Session.ActivateImpairment refuses a
		// session that is not `ready` and readiness is not ordered against the first video write:
		// rdev subscribes over `control`, so a write can precede the candidate-pair selection
		// maybeReady waits for. A single attempt would leave the run unimpaired on a timing
		// difference. Every failure is logged (the count is in the message, so a persistent
		// failure is distinguishable from one transient attempt) and `impairmentArmed` is only set
		// on success, which is what makes the retry happen at all.
		if err := peer.session.ActivateImpairment(); err != nil {
			peer.impairmentMutex.Lock()
			peer.impairmentArmFailures++
			failures := peer.impairmentArmFailures
			peer.impairmentMutex.Unlock()
			if failures == 1 || failures%60 == 0 {
				fmt.Printf("[impairment] arming refused after %d frames (attempt %d): %v\n",
					writes, failures, err)
			}
		} else {
			peer.impairmentMutex.Lock()
			peer.impairmentArmed = true
			peer.impairmentMutex.Unlock()
			fmt.Printf("[impairment] armed after %d frames\n", writes)
		}
	}
}

// configureImpairment records what this peer must wait for before arming, and creates the reporter's
// lifecycle — or leaves both absent when no profile was configured, which is every rdev host in
// existence except the certification's rdev arm.
func (peer *rdevPeer) configureImpairment(configuration *RecoveryImpairmentConfiguration) {
	if configuration == nil {
		return
	}
	peer.impairmentWarmupFrames = uint64(configuration.Profile.WarmupFrames)
	fmt.Printf("[impairment] profile %q seed %d, arming after %d frames\n",
		configuration.Profile.Name, configuration.Seed, peer.impairmentWarmupFrames)
}

// configureReporting creates the periodic reporter's lifecycle.
//
// THE PAIRING IS ONE DECISION IN ONE PLACE. The two channels and the goroutine guard and the
// close-time stop used to be three separate `!= nil` tests, and creating one channel without the
// other is not a cosmetic slip: a nil done channel panics the reporter on its own `defer close(...)`,
// and a nil stop channel makes its `select` block forever on a channel nothing can ever close, so the
// reporter never stops and `close()` waits on it forever. Both channels or neither, decided once.
func (peer *rdevPeer) configureReporting() {
	peer.reporterStop = make(chan struct{})
	peer.reporterDone = make(chan struct{})
}

// reporterRunning reports whether this peer has a reporter lifecycle to run and to stop.
//
// BOTH CHANNELS ARE TESTED, not one. Either alone is a broken half — see configureImpairment — so a
// guard that checked only `reporterStop` would start a goroutine that panics, and one that checked
// only `reporterDone` would wait on a stop nothing can signal.
func (peer *rdevPeer) reporterRunning() bool {
	return peer.reporterStop != nil && peer.reporterDone != nil
}

// runPeriodicReporter publishes the impairment snapshot and the FlexFEC window every
// rdevReportInterval until the peer closes.
//
// ONE GOROUTINE FOR BOTH REPORTS, rather than a second lifecycle beside this one. The pairing hazard
// documented on configureReporting is real and duplicating it to add a report would be the cheapest
// possible way to reintroduce it. Each report gates itself: reportImpairment returns on a peer with
// no impairment configured, reportRecovery on one with no negotiated FlexFEC.
//
// ON ITS OWN GOROUTINE, AND THAT IS THE WHOLE POINT — an earlier version of this called
// reportImpairment straight from pion_peer_write_track_video, which put an O(DECISIONS) JSON marshal
// and SHA-256 on the ENCODE PATH of the very arm being measured, growing through the run. The stock
// arm pays that cost exactly once, at teardown, so leaving it on the write path would have been a
// self-inflicted arm asymmetry in a latency measurement: the certification would have reported an
// instrument as an engine difference, and the artifact it produced would have looked perfect.
func (peer *rdevPeer) runPeriodicReporter() {
	// REFUSES A PEER WITH NO LIFECYCLE, AND THE FAILURE THIS PREVENTS IS A SILENT LEAK RATHER THAN A
	// PANIC — which is the opposite of what an earlier note here claimed. With a nil `reporterDone`,
	// `defer close(...)` binds nil and is scheduled for a return that NEVER COMES, because the select
	// below waits on a nil `reporterStop` beside a live ticker: no panic, no return, and a goroutine
	// that keeps calling `session.Stats()` every interval — including AFTER `Session.Close()`, which
	// is exactly what close()'s stop-and-wait ordering exists to prevent. Reproduced standalone
	// during review: "NO PANIC, NO RETURN … still ticking after 300ms".
	//
	// DEAD CODE IN TODAY'S CALL GRAPH, DELIBERATELY. configureReporting now creates both channels on
	// every peer, so this guard cannot fire — but dropping one of those creations is a one-line edit
	// that NO unit test can catch, since constructing a real peer needs a UDP bind. Without the guard
	// that slip becomes a goroutine leak that survives Session.Close, silently.
	if !peer.reporterRunning() {
		return
	}
	defer close(peer.reporterDone)
	ticker := time.NewTicker(rdevReportInterval)
	defer ticker.Stop()
	// A BASELINE IMMEDIATELY, before the first tick. It publishes a live controller with zero
	// decisions, which is what distinguishes "the impairment never armed" from "the host published
	// nothing at all" on a run that went wrong — two faults with entirely different causes.
	peer.reportImpairment()
	peer.reportRecovery()
	peer.reportDCDelivery()
	for {
		select {
		case <-ticker.C:
			peer.reportImpairment()
			peer.reportRecovery()
			peer.reportDCDelivery()
		case <-peer.reporterStop:
			return
		}
	}
}

// reportDCDelivery prints the host's own DataChannel counters, and says NOTHING when no source is
// routed there — so a silent log means "not in use" rather than "in use and delivering nothing".
//
// `src=0` WHILE routed>0 IS THE FAILURE THIS EXISTS TO MAKE VISIBLE. Both faults found while
// prototyping this transport — colliding symbol ids, and an instrument left running on a control arm
// — reported cleanly in every other counter while delivering nothing at all.
func (peer *rdevPeer) reportDCDelivery() {
	registry := peer.session.dcDelivery.Load()
	if registry == nil || registry.routedSlots() == 0 {
		return
	}
	fmt.Println(registry.report())
}

// reportRecovery prints one window of FlexFEC output, or nothing at all when this session has no
// negotiated FlexFEC to report on.
//
// IT IS THE ONLY PLACE rdev CAN SEE ITS OWN FEC. The engine has counted repair packets all along and
// nothing in rdev read them, so `[bridge] FlexFEC negotiated=true` and the media/FEC budget split
// were the whole of the evidence — neither of which says a repair packet ever reached the wire. A
// 50%-forced session on a real iPad was indistinguishable from one sending nothing.
func (peer *rdevPeer) reportRecovery() {
	stats := peer.session.Stats()
	if stats.FlexFEC == nil || !stats.FlexFEC.Negotiated {
		return
	}
	sample := recoverySampleFrom(stats.FlexFEC)
	fmt.Println(formatRecoveryReport(recoveryState{
		tier:           stats.FlexFEC.CurrentTier,
		degraded:       stats.FlexFEC.Degraded,
		degradedReason: stats.FlexFEC.DegradedReason,
		overrideBp:     stats.FlexFEC.OverrideBasisPoints,
		overridden:     stats.FlexFEC.Overridden,
	}, peer.lastRecovery, sample))
	peer.lastRecovery = sample
}

// nextVideoWriteAction counts one successful video write and reports whether it is the one that arms
// the impairment, plus how many writes have been seen.
//
// SPLIT OUT OF noteVideoWrite SO THE BOUNDARY IS TESTABLE. `arm` fires on exactly one write and the
// off-by-one is the whole risk: arming on write `warmupFrames` instead of the one after it gives the
// controller one fewer passthrough packet than the profile asked for, which is invisible in every
// counter. Everything noteVideoWrite does around this needs a live Session; this does not.
//
// IT IS ALSO THE WHOLE COST THIS PATH PAYS — a mutex acquisition and two integer comparisons. The
// snapshot is on runPeriodicReporter's goroutine, deliberately; see there.
func (peer *rdevPeer) nextVideoWriteAction() (arm bool, writes uint64) {
	peer.impairmentMutex.Lock()
	defer peer.impairmentMutex.Unlock()
	if peer.impairmentWarmupFrames == 0 {
		return false, peer.impairmentWrites
	}
	peer.impairmentWrites++
	// Strictly GREATER, matching CaptureHostRuntime: `warmupFrames` frames pass unimpaired and the
	// arming happens on the one after them.
	arm = !peer.impairmentArmed && peer.impairmentWrites > peer.impairmentWarmupFrames
	return arm, peer.impairmentWrites
}

// reportImpairment prints the controller's cumulative counters as one `[impairment]` line.
//
// IT IS PERIODIC *AND* EMITTED ON CLOSE, and the periodic half is what makes it usable at all: the
// gates stop the host with a signal, which does not run pion_peer_close, so a close-only report
// would be absent from every measured run. `Snapshot()` is cumulative and non-clearing (only
// ResetMeasurement zeroes it), so the last line of a run is the whole run — a reader takes the LAST
// one, not a sum, and tools/InputToDecodeReduce does exactly that.
//
// `sourceCoordinateDrops` IS DROPPED FROM THE LINE, and that is not tidying. It carries one object
// per dropped packet — thousands under a WAN profile — which would bury the host's own log, and no
// consumer reads it: the reducer summarises six integers out of this and records those.
//
// THE COUNTERS ARE THE ONLY EVIDENCE THAT THE PROFILE REACHED THE ENGINE. `capture-host` publishes
// the same snapshot inside its `final` event's engineSpecificStatsJSON; without an equivalent here
// the rdev arm's runs would fail `impairment-reached-the-engine` outright, which is the assertion
// that exists because "a flag parsed into a variable that never reaches the engine" is this
// project's most-repeated bug.
func (peer *rdevPeer) reportImpairment() {
	stats := peer.session.Stats()
	if stats.Impairment == nil {
		return
	}
	snapshot := *stats.Impairment
	snapshot.SourceCoordinateDrops = nil
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		fmt.Printf("[impairment] could not serialise the controller snapshot: %v\n", err)
		return
	}
	fmt.Printf("[impairment] %s\n", encoded)
}

// rdevSessionConfiguration builds the configuration an offer session needs from the environment.
//
// THE ADDRESSES ARE A REAL LIMITATION AND THEY ARE NOT MINE TO FIX HERE. newPeerAPI turns LocalIP
// and RemoteIP into four ICE restrictions on one shared SettingEngine — UDP4 only, gather on
// LocalIP, accept remote candidates ONLY from RemoteIP, mDNS disabled — and PeerConfig.Validate
// rejects a nil RemoteIP, so a session is reachable from exactly one pre-known IPv4 address. That
// code is shared with the answering path, i.e. with the certification's comparison arm, so
// changing it is a deliberate change to BOTH arms and is recorded as increment 2's first problem.
//
// THE DEFAULT IS THIS MACHINE'S OWN LAN ADDRESS FOR BOTH, which is correct for exactly the
// configuration increment 1 is certified in — a receiver on the same machine (RdevViewer, or a
// browser in the headless smoke) — and wrong for anything else. It is derived the way the gates
// derive it, from the default route, so the host and a viewer started by `gate-input-to-decode.sh`
// agree without either being told.
//
//	RDEV_LLV_LOCAL_IP        gather here          (default: default-route source address)
//	RDEV_LLV_REMOTE_IP       accept only this     (default: the same address)
//	RDEV_LLV_ICE_PORT        bind this UDP port   (default: probe a free one, per session)
//	RDEV_LLV_RTX_MAX_AGE_MS  retransmit window    (default: 30, what the reference records)
//
// Recovery is NOT configurable. Both certification arms run NACK/RTX and the reference records
// `--recovery nack-rtx`, so a knob here could only make the two arms differ in recovery while
// every number still looked comparable.
// rdevConfiguredRecovery reads RDEV_LLV_RECOVERY, which selects the recovery stack.
//
// THE DEFAULT IS `nack-rtx-flexfec` AS OF 2026-08-18, and `nack-rtx` is the OPT-OUT.
//
// WHY THE KNOB SURVIVES THE FLIP RATHER THAN BEING DELETED. The accepted consequence of FlexFEC is
// that a receiver which will not answer it CANNOT CONNECT AT ALL: Recovery is fixed on PeerConfig,
// there is no mid-session downgrade, and an answer that strips the FlexFEC payload fails the parser
// and kills the session. Chrome's answer was measured against the strict parser before this default
// moved (scripts/probe-flexfec-answer.sh, 13/13 fields), but SAFARI AND FIREFOX HAVE NEVER BEEN
// EXERCISED AGAINST rdev AT ALL — so `RDEV_LLV_RECOVERY=nack-rtx` is the only way to recover a
// machine whose browser cannot answer, short of a rebuild.
//
// AN UNRECOGNISED VALUE REFUSES THE SESSION rather than falling back to the default. A typo that
// silently selected the other recovery stack would be invisible: the session connects, streams and
// decodes either way, and the only difference is which repair mechanism is running — exactly the
// class of "parsed into a variable that reaches nothing" defect this file keeps a note about.
//
// GO SNAPSHOTS THE ENVIRONMENT AT RUNTIME INIT, which for a c-archive is before Swift's main runs.
// This must be set by the parent shell; a setenv() from Swift can never be seen here.
// STOP STAMPING THE PLAYOUT-DELAY EXTENSION AT ALL (`RDEV_LLV_PLAYOUT_DELAY_OFF=1`).
//
// rdev puts a playout-delay header extension on every packet, and this project has already measured
// that a receiver honours the SENDER'S extension over the page's own request — so that header is
// overriding each browser's native jitter buffer everywhere, with bounds (min 0ms, max 10ms) chosen
// for loopback latency and applied unconditionally to a relay.
//
// The consequences were measured this session and they are large: against 9ms of jitter, a 10ms
// ceiling left the receiver discarding 82 frames per five seconds with 27fps reaching the screen.
// Raising the ceiling fixed the discards; forcing a 100ms FLOOR made it "much smoother" still. Both
// are us picking a number for a path we cannot see.
//
// This removes rdev from that decision entirely and lets each browser use the jitter buffer it ships
// with — machinery tuned for exactly these conditions by people with far more traces than we have.
// The extension is still NEGOTIATED (Bind requires it and the wire format is unchanged); it is simply
// not written, and an absent extension imposes no constraint.
//
// A spike knob, not a product default: it is session-wide and gives up the low-latency mode that is
// correct on a LAN. Go snapshots the environment at runtime init, so this must come from the parent
// shell.
var rdevPlayoutDelayHeaderOff = strings.TrimSpace(os.Getenv("RDEV_LLV_PLAYOUT_DELAY_OFF")) == "1"

func rdevConfiguredRecovery() (RecoveryMode, error) {
	switch raw := strings.TrimSpace(os.Getenv("RDEV_LLV_RECOVERY")); raw {
	case "", "nack-rtx-flexfec":
		return RecoveryNACKRTXFlexFEC, nil
	case "nack-rtx":
		return RecoveryNACKRTX, nil
	case "off":
		// NO FEEDBACK AT ALL — the CARRIER configuration, and a spike rather than a product mode.
		//
		// `nackRTXEnabled` is false here, so nothing registers `nack`, `nack pli`, `transport-cc` or
		// an RTX codec, and FlexFEC negotiation is skipped. A receiver with no `nack pli` in the SDP
		// has no way to ask for a keyframe: not "we ignore its requests", but "it cannot make one".
		//
		// WHY THAT MATTERS FOR THE CARRIER. Forwarding frames to the browser's own decoder was
		// mandatory for exactly one reason — a starved decoder demands keyframes forever (measured:
		// fps to 31.7 with four keyframes per window, and again this week as an 18-22% keyframe share
		// that made the rate controller shed 6-10% of frames as judder). Remove the ability to ask and
		// forwarding becomes optional, which removes the synthetic-keyframe problem entirely: no
		// hand-built IDR per codec, no host-provided tiny frame, no swapping `frame.data`. The payload
		// is read out of the transform and the browser is simply never given anything.
		//
		// SESSION-WIDE, NOT PER TRACK, which is what keeps this a spike: it disables recovery for
		// every source, so real loss goes unrepaired until our own FEC and ARQ ride on top. That is
		// the point of the measurement — datagram semantics, with recovery we own.
		//
		// `RecoveryOff` is an engine mode rdev has never selected. The engine's own guards admit it
		// (peer_config, session, flexfec_negotiation all branch on it), but no rdev path has exercised
		// it, so treat surprises here as unexplored rather than broken.
		return RecoveryOff, nil
	default:
		return RecoveryNACKRTX, fmt.Errorf(
			"RDEV_LLV_RECOVERY=%q is not nack-rtx, nack-rtx-flexfec or off", raw)
	}
}

func rdevSessionConfiguration(iceServersJSON string, totalRTPBudgetBps uint32) (SessionConfiguration, error) {
	localIP, err := rdevConfiguredIP("RDEV_LLV_LOCAL_IP")
	if err != nil {
		return SessionConfiguration{}, err
	}
	remoteIP := localIP
	if raw := strings.TrimSpace(os.Getenv("RDEV_LLV_REMOTE_IP")); raw != "" {
		remoteIP, err = rdevConfiguredIP("RDEV_LLV_REMOTE_IP")
		if err != nil {
			return SessionConfiguration{}, err
		}
	}
	rtxMaxAge := 30 * time.Millisecond
	if raw := strings.TrimSpace(os.Getenv("RDEV_LLV_RTX_MAX_AGE_MS")); raw != "" {
		milliseconds, parseErr := strconv.Atoi(raw)
		if parseErr != nil || milliseconds < 1 || milliseconds > 1_000 {
			return SessionConfiguration{}, fmt.Errorf(
				"RDEV_LLV_RTX_MAX_AGE_MS=%q is not 1..1000 milliseconds", raw,
			)
		}
		rtxMaxAge = time.Duration(milliseconds) * time.Millisecond
	}
	// THE RETRANSMISSION WINDOW TRACKS RTT, FLOORED AT `rtxMaxAge`.
	//
	// It used to be fixed: `RTXAgeMode` was never set, so `normalizedRTXAgeMode` returned
	// RTXAgeFixed and every path got 30ms whatever its RTT. The engine's own reference says that is
	// broken on a WAN — at 50ms RTT it records 2,478 NACKs, 11,669 stale suppressions and ZERO
	// retransmissions, because a repair is age-refused before it can be sent.
	//
	// A REFUSED REPAIR IS NOT FREE: the responder escalates an unrepairable NACK to a KEYFRAME. So
	// the choice is not "retransmit or not", it is "one packet or a whole IDR", and the IDR is
	// larger than the frame that provoked it. Measured on a desktop capture over Wi-Fi, windows
	// reporting `lost=0 nack=9 pli=0` still produced 6 keyframes.
	//
	// THE FLOOR IS WHAT MAKES THIS A SUPERSET, NOT A RE-TUNING. `clamp(multiplier x RTT, Floor, Cap)`
	// with Floor at the old fixed value can only ever WIDEN the window — a LAN keeps exactly the
	// behaviour it has today, and only a path slow enough to have been broken sees a change.
	//
	// The multiplier and cap are STARTING POINTS, not measured values: 3x RTT for margin over the
	// receiver's own gap-detection and NACK batching, and a cap that bounds how long the cache holds
	// packets. Both are env-overridable so tuning needs no rebuild.
	rtxAgeMultiplierMilli := uint32(3_000)
	if raw := strings.TrimSpace(os.Getenv("RDEV_LLV_RTX_AGE_MULTIPLIER_MILLI")); raw != "" {
		value, parseErr := strconv.Atoi(raw)
		if parseErr != nil || value < 1_000 || value > 20_000 {
			return SessionConfiguration{}, fmt.Errorf(
				"RDEV_LLV_RTX_AGE_MULTIPLIER_MILLI=%q is not 1000..20000 (1.0x..20.0x)", raw,
			)
		}
		rtxAgeMultiplierMilli = uint32(value)
	}
	rtxAgeCap := 200 * time.Millisecond
	if raw := strings.TrimSpace(os.Getenv("RDEV_LLV_RTX_AGE_CAP_MS")); raw != "" {
		milliseconds, parseErr := strconv.Atoi(raw)
		if parseErr != nil || milliseconds < 1 || milliseconds > 1_000 {
			return SessionConfiguration{}, fmt.Errorf(
				"RDEV_LLV_RTX_AGE_CAP_MS=%q is not 1..1000 milliseconds", raw,
			)
		}
		rtxAgeCap = time.Duration(milliseconds) * time.Millisecond
	}
	// A cap below the floor is refused by NewRTXAgePolicy, which would fail every session at
	// creation. Say so HERE, naming both variables, rather than letting it surface as
	// "invalid RTX age policy" from three layers down.
	if rtxAgeCap < rtxMaxAge {
		return SessionConfiguration{}, fmt.Errorf(
			"RDEV_LLV_RTX_AGE_CAP_MS (%v) is below RDEV_LLV_RTX_MAX_AGE_MS (%v); the cap is the "+
				"widest the window may grow and the max age is its floor", rtxAgeCap, rtxMaxAge,
		)
	}
	recovery, err := rdevConfiguredRecovery()
	if err != nil {
		return SessionConfiguration{}, err
	}
	// The budget is only meaningful with a controller to spend it, and Validate refuses a non-zero
	// one outside FlexFEC mode — so it is dropped rather than passed through when FlexFEC is off.
	// It is NOT re-read from the environment here: see pion_peer_create's header comment.
	budget := uint32(0)
	flexFECPolicy := FlexFECPolicy(0)
	scalability := AV1ScalabilityMode(0)
	framesPerSecond := uint32(0)
	if recovery == RecoveryNACKRTXFlexFEC {
		if totalRTPBudgetBps == 0 {
			return SessionConfiguration{}, fmt.Errorf(
				"FlexFEC needs a total RTP budget; pion_peer_create was passed 0")
		}
		budget = totalRTPBudgetBps
		// ADAPTIVE, which is the whole point: a fixed tier spends a constant overhead whatever the
		// link is doing, and the controller LLV's WAN experiments selected is the adaptive one.
		flexFECPolicy = FlexFECPolicyAdaptive
		// L1T1 — one spatial, one temporal layer. rdev encodes a single stream per source with no
		// temporal layering, so anything else would describe a bitstream libaom is not producing.
		scalability = AV1ScalabilityL1T1
		// 60, fixed in code exactly as the encoder is. RDEV_VIDEO_FPS was deleted in 2026-07-30
		// because it defaulted to 30 while every real launch passed 60; per-source fps is a CLIENT
		// pref and always was the knob in use.
		framesPerSecond = rdevFlexFECFramesPerSecond
	}
	// FlexFECControllerPolicyJSON IS DELIBERATELY LEFT EMPTY, which selects the engine's EMBEDDED
	// policy — `controllerVersion: ll100-d1000-h250-b2x4`, the controller LLV's experiments chose
	// and the one rdev is asked to run. Supplying our own copy would fork it: the embedded file
	// travels with the engine and a re-import updates it, while a copy here would silently keep
	// running whatever it was pinned to. The validator additionally refuses a supplied policy
	// unless FlexFECPolicy is adaptive, so an accidental fork with a fixed tier fails loudly.
	impairment, err := rdevConfiguredImpairment()
	if err != nil {
		return SessionConfiguration{}, err
	}
	// lan, NOT strict: rdev's client is a browser and rdev cannot know its address in advance.
	// RemoteIP is deliberately NOT set — Validate refuses a populated one under lan, because nothing
	// would enforce it and a caller could set it and believe otherwise.
	_ = remoteIP
	return SessionConfiguration{
		ICEPolicy:  ICEPolicyLAN,
		LocalIP:    localIP,
		SignalPort: rdevDummySignalPort,
		// RECOVERY IS A KNOB, NOT A CONSTANT, and RDEV_LLV_RECOVERY is what turns FlexFEC on. The
		// negotiation it needs is implemented (validateFlexFECLocalOffer / validateFlexFECRemoteAnswer,
		// offer.go) and the controller's decisions now have somewhere to go (OnRecoveryPolicy, above).
		//
		// ACCEPTING THE CALLBACK AND IGNORING ITS BITRATE WAS CONSIDERED AND REJECTED: the controller
		// would believe media sits at one rate while it sits at another, so the total would exceed the
		// very budget the controller exists to respect. That is this project's most-repeated defect —
		// a value parsed into a variable that reaches nothing.
		Recovery: recovery, RTXMaxAge: rtxMaxAge,
		// Floor is RTXMaxAge above; these two make it adaptive rather than fixed.
		RTXAgeMode:            RTXAgeRTT,
		RTXAgeMultiplierMilli: rtxAgeMultiplierMilli,
		RTXAgeCap:             rtxAgeCap,
		// All four are zero unless FlexFEC is on; see the assignments above. The validator only
		// inspects them under FlexFEC, so `nack-rtx` stays byte-identical to what shipped.
		TotalRTPBudgetBitsPerSecond: budget,
		FlexFECPolicy:               flexFECPolicy,
		ScalabilityMode:             scalability,
		FramesPerSecond:             framesPerSecond,
		Impairment:                  impairment,
		ICEServersJSON:              iceServersJSON,
		// RDEV_TEST_SCTP_CHANNELS=1 (TEST-ONLY): the old three channels as SCTP, no lane — the lossy-link gate's
		// negative control (docs/bring-up.md).
		RdevSCTPChannels: os.Getenv("RDEV_TEST_SCTP_CHANNELS") == "1",
	}, nil
}

// rdevConfiguredImpairment reads ONE impairment profile out of the environment, or nil when none is
// configured. See the rdevImpairmentProfileVariable block for why the knob exists.
//
// EVERY FAILURE HERE REFUSES THE SESSION rather than falling back to "unimpaired". A profile that
// was asked for and silently not applied is the single most-repeated bug shape in this repo, and on
// this path it would be invisible: the run streams, decodes, and reports a full distribution — of
// the wrong condition, under the right name. The gate's `impairment-reached-the-engine` assertion is
// the second line of defence, not the first.
//
// THE SEED IS REQUIRED, NOT DEFAULTED. parseRecoveryMatrixProfileWithSeed takes a seed override, and
// the seeded catalogue profiles differ in nothing but that field — so a defaulted seed would run a
// DIFFERENT loss pattern from the one the comparison arm was given while both runs carried the same
// profile name. The answering path refuses the mirror-image mistake ("impairment seed has no
// profile", export.go), so both directions of the pair are now checked.
func rdevConfiguredImpairment() (*RecoveryImpairmentConfiguration, error) {
	path := strings.TrimSpace(os.Getenv(rdevImpairmentProfileVariable))
	rawSeed := strings.TrimSpace(os.Getenv(rdevImpairmentSeedVariable))
	if path == "" {
		if rawSeed != "" {
			return nil, fmt.Errorf(
				"%s=%q has no %s to apply it to",
				rdevImpairmentSeedVariable, rawSeed, rdevImpairmentProfileVariable,
			)
		}
		return nil, nil
	}
	if rawSeed == "" {
		return nil, fmt.Errorf(
			"%s=%q needs %s: the seeded profiles differ in nothing else, so an unseeded run would "+
				"face a different loss pattern under the same profile name",
			rdevImpairmentProfileVariable, path, rdevImpairmentSeedVariable,
		)
	}
	seed, err := strconv.ParseInt(rawSeed, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("%s=%q is not an integer seed", rdevImpairmentSeedVariable, rawSeed)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s=%q could not be read: %w", rdevImpairmentProfileVariable, path, err)
	}
	configuration, err := parseRecoveryImpairment(data, seed)
	if err != nil {
		return nil, fmt.Errorf("%s=%q is not one impairment profile object: %w",
			rdevImpairmentProfileVariable, path, err)
	}
	// THE SAME REFUSAL `capture-host` MAKES, AND FOR THE SAME MEASURED REASON.
	// validateRecoveryMatrixProfile accepts `warmupFrames: 0` (it only rejects a negative), but at
	// zero there is no window in which the controller can observe a passthrough packet and learn
	// which stream carries the original media — after which classifyDatagram files EVERY packet
	// under `other`, no burst ever matches, and every loss setting applies to nothing. The session
	// then reports a live controller with thousands of decisions and drops nothing.
	// All 101 catalogue profiles specify 30. See CaptureHostImpairmentArming's doc comment, which
	// records that this was caught only by diffing the host's own counters between two profiles.
	if configuration.Profile.WarmupFrames < 1 {
		return nil, fmt.Errorf(
			"%s=%q specifies warmupFrames=%d; it must be >= 1, or the impairment controller never "+
				"learns which stream is the original media and nothing is impaired",
			rdevImpairmentProfileVariable, path, configuration.Profile.WarmupFrames,
		)
	}
	return configuration, nil
}

// rdevConfiguredIP reads one IPv4 address from the environment, falling back to this machine's
// default-route source address.
func rdevConfiguredIP(variable string) (net.IP, error) {
	if raw := strings.TrimSpace(os.Getenv(variable)); raw != "" {
		parsed := net.ParseIP(raw)
		if parsed == nil || parsed.To4() == nil {
			return nil, fmt.Errorf("%s=%q is not an IPv4 address", variable, raw)
		}
		return parsed.To4(), nil
	}
	address, err := rdevDefaultRouteIPv4()
	if err != nil {
		return nil, fmt.Errorf("%s is unset and no default IPv4 route was found: %w", variable, err)
	}
	return address, nil
}

// rdevDefaultRouteIPv4 reports the source address the kernel would use for an off-link
// destination — the same interface `route -n get default` names, which is what the gates use.
//
// It SENDS NOTHING: a connected UDP socket only performs the route lookup, so this costs a
// syscall pair and reaches no network. The alternative — enumerating interfaces and picking the
// first private address — differs on any machine with a VPN, a dock or a Thunderbolt adapter,
// which is exactly where a wrong choice would make the remote-IP filter drop every candidate.
func rdevDefaultRouteIPv4() (net.IP, error) {
	probe, err := net.Dial("udp4", "8.8.8.8:53")
	if err != nil {
		return nil, err
	}
	defer probe.Close()
	address, ok := probe.LocalAddr().(*net.UDPAddr)
	if !ok || address.IP.To4() == nil {
		return nil, fmt.Errorf("route lookup produced %v, which is not an IPv4 address", probe.LocalAddr())
	}
	return address.IP.To4(), nil
}

// rdevReserveICEPort asks the kernel for a free UDP port on localIP and returns it. The socket is
// closed before returning, so newPeerAPI can bind it — see rdevICEPortAttempts for the window that
// leaves.
func rdevReserveICEPort(localIP net.IP) (uint16, error) {
	connection, err := net.ListenUDP("udp4", &net.UDPAddr{IP: localIP, Port: 0})
	if err != nil {
		return 0, err
	}
	defer connection.Close()
	address, ok := connection.LocalAddr().(*net.UDPAddr)
	if !ok || address.Port <= 0 || address.Port > 65_535 {
		return 0, fmt.Errorf("probe produced no usable UDP port (%v)", connection.LocalAddr())
	}
	return uint16(address.Port), nil
}

// newRdevPeer builds one offer session and the dispatcher that carries its callbacks out.
//
// EACH SESSION BINDS ITS OWN ICE PORT, which is why the port is probed per peer rather than fixed:
// newPeerAPI does a bare net.ListenUDP on (LocalIP, ICEPort) and hands it to an ICE mux, so two
// concurrent clients on one port fail the second bind. RDEV_LLV_ICE_PORT pins it for a
// single-client run (the certification) and then genuinely allows only one.
func newRdevPeer(ctx uintptr, iceServersJSON string, totalRTPBudgetBps uint32) (*rdevPeer, error) {
	configuration, err := rdevSessionConfiguration(iceServersJSON, totalRTPBudgetBps)
	if err != nil {
		return nil, err
	}
	// WHICH RECOVERY STACK IS LIVE IS OTHERWISE INVISIBLE, and it decides whether a receiver that
	// will not answer FlexFEC can connect at all — there is no mid-session downgrade, so the
	// difference between the two modes is "works" and "every session dies at SetAnswer". A silent
	// choice here is the same shape as the encode-resolution log this project added for exactly the
	// same reason: the one vantage point that knows what is really being negotiated.
	if rdevPlayoutDelayHeaderOff {
		fmt.Println("[bridge] playout delay: HEADER NOT SENT — each browser uses its own jitter buffer")
	}
	switch configuration.Recovery {
	case RecoveryNACKRTXFlexFEC:
		fmt.Printf("[bridge] recovery: nack-rtx + adaptive FlexFEC, budget=%d bps fps=%d\n",
			configuration.TotalRTPBudgetBitsPerSecond, configuration.FramesPerSecond)
	case RecoveryOff:
		// NAMED EXPLICITLY, because the two-branch form printed "nack-rtx" for this — the exact silent
		// misreport the comment above exists to prevent, and it cost a run: the mode was not in force
		// and the banner agreed with the mode that was.
		fmt.Println("[bridge] recovery: OFF — no nack, no pli, no rtx, no transport-cc, no FlexFEC " +
			"(carrier spike: the receiver cannot request anything)")
	default:
		fmt.Printf("[bridge] recovery: nack-rtx (rtx max age %v)\n", configuration.RTXMaxAge)
	}
	pinnedPort := strings.TrimSpace(os.Getenv("RDEV_LLV_ICE_PORT"))
	attempts := rdevICEPortAttempts
	if pinnedPort != "" {
		port, parseErr := strconv.Atoi(pinnedPort)
		if parseErr != nil || port <= 0 || port > 65_535 || uint16(port) == rdevDummySignalPort {
			return nil, fmt.Errorf("RDEV_LLV_ICE_PORT=%q is not a usable UDP port", pinnedPort)
		}
		configuration.ICEPort = uint16(port)
		attempts = 1
	}

	peer := &rdevPeer{
		ctx:            ctx,
		events:         make(chan func(), 64),
		done:           make(chan struct{}),
		dispatcherDone: make(chan struct{}),
		lastWriteLog:   map[int]time.Time{},
	}
	// The production sink. Assigned here rather than in the struct literal because it is a method
	// value on the peer being built.
	peer.onRecoveryPolicy = peer.emitRecoveryPolicy
	// Read off the CONFIGURATION rather than the environment a second time, so the frames this
	// peer waits for and the profile it was built with cannot disagree.
	peer.configureImpairment(configuration.Impairment)
	peer.configureReporting()
	callbacks := SessionCallbacks{
		OnLocalICECandidate: peer.emitICECandidate,
		OnChannelOpen: func(label string) {
			if channel, ok := rdevChannelIndex(label); ok {
				peer.emitChannelOpen(channel)
			}
		},
		OnChannelMessage: func(label string, data []byte) {
			if channel, ok := rdevChannelIndex(label); ok {
				peer.emitChannelMessage(channel, data)
			}
		},
		OnState:            peer.handleState,
		OnRecoveryKeyframe: peer.handleRecoveryKeyframe,
		OnRecoveryRequest:  peer.handleReferenceRecoveryRequest,
		// Registered UNCONDITIONALLY, even while Recovery is nack-rtx and the controller never runs.
		// validateSessionCallbacks demands it for FlexFEC of any policy, and a nil-when-off wiring
		// would make turning FlexFEC on a two-place change with one of them easy to miss.
		OnRecoveryPolicy: peer.deliverRecoveryPolicy,
		// THE ONLY PLACE A SESSION *FAILURE* IS OBSERVABLE, because rdev's ABI has no error
		// callback: it treats a dead connection as the client's problem to notice and recover
		// from (the web client's onControlClose, the signalling resume path). A failure here does
		// NOT stop the session working — `fail` records the error and closes failedCh, and
		// nothing in this file gates on either — which matters because handlePeerState calls it
		// on `disconnected`, and rdev recovers from a transient disconnect with an ICE restart on
		// this same peer.
		//
		// AND IT IS FIRED ONLY ONCE PER SESSION, WHICH IS WHY TWO OTHER THINGS IN THIS FILE EXIST.
		// `Session.fail` wraps its whole body in a `sync.Once`, and on this path the FIRST failure
		// is always the spurious readiness rejection below — so every later `fail` is swallowed.
		// The two that could have carried real information are covered without touching `fail`:
		// peer-connection failure states are logged from handleState (the state number is on a
		// separate path `fail` cannot swallow), and recovery-stack fatals are published
		// unconditionally by newOfferSession's wrapper around the recovery error reporter.
		OnError: peer.reportSessionError,
	}

	go peer.dispatch()
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if pinnedPort == "" {
			port, portErr := rdevReserveICEPort(configuration.LocalIP)
			if portErr != nil {
				lastErr = portErr
				continue
			}
			configuration.ICEPort = port
		}
		session, sessionErr := newOfferSession(configuration, callbacks)
		if sessionErr == nil {
			peer.session = session
			// REPORTED FROM THE BIND, not from add_video_track. See emitCodecResolved on Session.
			session.SetOnCodecResolved(peer.emitCodecResolved)
			// STARTED ONLY AFTER `peer.session` IS SET, which is what makes it safe at all: the
			// reporter's first act is a Stats() call, and a goroutine started before the assignment
			// would race a nil session on a construction that retried.
			if peer.reporterRunning() {
				go peer.runPeriodicReporter()
			}
			return peer, nil
		}
		lastErr = sessionErr
		// Only a bind collision is worth retrying — every other failure is a configuration or
		// construction error that a different port cannot fix, and retrying it five times would
		// print five copies of the same message.
		if !strings.Contains(sessionErr.Error(), "bind host ICE UDP mux") {
			break
		}
	}
	close(peer.done)
	<-peer.dispatcherDone
	return nil, lastErr
}

// handleState translates LLV's state JSON into the numeric PeerConnectionState the ABI carries.
func (peer *rdevPeer) handleState(encoded []byte) {
	var payload struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(encoded, &payload); err != nil {
		return
	}
	wire, ok := rdevPeerStateWire[payload.State]
	if !ok {
		// "ready" lands here, which is correct: it is LLV's own synthetic state, not a
		// PeerConnectionState, and rdev has no concept for it.
		return
	}
	peer.emitConnectionState(wire)
	// LOGGED HERE BECAUSE `fail` CANNOT BE RELIED ON TO REPORT IT. handlePeerState calls
	// session.fail for these three states, and `fail` is a sync.Once whose one shot is always
	// already spent on this path (see reportSessionError) — so the TEXT would be swallowed. The
	// state NUMBER arrives regardless, on this separate path, which is what makes recovering the
	// text here possible at all rather than a second guess at the same information.
	switch wire {
	case int(webrtc.PeerConnectionStateDisconnected),
		int(webrtc.PeerConnectionStateFailed),
		int(webrtc.PeerConnectionStateClosed):
		fmt.Printf("[bridge] peer connection %s\n", payload.State)
	}
	if wire != int(webrtc.PeerConnectionStateConnected) {
		return
	}
	// Push an IDR on connect so a fresh receiver has a keyframe in its first frames instead of
	// waiting out its own PLI debounce — there is no periodic IDR to save it (infinite GOP). Same
	// place rdev's own bridge did it, and idempotent with the request ChannelHub makes on the
	// same event.
	peer.emitKeyframeRequest(rdevAllSlotsKeyframe)
}

// rdevSpuriousReadinessRejection is the substring that identifies the ONE failure every
// same-machine session on this path produces, so that the line it logs says what it is.
//
// `selectedCandidateLocked` requires BOTH ICE candidates to be host candidates, which is true of
// LLV's own viewer on a known address and false of a browser: Chrome's host candidate is
// mDNS-obfuscated and dropped, so the pair that wins is PEER-REFLEXIVE. maybeReady then routes that
// through session.fail, and the session reads failed before it has done anything wrong.
//
// DELETED 2026-08-18 — rdevSpuriousReadinessRejection and the annotation that used it.
// It existed because maybeReady FAILED the session on a peer-reflexive candidate pair, which
// happened on every same-machine session and spent Session.fail's one-shot error slot before
// anything real could use it. The annotation printed a paragraph explaining that the failure was
// expected and harmless.
//
// It is gone because the failure is gone: an unmet readiness precondition is now a BLOCKER, not a
// failure (session.go, maybeReady), so nothing on this path reaches fail for that reason and the
// message it matched on can only be produced by an ICEPolicyStrict session — which rdev never runs.
// A branch annotating a message that cannot arrive is worse than no branch: it reads as live
// handling for a condition someone will then go looking for.

// reportSessionError is the ABI's OnError. It exists as a named method rather than a closure so the
// annotation below has somewhere to live.
func (peer *rdevPeer) reportSessionError(err error) {
	fmt.Printf("[bridge] session error: %v\n", err)
}

// handleRecoveryKeyframe maps LLV's keyframe STREAM id back to rdev's SLOT.
//
// videoKeyframeStreamID is `slot + 1`, so the inverse is `streamID - 1`. STREAM 0 IS NOT SLOT -1
// BY ARITHMETIC — it is the answering path's eager track and the interceptor-level request
// (`resources.SetRecoveryCallbacks(func() { session.emitRecoveryKeyframe(0) }, …)`), neither of
// which names an rdev source. Reporting it as -1 is exactly rdev's own "all of this client's
// sources" request, which is the honest reading of a keyframe request that names no track.
func (peer *rdevPeer) handleRecoveryKeyframe(streamID uint64) {
	if streamID == eagerVideoKeyframeStreamID {
		peer.emitKeyframeRequest(rdevAllSlotsKeyframe)
		return
	}
	peer.emitKeyframeRequest(int(streamID) - 1)
}

// rdevChannelIndex maps a channel LABEL to the integer slot the ABI uses.
//
// THERE IS NO TRANSLATION TABLE, AND THAT IS DELIBERATE: rdevChannelLabels' INDEX is the ABI's
// channel number. rdev's own bridge had `chLabels = {0: "terminal", 1: "input", 2: "control"}` and
// createRdevDataChannels creates them in exactly that order, so index i IS channel i and the two
// cannot disagree. `PionChannel` in Swift is the same enum with the same values.
func rdevChannelIndex(label string) (int, bool) {
	for index, candidate := range rdevChannelLabels {
		if candidate == label {
			return index, true
		}
	}
	return 0, false
}

// rdevChannelLabel is the inverse, for pion_peer_send_data.
func rdevChannelLabel(channel int) (string, bool) {
	if channel < 0 || channel >= len(rdevChannelLabels) {
		return "", false
	}
	return rdevChannelLabels[channel], true
}

func (peer *rdevPeer) close() {
	peer.closeOnce.Do(func() {
		// STOP THE REPORTER AND WAIT FOR IT, BEFORE Session.Close. Waiting is the load-bearing half:
		// Stats() reads apiResources, so a snapshot still in flight when Close tears the controller
		// down would be reading a session being dismantled. Same shape as `<-dispatcherDone` below,
		// and for the same reason.
		if peer.reporterRunning() {
			close(peer.reporterStop)
			<-peer.reporterDone
		}
		// One FINAL report, on the same reasoning: it is the only one that sees the tail of a run, so
		// a graceful shutdown gets a complete count where a signalled one gets the last periodic line.
		if peer.session != nil {
			peer.reportImpairment()
			peer.reportRecovery()
			if err := peer.session.Close(); err != nil {
				fmt.Printf("[bridge] session close: %v\n", err)
			}
		}
		// AFTER Session.Close, WHICH IS THE ORDER THAT MAKES PionPeer.close SAFE. Session.Close
		// drains its own callback gate, so no further callback can be ENQUEUED; closing `done` and
		// waiting for the dispatcher then guarantees every callback already enqueued has been
		// DELIVERED. Only once both hold may Swift release the retained ctx, which it does on the
		// line after pion_peer_close returns.
		close(peer.done)
		<-peer.dispatcherDone
	})
}

//export pion_init
func pion_init() {}

//export pion_set_callbacks
func pion_set_callbacks(a C.pion_on_local_description, b C.pion_on_ice_candidate,
	c C.pion_on_datachannel_open, d C.pion_on_datachannel_message, e C.pion_on_connection_state,
	f C.pion_on_keyframe_request, g C.pion_on_codec_resolved, h C.pion_on_recovery_policy) {
	C.rdev_set_cbs(a, b, c, d, e, f, g, h)
}

// pion_peer_create builds one client's session. Returns 0 on failure, which is what
// PionPeer.init checks.
//
// `ice_servers_json` IS PARSED AND REGISTERED as of 2026-08-18 (it was accepted and ignored from
// the engine cutover until then). Malformed JSON fails the session rather than yielding zero relay
// candidates a caller would have to diagnose one layer away from the cause. It reaches
// webrtc.Configuration{ICEServers:} via SessionConfiguration.ICEServersJSON.
//
// THE DATA CHANNELS ARE CREATED HERE, NOT IN pion_peer_start_offer, and the net effect is the
// same: a data m-section only appears in an offer if a channel exists when that offer is built,
// and every caller calls start_offer immediately after create.
//
//export pion_peer_create
func pion_peer_create(ctx C.uintptr_t, iceJSON *C.char, totalRTPBudgetBps C.uint32_t) C.longlong {
	peer, err := newRdevPeer(uintptr(ctx), C.GoString(iceJSON), uint32(totalRTPBudgetBps))
	if err != nil {
		fmt.Printf("[bridge] peer create failed: %v\n", err)
		return 0
	}
	return C.longlong(rdevRegister(peer))
}

//export pion_peer_start_offer
func pion_peer_start_offer(handle C.longlong) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	sdp, err := peer.session.CreateOffer()
	if err != nil {
		fmt.Printf("[bridge] start offer failed: %v\n", err)
		return
	}
	peer.emitLocalDescription(sdp)
}

//export pion_peer_restart_ice
func pion_peer_restart_ice(handle C.longlong) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	sdp, err := peer.session.CreateICERestartOffer()
	if err != nil {
		fmt.Printf("[bridge] ICE restart offer failed: %v\n", err)
		return
	}
	peer.emitLocalDescription(sdp)
}

// pion_peer_set_answer applies the answer and then emits any offer that was coalesced while
// signalling was in flight.
//
// THE ERROR IS LOGGED, NOT DISCARDED, AND THIS IS THE ONE THAT MATTERS MOST — the same note
// rdev's own bridge carried, and it applies harder here. pion runs a sender's one-shot Send()
// INSIDE SetRemoteDescription, which is where FrameTrack.Bind runs, and Bind REFUSES an answer
// that did not negotiate AV1/90000, the playout-delay extension or the dependency-descriptor
// extension. Every downstream state then reads healthy — the track exists, WriteVideo is called
// at 60 fps — while zero RTP egresses. Without this line the only observable is "no picture".
//
//export pion_peer_set_answer
func pion_peer_set_answer(handle C.longlong, sdp *C.char) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	answer := C.GoString(sdp)
	if err := peer.session.SetAnswer(answer); err != nil {
		fmt.Printf("[bridge] setAnswer: %v\n", err)
		// THE ANSWER'S OWN CODEC LINES, printed ONLY when the answer was refused. Every failure here
		// is "the far side did not offer what rdev needs", and without them the log names the
		// conclusion ("none of rdev's codecs were negotiated") while withholding the evidence — which
		// is what a browser advertising a codec it then omits from the answer looks like from here.
		// Cheap because it is on the failure path only.
		fmt.Printf("[bridge] setAnswer: the answer's video codecs were:\n%s\n",
			answerCodecLines(answer))
	}
	peer.driveOffer()
}

// answerCodecLines extracts the rtpmap/fmtp/extmap lines of an SDP for the failure log above.
//
// A SUBSTRING SCAN, not a parse: this runs when the session is already refusing an answer, so it must
// not be able to fail in its own right. Indented so a multi-line dump reads as one log entry.
func answerCodecLines(sdp string) string {
	var out strings.Builder
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.HasPrefix(line, "m=") || strings.HasPrefix(line, "a=rtpmap:") ||
			strings.HasPrefix(line, "a=fmtp:") || strings.HasPrefix(line, "a=extmap:") {
			out.WriteString("    ")
			out.WriteString(line)
			out.WriteString("\n")
		}
	}
	if out.Len() == 0 {
		return "    (no m=/rtpmap/fmtp/extmap lines found)"
	}
	return strings.TrimRight(out.String(), "\n")
}

//export pion_peer_add_ice
func pion_peer_add_ice(handle C.longlong, candidateJSON *C.char) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	if err := peer.session.AddRemoteICE(C.GoString(candidateJSON)); err != nil {
		fmt.Printf("[bridge] addICE: %v\n", err)
	}
}

// pion_peer_add_video_track adds a sendonly AV1 track carrying source_id as its MSID,
// renegotiates, and reports the codec. Returns the slot, or -1.
//
// THE CODEC IS REPORTED FROM THE BIND, NOT FROM HERE, and that changed when rdev gained a second
// codec. It used to be reported immediately with AV1, which was CORRECT while the engine registered
// one codec: an answer cannot change a single-codec offer's codec, only refuse it, so there was
// nothing to wait for. With three registered the answer decides.
//
// The ordering is load-bearing in both directions. rdev builds a source's encoder ON
// pion_on_codec_resolved (ChannelHub.codecResolved → SimManager.ensureEncoder) and attaches the
// delivery sink there — so a track whose codec is never reported has no encoder and no sink and
// streams nothing at all, while one reported too early builds an encoder for a codec the remote may
// not have accepted. ChannelHub.codecResolved's own doc already said it "Runs on the peer's ordered
// dispatcher (post-answer)"; this is the Go side catching up to a contract Swift never stopped
// documenting.
//
//export pion_peer_add_source_tracks
func pion_peer_add_source_tracks(handle C.longlong, sourceID *C.char, codecPref C.int,
	audioSlotOut *C.int) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return -1
	}
	videoSlot, audioSlot, err := peer.session.AddSourceTracks(
		C.GoString(sourceID), codecPreferenceFromWire(int(codecPref)),
	)
	if err != nil {
		fmt.Printf("[bridge] addSourceTracks: %v\n", err)
		return -1
	}
	// WRITTEN BEFORE THE OFFER IS SCHEDULED. scheduleOffer can emit synchronously — driveOffer runs
	// inline whenever signalling is already stable — so a caller that read its audio slot after the
	// offer had gone out would be reading a race.
	if audioSlotOut != nil {
		*audioSlotOut = C.int(audioSlot)
	}
	// ONE OFFER FOR BOTH TRACKS, and that is the whole reason this entry point replaced
	// pion_peer_add_video_track. See Session.AddSourceTracks.
	peer.scheduleOffer()
	return C.int(videoSlot)
}

// pion_peer_active_recovery reports the stack this connection actually runs.
//
// UNRESOLVED AND UNKNOWN-HANDLE ARE BOTH 0, deliberately: the caller's only correct response to
// either is to omit the field, and giving them separate values would invite a client to render
// "unknown handle" as a state.
//
//export pion_peer_active_recovery
func pion_peer_active_recovery(handle C.longlong) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return 0
	}
	switch peer.session.ActiveRecovery() {
	case "nack-rtx-flexfec":
		// A DEGRADED SESSION REPORTS THE STACK THAT IS ACTUALLY RUNNING. FlexFEC can be negotiated on
		// the wire, log `negotiated=true`, and still disable itself the first time it is asked to
		// protect a frame — at which point answering 2 is a lie the client renders as a healthy
		// footer, and the `no FEC` cell exists precisely to show that downgrade.
		if peer.session.FlexFECIsDegraded() {
			return 1
		}
		return 2
	case "nack-rtx":
		return 1
	default:
		return 0
	}
}

// codecPreferenceFromWire maps the ABI's codec_pref to rdev's preference order for one track.
//
// THE NUMBERING IS 0 auto / 1 av1 / 2 h265 / 3 h264 AND IS DELIBERATELY NOT NegotiatedCodec's
// (h264=0, h265=1, av1=2). The two cross this ABI in OPPOSITE directions — a preference in, a
// resolved codec out — so sharing a numbering would make 0 mean two different things.
//
// AN UNRECOGNISED VALUE CLAMPS TO auto, never to an empty list: an empty preference is a track that
// can never bind, so a version skew would take video down rather than degrade.
func codecPreferenceFromWire(pref int) []codecID {
	switch pref {
	case 1:
		return []codecID{rdevNegotiatedCodecAV1}
	case 2:
		return []codecID{rdevNegotiatedCodecH265}
	case 3:
		return []codecID{rdevNegotiatedCodecH264}
	default:
		return nil
	}
}

// pion_peer_remove_video_track drops the track at slot and renegotiates — but ONLY IF SOMETHING
// WAS REMOVED, and that condition is load-bearing rather than tidy.
//
// rdev REMOVES SLOTS IT MAY NOT OWN, BY DESIGN. ChannelHub.rebindPeer calls removeVideo against the
// FRESH peer of a resuming client, documented there as "a harmless no-op — it has no track in that
// slot yet". LLV's RemoveVideoTrack returns an error for an unknown slot where rdev's own bridge
// returned silently, which is an improvement — but renegotiating anyway is not. MEASURED, in
// scripts/smoke-host.sh's reload step: the no-op removal scheduled an offer, driveOffer emitted it
// because signalling was still stable, and the client's own first offer then failed with
// `invalid proposed signaling state transition: have-local-offer->SetLocal(offer)`. Worse than the
// error, the emitted offer carried the restart flag PionPeer sets on every removeVideoTrack — so a
// client that had just reloaded, and needed a fresh peer connection, was told to keep its old one.
//
// The error is still LOGGED, because the same message also reports the orphaned-sender case (a
// removal that failed with the sender still attached, so the next offer keeps advertising a source
// nobody is sending), and that one is worth seeing.
//
//export pion_peer_remove_source_tracks
func pion_peer_remove_source_tracks(handle C.longlong, videoSlot C.int, audioSlot C.int) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	if err := peer.session.RemoveSourceTracks(int(videoSlot), int(audioSlot)); err != nil {
		fmt.Printf("[bridge] removeSourceTracks: %v\n", err)
		return
	}
	// ONE OFFER, symmetric with pion_peer_add_source_tracks and for the same reason: two removes
	// would produce two renegotiations in reverse.
	peer.scheduleOffer()
}

// pion_peer_write_track_audio writes one encoded Opus packet to an audio slot.
//
// pts_ns REACHES THE WIRE HERE, unlike pion_peer_write_track_video's, which is paced on a fixed
// step: audio's RTP timestamp is derived from real capture time and anchored to the first packet.
//
//export pion_peer_write_track_audio
func pion_peer_write_track_audio(handle C.longlong, slot C.int, payload *C.uint8_t,
	length C.int, ptsNanos C.longlong) {
	peer := rdevLookup(int64(handle))
	if peer == nil || length <= 0 {
		return
	}
	// THROTTLED THROUGH THE SAME logWriteFailure THE VIDEO PATH USES. A write can legitimately land
	// between AddSourceTracks and the answer that negotiates it; a line that KEEPS repeating is the
	// real signal. Audio slots share the video slot NUMBER SPACE in that log only — the throttle is
	// keyed by slot and a collision costs at most a suppressed line, never a wrong write.
	if err := peer.session.WriteAudio(int(slot), C.GoBytes(unsafe.Pointer(payload), length),
		int64(ptsNanos)); err != nil {
		peer.logWriteFailure(int(slot), err)
	}
}

// pion_peer_set_recovery_override forces the FEC overhead ratio, or returns the session to adaptive
// control with -1.
//
// IT VALIDATES SYNCHRONOUSLY AND APPLIES ASYNCHRONOUSLY, AND THAT SPLIT IS NOT A STYLE CHOICE — a
// synchronous version DEADLOCKS, measured. rdev delivers data-channel messages ON THE PEER'S ORDERED
// DISPATCHER, so this entry point is already running on that goroutine; Session.SetRecoveryOverride
// emits a RecoveryPolicyUpdate, and rdev's OnRecoveryPolicy (deliverRecoveryPolicy) enqueues onto the
// SAME dispatcher and waits for a reply. The dispatcher cannot drain the reply while it is blocked
// inside this call, so the client's control message never returns and the session wedges.
//
// CLAUDE.md names this hazard in as many words — "blocking on it FROM the dispatcher goroutine would
// self-deadlock; the controller never calls from there" — and this is the first ABI entry point that
// IS called from there. Any future entry point that emits a callback has the same constraint.
//
// The status therefore means ACCEPTED, not APPLIED: the range and the peer are checked here, and a
// rejection from the coordinator is reported the way the controller's own rejections are.
//
// pion_peer_set_playout_delay_min forces a playout-delay floor on every video track of this peer.
//
// SYNCHRONOUS, unlike pion_peer_set_recovery_override beside it. That one validates here and applies
// on a goroutine because applying it emits the ORDERED recovery-policy callback, and blocking on the
// dispatcher from the dispatcher self-deadlocks. This emits no callback, so it can answer honestly:
// 0 means APPLIED, not merely accepted.
//
//export pion_peer_set_playout_delay_min
func pion_peer_set_playout_delay_min(handle C.longlong, minMs C.int) C.int {
	return pion_peer_set_playout_delay(handle, minMs, -1)
}

// pion_peer_set_playout_delay sets BOTH bounds of the playout-delay extension on every video track
// of this peer: `max_ms < 0` keeps the configured ceiling (raised to the floor), `max_ms >= 0` is an
// explicit ceiling and is refused below the floor. min = max is a WINDOW — a fixed offset from
// capture — which is the setting a Chromium receiver on a clean path measures best on
// (docs/latency-campaign/2026-09-04-report.md); min = max = 0 is the gaming MODE. Synchronous, like
// the floor-only entry: 0 means APPLIED.
//
//export pion_peer_set_playout_delay
func pion_peer_set_playout_delay(handle C.longlong, minMs C.int, maxMs C.int) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		// LOUD, for the same reason as the recovery override: this answers a user action, and a
		// silent -1 presents as a control that does nothing with no line anywhere saying why.
		fmt.Printf("[bridge] setPlayoutDelay(%d, %d): no peer for handle %d\n",
			int(minMs), int(maxMs), int64(handle))
		return -1
	}
	if int(minMs) < 0 {
		fmt.Printf("[bridge] setPlayoutDelay(%d, %d): negative floor\n", int(minMs), int(maxMs))
		return -1
	}
	if err := peer.session.SetPlayoutDelayBounds(int(minMs), int(maxMs)); err != nil {
		fmt.Printf("[bridge] setPlayoutDelay(%d, %d): %v\n", int(minMs), int(maxMs), err)
		return -1
	}
	// REPORT THE RESOLVED PAIR, NOT THE REQUEST. The ceiling moves with the floor, and the receiver
	// obeys what is on the wire — so a log that echoed only the request could not distinguish "the
	// ceiling came back down and the receiver ignored it" from "this build never lowers the ceiling".
	if minUnits, maxUnits, ok := peer.session.PlayoutDelayBoundsUnits(); ok {
		fmt.Printf("[bridge] playout-delay set to min %dms max %s for this session — wire now min %dms max %dms\n",
			int(minMs), playoutDelayMaxLabel(int(maxMs)), int(minUnits)*10, int(maxUnits)*10)
	} else {
		fmt.Printf("[bridge] playout-delay set to min %dms max %s for this session (no video track yet)\n",
			int(minMs), playoutDelayMaxLabel(int(maxMs)))
	}
	return 0
}

// playoutDelayMaxLabel names a requested ceiling for a log line: the number, or "ceiling" for -1.
func playoutDelayMaxLabel(maxMs int) string {
	if maxMs < 0 {
		return "ceiling"
	}
	return fmt.Sprintf("%dms", maxMs)
}

//export pion_peer_set_recovery_override
func pion_peer_set_recovery_override(handle C.longlong, overrideBp C.int) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		// LOUD, unlike most nil-handle returns on this ABI. This one answers a user action, so a
		// silent -1 presents as a control that does nothing with no line anywhere saying why.
		fmt.Printf("[bridge] setRecoveryOverride(%d): no peer for handle %d\n",
			int(overrideBp), int64(handle))
		return -1
	}
	if int(overrideBp) < -1 || int(overrideBp) > int(maximumFlexFECOverrideBasisPoints) {
		fmt.Printf("[bridge] setRecoveryOverride(%d): not -1 (auto) or 0..%d\n",
			int(overrideBp), maximumFlexFECOverrideBasisPoints)
		return -1
	}
	go func() {
		if err := peer.session.SetRecoveryOverride(int(overrideBp)); err != nil {
			fmt.Printf("[bridge] setRecoveryOverride(%d): %v\n", int(overrideBp), err)
			return
		}
		fmt.Printf("[bridge] recovery override -> %s\n", recoveryOverrideLabel(int(overrideBp)))
	}()
	return 0
}

// recoveryOverrideLabel renders a basis-point override the way the operator set it, so the log line
// and the titlebar read the same number.
func recoveryOverrideLabel(bp int) string {
	if bp < 0 {
		return "auto (adaptive controller)"
	}
	return fmt.Sprintf("forced %d.%02d%% FEC overhead", bp/100, bp%100)
}

//export pion_peer_write_track_video
func pion_peer_write_track_video(handle C.longlong, slot C.int, payload *C.uint8_t, length C.int,
	ptsNS C.longlong, isKeyframe C.int) {
	peer := rdevLookup(int64(handle))
	if peer == nil || length <= 0 || payload == nil {
		return
	}
	// Copied before it crosses into Go's world for the same reason every other buffer here is:
	// the caller owns the bytes only for the duration of the call, and WriteVideo hands them to a
	// payloader that keeps them until the last packet is written.
	data := C.GoBytes(unsafe.Pointer(payload), length)
	// ROUTED HERE, AND THIS IS THE ONLY PLACE THE TWO PATHS DIVERGE. The video track stays negotiated
	// either way, so switching costs no renegotiation, no new SSRC and no keyframe storm — and the
	// encoder's sink stays ATTACHED, because a detached sink would starve the DataChannel too. That
	// mistake was in an early draft of the design: it would have delivered nothing on either path.
	//
	// ptsNS REACHES THE WIRE ON THIS PATH, unlike the RTP one below. dcVideoStream anchors it to the
	// stream's first frame to build the 90kHz media clock the client's pacer runs on; a constant
	// would leave that pacer with no clock at all.
	if delivery := peer.session.dcDelivery.Load(); delivery != nil {
		payloadType := peer.session.VideoPayloadType(int(slot))
		if delivery.write(int(slot), data, int64(ptsNS), isKeyframe != 0, payloadType) {
			peer.noteVideoWrite()
			return
		}
	}
	// ptsNanoseconds IS ACCEPTED AND CANNOT REACH THE WIRE. FrameTrack paces RTP timestamps on a
	// FIXED 60 fps step, and changing that is the answering path's wire behaviour — the thing that
	// must not drift while it is the certification's comparison arm. rdev's fps is fixed at 60 in
	// code (HostConfig) so the step and the cadence agree today; a per-source 15 or 30 fps pref
	// would ship timestamps that disagree with the real cadence, which a receiver reads as jitter.
	// Recorded on WriteVideo as well; increment 4 is where it bites.
	if err := peer.session.WriteVideo(int(slot), data, int64(ptsNS), isKeyframe != 0); err != nil {
		peer.logWriteFailure(int(slot), err)
		return
	}
	// A NO-OP UNLESS AN IMPAIRMENT PROFILE WAS CONFIGURED — one mutex acquisition and a zero test,
	// on a path that already takes one for its failure log. See noteVideoWrite.
	peer.noteVideoWrite()
}

//export pion_peer_send_data
func pion_peer_send_data(handle C.longlong, channel C.int, data *C.uint8_t, length C.int) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	label, ok := rdevChannelLabel(int(channel))
	if !ok {
		fmt.Printf("[bridge] send on unknown channel %d\n", int(channel))
		return
	}
	var payload []byte
	if length > 0 && data != nil {
		payload = C.GoBytes(unsafe.Pointer(data), length)
	}
	if err := peer.session.SendChannelData(label, payload); err != nil {
		// Throttled on a per-CHANNEL key in the same map the video slots use, which cannot collide
		// with them: `-1 - channel` maps channels 0..2 to the NEGATIVE keys -1..-3, and slots are
		// the non-negative ones. Terminal output is a high-rate stream, so an unthrottled log on a
		// closed channel would bury everything else.
		peer.logWriteFailure(-1-int(channel), err)
	}
}

// pion_peer_channel_buffered: the bytes `channel` holds that the peer has not yet acknowledged
// (Session.ChannelBufferedAmount: pion's count for `bulk`, a lane stream's unacknowledged payload for 0…2), or -1
// when it is not open (or the handle names no peer). The host paces on it: TermPacer on the terminal, FileFetcher's
// image on `bulk`.
//
//export pion_peer_channel_buffered
func pion_peer_channel_buffered(handle C.longlong, channel C.int) C.longlong {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return -1
	}
	label, ok := rdevChannelLabel(int(channel))
	if !ok {
		return -1
	}
	held, open := peer.session.ChannelBufferedAmount(label)
	if !open {
		return -1
	}
	return C.longlong(held)
}

//export pion_peer_set_video_delivery
func pion_peer_set_video_delivery(handle C.longlong, slot C.int, delivery C.int, sourceID *C.char) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return -1
	}
	registry := peer.session.dcDelivery.Load()
	if registry == nil {
		// No channels on this session: RTP, and the caller reports RTP. Reporting the REQUEST here
		// would make a session that cannot do this look like one that is.
		return 0
	}
	name := ""
	if sourceID != nil {
		name = C.GoString(sourceID)
	}
	if !registry.setDelivery(int(slot), delivery == 1, name) {
		return 0
	}
	index := registry.sourceIndexFor(int(slot))
	if index < 0 {
		return 0
	}
	return C.int(index<<1 | 1)
}

//export pion_peer_bump_video_delivery
func pion_peer_bump_video_delivery(handle C.longlong, slot C.int) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	if registry := peer.session.dcDelivery.Load(); registry != nil {
		registry.bump(int(slot))
	}
}

//export pion_peer_set_video_hidden
func pion_peer_set_video_hidden(handle C.longlong, hidden C.int) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	if registry := peer.session.dcDelivery.Load(); registry != nil {
		registry.setHidden(hidden != 0)
	}
}

//export pion_peer_close
func pion_peer_close(handle C.longlong) {
	peer := rdevLookup(int64(handle))
	if peer == nil {
		return
	}
	peer.close()
	rdevUnregister(int64(handle))
}

//export pion_set_reference_callbacks
func pion_set_reference_callbacks(cb C.pion_on_reference_sent) { C.rdev_set_reference_cb(cb) }

//export pion_peer_reference_track_id
func pion_peer_reference_track_id(handle C.longlong, slot C.int, output *C.char, capacity C.int) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil || output == nil || capacity <= 0 {
		return -1
	}
	peer.session.mutex.Lock()
	entry := peer.session.videoTracks[int(slot)]
	id := ""
	if entry != nil {
		id = entry.track.ID()
	}
	peer.session.mutex.Unlock()
	if id == "" || len(id)+1 > int(capacity) {
		return -1
	}
	buffer := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
	copy(buffer, id)
	buffer[len(id)] = 0
	return C.int(len(id))
}

//export pion_peer_next_reference_frame
func pion_peer_next_reference_frame(handle C.longlong, slot C.int, result *C.uint64_t) C.int {
	peer := rdevLookup(int64(handle))
	if !peer.referenceRTPAllowed(int(slot)) || result == nil {
		return -1
	}
	n, err := peer.session.NextReferenceFrame(int(slot))
	if err != nil {
		return -1
	}
	*result = C.uint64_t(n)
	return 0
}

//export pion_peer_write_track_video_reference
func pion_peer_write_track_video_reference(handle C.longlong, slot C.int, payload *C.uint8_t, length C.int, ptsNS C.longlong, isKeyframe C.int, metadataJSON *C.char) C.int {
	peer := rdevLookup(int64(handle))
	if !peer.referenceRTPAllowed(int(slot)) || payload == nil || length <= 0 || metadataJSON == nil {
		return -1
	}
	n := C.strnlen(metadataJSON, 4097)
	if n == 0 || n > 4096 {
		return -1
	}
	metadata, err := parseReferenceMetadata(C.GoBytes(unsafe.Pointer(metadataJSON), C.int(n)), isKeyframe != 0)
	if err != nil {
		return -1
	}
	err = peer.writeReferenceVideo(int(slot), C.GoBytes(unsafe.Pointer(payload), length), int64(ptsNS), isKeyframe != 0, metadata, func(data []byte) {
		value := C.CString(string(data))
		defer C.free(unsafe.Pointer(value))
		C.rdev_cb_reference_sent(C.uintptr_t(peer.ctx), slot, value)
	})
	if err != nil {
		peer.logWriteFailure(int(slot), err)
		return -1
	}
	peer.noteVideoWrite()
	return 0
}

func (peer *rdevPeer) handleReferenceRecoveryRequest(stream uint64, reason string, independent bool) {
	slot := int(stream) - 1
	if stream == eagerVideoKeyframeStreamID {
		slot = rdevAllSlotsKeyframe
		independent = true
	}
	peer.enqueue(func() {
		text := C.CString(reason)
		defer C.free(unsafe.Pointer(text))
		force := C.int(0)
		if independent {
			force = 1
		}
		C.rdev_cb_reference_request(C.uintptr_t(peer.ctx), C.int(slot), text, force)
	})
}

//export pion_set_reference_request_callback
func pion_set_reference_request_callback(cb C.pion_on_reference_request) {
	C.rdev_set_reference_request_cb(cb)
}

//export pion_peer_reference_recovery_outcome
func pion_peer_reference_recovery_outcome(handle C.longlong, slot C.int, epoch, id, kind *C.char) C.int {
	peer := rdevLookup(int64(handle))
	if peer == nil || epoch == nil || id == nil || kind == nil {
		return -1
	}
	if C.strnlen(epoch, 129) > 128 || C.strnlen(id, 129) > 128 || C.strnlen(kind, 16) > 15 {
		return -1
	}
	if !peer.session.ReferenceRecoveryOutcome(int(slot), C.GoString(epoch), C.GoString(id), C.GoString(kind)) {
		return -1
	}
	return 0
}
