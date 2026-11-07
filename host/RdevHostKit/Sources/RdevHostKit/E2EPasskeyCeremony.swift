import Foundation
import RdevCore

/// **The platform's passkey API, as the one thing the Mac's ceremony needs from it.** The app answers it
/// with `ASAuthorization` (`app/Sources/PasskeyAuthorizer.swift`), anchored to its dashboard; a test
/// answers it with a fake. Everything a ceremony DECIDES is `RdevCore.E2EPasskeyGrant` and the flows
/// below, so none of it waits on a person to be tested.
public protocol PasskeyAuthenticator: Sendable {
    /// An assertion over `challenge` on `rpID`. An EMPTY `allowedCredentials` is §10.1's discovery: the
    /// authenticator offers what it holds and the person picks.
    func assert(rpID: String, challenge: [UInt8], allowedCredentials: [[UInt8]],
                largeBlob: PasskeyLargeBlob?) async -> Result<E2EPasskeyGrant.Answer, PasskeyFailure>
    /// A new discoverable ES256 credential on `rpID`, user-verified, no attestation; the
    /// `attestationObject`'s raw bytes.
    func register(rpID: String, challenge: [UInt8], userID: [UInt8],
                  userName: String) async -> Result<[UInt8], PasskeyFailure>
}

/// What an assertion does with the credential's large blob: READ the root descriptor it holds (a
/// discovery), or WRITE it (the grant assertion right after creating — the browser does the same, so
/// the authenticator can name the root itself next time).
public enum PasskeyLargeBlob: Equatable, Sendable { case read, write([UInt8]) }

public enum PasskeyFailure: Error, Equatable, Sendable {
    /// The person closed the prompt. A decision, not a fault: the panel goes back to its form.
    case dismissed
    /// The platform refused this app the relying party: Apple has not (yet) confirmed the
    /// `webcredentials:` association against `/.well-known/apple-app-site-association`.
    case notAssociated
    /// Any other refusal, named as the platform named it.
    case refused(String)
}

/// Every way the Mac's ceremony can end without an identity. `reason` is the code the dashboard's
/// panel turns into a sentence (`web/src/shared/e2e-setup.ts`), the browser's own codes where the two
/// mean the same thing.
public enum E2EPasskeyFailure: Error, Equatable, Sendable {
    case passkey(PasskeyFailure)
    /// The Worker gave a DEFINITE "no identity is registered for that passkey" (404 `not-found`).
    case notFound
    /// The Worker did not answer the credential lookup — a timeout, a 5xx — which proves nothing.
    case lookupUnavailable
    /// The descriptor that came back is another relying party's.
    case rootRPID
    /// What came back did not verify; carries `E2EVerify`'s reason.
    case unverified(String)
    /// Nothing durable could be written. §12.3: an unsuccessful durable write grants no authority.
    case storage
    /// "Finish setting up" with nothing retained — reachable only as a race.
    case noPending
    case malformed

    public var reason: String {
        switch self {
        case .passkey(.dismissed): return "dismissed"
        case .passkey(.notAssociated): return "not-associated"
        case .passkey(.refused(let detail)): return "refused/\(detail)"
        case .notFound: return "not-found"
        case .lookupUnavailable: return "lookup"
        case .rootRPID: return "root-rpid"
        case .unverified(let detail): return detail
        case .storage: return "storage"
        case .noPending: return "no-pending"
        case .malformed: return "malformed"
        }
    }
}

/// **THE MAC'S OWN PASSKEY CEREMONY, AS IO** (2026-10-06; `docs/e2e.md`, "The Mac's own passkey
/// ceremony"): the browser's sign-in and create routes (`ClientE2EIdentity.signIn`, `enroll`), with the
/// platform's passkey API where the browser has `navigator.credentials`, and the trust record where it
/// has IndexedDB. It replaced §12.1's courier — a browser tab, a Worker holding the result, a poll.
extension E2EHostIdentity {

    /// §10.1's relying party, the policy's: `xpromptvs.ai` on the product's domain — the apex or `app.`
    /// (`E2EOrigin.product`) — the one the app's `webcredentials:` entitlement names.
    public var relyingParty: String { policy.rpID }

    /// **Sign in: ONE prompt.** The passkey signs this device's grant commitment, which names no root,
    /// so the ceremony that finds the identity is the one that authorises this Mac.
    ///
    /// A Mac that already trusts a root (§10.3's upgrade: adopted by code, capability 2) asks only for
    /// THAT credential — a device that trusts a root is not shopping, and §10.1 forbids an incoming
    /// chain replacing it. Otherwise `allowedCredentials` is empty and the authenticator offers what it
    /// holds; the descriptor for the credential that answered comes from its large blob, a passkey this
    /// Mac created and never finished, or the Worker's index — each only a HINT until the assertion
    /// verifies under it (`verifyDiscoveredRoot`).
    ///
    /// Adopts without a confirmation step, as the browser does since 2026-09-14: §10.1's Residual is
    /// about a candidate the DIRECTORY named, and here the authenticator offered and the person picked.
    /// The identity is stated afterwards, Sign out beside it.
    public func signIn(authenticator: PasskeyAuthenticator,
                       transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> Result<E2EIdentityManager.Acceptance, E2EPasskeyFailure> {
        guard case .success(let loaded) = manager.load() else { return .failure(.storage) }
        guard let request = E2EPasskeyGrant.request(keys: loaded.installation.keys) else {
            return .failure(.malformed)
        }
        let trusted = loaded.record.root.flatMap(E2EIdentity.parseRoot)
        let answer: E2EPasskeyGrant.Answer
        switch await authenticator.assert(rpID: relyingParty, challenge: request.challenge,
                                          allowedCredentials: trusted.map { [$0.credentialID] } ?? [],
                                          largeBlob: trusted == nil ? .read : nil) {
        case .success(let a): answer = a
        case .failure(let f): return .failure(.passkey(f))
        }

        let root: E2EIdentity.Root
        if let trusted {
            switch E2EPasskeyGrant.verifyDiscoveredRoot(root: trusted.bytes, answer: answer,
                                                        request: request, policy: policy) {
            case .success(let r): root = r
            case .failure(let f): return .failure(Self.failure(f))
            }
        } else {
            switch await discoveredRoot(for: answer, request: request, transport: transport) {
            case .success(let r): root = r
            case .failure(let f): return .failure(f)
            }
        }
        let outcome = commit(root: root, answer: answer, request: request, loaded: loaded,
                             newRoot: .discovered)
        // A passkey created here and finished by signing in with it is no longer pending.
        if case .success = outcome, pendingRoot.read().flatMap(E2EIdentity.parseRoot)?.id == root.id {
            _ = pendingRoot.delete()
        }
        return outcome
    }

    /// **Create, prompt one of two: a new passkey — a new identity — RETAINED before anything else can
    /// fail.** §10.1 route 1's "retain the registration public key and credential ID": a registration is
    /// the only moment a passkey hands out its public key, so a descriptor dropped here is unrecoverable
    /// by anyone. The grant is `authorise`'s, a second prompt, because a registration carries no
    /// signature (Apple answers `fmt: "none"`, measured 2026-09-14).
    public func createPasskey(authenticator: PasskeyAuthenticator,
                              random: (Int) -> [UInt8] = DeviceIdentity.systemRandom)
        async -> Result<Void, E2EPasskeyFailure> {
        // The browser's parameters (`rootCreationOptions`): an unbound challenge — a registration proves
        // nothing that is checked — 16 random bytes of user handle, the relying party as the name.
        let attestation: [UInt8]
        switch await authenticator.register(rpID: relyingParty, challenge: random(32),
                                            userID: random(16), userName: relyingParty) {
        case .success(let a): attestation = a
        case .failure(let f): return .failure(.passkey(f))
        }
        guard let root = WebAuthnRegistration.root(fromAttestationObject: attestation,
                                                   rpID: relyingParty) else {
            return .failure(.malformed)
        }
        return pendingRoot.write(root) ? .success(()) : .failure(.storage)
    }

    /// **Create, prompt two — and "Finish setting up"**: the retained passkey authorises this Mac. The
    /// descriptor is WRITTEN to the credential's large blob on the same assertion, as the browser does.
    /// The retained entry goes on a commit and on a verification failure, NEVER on a ceremony failure
    /// (a cancel and "no such credential" are one error, `docs/e2e.md`).
    public func authorise(authenticator: PasskeyAuthenticator)
        async -> Result<E2EIdentityManager.Acceptance, E2EPasskeyFailure> {
        guard let retained = pendingRoot.read() else { return .failure(.noPending) }
        guard let pending = E2EIdentity.parseRoot(retained) else {
            _ = pendingRoot.delete()
            return .failure(.noPending)
        }
        guard case .success(let loaded) = manager.load() else { return .failure(.storage) }
        guard let request = E2EPasskeyGrant.request(keys: loaded.installation.keys) else {
            return .failure(.malformed)
        }
        let answer: E2EPasskeyGrant.Answer
        switch await authenticator.assert(rpID: relyingParty, challenge: request.challenge,
                                          allowedCredentials: [pending.credentialID],
                                          largeBlob: .write(pending.bytes)) {
        case .success(let a): answer = a
        case .failure(let f): return .failure(.passkey(f))
        }
        switch E2EPasskeyGrant.verifyDiscoveredRoot(root: pending.bytes, answer: answer,
                                                    request: request, policy: policy) {
        case .success: break
        case .failure(let f):
            _ = pendingRoot.delete()
            return .failure(Self.failure(f))
        }
        let outcome = commit(root: pending, answer: answer, request: request, loaded: loaded,
                             newRoot: .created)
        switch outcome {
        case .success, .failure(.unverified): _ = pendingRoot.delete()
        default: break
        }
        return outcome
    }

    /// A passkey this Mac created and never finished — the panel's "Finish setting up".
    public var hasPendingRoot: Bool { pendingRoot.read() != nil }

    // MARK: - the shared tail

    /// Which descriptor names the credential that answered a DISCOVERY, verified. The browser's order:
    /// the large blob if it parses, else the Worker; a blob that fails verification falls back to the
    /// Worker once. A passkey created HERE is a candidate before the Worker — it is the one place a
    /// never-registered credential can be resolved.
    private func discoveredRoot(for answer: E2EPasskeyGrant.Answer, request: E2EPasskeyGrant.Request,
                                transport: E2EDirectoryClient.Transport)
        async -> Result<E2EIdentity.Root, E2EPasskeyFailure> {
        var local: [[UInt8]] = []
        if let blob = answer.largeBlob, E2EIdentity.parseRoot(blob) != nil { local.append(blob) }
        if let retained = pendingRoot.read(), let r = E2EIdentity.parseRoot(retained),
           r.credentialID == answer.credentialID { local.append(retained) }
        for candidate in local {
            if case .success(let root) = E2EPasskeyGrant.verifyDiscoveredRoot(
                root: candidate, answer: answer, request: request, policy: policy) { return .success(root) }
        }
        switch await E2ECredentialLookup(origin: origin.url, transport: transport)
            .root(credentialID: answer.credentialID) {
        case .found(let root):
            return E2EPasskeyGrant.verifyDiscoveredRoot(root: root, answer: answer, request: request,
                                                        policy: policy).mapError(Self.failure)
        case .absent: return .failure(.notFound)
        case .unknown: return .failure(.lookupUnavailable)
        }
    }

    /// The grant naming `root`, verified, then accepted and committed in one step
    /// (`acceptEnrollmentReturn`: §10.4's bindings, the device descriptor, §12.3's order).
    private func commit(root: E2EIdentity.Root, answer: E2EPasskeyGrant.Answer,
                        request: E2EPasskeyGrant.Request, loaded: E2EIdentityManager.Loaded,
                        newRoot: E2EIdentityManager.NewRoot)
        -> Result<E2EIdentityManager.Acceptance, E2EPasskeyFailure> {
        guard let bundle = E2EPasskeyGrant.bundle(root: root, answer: answer, request: request,
                                                  keys: loaded.installation.keys, policy: policy)
        else { return .failure(.unverified("chain")) }
        switch manager.acceptEnrollmentReturn(bundle: bundle, pendingOperationID: request.operationID,
                                              loaded: loaded, policy: policy, newRoot: newRoot) {
        case .success(let accepted): return .success(accepted.acceptance)
        case .failure(.returnRejected): return .failure(.unverified("chain"))
        case .failure: return .failure(.storage)
        }
    }

    private static func failure(_ f: E2EPasskeyGrant.DiscoveryFailure) -> E2EPasskeyFailure {
        switch f {
        case .malformed: return .malformed
        case .rootRPID: return .rootRPID
        case .refused(let reason): return .unverified(reason.rawValue)
        }
    }
}

/// **`GET /credential/<credential_id>`** — the Worker's credential index, which a discovery needs
/// because an assertion returns no public key. A HINT: `verifyDiscoveredRoot` is what makes an answer
/// usable. Only the Worker's own `404 {"error":"not-found"}` counts as absent; every other outcome,
/// a timeout included, is unknown (`web/src/lib/credential-lookup.ts`'s `credentialLookupOutcome`).
public struct E2ECredentialLookup {
    public enum Outcome: Equatable, Sendable { case found([UInt8]), absent, unknown }

    private let origin: URL
    private let transport: E2EDirectoryClient.Transport

    public init(origin: URL, transport: E2EDirectoryClient.Transport) {
        self.origin = origin
        self.transport = transport
    }

    public func root(credentialID: [UInt8]) async -> Outcome {
        guard !credentialID.isEmpty else { return .unknown }
        var request = URLRequest(url: origin.appendingPathComponent("credential")
            .appendingPathComponent(base64urlEncode(Data(credentialID))))
        request.timeoutInterval = 5
        guard let (data, status) = await transport.send(request) else { return .unknown }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200:
            guard let encoded = body?["root"] as? String, let root = base64urlDecode(encoded),
                  !root.isEmpty else { return .unknown }
            return .found(root)
        case 404 where body?["error"] as? String == "not-found": return .absent
        default: return .unknown
        }
    }
}
