import Foundation
import RdevCore

/// **§12.2's publication, as IO.** Get a one-use challenge, sign the request body with this device's
/// certified key, submit the bundle, and classify what comes back.
///
/// **DELIBERATELY THIN**: every decision — what the body is, what each
/// response means, which outcomes retry — is `RdevCore.E2EDirectory`, tested without a network.
///
/// **PUBLICATION IS BEST-EFFORT WITH A BOUNDED WAIT, AND THAT IS THE POINT.** §12.2 changed this
/// deliberately from an earlier revision that made a completed registration a precondition for
/// access: an honest Worker outage would otherwise leave a correctly enrolled device unusable. So
/// nothing here can fail an enrollment — the worst it returns is a status the caller stores and
/// surfaces.
public struct E2EDirectoryClient {

    /// The one thing this needs from the world. Narrower than the enrollment client's, which also
    /// opens a browser; a directory publication never involves a person.
    ///
    /// **NIL MEANS THE REPLY DID NOT ARRIVE**, and it is nil rather than a status code because §12.2
    /// counts that as TRANSIENT while `E2EDirectory.classify` reads an unrecognised code as
    /// terminal. A transport that reported a failure as `0` would pause the retry job on every
    /// network hiccup — which is exactly the outcome "publication is best-effort" exists to avoid.
    public protocol Transport: Sendable {
        func send(_ request: URLRequest) async -> (Data, Int)?
    }

    private let origin: URL
    private let transport: Transport

    public init(origin: URL, transport: Transport) {
        self.origin = origin
        self.transport = transport
    }

    // MARK: - §12.2's grant registration

    /// Register one grant. **Never throws and never fails** — §12.2's three outcomes are all statuses.
    ///
    /// **NAMED `registerGrant`, NOT `publish`, and the distinction is load-bearing.** §12.2 calls
    /// this "publication", and rdev separately has a `publish` ACTION that announces a live session.
    /// One method named for the specification's word and another for the wire's would be two things
    /// called publish that send different actions — so the wire's word wins and this one says what
    /// it registers.
    public func registerGrant(bundle: [UInt8], operationID: [UInt8], rootID: [UInt8],
                              signingPrivateKey: [UInt8]) async -> E2EWire.PublicationStatus {
        let sent = base64urlEncode(Data(bundle))
        guard let reply = await submit(action: .register, payload: bundle, extra: [:],
                                       bundle: bundle, operationID: operationID, rootID: rootID,
                                       signingPrivateKey: signingPrivateKey)
        else { return .unconfirmed }
        guard case .sent(let data, let status) = reply else { return .rejected }
        return E2EDirectory.classify(response(status: status, data: data, sentBundle: sent))
    }

    // MARK: - session discovery (§12.2's directory, rdev's actions)

    /// Announce this Mac's live room under the root it belongs to, and keep announcing it.
    ///
    /// **IDEMPOTENT ON THE ROOM CODE**, which is what makes one call both the publication and the
    /// heartbeat: there is no publish-id to track and no way for the two to disagree. That rule came
    /// from the account implementation this replaces and survives the move.
    ///
    /// `session.deviceID` is IGNORED by the Worker — it derives one from the verified chain — so a
    /// caller signs over an empty string and the two can never disagree.
    public func publishSession(_ session: E2EDirectory.Session, bundle: [UInt8],
                               operationID: [UInt8], rootID: [UInt8],
                               signingPrivateKey: [UInt8]) async -> E2EWire.PublicationStatus {
        guard let payload = E2EDirectory.sessionPayload(session) else { return .rejected }
        let body: [String: Any] = ["session": ["code": session.code, "token": session.token,
                                               "label": session.label]]
        guard let reply = await submit(action: .publish, payload: payload, extra: body,
                                       bundle: bundle, operationID: operationID, rootID: rootID,
                                       signingPrivateKey: signingPrivateKey)
        else { return .unconfirmed }
        guard case .sent(_, let status) = reply else { return .rejected }
        return E2EDirectory.classify(.httpStatus(status))
    }

    /// Withdraw a room. **Only the device that published it may**, which the Worker enforces from the
    /// verified chain — anything else would be one authenticated device in an identity silently
    /// unpublishing another's room.
    public func unpublishSession(code: String, bundle: [UInt8], operationID: [UInt8],
                                 rootID: [UInt8],
                                 signingPrivateKey: [UInt8]) async -> E2EWire.PublicationStatus {
        guard let reply = await submit(action: .unpublish, payload: Array(code.utf8),
                                       extra: ["code": code], bundle: bundle,
                                       operationID: operationID, rootID: rootID,
                                       signingPrivateKey: signingPrivateKey)
        else { return .unconfirmed }
        guard case .sent(_, let status) = reply else { return .rejected }
        return E2EDirectory.classify(.httpStatus(status))
    }

    /// Every live room under this root, or nil if the directory could not answer.
    ///
    /// **A LISTING IS A HINT, NOT A VIEW OF WHO HAS ACCESS.** §12.2 is explicit that absence from
    /// the directory must never be read as revocation, and §4 puts this Worker inside the adversary
    /// model — it can omit a room, invent one, or answer nothing. What makes the answer usable is
    /// what happens next: every row carries a `code` and `token` that lead to §11's gate, which
    /// refuses anything the root did not certify. A row is an invitation to try, never a fact.
    ///
    /// Nil rather than an empty array when the request failed, because "the directory says there
    /// are none" and "the directory did not answer" are different things to put in front of a
    /// person, and an empty array conflates them.
    public func listSessions(bundle: [UInt8], operationID: [UInt8], rootID: [UInt8],
                             signingPrivateKey: [UInt8]) async -> [E2EDirectory.Session]? {
        guard let reply = await submit(action: .list, payload: [], extra: [:], bundle: bundle,
                                       operationID: operationID, rootID: rootID,
                                       signingPrivateKey: signingPrivateKey),
              case .sent(let data, let status) = reply, status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["sessions"] as? [[String: Any]]
        else { return nil }

        // Every field is checked. A row missing one is DROPPED rather than defaulted: a session with
        // no token is one nothing can connect to, and showing it would be offering a door with no
        // key behind a name a person recognises.
        return rows.compactMap { row in
            guard let code = row["code"] as? String, !code.isEmpty,
                  let token = row["token"] as? String, !token.isEmpty,
                  let label = row["label"] as? String,
                  let deviceID = row["device_id"] as? String
            else { return nil }
            return E2EDirectory.Session(code: code, token: token, label: label, deviceID: deviceID)
        }
    }

    // MARK: - the shared half

    /// What `submit` observed. **`.local` is not an HTTP outcome**: a body this device cannot build
    /// or sign is a defect here, not the directory refusing, and retrying would spin forever.
    private enum Reply {
        case sent(Data, Int)
        case local
    }

    /// Challenge, body, signature, POST — the whole of §12.2's authorisation, once.
    ///
    /// `signingPrivateKey` is the device's certified Ed25519 key: §12.2 requires "the requester's
    /// proof of possession", and for a device acting on its OWN behalf the requester is the device
    /// named in the chain it sends. The Worker rebuilds the body from what it knows rather than
    /// trusting the one sent, exactly as §11.2's responder rebuilds a device proof — a signature
    /// over a supplied body would prove only that someone signed something.
    ///
    /// Nil means the reply did not arrive, which §12.2 counts as TRANSIENT.
    private func submit(action: E2EDirectory.Action, payload: [UInt8], extra: [String: Any],
                        bundle: [UInt8], operationID: [UInt8], rootID: [UInt8],
                        signingPrivateKey: [UInt8]) async -> Reply? {
        let root = base64urlEncode(Data(rootID))
        guard let challenge = await challenge(root: root) else { return nil }

        guard let body = E2EDirectory.requestBody(action: action, challenge: challenge,
                                                  rootID: rootID, operationID: operationID,
                                                  payload: payload),
              let signature = E2EVerify.signEd25519(message: body, privateKey: signingPrivateKey)
        else { return .local }

        var object: [String: Any] = [
            "bundle": base64urlEncode(Data(bundle)),
            "operation_id": base64urlEncode(Data(operationID)),
            "signature": base64urlEncode(Data(signature)),
            "challenge": base64urlEncode(Data(challenge)),
        ]
        for (key, value) in extra { object[key] = value }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.sortedKeys]) else {
            return .local
        }

        var request = URLRequest(url: directory(root, action.rawValue))
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // §12.2's `PUBLISH_DEADLINE`. A request that is neither answered nor refused has not failed,
        // and without a deadline it stalls for as long as M cares to stay silent — which hands M the
        // denial of service that "publication is best-effort" exists to avoid.
        request.timeoutInterval = E2EDirectory.publishDeadlineSeconds

        guard let (data, status) = await transport.send(request) else { return nil }
        return .sent(data, status)
    }

    /// §12.2: the challenge is "fresh, one-use, 32-byte, valid for at most 120 seconds". A response
    /// this device cannot read is silence as far as publication is concerned.
    private func challenge(root: String) async -> [UInt8]? {
        var request = URLRequest(url: directory(root, "challenge"))
        request.httpMethod = "POST"
        request.timeoutInterval = E2EDirectory.publishDeadlineSeconds
        guard let (data, status) = await transport.send(request), status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = object["challenge"] as? String,
              let bytes = base64urlDecode(encoded),
              bytes.count == E2EDirectory.challengeLength
        else { return nil }
        return bytes
    }

    /// **A 409 is not automatically a rejection.** §12.2: one carrying the SAME content "is the
    /// idempotent success path"; this Worker answers that case 200, but a different one might not,
    /// and the distinction belongs here rather than in a status code.
    private func response(status: Int, data: Data, sentBundle: String) -> E2EDirectory.Response {
        guard status != 409 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let stored = ((object?["record"] as? [String: Any])?["bundle"] as? String)
            return stored == sentBundle ? .conflictSameContent : .conflictDifferentContent
        }
        return .httpStatus(status)
    }

    private func directory(_ root: String, _ action: String) -> URL {
        origin.appendingPathComponent("directory").appendingPathComponent(root)
            .appendingPathComponent(action)
    }
}

/// The real world: `URLSession`, and nothing else. **A request that did not arrive is NIL**, never a
/// status code — §12.2 counts every such case as transient, and an invented `0` would be read as a
/// refusal and pause the retry job.
public struct LiveDirectoryTransport: E2EDirectoryClient.Transport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async -> (Data, Int)? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }
}
