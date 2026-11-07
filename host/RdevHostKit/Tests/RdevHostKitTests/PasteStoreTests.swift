import CoreGraphics
import ImageIO
import XCTest
import RdevCore
@testable import RdevHostKit

/// The paste folder (§6): private, written under a partial name, emptied at launch and quit, swept.
final class PasteStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("paste-store-\(UUID().uuidString)/Pastes")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testLaunchMakesAPrivateEmptyFolder() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("left by a crash".utf8).write(to: dir.appendingPathComponent("old.png"))
        try Data().write(to: dir.appendingPathComponent(".x.partial"))
        let store = PasteStore(directory: dir)
        store.prepareAtLaunch()
        XCTAssertEqual(try listing(), [])
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testAFileIsPartialUntilCommittedThenPrivateUnderItsSavedName() throws {
        let store = PasteStore(directory: dir, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        store.prepareAtLaunch()
        let f = try store.open(name: "IMG 1.png", type: "image/png")
        try f.append(Data("ab".utf8)); try f.append(Data("c".utf8))
        let during = try listing()
        XCTAssertEqual(during.count, 1)
        XCTAssertTrue(during[0].hasPrefix("."), "visible before it is whole: \(during)")
        let url = try store.commit(f)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-IMG-1.png"), url.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: url), Data("abc".utf8))
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try listing(), [url.lastPathComponent])
    }

    func testTwoFilesWithOneNameInOneSecondDoNotCollide() throws {
        let store = PasteStore(directory: dir, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        store.prepareAtLaunch()
        let a = try store.open(name: "a.png", type: "image/png")
        let b = try store.open(name: "a.png", type: "image/png")      // opened before a is committed
        try a.append(Data([1])); try b.append(Data([2]))
        XCTAssertNotEqual(try store.commit(a), try store.commit(b))
    }

    /// TWO NAMES THAT DIFFER ONLY IN CASE ARE TWO FILES. APFS (the default volume) is case-INSENSITIVE, so
    /// `…-Photo.png` and `…-photo.png` are one file there: both partials were one file, the first commit took the
    /// second's bytes and the second commit threw — `disk`, and the whole delivery deleted. The second gets `-2`,
    /// on any volume: the names must differ ignoring case, not merely as strings.
    func testNamesThatDifferOnlyInCaseAreTwoFiles() throws {
        let store = PasteStore(directory: dir, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        store.prepareAtLaunch()
        let a = try store.open(name: "Photo.PNG", type: "image/png")
        let b = try store.open(name: "photo.png", type: "image/png")       // one delivery: both still arriving
        try a.append(Data("first".utf8)); try b.append(Data("second".utf8))
        XCTAssertNotEqual(a.finalURL.lastPathComponent.lowercased(), b.finalURL.lastPathComponent.lowercased())
        let ua = try store.commit(a), ub = try store.commit(b)
        XCTAssertEqual(try Data(contentsOf: ua), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: ub), Data("second".utf8))
        XCTAssertTrue(ub.lastPathComponent.hasSuffix("-photo-2.png"), ub.lastPathComponent)
        XCTAssertEqual(try listing().count, 2)
        // A file the host derives takes a name free of a case-variant still arriving, too.
        let held = try store.open(name: "Shot.heic", type: "image/heic")
        let stem = String(held.finalURL.lastPathComponent.dropLast(".heic".count))
        let derived = store.sibling(of: dir.appendingPathComponent(stem.lowercased() + ".heic"), ext: "heic")
        XCTAssertEqual(derived.lastPathComponent, stem.lowercased() + "-2.heic")
        store.discard(held)
    }

    func testDiscardLeavesNothing() throws {
        let store = PasteStore(directory: dir); store.prepareAtLaunch()
        let f = try store.open(name: "a", type: ""); try f.append(Data([1]))
        store.discard(f)
        XCTAssertEqual(try listing(), [])
    }

    func testQuitEmptiesTheFolder() throws {
        let store = PasteStore(directory: dir); store.prepareAtLaunch()
        let f = try store.open(name: "a", type: ""); try f.append(Data([1])); _ = try store.commit(f)
        store.emptyAll()
        XCTAssertEqual(try listing(), [])
    }

    func testTheSweepDeletesWhatTheRuleNames() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let store = PasteStore(directory: dir, now: { clock }); store.prepareAtLaunch()
        let old = try store.open(name: "old", type: ""); try old.append(Data([1])); let oldURL = try store.commit(old)
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-25 * 3600)], ofItemAtPath: oldURL.path)
        clock = clock.addingTimeInterval(1)
        let young = try store.open(name: "young", type: ""); try young.append(Data([1])); let youngURL = try store.commit(young)
        store.sweep(keep: youngURL)
        XCTAssertEqual(try listing(), [youngURL.lastPathComponent])
    }

    /// A file the host DERIVES from a saved one (a HEIC's JPEG, §4.1) takes a free name beside it: free of
    /// what is on disk AND of every name handed out to a file still being received.
    func testASiblingNameIsFreeOfFilesAndOfNamesHandedOut() throws {
        let store = PasteStore(directory: dir, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        store.prepareAtLaunch()
        let heic = dir.appendingPathComponent("20260921-141320-IMG.heic")
        XCTAssertEqual(store.sibling(of: heic, ext: "jpg").lastPathComponent, "20260921-141320-IMG.jpg")
        try Data([1]).write(to: dir.appendingPathComponent("20260921-141320-IMG.jpg"))
        XCTAssertEqual(store.sibling(of: heic, ext: "jpg").lastPathComponent, "20260921-141320-IMG-2.jpg")
        // A file still arriving holds its name before anything exists under it.
        let inFlight = try store.open(name: "x.jpg", type: "")
        let held = inFlight.finalURL.lastPathComponent
        let derived = store.sibling(of: dir.appendingPathComponent(String(held.dropLast(".jpg".count)) + ".heic"), ext: "jpg")
        XCTAssertEqual(derived.lastPathComponent, String(held.dropLast(".jpg".count)) + "-2.jpg")
        XCTAssertEqual(derived.deletingLastPathComponent().path, dir.path)
        store.discard(inFlight)
    }

    func testTheDefaultFolderHasNoSpace() {
        let d = PasteStore.defaultDirectory(bundleID: "dev.rdev.host")
        XCTAssertTrue(d.path.hasSuffix("/Library/Caches/dev.rdev.host/Pastes"), d.path)
        XCTAssertFalse(d.path.contains(" "))
    }

    func testAHEICBecomesAJPEG() throws {
        // A 2×2 HEIC made with ImageIO, so the test needs no fixture file.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let heic = dir.appendingPathComponent("a.heic")
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("this Mac cannot encode HEIC") }
        XCTAssertTrue(PasteImages.isHEIC(type: "image/heic", name: "a.heic"))
        XCTAssertTrue(PasteImages.isHEIC(type: "", name: "A.HEIF"))
        XCTAssertFalse(PasteImages.isHEIC(type: "image/png", name: "a.png"))
        let jpg = dir.appendingPathComponent("a.jpg")
        XCTAssertTrue(PasteImages.jpeg(fromHEIC: heic, to: jpg))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "public.jpeg")
        XCTAssertTrue(PasteImages.isImage(jpg))
        XCTAssertNotNil(PasteImages.png(jpg))
    }
}
