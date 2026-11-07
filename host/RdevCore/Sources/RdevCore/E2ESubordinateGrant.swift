import Foundation

/// **§10.3's `root → A → B` chain, issued by A.**
///
/// A directly enrolled device carries capabilities `7`, and the `enroll` bit in it is not decoration:
/// §10.3's authority table says such a device "may connect, host, and enroll access-only devices".
/// This is the code that does that, and there is exactly one caller today — the native app issuing
/// to its OWN client window.
///
/// **Why that window needs a grant of its own at all.** It is served from `app://client/`, an origin
/// no passkey ceremony can run in (§2, profile P-A: "an Electron custom-scheme renderer must use a
/// supported native API or an HTTPS ceremony with an authenticated return"). The supported native
/// API is this one. The alternative — letting the renderer borrow the host's device keys — needs a
/// signing oracle across the bridge and makes one machine indistinguishable from itself whenever both
/// ends of a session are local, which is a defect this repo has already met once.
///
/// **Capability `1`, never more.** The renderer is a client: it never shares a screen, so it has no
/// use for `host`, and §10.3 is explicit that a device-issued grant carrying `enroll` must be
/// rejected outright — `authorityIsWellFormed` refuses to encode one, so that is not a check this
/// file has to remember. `1` is what "least privilege is expressible" means here.
///
/// Pure and injectable: `operationID` and `randomness` are parameters because a test that cannot pin
/// them cannot assert the bytes, and the bytes are what a signature covers.
public enum E2ESubordinateGrant {

    public enum Failure: String, Error, Equatable, Sendable {
        /// This device has committed no chain, so it has no authority to delegate.
        case notEnrolled = "not-enrolled"
        /// This device's own chain does not verify — refuse rather than extend it.
        case ownChainInvalid = "own-chain-invalid"
        /// This device's grant does not carry `enroll`. A code-enrolled device (`3`) lands here, and
        /// so does anything already subordinate: §10.3's table stops at `root → A → B`.
        case notAuthorized = "not-authorized"
        /// The subordinate descriptor does not parse, or names a different root.
        case malformedDevice = "malformed-device"
        /// The signing key does not match the device this chain certifies.
        case keyMismatch = "key-mismatch"
        /// A grant, certificate or bundle could not be encoded, or could not be signed.
        case encoding = "encoding"
        /// The assembled bundle does not verify. A programming error here, never a runtime state —
        /// and the one failure worth checking for anyway, because the alternative is handing out a
        /// chain that the receiving device silently refuses later, far from here.
        case unverified = "unverified"
    }

    /// Issue a subordinate grant over `device`, returning the FULL bundle the subordinate stores:
    /// the root descriptor, this device's own certificates, and the new one appended.
    ///
    /// The subordinate stores the whole chain rather than its own certificate alone, because §10.4
    /// verification walks from the root every time and a device that held only its leaf could not
    /// present one.
    public static func issue(
        to device: [UInt8],
        ownRoot: [UInt8],
        ownBundle: [UInt8],
        signingPrivateKey: [UInt8],
        operationID: [UInt8],
        randomness: [UInt8],
        policy: E2EVerify.Policy,
        capabilities: E2EIdentity.Capabilities = .connectOnly
    ) -> Result<[UInt8], Failure> {
        let rootID = E2EIdentity.rootID(ownRoot)

        // 1. Our own chain, verified. This is what establishes that we MAY delegate, and it is a
        //    verification rather than a parse on purpose: a chain we cannot verify is one the
        //    subordinate could not verify either, and the failure belongs here where it is legible.
        let own: E2EVerify.VerifiedChain
        switch E2EVerify.verifyBundle(ownBundle, trustedRootID: rootID, policy: policy) {
        case .success(let chain): own = chain
        case .failure: return .failure(.ownChainInvalid)
        }
        guard own.capabilities.canEnroll else { return .failure(.notAuthorized) }

        // 2. The key we are about to sign with must be the key the chain certifies. Without this a
        //    caller could hand in any private key and produce a certificate nobody can verify —
        //    which would surface as `unverified` below, but naming the real cause is cheaper.
        guard let signingPublic = E2EVerify.ed25519PublicKey(privateKey: signingPrivateKey),
              signingPublic == own.leafDevice.signingPublicKey else { return .failure(.keyMismatch) }

        // 3. The subordinate descriptor. It NAMES its root (§10.2), and a descriptor naming another
        //    root is not something to re-point — it is a different identity.
        guard let subordinate = E2EIdentity.parseDevice(device),
              subordinate.rootID == rootID else { return .failure(.malformedDevice) }

        // 4. The grant. `binding` is LOCAL: this is an issuance on one machine, with no Noise
        //    transcript to bind to, which is the same shape §12.1's direct passkey grant uses.
        guard let grant = E2EIdentity.grant(
                rootID: rootID, operationID: operationID, issuerKind: .device,
                issuerID: own.leaf.id, device: device, capabilities: capabilities,
                binding: .local(randomness: randomness)) else { return .failure(.encoding) }

        // 5. §10.4: a device-issued grant is evidenced by a raw Ed25519 signature over the grant
        //    BYTES — not over a hash of them, and not over anything WebAuthn-shaped. The evidence
        //    form is chosen by `issuer_kind`, so getting this wrong produces a certificate that
        //    parses and never verifies.
        guard let signature = E2EVerify.signEd25519(message: grant, privateKey: signingPrivateKey),
              let certificate = E2ECertificate.certificate(grant: grant, evidence: signature)
        else { return .failure(.encoding) }

        guard let parsedOwn = try? E2ECertificate.parseBundle(ownBundle).get() else {
            return .failure(.ownChainInvalid)
        }
        let existing = parsedOwn.certificates.compactMap {
            E2ECertificate.certificate(grant: $0.grant, evidence: $0.evidence)
        }
        guard existing.count == parsedOwn.certificates.count,
              let bundle = E2ECertificate.bundle(root: ownRoot, certificates: existing + [certificate])
        else { return .failure(.encoding) }

        // 6. The verdict that counts is the SUBORDINATE's, against state this never sees — but a
        //    bundle that fails here could never pass there, and failing at the issuer is the only
        //    place a person can still be told something useful.
        guard case .success = E2EVerify.verifyBundle(
                bundle, trustedRootID: rootID, policy: policy,
                expectedNoiseStatic: subordinate.noisePublicKey) else { return .failure(.unverified) }

        return .success(bundle)
    }
}
