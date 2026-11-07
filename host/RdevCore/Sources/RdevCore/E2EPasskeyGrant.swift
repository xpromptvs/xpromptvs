import Foundation

/// **THE MAC'S OWN PASSKEY CEREMONY, AS DECISIONS** (2026-10-06; `docs/e2e.md`, "The Mac's own passkey
/// ceremony"). The app runs §10.1's ceremony itself through the platform's passkey API — the protocol's
/// "supported native API" (§2) — where it used to send the person to a browser and poll a courier for
/// the result. Everything decidable without the platform lives here and is tested without it; what is
/// left outside is the ceremony itself.
///
/// The steps are the browser's (`ClientE2EIdentity.signIn` and `enroll`, `web/src/lib/e2e-grant.ts`), so
/// one grant is built one way whichever device built it: freeze a request — an operation id, a LOCAL
/// binding and the commitment over this device's keys — before the ceremony; let the passkey sign
/// `H(commitment)`; learn the root from the credential that answered; assemble the grant naming it and
/// verify the whole bundle before anything is stored.
public enum E2EPasskeyGrant {

    /// What a ceremony is run for, frozen before it starts (§17.1): the passkey signs `challenge`, and
    /// the grant built afterwards must project back to exactly `preimage`.
    public struct Request: Equatable, Sendable {
        public let operationID: [UInt8]
        public let binding: E2EIdentity.Binding
        public let capabilities: E2EIdentity.Capabilities
        public let preimage: [UInt8]
        public var challenge: [UInt8] { E2EIdentity.sha256(preimage) }
    }

    /// A §12.1 direct grant request for `keys` — root-issued, a LOCAL binding (a passkey ceremony has
    /// no Noise transcript to bind to), capabilities 7 (connect, host, enroll) by default. Nil only for
    /// malformed keys.
    public static func request(keys: DeviceIdentity.Keys,
                               capabilities: E2EIdentity.Capabilities = .full,
                               random: (Int) -> [UInt8] = DeviceIdentity.systemRandom) -> Request? {
        let operationID = E2EOperation.newID(randomBytes: random)
        let binding = E2EIdentity.Binding.local(randomness: random(E2EIdentity.idLength))
        guard let signing = keys.signingPublicKey, let noise = keys.noisePublicKey,
              let preimage = E2EIdentity.grantCommitmentPreimage(
                operationID: operationID, issuerKind: .root, signingPublicKey: signing,
                noisePublicKey: noise, capabilities: capabilities, binding: binding)
        else { return nil }
        return Request(operationID: operationID, binding: binding, capabilities: capabilities,
                       preimage: preimage)
    }

    /// **A direct grant for ANOTHER device** — Add device by code from a Mac (2026-10-07): the newcomer's
    /// descriptor as its message 3 delivered it (it already names this identity's root), capability `2` by
    /// default, and a REMOTE binding to the live handshake that authenticated it (§10.3, checked by the
    /// newcomer against its own view). The browser's `issueDirectGrant` with `binding: remote`, built the
    /// way it builds it: the grant first, then the commitment PROJECTED from it by the function
    /// `verifyBundle` calls, so the signer and the verifier cannot drift. Nil for a descriptor that names
    /// another root, or anything malformed.
    public static func request(issuingTo device: [UInt8], rootID: [UInt8],
                               capabilities: E2EIdentity.Capabilities = .hostOnly,
                               binding: E2EIdentity.Binding,
                               random: (Int) -> [UInt8] = DeviceIdentity.systemRandom) -> Request? {
        let operationID = E2EOperation.newID(randomBytes: random)
        guard let parsedDevice = E2EIdentity.parseDevice(device), parsedDevice.rootID == rootID,
              let grant = E2EIdentity.grant(rootID: rootID, operationID: operationID, issuerKind: .root,
                                            issuerID: rootID, device: device, capabilities: capabilities,
                                            binding: binding),
              let parsed = E2EIdentity.parseGrant(grant),
              let preimage = E2EIdentity.grantCommitment(parsed, trustedRootID: rootID)
        else { return nil }
        return Request(operationID: operationID, binding: binding, capabilities: capabilities,
                       preimage: preimage)
    }

    /// What came back from the authenticator, as raw bytes — never re-serialised (§10.4: "Do not
    /// reserialize `clientDataJSON`").
    public struct Answer: Equatable, Sendable {
        public let credentialID: [UInt8]
        public let clientDataJSON: [UInt8]
        public let authenticatorData: [UInt8]
        public let signature: [UInt8]
        /// The root descriptor the credential's large blob held, when the platform read one.
        public let largeBlob: [UInt8]?

        public init(credentialID: [UInt8], clientDataJSON: [UInt8], authenticatorData: [UInt8],
                    signature: [UInt8], largeBlob: [UInt8]?) {
            self.credentialID = credentialID; self.clientDataJSON = clientDataJSON
            self.authenticatorData = authenticatorData; self.signature = signature
            self.largeBlob = largeBlob
        }

        public var assertion: [UInt8]? {
            E2ECertificate.assertion(credentialID: credentialID, clientDataJSON: clientDataJSON,
                                     authenticatorData: authenticatorData, signature: signature)
        }
    }

    public enum DiscoveryFailure: Equatable, Sendable, Error {
        case malformed
        /// The descriptor that came back is another relying party's (`verifyDiscoveredRoot`'s
        /// `root-rpid`): the answer was wrong, not the passkey.
        case rootRPID
        case refused(E2EVerify.Failure)
    }

    /// **`verifyDiscoveredRoot`, in Swift** (`protocol/src/e2e-verify.ts`): a descriptor someone NAMED
    /// for the credential that answered — its large blob, the Worker's index — is usable only if the
    /// assertion the authenticator just made verifies under it, against local policy. That pins the
    /// credential id, the public key and, through the `rp_id` check `verifyBundle` does not need, the
    /// relying party. §4 puts the Worker inside the adversary model; this is what makes its answer a hint.
    public static func verifyDiscoveredRoot(root: [UInt8], answer: Answer, request: Request,
                                            policy: E2EVerify.Policy)
        -> Result<E2EIdentity.Root, DiscoveryFailure> {
        guard let encoded = answer.assertion, let assertion = E2ECertificate.parseAssertion(encoded),
              let parsed = E2EIdentity.parseRoot(root) else { return .failure(.malformed) }
        guard parsed.rpID == policy.rpID else { return .failure(.rootRPID) }
        if let failure = E2EVerify.verifyAssertion(assertion, preimage: request.preimage,
                                                   root: parsed, policy: policy) {
            return .failure(.refused(failure))
        }
        return .success(parsed)
    }

    /// The bundle a ceremony produced: the grant naming `root`, evidenced by the answer, VERIFIED end to
    /// end before it is returned (`issueDirectGrant`'s order). The commitment is rebuilt by parsing the
    /// grant back and projecting it — the SAME function `verifyBundle` calls — so signer and verifier
    /// cannot drift. Nil when anything disagrees.
    public static func bundle(root: E2EIdentity.Root, answer: Answer, request: Request,
                              keys: DeviceIdentity.Keys, policy: E2EVerify.Policy) -> [UInt8]? {
        guard let device = keys.descriptor(rootID: root.id) else { return nil }
        return bundle(root: root, answer: answer, request: request, device: device, policy: policy)
    }

    /// The same, for the device `request` was made for when that is ANOTHER device's descriptor
    /// (`request(issuingTo:)`).
    public static func bundle(root: E2EIdentity.Root, answer: Answer, request: Request,
                              device: [UInt8], policy: E2EVerify.Policy) -> [UInt8]? {
        guard let grant = E2EIdentity.grant(rootID: root.id, operationID: request.operationID,
                                            issuerKind: .root, issuerID: root.id, device: device,
                                            capabilities: request.capabilities, binding: request.binding),
              let parsed = E2EIdentity.parseGrant(grant),
              E2EIdentity.grantCommitment(parsed, trustedRootID: root.id) == request.preimage,
              let assertion = answer.assertion,
              let certificate = E2ECertificate.certificate(grant: grant, evidence: assertion),
              let bundle = E2ECertificate.bundle(root: root.bytes, certificates: [certificate]),
              case .success = E2EVerify.verifyBundle(bundle, trustedRootID: root.id, policy: policy)
        else { return nil }
        return bundle
    }
}

/// §12.3's operation ids. A fresh one per operation, persisted before any request that can reserve
/// anything, and REUSED for a retry of the same operation (§12.2 keys idempotence on it).
public enum E2EOperation {
    public static func newID(randomBytes: (Int) -> [UInt8] = DeviceIdentity.systemRandom) -> [UInt8] {
        randomBytes(E2EWire.idLength)
    }
}
