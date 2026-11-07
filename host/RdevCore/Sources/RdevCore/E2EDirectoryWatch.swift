import Foundation

/// **§12.2's directory as a STREAM — the Mac's half, as a pure machine.**
/// `docs/superpowers/specs/2026-09-24-live-device-list-design.md`.
///
/// Inputs are what the socket did; effects are what the glue (`E2EDirectoryWatcher`, RdevHostKit)
/// must do. No clock, no socket, no threads — so every rule below is asserted in a third of a second,
/// and the glue is left with timers and a `URLSessionWebSocketTask`.
public struct E2EDirectoryWatch: Sendable {
    public static let pingSeconds: TimeInterval = 20
    public static let staleSeconds: TimeInterval = 45
    public static let giveUpAfter = 3
    static let terminal: Set<Int> = [4401, 4403, 4429]

    public struct Credentials: Sendable {
        public let bundle: [UInt8]
        public let rootID: [UInt8]
        public let signingPrivateKey: [UInt8]
        /// base64url of this Mac's device id — its own row is dropped, as `listSessions` does.
        public let ownDeviceID: String
        public init(bundle: [UInt8], rootID: [UInt8], signingPrivateKey: [UInt8], ownDeviceID: String) {
            self.bundle = bundle; self.rootID = rootID
            self.signingPrivateKey = signingPrivateKey; self.ownDeviceID = ownDeviceID
        }
    }
    public enum Stop: Equatable, Sendable { case refused(Int), unavailable }
    public enum Input: Sendable {
        case opened, message(String), closed(code: Int?), renewDue(challenge: String)
    }
    public enum Effect: Equatable, Sendable {
        case send(String)
        case renew(after: TimeInterval, challenge: String)
        case sessions([E2EDirectory.Session])
        case down
        case reconnectNow
        case stop(Stop)
    }

    private let credentials: Credentials
    private let operationID: @Sendable () -> [UInt8]
    private var openedThisAttempt = false
    private var unopened = 0

    public init(credentials: Credentials, operationID: @escaping @Sendable () -> [UInt8]) {
        self.credentials = credentials
        self.operationID = operationID
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch input {
        case .opened:
            openedThisAttempt = true
            unopened = 0
            return []
        case .renewDue(let challenge):
            return subscribe(challenge)
        case .closed(let code):
            if let code, Self.terminal.contains(code) { return [.stop(.refused(code))] }
            if !openedThisAttempt { unopened += 1 }
            openedThisAttempt = false
            if unopened >= Self.giveUpAfter { return [.stop(.unavailable)] }
            return code == 4408 ? [.down, .reconnectNow] : [.down]
        case .message(let text):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { return [] }
            switch object["t"] as? String {
            case "challenge":
                return subscribe(object["challenge"] as? String ?? "")
            case "subscribed":
                let seconds = (object["renew_in"] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 60
                guard let next = object["challenge"] as? String else { return [] }
                return [.renew(after: seconds / 2, challenge: next)]
            case "sessions":
                guard let rows = object["sessions"] as? [[String: Any]] else { return [] }
                return [.sessions(rows.compactMap(row).filter { $0.deviceID != credentials.ownDeviceID })]
            default:
                return []
            }
        }
    }

    private func subscribe(_ challenge: String) -> [Effect] {
        // The operation id must be the one signed over, so it is drawn ONCE.
        let operation = operationID()
        guard let bytes = base64urlDecode(challenge),
              let body = E2EDirectory.requestBody(action: .subscribe, challenge: bytes,
                                                  rootID: credentials.rootID,
                                                  operationID: operation, payload: []),
              let signature = E2EVerify.signEd25519(message: body,
                                                    privateKey: credentials.signingPrivateKey)
        else { return [.stop(.refused(0))] }
        let object: [String: Any] = [
            "t": "subscribe",
            "bundle": base64urlEncode(Data(credentials.bundle)),
            "operation_id": base64urlEncode(Data(operation)),
            "signature": base64urlEncode(Data(signature)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return [.stop(.refused(0))] }
        return [.send(text)]
    }

    private func row(_ r: [String: Any]) -> E2EDirectory.Session? {
        guard let code = r["code"] as? String, !code.isEmpty,
              let token = r["token"] as? String, !token.isEmpty,
              let label = r["label"] as? String,
              let deviceID = r["device_id"] as? String else { return nil }
        return E2EDirectory.Session(code: code, token: token, label: label, deviceID: deviceID)
    }
}
