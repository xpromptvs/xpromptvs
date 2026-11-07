import Foundation

/// Turning a Control Plane's list of live hosts into something a person may be shown.
///
/// Mirror of `protocol/src/e2e-host-list.ts`. **The Mac app is a client as well as a Host** — it
/// lists the other machines on the account and connects to them — so it needs this exactly as the
/// browser does.
///
/// **THE LIST IS EVIDENCE OF NOTHING.** §4 puts the Control Plane inside the adversary model and
/// §9.2 is explicit that "addresses and room tokens confer no E2E authority", so every field here is
/// a claim. This turns those claims into three answers: which rows can be connected to at all, which
/// names are vouched for, and which are merely asserted.
///
/// **IT DECIDES NOTHING ABOUT ACCESS.** A row surviving this is a row worth offering; whether the
/// peer at the other end is who it claims is settled by the handshake (§11.1's expected-peer check)
/// and by §13. What this stops is narrower and entirely about the human: being shown a name the
/// directory chose.
public enum E2EHostList {

    /// The shape the account layer publishes. Every identity field is optional, because a deployment
    /// without E2E identity publishes none of them.
    public struct Listed: Equatable, Sendable {
        public let name: String
        public let code: String
        public let token: String
        public let e2eDeviceID: String?
        public let label: String?
        public let labelSignature: String?
        public let labelSignerBundle: String?

        public init(name: String, code: String, token: String, e2eDeviceID: String? = nil,
                    label: String? = nil, labelSignature: String? = nil,
                    labelSignerBundle: String? = nil) {
            self.name = name
            self.code = code
            self.token = token
            self.e2eDeviceID = e2eDeviceID
            self.label = label
            self.labelSignature = labelSignature
            self.labelSignerBundle = labelSignerBundle
        }
    }

    public enum NameSource: String, Equatable, Sendable {
        /// The name came from a label this endpoint verified against its own trusted root.
        case verified
        /// The name came from the directory and nothing vouches for it. **A caller MUST mark it** —
        /// §10.1's residual is about exactly this: a name "the same adversary chose".
        case unverified
    }

    public struct Reviewed: Equatable, Sendable {
        public let code: String
        public let token: String
        public let displayName: String
        public let nameSource: NameSource
        public let deviceID: [UInt8]?
        /// **A row with no device id cannot be selected.** §11.1 requires that "a selected Host's
        /// `device_id` must also match the selection", and a selection with nothing to match is not
        /// one — a caller offering this row could never make the check that makes the offer safe.
        public let connectable: Bool
        /// Why the label was not used, when it was not. Nil when there was no label to reject.
        public let labelFailure: E2EDeviceLabel.Failure?
        /// The directory's own `name` disagreed with the verified label. Not a refusal — the
        /// verified name wins — but it is the directory caught saying something a signature
        /// contradicts.
        public let nameContested: Bool
    }

    public static func review(_ host: Listed, trustedRootID: [UInt8], policy: E2EVerify.Policy,
                              revokedDeviceIDs: Set<[UInt8]> = []) -> Reviewed {
        let deviceID = host.e2eDeviceID.flatMap(base64urlDecode).flatMap {
            $0.count == E2EWire.idLength ? $0 : nil
        }
        func unverified(_ failure: E2EDeviceLabel.Failure? = nil) -> Reviewed {
            Reviewed(code: host.code, token: host.token, displayName: host.name,
                     nameSource: .unverified, deviceID: deviceID, connectable: deviceID != nil,
                     labelFailure: failure, nameContested: false)
        }
        guard let deviceID else { return unverified() }

        // A partial label is NO label. Three fields that only mean anything together, so a row
        // carrying two of them has a name nothing vouches for — not one to half-believe.
        guard let body = host.label.flatMap(base64urlDecode),
              let signature = host.labelSignature.flatMap(base64urlDecode),
              let signerBundle = host.labelSignerBundle.flatMap(base64urlDecode)
        else { return unverified() }

        switch E2EDeviceLabel.verify(body: body, signature: signature, signerBundle: signerBundle,
                                     expectedDeviceID: deviceID, trustedRootID: trustedRootID,
                                     policy: policy, revokedDeviceIDs: revokedDeviceIDs) {
        case .failure(let failure):
            return unverified(failure)
        case .success(let label):
            return Reviewed(code: host.code, token: host.token, displayName: label.name,
                            nameSource: .verified, deviceID: deviceID, connectable: true,
                            labelFailure: nil,
                            // The verified name WINS; this records that the directory said otherwise.
                            nameContested: label.name != host.name)
        }
    }

    /// Review a whole listing, preserving order.
    ///
    /// **Nothing is dropped.** A row silently missing from a list is indistinguishable from a device
    /// that is not running, and §12.2 is emphatic that absence must never be read as a verdict. Rows
    /// come back marked, not removed.
    public static func review(_ hosts: [Listed], trustedRootID: [UInt8], policy: E2EVerify.Policy,
                              revokedDeviceIDs: Set<[UInt8]> = []) -> [Reviewed] {
        hosts.map { review($0, trustedRootID: trustedRootID, policy: policy,
                           revokedDeviceIDs: revokedDeviceIDs) }
    }
}
