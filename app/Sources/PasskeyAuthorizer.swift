import AppKit
import AuthenticationServices
import RdevCore
import RdevHostKit

/// **The Mac's passkey prompt** — `PasskeyAuthenticator` answered by the platform's `ASAuthorization`
/// (2026-10-06; `docs/desktop-app.md`, "Signing and notarization", `docs/e2e.md`, "The Mac's own passkey
/// ceremony"). It is allowed to ask for `xpromptvs.ai`'s passkeys only because the signed app carries
/// `webcredentials:xpromptvs.ai` and the Worker serves the `apple-app-site-association` naming its App
/// ID; without Apple's confirmation of that pair, every request is refused (`notAssociated`).
///
/// GLUE ONLY: what is asked and what the answer means is `E2EHostIdentity`'s and
/// `RdevCore.E2EPasskeyGrant`'s. The raw bytes come back untouched — `rawClientDataJSON`,
/// `rawAuthenticatorData`, the DER signature — because §10.4 forbids re-serialising them.
final class PasskeyAuthorizer: PasskeyAuthenticator, @unchecked Sendable {

    /// The window the system's sheet attaches to: the dashboard that asked, else whatever is key.
    private let anchor: @MainActor () -> NSWindow?

    init(anchor: @escaping @MainActor () -> NSWindow?) { self.anchor = anchor }

    func assert(rpID: String, challenge: [UInt8], allowedCredentials: [[UInt8]],
                largeBlob: PasskeyLargeBlob?) async -> Result<E2EPasskeyGrant.Answer, PasskeyFailure> {
        let outcome = await perform { () -> ASAuthorizationRequest in
            let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
                .createCredentialAssertionRequest(challenge: Data(challenge))
            // EMPTY is §10.1's discovery: the authenticator offers what it holds and the person picks.
            request.allowedCredentials = allowedCredentials.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: Data($0))
            }
            request.userVerificationPreference = .required
            switch largeBlob {
            case .read?: request.largeBlob = .read
            case .write(let bytes)?: request.largeBlob = .write(Data(bytes))
            case nil: break
            }
            return request
        }
        switch outcome {
        case .failure(let f): return .failure(f)
        case .success(let credential):
            guard let a = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
                  let authenticatorData = a.rawAuthenticatorData, let signature = a.signature
            else { return .failure(.refused("not-an-assertion")) }
            var blob: [UInt8]?
            if case .read(let data)? = a.largeBlob?.result, let data { blob = Array(data) }
            return .success(.init(credentialID: Array(a.credentialID), clientDataJSON: Array(a.rawClientDataJSON),
                                  authenticatorData: Array(authenticatorData), signature: Array(signature),
                                  largeBlob: blob))
        }
    }

    func register(rpID: String, challenge: [UInt8], userID: [UInt8],
                  userName: String) async -> Result<[UInt8], PasskeyFailure> {
        let outcome = await perform { () -> ASAuthorizationRequest in
            let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
                .createCredentialRegistrationRequest(challenge: Data(challenge), name: userName,
                                                     userID: Data(userID))
            request.userVerificationPreference = .required
            request.attestationPreference = .none
            // So a later discovery can read the root descriptor from the authenticator itself (the
            // grant assertion writes it); preferred, never required — Apple's support is not universal.
            request.largeBlob = .supportPreferred
            return request
        }
        switch outcome {
        case .failure(let f): return .failure(f)
        case .success(let credential):
            guard let r = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                  let attestation = r.rawAttestationObject else { return .failure(.refused("no-attestation")) }
            return .success(Array(attestation))
        }
    }

    // MARK: - one request

    /// Run one request on the main actor and wait for its delegate.
    private func perform(_ make: @escaping @MainActor () -> ASAuthorizationRequest)
        async -> Result<ASAuthorizationCredential, PasskeyFailure> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let run = Run(anchor: anchor() ?? NSApp.keyWindow ?? NSApp.windows.first) { result in
                    continuation.resume(returning: result)
                }
                run.start(make())
            }
        }
    }

    /// One `ASAuthorizationController` and the delegate it reports to, alive until it reports —
    /// a controller holds its delegate weakly, so `Run` keeps itself until the answer arrives.
    @MainActor private final class Run: NSObject, ASAuthorizationControllerDelegate,
                                        ASAuthorizationControllerPresentationContextProviding {
        private static var live: Set<Run> = []
        /// **A prompt that never answers must not hold the ceremony for good**: the service's in-flight
        /// claim refuses every later attempt until this one settles, so past this the request is
        /// cancelled and reported. Far longer than a person takes (WebAuthn's own default is 2 min).
        private static let deadline: TimeInterval = 300
        private let window: NSWindow?
        private let done: (Result<ASAuthorizationCredential, PasskeyFailure>) -> Void
        private var controller: ASAuthorizationController?
        private var settled = false

        init(anchor: NSWindow?, done: @escaping (Result<ASAuthorizationCredential, PasskeyFailure>) -> Void) {
            window = anchor; self.done = done
        }

        func start(_ request: ASAuthorizationRequest) {
            Self.live.insert(self)
            let c = ASAuthorizationController(authorizationRequests: [request])
            c.delegate = self
            c.presentationContextProvider = self
            controller = c
            c.performRequests()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
                guard let self, !self.settled else { return }
                self.controller?.cancel()
                self.finish(.failure(.refused("timeout")))
            }
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            window ?? ASPresentationAnchor()
        }

        func authorizationController(controller: ASAuthorizationController,
                                     didCompleteWithAuthorization authorization: ASAuthorization) {
            finish(.success(authorization.credential))
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            finish(.failure(Self.failure(error)))
        }

        /// Exactly once: a cancel after the deadline reports again through the delegate.
        private func finish(_ result: Result<ASAuthorizationCredential, PasskeyFailure>) {
            guard !settled else { return }
            settled = true
            done(result)
            controller = nil
            Self.live.remove(self)
        }

        /// A closed sheet is `dismissed`; a relying party Apple has not confirmed for this app is
        /// `notAssociated` (its message names the association — the code alone is the generic
        /// `failed`); anything else is named by its domain and code.
        static func failure(_ error: Error) -> PasskeyFailure {
            let e = error as NSError
            if e.domain == ASAuthorizationError.errorDomain, e.code == ASAuthorizationError.canceled.rawValue {
                return .dismissed
            }
            let text = "\(e.localizedDescription) \(e.userInfo)".lowercased()
            if text.contains("not associated") || text.contains("associated domain") { return .notAssociated }
            print("[e2e] passkey request refused: \(e.domain) \(e.code) \(e.localizedDescription)")
            return .refused("\(e.domain == ASAuthorizationError.errorDomain ? "as" : e.domain)-\(e.code)")
        }
    }
}
