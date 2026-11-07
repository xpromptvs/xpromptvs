import Foundation
import CPionBridge
import RdevCore

/// One pion PeerConnection per client. Replaces the libwebrtc PeerSession. The Swift object pointer
/// is the `ctx` handed to the bridge; PionBridge routes every callback back here. `close()` tears
/// down the bridge peer (which drains its dispatcher) before this object is released.
public final class PionPeer: @unchecked Sendable {
    public let clientId: String
    private var handle: Int64 = 0
    private var ctxRetained: Unmanaged<PionPeer>?
    private let closeLock = NSLock()
    private let restartLock = NSLock()
    /// Guarded by `restartLock`. See OfferRestartFlag (RdevCore) for what the tag means and why a
    /// fresh peer's first offer must never carry it.
    private var restartFlag = OfferRestartFlag()
    /// Guarded by `restartLock`. The host is always the OFFERER, so every local description is an
    /// offer, and this is true from one until its answer is accepted — `PeerHub.resume` reads it,
    /// because an ICE restart cannot be offered on top of an unanswered offer.
    private var offerOutstanding = false

    public var onLocalDescription: ((String) -> Void)?
    public var onIceCandidate: (([String: Any]) -> Void)?
    public var onKeyframeRequest: ((Int32) -> Void)?
    public var onCodecResolved: ((_ slot: Int32, _ codec: NegotiatedCodec) -> Void)?
    /// Sent notices arrive on the ordered Go dispatcher. A write failure arrives on
    /// the encoding queue: handlers must enqueue their work, never reenter the encoder.
    public var onReferenceRecoveryRequest: ((Int32, String, RecoveryIntent) -> Void)?
    public var onReferenceSent: ((Int32, [String: Any]) -> Void)?
    public var onReferenceWriteFailed: ((Int32, AV1ReferenceFrameMetadata) -> Void)?
    public weak var delegate: PionPeerDelegate?

    /// Applies one adaptive-FlexFEC controller decision, returning 0 when it was applied and
    /// non-zero when it was not. Task 2 replaces this default with the real sink; until then rdev
    /// runs `nack-rtx`, the controller never evaluates, and nothing calls it.
    ///
    /// IT REPORTS FAILURE BY DEFAULT, deliberately. An unset handler means nobody applied the
    /// update, and saying otherwise is the one lie this status exists to prevent.
    ///
    /// IT IS AN `init` PARAMETER AND NOT A SETTABLE PROPERTY, WHICH COST A MEASUREMENT TO LEARN. The
    /// adaptive controller emits its first update — sequence 1, tier off — from INSIDE
    /// `pion_peer_create`, as a handshake it requires to succeed: `create adaptive FlexFEC
    /// controller: acknowledge adaptive FlexFEC initial off tier`. A handler assigned after the
    /// constructor returns is therefore installed one step too late, and the session dies at
    /// creation with `recovery policy update 1 rejected: -1`. Assigning it before the
    /// `pion_peer_create` call below is what makes the handshake reachable.
    private let onRecoveryPolicy: ((_ sequence: UInt64, _ tier: Int32,
                                    _ mediaBitrateBps: UInt32) -> Bool)?

    func handleRecoveryPolicy(sequence: UInt64, tier: Int32, mediaBitrateBps: UInt32) -> Int32 {
        // LOGGED IN FULL, because the controller only speaks when its tier CHANGES — measured at two
        // updates for a whole short session, one per peer — so this is sparse rather than a per-frame
        // firehose, and it is the only place the adaptive decision is observable at all. It is also
        // what distinguishes "FlexFEC negotiated" from "FlexFEC is doing something", which are very
        // different states that look identical from every other vantage point.
        print("[bridge] recovery policy seq=\(sequence) tier=\(tier) media=\(mediaBitrateBps) bps")
        guard let onRecoveryPolicy else { return -1 }
        return onRecoveryPolicy(sequence, tier, mediaBitrateBps) ? 0 : -1
    }

    public init(clientId: String, turn: TurnCreds?, totalRTPBudgetBps: UInt32 = 0,
                onRecoveryPolicy: ((_ sequence: UInt64, _ tier: Int32,
                                    _ mediaBitrateBps: UInt32) -> Bool)? = nil) {
        self.clientId = clientId
        // BEFORE pion_peer_create, or the controller's initial handshake update finds no handler.
        self.onRecoveryPolicy = onRecoveryPolicy
        let retained = Unmanaged.passRetained(self)
        self.ctxRetained = retained
        let ctx = UInt(bitPattern: retained.toOpaque())
        let iceJSON = PionPeer.iceServersJSON(turn)
        // The budget is 0 while recovery is nack-rtx: the engine refuses a non-zero one outside
        // FlexFEC mode, and there is no controller to spend it.
        self.handle = iceJSON.withCString { pion_peer_create(ctx, $0, totalRTPBudgetBps) }
        if handle == 0 { print("[PionPeer] create failed for \(clientId)") }
    }

    static func iceServersJSON(_ turn: TurnCreds?) -> String {
        guard let turn else { return "[]" }
        let obj: [[String: Any]] = [[
            "urls": turn.urls, "username": turn.username, "credential": turn.credential,
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Emit this peer's FIRST offer.
    ///
    /// CLEARS THE RESTART TAG, and that is the point rather than housekeeping. `PeerHub.rebuildPeer`
    /// builds a fresh peer, `ChannelHub.rebindPeer` issues a no-op `removeVideo` against it — which
    /// tags the next offer — and then this runs. Tagged, the opening offer told a client that had
    /// just lost its connection to KEEP the one it had, whose m-line history belonged to the peer
    /// that was closed a moment earlier. Safari then refused the offer outright with
    /// `The order of m-lines in subsequent offer doesn't match order from previous offer/answer`,
    /// and the session was over. Both callers of this build the peer immediately before calling it.
    public func startOffer() {
        restartLock.lock(); restartFlag.markFirstOffer(); restartLock.unlock()
        pion_peer_start_offer(handle)
    }
    /// Restart ICE on this peer (renegotiation after a network change). Marks the next
    /// `onLocalDescription` as a restart so `PeerHub` can tag the outgoing offer `restart:true`.
    public func restartIce() {
        restartLock.lock(); restartFlag.markRestart(); restartLock.unlock()
        pion_peer_restart_ice(handle)
    }
    /// Returns whether the next offer is a restart, clearing the flag.
    public func consumeRestartFlag() -> Bool {
        restartLock.lock(); defer { restartLock.unlock() }
        return restartFlag.consume()
    }
    public func acceptAnswer(_ sdp: String) {
        restartLock.lock(); offerOutstanding = false; restartLock.unlock()
        sdp.withCString { pion_peer_set_answer(handle, $0) }
    }
    /// Whether the last offer this peer produced is still waiting for its answer.
    public var awaitingAnswer: Bool {
        restartLock.lock(); defer { restartLock.unlock() }
        return offerOutstanding
    }
    public func addIce(_ cand: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: cand),
              let s = String(data: data, encoding: .utf8) else { return }
        s.withCString { pion_peer_add_ice(handle, $0) }
    }
    public func send(_ ch: PionChannel, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            pion_peer_send_data(handle, ch.rawValue, base.assumingMemoryBound(to: UInt8.self), Int32(data.count))
        }
    }
    public func bufferedAmount(_ ch: PionChannel) -> Int? {
        let held = pion_peer_channel_buffered(handle, ch.rawValue)
        return held < 0 ? nil : Int(held)
    }
    /// Add this source's VIDEO AND AUDIO tracks (MSIDs `sourceID` and `audio:<sourceID>`) under ONE
    /// renegotiation, OFFERING BOTH codecs. The negotiated
    /// codec is delivered later via `onCodecResolved(slot, codec)`. Returns the slot (>= 0), -1 on failure.
    /// Tagged restart so the client keeps its PC. The caller MUST serialize renegotiations per peer (one
    /// negotiation in flight at a time).
    ///
    /// `codecPref`: 0 auto · 1 av1 · 2 h265 · 3 h264 — NOT `NegotiatedCodec`'s numbering, which is a
    /// RESOLVED codec and has no `auto`. The default keeps every current caller on "whatever the host
    /// would have chosen anyway"; a real per-source preference is threaded here in a later increment.
    public func addSourceTracks(sourceID: String, codecPref: Int32 = 0) -> (video: Int32, audio: Int32) {
        restartLock.lock(); restartFlag.markRestart(); restartLock.unlock()
        var audioSlot: Int32 = -1
        let videoSlot = sourceID.withCString { id in
            withUnsafeMutablePointer(to: &audioSlot) { out in
                pion_peer_add_source_tracks(handle, id, codecPref, out)
            }
        }
        return (videoSlot, audioSlot)
    }

    /// Remove BOTH of a source's tracks under one renegotiation. Tagged restart.
    public func removeSourceTracks(videoSlot: Int32, audioSlot: Int32) {
        restartLock.lock(); restartFlag.markRestart(); restartLock.unlock()
        pion_peer_remove_source_tracks(handle, videoSlot, audioSlot)
    }

    /// Write one encoded Opus packet to the audio track at `slot`. No-op for an unknown slot.
    ///
    /// `ptsNs` REACHES THE WIRE here, unlike `writeTrackVideo`'s: audio's RTP timestamp is derived
    /// from real capture time and anchored, because a fixed step against a content-driven source
    /// accumulates the media-clock error the video path measured at -5.87%.
    public func writeTrackAudio(slot: Int32, _ payload: [UInt8], ptsNs: Int64) {
        payload.withUnsafeBufferPointer { buf in
            pion_peer_write_track_audio(handle, slot, buf.baseAddress, Int32(buf.count), ptsNs)
        }
    }

    /// Force this peer's FEC overhead in basis points of media (0...5000), or `nil` for adaptive
    /// control. Returns whether the engine ACCEPTED it — the value is validated synchronously and
    /// applied asynchronously, because this is called from the peer's own dispatcher and applying it
    /// has to go back through that dispatcher. See pion_peer_set_recovery_override.
    ///
    /// NO RENEGOTIATION at any value, unlike every other video-shape change on this type: FlexFEC
    /// stays negotiated even at a forced 0%, so nothing about the track, its SSRCs or its codec
    /// moves and there is no restart to tag.
    /// Which recovery stack this connection actually runs, or nil before the answer settles it.
    ///
    /// NOT THE SAME AS THE CONFIGURED MODE. A session configured for FlexFEC whose receiver declined
    /// it runs NACK/RTX — which is a real difference in resilience, since FEC repairs in band with
    /// no round trip and is the only mechanism that helps where RTX is age-refused before a NACK can
    /// arrive. nil means UNRESOLVED, never "degraded"; the client must be able to tell them apart.
    public var activeRecovery: String? {
        switch pion_peer_active_recovery(handle) {
        case 2: return "nack-rtx-flexfec"
        case 1: return "nack-rtx"
        default: return nil
        }
    }

    @discardableResult
    public func setRecoveryOverride(_ bp: Int?) -> Bool {
        pion_peer_set_recovery_override(handle, Int32(bp ?? -1)) == 0
    }

    /// Force a playout-delay FLOOR on every video track of this peer, in milliseconds. nil is Auto,
    /// which today means zero — "play this out as soon as you can".
    ///
    /// Unlike `setRecoveryOverride`, whose status means ACCEPTED, this one is applied by the time it
    /// returns: it emits no ABI callback, so there is no ordered dispatcher to defer to.
    @discardableResult
    public func setPlayoutDelayMin(_ ms: Int?) -> Bool {
        setPlayoutDelay(minMs: ms, maxMs: nil)
    }

    /// Both bounds. `maxMs` nil keeps the configured ceiling (raised to the floor); a number is an
    /// explicit ceiling, and `minMs == maxMs` is a fixed WINDOW from capture — see
    /// `pion_peer_set_playout_delay` in `pion_bridge.h` for what that measured.
    @discardableResult
    public func setPlayoutDelay(minMs: Int?, maxMs: Int?) -> Bool {
        pion_peer_set_playout_delay(handle, Int32(minMs ?? 0), Int32(maxMs ?? -1)) == 0
    }

    /// Route one video slot, and report what the bridge ACTUALLY applied.
    ///
    /// THE RETURN VALUE IS THE POINT. A bridge with no channels, or a slot it will not route, answers
    /// `.rtp` — and that is what reaches `view-set` as `activeDelivery`. Echoing the request back
    /// would make a refusal invisible, which is the failure the amber `codecUnmet` exists to prevent.
    ///
    /// Applied by the time it returns: it emits no ABI callback, so there is no ordered dispatcher to
    /// defer to — the same property `setPlayoutDelayMin` has and `setRecoveryOverride` does not.
    public func setVideoDelivery(slot: Int, sourceID: String,
                                 delivery: VideoDelivery) -> (delivery: VideoDelivery, dcIndex: Int?) {
        sourceID.withCString { id in
            decodeVideoDeliveryResult(
                pion_peer_set_video_delivery(handle, Int32(slot), delivery == .dc ? 1 : 0, id))
        }
    }

    /// Mark a discontinuity on one video slot: a codec change or encoder rebuild. The client then
    /// discards its decoder state for that source rather than solving equations against a stream that
    /// no longer exists.
    public func bumpVideoDelivery(slot: Int) {
        pion_peer_bump_video_delivery(handle, Int32(slot))
    }

    /// Stop routing this slot over the DataChannel and retire its source index.
    public func releaseVideoDelivery(slot: Int) {
        _ = pion_peer_set_video_delivery(handle, Int32(slot), 0, nil)
    }

    /// Pause or resume DataChannel emission for every routed source. SESSION-SCOPED, like the RTP
    /// path's visibility pause — it is a property of the CLIENT, not of any one window.
    public func setVideoHidden(_ hidden: Bool) {
        pion_peer_set_video_hidden(handle, hidden ? 1 : 0)
    }

    /// Write one encoded access unit (H.264/H.265 Annex-B, or an AV1 temporal unit) to the extra track at
    /// `slot` — the track's codec selects pion's payloader, so this is codec-agnostic bytes. No-op for an
    /// unknown/removed slot.
    public func writeTrackVideo(slot: Int32, _ payload: [UInt8], ptsNs: Int64, keyframe: Bool) {
        payload.withUnsafeBufferPointer { buf in
            pion_peer_write_track_video(handle, slot, buf.baseAddress, Int32(buf.count), ptsNs, keyframe ? 1 : 0)
        }
    }

    func handleReferenceRecoveryRequest(_ slot: Int32, reason: String, independent: Bool) {
        if let onReferenceRecoveryRequest {
            onReferenceRecoveryRequest(slot, reason, independent ? .independentKeyframe : .repairEstablishedStream)
        } else { handleKeyframeRequest(slot) }
    }
    public func referenceRecoveryOutcome(slot: Int32, outcome: ReferenceAttemptOutcome) {
        outcome.epoch.withCString { epoch in outcome.recoveryID.withCString { id in
            outcome.kind.rawValue.withCString { kind in
                _ = pion_peer_reference_recovery_outcome(handle, slot, epoch, id, kind)
            }
        } }
    }
    public func referenceTrackID(slot: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 512)
        guard pion_peer_reference_track_id(handle, slot, &bytes, Int32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }
    public func nextReferenceFrame(slot: Int32) -> UInt64? {
        var result: UInt64 = 0
        return pion_peer_next_reference_frame(handle, slot, &result) == 0 ? result : nil
    }
    public func writeTrackVideo(slot: Int32, _ payload: [UInt8], ptsNs: Int64, keyframe: Bool,
                               reference: AV1ReferenceFrameMetadata) {
        guard let data = try? JSONSerialization.data(withJSONObject: reference.wireObject) else {
            onReferenceWriteFailed?(slot, reference); return
        }
        let json = String(decoding: data, as: UTF8.self)
        let status = json.withCString { metadata in
            payload.withUnsafeBufferPointer { bytes in
                pion_peer_write_track_video_reference(handle, slot, bytes.baseAddress, Int32(bytes.count),
                                                      ptsNs, keyframe ? 1 : 0, metadata)
            }
        }
        if status != 0 { onReferenceWriteFailed?(slot, reference) }
    }
    func handleReferenceSent(_ slot: Int32, _ json: String) {
        guard let data = json.data(using: .utf8), data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        onReferenceSent?(slot, object)
    }

    public func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        if handle != 0 { pion_peer_close(handle); handle = 0 }   // drains the dispatcher before returning
        ctxRetained?.release(); ctxRetained = nil                // safe: no callback can fire after close
    }

    // Called by PionBridge (already routed to this instance).
    func handleLocalDescription(_ sdp: String) {
        restartLock.lock(); offerOutstanding = true; restartLock.unlock()
        onLocalDescription?(sdp)
    }
    func handleIce(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        onIceCandidate?(obj)
    }
    func handleOpen(_ ch: Int32) { if let c = PionChannel(rawValue: ch) { delegate?.pionPeer(self, didOpen: c) } }
    func handleMessage(_ data: Data, _ ch: Int32) {
        if let c = PionChannel(rawValue: ch) { delegate?.pionPeer(self, didReceive: data, on: c) }
    }
    func handleState(_ st: Int32) { delegate?.pionPeer(self, stateDidChange: st) }
    func handleKeyframeRequest(_ slot: Int32) { onKeyframeRequest?(slot) }
    func handleCodecResolved(_ slot: Int32, _ codec: NegotiatedCodec) { onCodecResolved?(slot, codec) }
}
