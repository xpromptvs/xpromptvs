import Foundation

/// Bundled document authority for related native source views. This does not grant remote control:
/// the bridge also checks actual WKWebView/frame identity, current owner generation and membership.
public enum NativeSourceDocument {
    private static func components(_ url: URL?) -> URLComponents? {
        guard let url, let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              value.scheme?.lowercased() == "app", value.host?.lowercased() == "client",
              value.user == nil, value.password == nil, value.port == nil else { return nil }
        return value
    }

    public static func permitsOwner(url: URL?, mainFrame: Bool, remoteOwner: Bool) -> Bool {
        guard mainFrame, remoteOwner, let value = components(url) else { return false }
        return value.percentEncodedPath == "/index.html"
    }

    private static func validTicket(_ ticket: String) -> Bool {
        guard ticket.utf8.count == 36, let uuid = UUID(uuidString: ticket) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(ticket) == .orderedSame
    }

    public static func url(ticket: String) -> URL? {
        guard validTicket(ticket) else { return nil }
        return URL(string: "app://client/source-window.html?ticket=\(ticket)")
    }

    public static func ticket(url: URL?) -> String? {
        guard let value = components(url), value.percentEncodedPath == "/source-window.html",
              value.fragment == nil, let items = value.queryItems, items.count == 1,
              items[0].name == "ticket", let ticket = items[0].value, validTicket(ticket),
              value.percentEncodedQuery == "ticket=\(ticket)" else { return nil }
        return ticket
    }
}
