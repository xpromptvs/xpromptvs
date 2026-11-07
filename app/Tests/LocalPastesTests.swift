import Foundation
import ShellstormCore
import XCTest

final class LocalPastesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPastesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ text: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func testFilesClassifiesFoldersAndFilesInOrderAndDropsWhatIsNotThere() throws {
        try write("My Projects/a.txt", "a")
        try write("notes.txt", "n")
        let urls = [root.appendingPathComponent("My Projects"), URL(string: "https://example.com/x")!,
                    root.appendingPathComponent("notes.txt"), root.appendingPathComponent("gone")]
        let out = LocalPastes.files(urls)
        XCTAssertEqual(out.map(\.name), ["My Projects", "notes.txt"])
        XCTAssertEqual(out.map(\.isDirectory), [true, false])
        XCTAssertEqual(out[0].path, root.appendingPathComponent("My Projects").standardizedFileURL.path)
        XCTAssertEqual(out[0].json["dir"] as? Bool, true)
    }

    func testZipMakesFinderStyleArchiveWithTheFolderAsItsOneTopLevelEntry() throws {
        try write("Proj/src/main.swift", "print(1)")
        try write("Proj/README", "hello")
        let zip = try LocalPastes.zip(folder: root.appendingPathComponent("Proj"), into: root.appendingPathComponent("out"))
        // A FIXED name on disk: `<name>.zip` passes NAME_MAX for a folder name of 252 bytes or more. The name the
        // page shows is the registry's (`PreparedPastes.add(name:)`).
        XCTAssertEqual(zip.lastPathComponent, "archive.zip")
        let back = root.appendingPathComponent("back")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, back.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let top = try FileManager.default.contentsOfDirectory(atPath: back.path).filter { $0 != "__MACOSX" }
        XCTAssertEqual(top, ["Proj"])
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("Proj/src/main.swift"), encoding: .utf8), "print(1)")
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("Proj/README"), encoding: .utf8), "hello")
    }

    func testZipOfAMissingFolderThrowsAndLeavesNoArchive() {
        let out = root.appendingPathComponent("out")
        XCTAssertThrowsError(try LocalPastes.zip(folder: root.appendingPathComponent("nope"), into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("archive.zip").path))
    }

    /// Random bytes do not compress: a folder of `n` of them zips to about `n`.
    private func incompressible(_ rel: String, _ n: Int) throws {
        var bytes = Data(count: n)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, n) }
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: u)
    }

    /// A folder that would zip past the cap is STOPPED as its archive passes it — never zipped whole first (a
    /// 40 GB folder, the boot volume, would write until done) — and leaves nothing behind.
    func testAZipPastItsLimitIsStoppedAndLeavesNothing() throws {
        try incompressible("Big/a.bin", 3 * 1024 * 1024)
        let out = root.appendingPathComponent("out")
        XCTAssertThrowsError(try LocalPastes.zip(folder: root.appendingPathComponent("Big"), into: out, limit: 512 * 1024)) {
            XCTAssertEqual($0 as? LocalPastes.ZipError, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("archive.zip").path))
    }

    /// ...and it is stopped AS IT PASSES the limit, not after: well under the time the whole zip takes.
    func testABigZipIsCutShortNotFinishedFirst() throws {
        try incompressible("Long/a.bin", 40 * 1024 * 1024)
        var t0 = Date()
        _ = try LocalPastes.zip(folder: root.appendingPathComponent("Long"), into: root.appendingPathComponent("whole"))
        let whole = Date().timeIntervalSince(t0)
        t0 = Date()
        XCTAssertThrowsError(try LocalPastes.zip(folder: root.appendingPathComponent("Long"), into: root.appendingPathComponent("cut"),
                                                 limit: 1024 * 1024)) { XCTAssertEqual($0 as? LocalPastes.ZipError, .tooLarge) }
        let cut = Date().timeIntervalSince(t0)
        XCTAssertLessThan(cut, whole / 2, "stopped at the limit (\(cut) s) — not zipped whole (\(whole) s) and then refused")
    }

    /// A job cancelled while `ditto` runs kills it — Stop sending, the window closing, the app quitting — and one
    /// cancelled before it starts never runs it.
    func testACancelledJobKillsItsZipAndLeavesNothing() throws {
        try incompressible("Slow/a.bin", 40 * 1024 * 1024)
        let out = root.appendingPathComponent("out")
        let job = ZipJob()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { job.cancel() }
        let t0 = Date()
        XCTAssertThrowsError(try LocalPastes.zip(folder: root.appendingPathComponent("Slow"), into: out, job: job)) {
            XCTAssertEqual($0 as? LocalPastes.ZipError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("archive.zip").path))
        let early = ZipJob()
        early.cancel()
        XCTAssertThrowsError(try LocalPastes.zip(folder: root.appendingPathComponent("Slow"), into: out, job: early)) {
            XCTAssertEqual($0 as? LocalPastes.ZipError, .cancelled)
        }
    }

    func testAPreparedFileIsTakenOnceAndOnlyByTheWebViewThatAskedForIt() throws {
        let reg = PreparedPastes()
        let url = reg.add(file: root.appendingPathComponent("x.zip"), name: "My Proj.zip", type: "application/zip",
                          temporary: true, owner: AnyHashable("view-1"))
        XCTAssertTrue(url.hasPrefix("app://client/__paste/"))
        XCTAssertTrue(url.hasSuffix("/My%20Proj.zip"))
        let path = try XCTUnwrap(URL(string: url)?.path(percentEncoded: true))
        let token = try XCTUnwrap(PreparedPastes.token(inPath: path))
        XCTAssertNil(reg.take(token, owner: AnyHashable("view-2")))
        let e = try XCTUnwrap(reg.take(token, owner: AnyHashable("view-1")))
        XCTAssertEqual(e.name, "My Proj.zip")
        XCTAssertEqual(e.type, "application/zip")
        XCTAssertNil(reg.take(token, owner: AnyHashable("view-1")), "once")
    }

    func testTheRouteIsOnlyThePastePrefixWithATokenAndAName() {
        XCTAssertEqual(PreparedPastes.token(inPath: "/__paste/abc/Proj.zip"), "abc")
        XCTAssertNil(PreparedPastes.token(inPath: "/__paste/abc"))
        XCTAssertNil(PreparedPastes.token(inPath: "/__paste//Proj.zip"))
        XCTAssertNil(PreparedPastes.token(inPath: "/index.html"))
        XCTAssertNil(PreparedPastes.token(inPath: "/assets/__paste/abc/x"))
    }

    func testATemporaryArchiveGoesWithItsFolderWhenServedDiscardedOrPurgedAndAPersonsFileNever() throws {
        try write("t1/a.zip", "z")
        try write("t2/b.zip", "z")
        try write("t3/c.zip", "z")
        try write("mine.txt", "keep")
        let reg = PreparedPastes()
        let me = AnyHashable("view")
        let u1 = reg.add(file: root.appendingPathComponent("t1/a.zip"), name: "a.zip", type: "application/zip", temporary: true, owner: me)
        let u2 = reg.add(file: root.appendingPathComponent("t2/b.zip"), name: "b.zip", type: "application/zip", temporary: true, owner: me)
        _ = reg.add(file: root.appendingPathComponent("t3/c.zip"), name: "c.zip", type: "application/zip", temporary: true, owner: AnyHashable("other"))
        let u4 = reg.add(file: root.appendingPathComponent("mine.txt"), name: "mine.txt", type: "text/plain", temporary: false, owner: me)
        let t1 = try XCTUnwrap(PreparedPastes.token(inPath: URL(string: u1)!.path(percentEncoded: true)))
        reg.finished(try XCTUnwrap(reg.take(t1, owner: me)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("t1").path))
        reg.discard(urls: [u2, u4], owner: me)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("t2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mine.txt").path), "a person's own file is never deleted")
        XCTAssertEqual(reg.count, 1)
        reg.purge(owner: me)
        XCTAssertEqual(reg.count, 1, "another window's is not this one's to purge")
        reg.purge()
        XCTAssertEqual(reg.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("t3").path))
    }
}
