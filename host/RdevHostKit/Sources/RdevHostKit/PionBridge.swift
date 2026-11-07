import Foundation
import CPionBridge
import RdevCore

public enum PionChannel: Int32 { case terminal = 0, input = 1, control = 2, bulk = 3 }

public protocol PionPeerDelegate: AnyObject {
    func pionPeer(_ p: PionPeer, didOpen ch: PionChannel)
    func pionPeer(_ p: PionPeer, didReceive data: Data, on ch: PionChannel)
    func pionPeer(_ p: PionPeer, stateDidChange state: Int32)
}

/// Registers the process-wide C callbacks once and routes each event (by `ctx`, which is the
/// PionPeer pointer) back to the right PionPeer. Buffers are copied at the boundary.
public enum PionBridge {
    // `static let` is initialized exactly once, thread-safely (Swift run-once semantics).
    private static let registered: Void = {
        pion_init()
        pion_set_callbacks(
            { ctx, sdp in route(ctx) { $0.handleLocalDescription(String(cString: sdp!)) } },
            { ctx, j   in route(ctx) { $0.handleIce(String(cString: j!)) } },
            { ctx, ch  in route(ctx) { $0.handleOpen(ch) } },
            { ctx, ch, ptr, n in
                let data = Data(bytes: ptr!, count: Int(n))
                route(ctx) { $0.handleMessage(data, ch) }
            },
            { ctx, st  in route(ctx) { $0.handleState(st) } },
            { ctx, slot in route(ctx) { $0.handleKeyframeRequest(slot) } },
            { ctx, slot, codec in
                guard let c = NegotiatedCodec(wireValue: codec) else { return }
                route(ctx) { $0.handleCodecResolved(slot, c) }
            },
            // The adaptive FlexFEC controller's decision. UNLIKE EVERY OTHER CALLBACK HERE IT
            // RETURNS A STATUS, and a non-zero return tells the controller the update was NOT
            // applied — which is the truth whenever no peer is routed or no sink is installed.
            // Reporting success for an update nobody received would let the controller believe
            // media sits at one rate while it sits at another, so the total would exceed the very
            // budget the controller exists to respect.
            { ctx, sequence, tier, mediaBitrateBps in
                var status: Int32 = -1
                route(ctx) {
                    status = $0.handleRecoveryPolicy(
                        sequence: sequence, tier: tier, mediaBitrateBps: mediaBitrateBps)
                }
                return status
            }
        )
        pion_set_reference_request_callback { ctx, slot, reason, independent in
            guard let reason else { return }
            let copy = String(cString: reason)
            route(ctx) { $0.handleReferenceRecoveryRequest(slot, reason: copy, independent: independent != 0) }
        }
        pion_set_reference_callbacks { ctx, slot, json in
            guard let json else { return }
            let copy = String(cString: json)
            route(ctx) { $0.handleReferenceSent(slot, copy) }
        }
    }()

    public static func start() { _ = registered }

    private static func route(_ ctx: UInt, _ body: (PionPeer) -> Void) {
        guard let raw = UnsafeRawPointer(bitPattern: ctx) else { return }
        body(Unmanaged<PionPeer>.fromOpaque(raw).takeUnretainedValue())
    }
}
