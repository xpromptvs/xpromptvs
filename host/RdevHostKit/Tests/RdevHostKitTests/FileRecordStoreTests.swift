import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// The file behind the §10.2 trust record.
///
/// **The property worth testing is ATOMICITY.** A torn write produces bytes that are not a record,
/// and `E2EIdentityManager` answers that with `blocked` — correctly, since it cannot tell a
/// truncated file from a corrupted one. So the failure this class exists to prevent is a device
/// bricked by a crash mid-save, and "the old bytes or the new, never half" is the assertion.
final class FileRecordStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdev-file-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ name: String = "record") -> FileRecordStore {
        FileRecordStore(url: directory.appendingPathComponent(name))
    }

    func testAnAbsentFileReadsAsNilRatherThanEmpty() {
        // Nil is "nothing stored", which is what makes a fresh identity. An empty array would be
        // "something stored that is not a record", which BLOCKS — the two must never be confused.
        XCTAssertNil(store().read())
    }

    func testARoundTrip() throws {
        let s = store()
        let record = E2ETrustStore.Record(root: Array("a root".utf8), bundle: [1, 2, 3],
                                          publicationStatus: .unconfirmed,
                                          revokedDeviceIDs: [Array(repeating: 9, count: 32)])
        let bytes = try XCTUnwrap(E2ETrustStore.encode(record))
        XCTAssertTrue(s.write(bytes))
        XCTAssertEqual(s.read(), bytes)
        XCTAssertEqual(E2ETrustStore.decode(try XCTUnwrap(s.read())), record)
    }

    func testOverwritingReplacesRatherThanAppends() throws {
        let s = store()
        XCTAssertTrue(s.write([1, 2, 3, 4, 5, 6]))
        XCTAssertTrue(s.write([9, 9]))
        XCTAssertEqual(s.read(), [9, 9])
    }

    /// The temporary file must be in the SAME directory and must not survive: one left behind is a
    /// copy of the trust record sitting where nothing will ever clean it up.
    func testNoTemporaryFilesAreLeftBehind() throws {
        let s = store()
        XCTAssertTrue(s.write([1, 2, 3]))
        XCTAssertTrue(s.write([4, 5, 6]))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.sorted(), ["record"], "found: \(contents)")
    }

    /// **THE ATOMICITY ASSERTION.** A reader that runs between the two writes sees one whole record
    /// or the other, never a prefix. Exercised by interleaving a reader with writes of DIFFERENT
    /// lengths, which is the shape a truncation would show up in.
    func testAReaderNeverSeesAPartialRecord() throws {
        let s = store()
        let short = try XCTUnwrap(E2ETrustStore.encode(E2ETrustStore.Record()))
        let long = try XCTUnwrap(E2ETrustStore.encode(E2ETrustStore.Record(
            root: Array(repeating: 7, count: 200), bundle: Array(repeating: 8, count: 2000),
            revokedDeviceIDs: Set((0 ..< 40).map { Array(repeating: UInt8($0), count: 32) }))))
        XCTAssertNotEqual(short.count, long.count)
        XCTAssertTrue(s.write(long))

        let done = expectation(description: "writes")
        let reader = expectation(description: "reads")
        var partials = 0
        var reads = 0

        DispatchQueue.global().async {
            for i in 0 ..< 200 { _ = s.write(i % 2 == 0 ? short : long) }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0 ..< 400 {
                guard let bytes = s.read() else { continue }
                reads += 1
                // Every read must decode. A prefix of either record would not.
                if E2ETrustStore.decode(bytes) == nil { partials += 1 }
            }
            reader.fulfill()
        }
        wait(for: [done, reader], timeout: 30)
        XCTAssertGreaterThan(reads, 0, "the reader has to have read something")
        XCTAssertEqual(partials, 0, "\(partials) of \(reads) reads saw a partial record")
    }

    func testDeleteRemovesItAndDeletingNothingSucceeds() {
        let s = store()
        XCTAssertTrue(s.write([1]))
        XCTAssertTrue(s.delete())
        XCTAssertNil(s.read())
        // Already absent is the outcome the caller asked for.
        XCTAssertTrue(s.delete())
    }

    func testTheFileIsNotWorldReadable() throws {
        let s = store()
        XCTAssertTrue(s.write([1, 2, 3]))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("record").path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        // Not secret — §10.2 keeps only the keys in the keychain — but there is no reason for
        // another user on the machine to read which devices this one trusts.
        XCTAssertEqual(mode & 0o077, 0, "mode was \(String(mode, radix: 8))")
    }

    /// The manager and this store have to agree about what "nothing" means, because one produces a
    /// fresh identity and the other blocks.
    func testItComposesWithTheIdentityManager() throws {
        let keys = InstallationStore.Memory()
        let trustFile = store("trust")
        let manager = E2EIdentityManager(installations: keys, trust: trustFile)

        guard case .success(let fresh) = manager.load() else { return XCTFail("load") }
        XCTAssertEqual(fresh.state, .unenrolled)

        guard case .success = manager.revoke(deviceID: Array(repeating: 3, count: 32),
                                             in: fresh.record) else { return XCTFail("revoke") }
        guard case .success(let reloaded) = manager.load() else { return XCTFail("reload") }
        XCTAssertTrue(reloaded.record.revokedDeviceIDs.contains(Array(repeating: 3, count: 32)))

        // And a file that is not a record blocks rather than looking like a fresh device.
        XCTAssertTrue(trustFile.write(Array("not a record".utf8)))
        guard case .success(let blocked) = manager.load() else { return XCTFail("load") }
        XCTAssertEqual(blocked.state, .blocked(.unreadableTrust))
    }
}
