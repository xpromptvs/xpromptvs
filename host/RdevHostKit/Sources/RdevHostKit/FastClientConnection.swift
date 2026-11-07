import Foundation
import RdevCore

/// Stable application connection; WebRTC peer and encrypted WebSocket are replaceable carriers.
/// No hub/application callback runs under stateLock. send/bufferedAmount may be called under hub locks.
final class FastClientConnection: ClientConnection, PionPeerDelegate, @unchecked Sendable {
    let clientId: String
    let generation: Data
    var presentation: ClientPresentation { .streamedSources }
    private let stateLock = NSLock()
    private let events = DispatchQueue(label: "rdev.fast-data.events")
    // Ordering belongs to each stream. A control snapshot must not queue keystrokes behind it.
    private let applications = (0...2).map { DispatchQueue(label: "rdev.fast-data.application.\($0)") }
    // Application handlers can build snapshots synchronously. Their work must not
    // hold outgoing data, acknowledgements or liveness probes behind that snapshot.
    private let outbound = DispatchQueue(label: "rdev.fast-data.outbound")
    private let engine: FastDelivery
    private let policy = FastCarrierPolicy()
    private var peer: PionPeer?
    private var connected = false, ready = false, closed = false
    private var applicationBytes = [0, 0, 0], applicationCount = [0, 0, 0]
    private var queuedRecords = 0, queuedWireBytes = 0
    private var retry = false
    private var rtcOpen = [false, false, false]
    private var ws: ((Data) -> Bool)?
    private var timer: DispatchSourceTimer?
    private let onOpen: (PionChannel) -> Void
    private let onMessage: (PionChannel, Data) -> Void
    private let onFailure: (String) -> Void
    var onMediaState: ((PionPeer, Int32) -> Void)?
    var mediaPeer: PionPeer? { stateLock.withLock { peer } }
    var mediaReady: Bool { stateLock.withLock { connected && !closed } }
    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    init(clientId: String, generation: Data, onOpen: @escaping (PionChannel) -> Void,
         onMessage: @escaping (PionChannel, Data) -> Void, onFailure: @escaping (String) -> Void) {
        self.clientId = clientId; self.generation = generation; engine = FastDelivery(generation: generation)
        self.onOpen = onOpen; self.onMessage = onMessage; self.onFailure = onFailure
        let t = DispatchSource.makeTimerSource(queue: outbound)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }; timer = t; t.resume()
    }
    deinit { timer?.cancel() }
    func attachMediaPeer(_ p: PionPeer) {
        stateLock.withLock {
            peer = p; connected = false; rtcOpen = [false, false, false]
            for s in UInt8(0)...2 { apply(policy.channelState(.webRTC, stream: s, open: false, nowMs: now)) }
        }
        p.delegate = self
    }
    func setWebSocketSender(_ sender: ((Data) -> Bool)?) {
        stateLock.withLock {
            ws = sender
            for s in UInt8(0)...2 { apply(policy.channelState(.webSocket, stream: s, open: sender != nil && ready, nowMs: now)) }
        }
    }
    func markReady() {
        stateLock.withLock {
            guard !ready, !closed else { return }; ready = true
            for s in UInt8(0)...2 { apply(policy.channelState(.webSocket, stream: s, open: ws != nil, nowMs: now)) }
            // Enqueued before any input accepted after ready; no application listener runs under this lock.
            events.async { [weak self] in
                guard let self, self.isLive else { return }
                for ch in [PionChannel.terminal, .input, .control] { self.onOpen(ch) }
            }
        }
    }
    private var isLive: Bool { stateLock.withLock { !closed && ready } }
    func send(_ ch: PionChannel, _ data: Data) {
        if ch == .bulk { mediaPeer?.send(ch, data); return }
        stateLock.withLock {
            guard ready, !closed else { return }
            switch engine.send(UInt8(ch.rawValue), message: data, nowMs: now) {
            case .accepted(let effects): apply(effects); updateOutstanding()
            case .full: fail("fast-data queue full")
            case .invalid: fail("invalid fast-data send")
            }
        }
    }
    func bufferedAmount(_ ch: PionChannel) -> Int? {
        if ch == .bulk { return mediaPeer?.bufferedAmount(ch) }
        return stateLock.withLock { ready && !closed ? engine.bufferedAmount(UInt8(ch.rawValue)) : nil }
    }
    func receive(_ r: FastData.Record, from carrier: FastCarrierKind) {
        stateLock.withLock {
            guard ready, !closed, r.generation == generation, r.stream <= 2 else { return }
            if carrier == .webSocket && ws == nil { return }
            if r.kind == .probe { transmit(.init(kind: .probeReply, generation: generation, stream: r.stream, value: r.value), over: carrier); return }
            if r.kind == .probeReply { apply(policy.probeReply(carrier, stream: r.stream, nonce: r.value, nowMs: now)); return }
            let before = engine.bufferedAmount(r.stream)
            // Terminal ACK delay is sampled as path delay by TermPath. Keep it within
            // the pacing headroom, otherwise sparse output teaches a one-second queue budget.
            let rtcAckDelay = r.stream == 0 ? Double(TermPath.headroomNanos) / 1_000_000 : 1000
            apply(engine.receive(r, nowMs: now, ackDelayMs: carrier == .webRTC ? rtcAckDelay : 20))
            if engine.bufferedAmount(r.stream) < before { policy.dataProgress(carrier, stream: r.stream, nowMs: now) }
            updateOutstanding()
        }
    }
    func resume(offsets: [UInt64]) {
        guard offsets.count == 3 else { return }
        stateLock.withLock {
            guard !closed else { return }
            for s in UInt8(0)...2 { apply(engine.receive(.init(kind: .ack, generation: generation, stream: s, value: offsets[Int(s)]), nowMs: now)) }
            for s in [UInt8(2), 1, 0] { for r in engine.replay(s) { transmit(r, over: policy.selected) } }
            updateOutstanding()
        }
    }
    func receiveOffsets() -> [UInt64] { stateLock.withLock { engine.receiveOffsets() } }
    private func updateOutstanding() { for stream in UInt8(0)...2 { policy.setOutstanding(engine.bufferedAmount(stream) > 0, stream: stream, nowMs: now) } }
    private func tick() {
        stateLock.withLock { guard ready, !closed else { return }; apply(engine.poll(nowMs: now)); apply(policy.tick(nowMs: now)); if retry && (ws != nil || connected) { retry = false; for s in [UInt8(2), 1, 0] { for r in engine.replay(s) { transmit(r, over: policy.selected) } } } }
    }
    private func apply(_ effects: [FastDelivery.Effect]) {
        for e in effects {
            switch e {
            case .transmit(let r): transmit(r, over: policy.selected)
            case .failed(let reason): fail(reason)
            case .deliver(let s, let bytes):
                let index = Int(s)
                guard applicationBytes[index] + bytes.count <= 2 * 1024 * 1024, applicationCount[index] < 2048 else {
                    fail("fast-data application queue full"); return
                }
                applicationBytes[index] += bytes.count; applicationCount[index] += 1
                // The coordination queue puts every message behind the initial open batch,
                // then hands work to independent, bounded per-stream queues.
                events.async { [weak self] in
                    self?.applications[index].async { [weak self] in
                        guard let self else { return }
                        defer { self.stateLock.withLock { self.applicationBytes[index] -= bytes.count; self.applicationCount[index] -= 1 } }
                        guard self.isLive, let ch = PionChannel(rawValue: Int32(s)) else { return }
                        // Bulk remains a separate service even if put on control by an authenticated peer.
                        guard let payload = unwrapMessage(bytes) else { return }
                        // Updates have their own authority-checked handler in ChannelHub, outside
                        // InboundMessage. Preserve that control path on both fast carriers.
                        if ch == .control, payload.count <= 4096,
                           let object = try? JSONSerialization.jsonObject(with: payload),
                           HostUpdateRequest.parse(object) != nil {
                            self.onMessage(ch, bytes); return
                        }
                        guard let msg = parseInbound(payload) else { return }
                        switch msg { case .pasteBegin, .pasteData, .pasteEnd, .pasteCancel, .fileGet: return; default: break }
                        self.onMessage(ch, bytes)
                    }
                }
            }
        }
    }
    private func apply(_ effects: [FastCarrierPolicy.Effect]) {
        for e in effects {
            switch e {
            case .sendProbe(let c, let s, let n): transmit(.init(kind: .probe, generation: generation, stream: s, value: n), over: c)
            case .select(let c):
                for s in [UInt8(2), 1, 0] { for r in engine.replay(s) { transmit(r, over: c) } }
            }
        }
    }
    private func transmit(_ r: FastData.Record, over carrier: FastCarrierKind) {
        guard !closed else { return }
        // Delivery bounds do not bound duplicate replays or callback closures. Bound this IO queue too.
        let size = r.bytes.count + 29
        guard queuedRecords < 4096, queuedWireBytes + size <= 8 * 1024 * 1024 else { fail("fast-data carrier queue full"); return }
        queuedRecords += 1; queuedWireBytes += size
        outbound.async { [weak self] in
            guard let self else { return }
            defer { self.stateLock.withLock { self.queuedRecords -= 1; self.queuedWireBytes -= size } }
            let target = self.stateLock.withLock { (self.closed, self.ws, self.peer) }
            guard !target.0, let bytes = try? FastData.encode(r) else { return }
            if carrier == .webSocket { if target.1?(bytes) != true && r.kind == .data { self.stateLock.withLock { self.retry = true } } }
            else if let ch = PionChannel(rawValue: Int32(r.stream)) { target.2?.send(ch, bytes) }
        }
    }
    private func fail(_ reason: String) {
        guard !closed else { return }; closed = true
        events.async { [weak self] in self?.onFailure(reason) }
    }
    func close() { stateLock.withLock { closed = true; ws = nil; peer = nil }; timer?.cancel() }
    func pionPeer(_ p: PionPeer, didOpen ch: PionChannel) {
        stateLock.withLock {
            guard peer === p, !closed else { return }
            if ch == .bulk { events.async { [weak self] in guard let self, self.stateLock.withLock({ !self.closed && self.ready && self.peer === p }) else { return }; self.onOpen(.bulk) }; return }
            rtcOpen[Int(ch.rawValue)] = true
            apply(policy.channelState(.webRTC, stream: UInt8(ch.rawValue), open: true, nowMs: now))
        }
    }
    func pionPeer(_ p: PionPeer, didReceive data: Data, on ch: PionChannel) {
        guard stateLock.withLock({ peer === p && !closed }) else { return }
        if ch == .bulk { events.async { [weak self] in guard let self, self.stateLock.withLock({ !self.closed && self.ready && self.peer === p }) else { return }; self.onMessage(ch, data) }; return }
        guard let r = FastData.decode(data), r.stream == UInt8(ch.rawValue) else { return }
        receive(r, from: .webRTC)
    }
    func pionPeer(_ p: PionPeer, stateDidChange state: Int32) {
        stateLock.withLock {
            guard peer === p, !closed else { return }; connected = state == 3
            if state == 3 { for s in UInt8(0)...2 { apply(policy.channelState(.webRTC, stream: s, open: rtcOpen[Int(s)], nowMs: now)) } }
            if state >= 4 { for s in UInt8(0)...2 { apply(policy.channelState(.webRTC, stream: s, open: false, nowMs: now)) } }
            events.async { [weak self, weak p] in
                guard let self, let p, self.stateLock.withLock({ self.peer === p && !self.closed }) else { return }
                self.onMediaState?(p, state)
            }
        }
    }
}
