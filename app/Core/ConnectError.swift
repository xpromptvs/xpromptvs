import Foundation

/// The sentence a failed connect attempt rejects with — ported from the retired Electron
/// `connect-error.ts`; `docs/desktop-app.md` ("A failed connect carries its reason") explains each arm. A LOAD failure may never say "check the session window": it is blank.
public enum ConnectFailure: Equatable, Sendable {
    case client(text: String?)
    case load(domain: String, code: Int, description: String?)
    case closed
    case gone
}

public enum ConnectError {
    public static func message(_ failure: ConnectFailure) -> String {
        switch failure {
        case .client(let text):
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Could not connect. Check the session window for details."
                             : t.prefix(1).uppercased() + t.dropFirst()
        case .load(let domain, let code, let description):
            let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "The session window could not load (\(d.isEmpty ? "\(domain) error \(code)" : d))."
        case .closed: return "Connection closed."
        case .gone: return "The session window stopped. Try connecting again."
        }
    }
}
