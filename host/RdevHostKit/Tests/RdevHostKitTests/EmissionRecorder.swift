import Foundation
import XCTest
import RdevCore
@testable import RdevHostKit

/// Everything a TerminalManager emits, in order, thread-safe — the tests' view of the terminal channel.
final class EmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TermEmission] = []

    /// `true`: a recorder stands for a wire that decodes everything it is given.
    @discardableResult
    func record(_ e: TermEmission) -> Bool { lock.lock(); items.append(e); lock.unlock(); return true }
    var all: [TermEmission] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all.count }

    func snapshots(of id: TermTabID, since: Int = 0) -> [(size: TermGridSize, bytes: [UInt8])] {
        all.dropFirst(since).compactMap { if case .snapshot(id, let s, let b) = $0 { return (s, b) }; return nil }
    }
    func output(of id: TermTabID, since: Int = 0) -> [UInt8] {
        all.dropFirst(since).flatMap { e -> [UInt8] in if case .output(id, let b) = e { return b }; return [] }
    }
    func text(of id: TermTabID, since: Int = 0) -> String { String(decoding: output(of: id, since: since), as: UTF8.self) }
    func closed(since: Int = 0) -> [TermTabID] {
        all.dropFirst(since).compactMap { if case .closed(let id) = $0 { return id }; return nil }
    }

    @discardableResult
    func wait(_ what: String, timeout: TimeInterval = 15, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(cond(), what)
        return cond()
    }
}
