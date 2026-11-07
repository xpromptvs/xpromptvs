import Foundation

/// One row of §12.2's listing as the directory returned it.
public struct ListingRow: Equatable, Sendable {
    public let label: String, code: String, token: String, deviceID: String
    public init(label: String, code: String, token: String, deviceID: String) {
        self.label = label; self.code = code; self.token = token; self.deviceID = deviceID
    }
}

public struct Listing: Equatable, Sendable {
    public enum State: String, Sendable { case loading, ready, error }
    public let state: State
    public let error: String
    /// A refresh is in flight over rows already shown.
    public let refreshing: Bool
    public let rows: [ListingRow]
    public init(state: State, error: String, refreshing: Bool, rows: [ListingRow]) {
        self.state = state; self.error = error; self.refreshing = refreshing; self.rows = rows
    }

    /// What a person reads, ported from the retired Electron `sessions.ts`: a row missing its code or
    /// token is DROPPED (a door with no key), and a Mac that gave no name SAYS SO.
    public var display: [(name: String, code: String, token: String)] {
        rows.compactMap { row -> (name: String, code: String, token: String)? in
            guard !row.code.isEmpty, !row.token.isEmpty else { return nil }
            let label = row.label.trimmingCharacters(in: .whitespaces)
            return (label.isEmpty ? "Unnamed Mac" : label, row.code, row.token)
        }
    }
}

/// §12.2's listing as a pure state machine — every rule `E2EBox` carried inline, where a test
/// reaches it. `E2EHost` wraps it in a lock and owns the watcher object.
public struct ListingStore: Sendable {
    private var rows: [ListingRow]?          // nil = nothing known yet → `loading`
    private var error = ""
    public private(set) var inFlight = false
    /// Bumped whenever the identity the listing belongs to goes away; a fetch or snapshot started
    /// under an older epoch is discarded.
    public private(set) var epoch = 0
    public private(set) var watchLive = false

    public init() {}

    /// A read. Returns true when the caller must start a fetch (now marked in flight). While the
    /// stream is live a forced refresh is answered from it.
    public mutating func read(refresh: Bool) -> Bool {
        let fetch = !inFlight && ((refresh && !watchLive) || rows == nil)
        if fetch { inFlight = true }
        return fetch
    }

    /// A fetch landed. nil = the directory did not answer: the previous rows SURVIVE, marked, because
    /// `connect-session` looks a row's token up in this listing.
    public mutating func store(_ fetched: [ListingRow]?, epoch e: Int) {
        guard e == epoch else { return }
        inFlight = false
        if let fetched { rows = fetched; error = "" } else { rows = rows ?? []; error = "unreachable" }
    }

    public mutating func streamed(_ snapshot: [ListingRow], epoch e: Int) {
        guard e == epoch else { return }
        watchLive = true; rows = snapshot; error = ""
    }

    public mutating func setWatchLive(_ live: Bool) { watchLive = live }

    public mutating func forget() {
        rows = nil; error = ""; inFlight = false; epoch += 1; watchLive = false
    }

    public var snapshot: Listing {
        guard let rows else { return Listing(state: .loading, error: "", refreshing: false, rows: []) }
        return Listing(state: error.isEmpty ? .ready : .error, error: error, refreshing: inFlight, rows: rows)
    }
}
