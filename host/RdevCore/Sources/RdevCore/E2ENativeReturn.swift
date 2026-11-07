import Foundation

/// **What the native app checks before it commits a direct grant for its own keys** (§10.4) — the grant
/// its own passkey ceremony just produced (`E2EHostIdentity.signIn`/`authorise`, the platform's passkey
/// API since 2026-10-06; it came back from a browser through a courier before, `git log -p`).
///
/// §10.4: a grant from a LOCAL enrollment is bound to "fresh local randomness and locally generated
/// keys", and must name "that exact pending operation and key descriptor" before it is accepted. So
/// every check is against what this device froze before the ceremony — the operation id and its own
/// descriptor — never against anything that arrived beside the bundle. §18 lists "the native ceremony
/// return path" among the things that must be validated before claiming conformance.
public enum E2ENativeReturn {

    public enum Failure: String, Error, Equatable, Sendable {
        /// Not a §10.4 bundle at all.
        case notABundle = "not-a-bundle"
        /// The bundle did not verify. Carries no detail on purpose: §14 gives one action for an
        /// invalid signature or chain — hard stop — and a caller has nothing to decide between.
        case chain = "chain"
        /// §10.4: the grant is not bound to THIS app's pending operation.
        case operationMismatch = "operation-mismatch"
        /// §10.4: the grant does not name THIS app's key descriptor.
        case descriptorMismatch = "descriptor-mismatch"
        /// The grant is not one a direct enrollment produces.
        case notDirect = "not-direct"
        /// No enrollment was pending. A return that arrives unsolicited is not a slow answer to
        /// something; nothing asked for it.
        case nothingPending = "nothing-pending"
    }

    /// Accept, or refuse, a grant a ceremony produced for this device.
    ///
    /// **EVERY CHECK IS AGAINST LOCAL STATE**, never against anything that came with the bundle: the
    /// pending operation and the device descriptor are what this device froze before the ceremony.
    public static func accept(bundle: [UInt8],
                              pendingOperationID: [UInt8]?,
                              deviceDescriptor: [UInt8],
                              trustedRootID: [UInt8],
                              policy: E2EVerify.Policy,
                              revokedDeviceIDs: Set<[UInt8]> = [])
        -> Result<E2EVerify.VerifiedChain, Failure> {

        // §10.4 binds the return to a PENDING operation. Without one there is nothing to bind to,
        // and an unsolicited return is not a slow answer — nothing asked for it.
        guard let pendingOperationID else { return .failure(.nothingPending) }

        guard case .success = E2ECertificate.parseBundle(bundle) else {
            return .failure(.notABundle)
        }

        let verified: E2EVerify.VerifiedChain
        switch E2EVerify.verifyBundle(bundle, trustedRootID: trustedRootID, policy: policy,
                                      revokedDeviceIDs: revokedDeviceIDs) {
        case .success(let chain): verified = chain
        case .failure: return .failure(.chain)
        }

        // §12.1: a direct grant is what this ceremony produces — "A subsequent device can use the
        // same passkey to obtain its own direct grant." A leaf arriving here would mean a delegation
        // instead of the passkey, which is a different ceremony with different authority (§10.3: a
        // leaf can never carry `enroll`).
        guard verified.leaf.issuerKind == .root else { return .failure(.notDirect) }

        // §10.4's two bindings, in the order a reader checks them: the operation this app started,
        // and the keys this app holds.
        guard verified.leaf.operationID == pendingOperationID else {
            return .failure(.operationMismatch)
        }
        // THE DESCRIPTOR ITSELF, not its device id and not its DH key. Two devices can share a DH
        // key with different signing keys (see `E2ESession`), so anything less than the whole
        // descriptor admits a grant for an identity built around this app's public key.
        guard verified.leafDevice.bytes == deviceDescriptor else {
            return .failure(.descriptorMismatch)
        }
        return .success(verified)
    }
}
