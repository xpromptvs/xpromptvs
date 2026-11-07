import AppKit
import XCTest
@testable import RdevHostKit

/// §4.2: the clipboard gets a string, or file URLs — and an image also as PNG and TIFF — then EXACTLY ⌘V.
final class WindowPasteTests: XCTestCase {
    /// THE BYTES OFF MAIN, THE ITEMS ON IT. The PNG and TIFF encodes of a large photo are the slow part and stay
    /// off main (`payload`, built here on a background queue); an `NSPasteboardItem` is an AppKit object and is made
    /// on MAIN (`items`, `@MainActor`), in the turn that writes the pasteboard.
    private func payload(_ content: PasteboardContent) -> [WindowPasteboard.Item] {
        var out: [WindowPasteboard.Item] = []
        let done = expectation(description: "built off main")
        DispatchQueue.global().async { out = WindowPasteboard.payload(for: content); done.fulfill() }
        wait(for: [done], timeout: 5)
        return out
    }

    func testTextIsAString() {
        let p = payload(.text("héllo\nworld"))
        XCTAssertEqual(p, [WindowPasteboard.Item(string: "héllo\nworld")])
        let items = MainActor.assumeIsolated { WindowPasteboard.items(for: p) }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].string(forType: .string), "héllo\nworld")
    }

    func testAFileIsAFileURLAndAnImageIsAlsoPNGAndTIFF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("a.txt"); try Data("x".utf8).write(to: txt)
        let png = dir.appendingPathComponent("b.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let p = payload(.files([txt, png]))
        XCTAssertEqual(p.map(\.fileURL), [txt.absoluteString, png.absoluteString])
        XCTAssertEqual(p.map { $0.png == nil }, [true, false])
        XCTAssertEqual(p.map { $0.tiff == nil }, [true, false])
        let items = MainActor.assumeIsolated { WindowPasteboard.items(for: p) }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .fileURL), txt.absoluteString)
        XCTAssertNil(items[0].data(forType: .png))
        XCTAssertEqual(items[1].string(forType: .fileURL), png.absoluteString)
        XCTAssertEqual(items[1].data(forType: .png), p[1].png)
        XCTAssertEqual(items[1].data(forType: .tiff), p[1].tiff)
    }

    /// ⌘V as a keyboard types it — ⌘ down, V down, V up, ⌘ up — with ⌘ ALONE on every event that holds it, and
    /// nothing held after: the ⌘ released, no other modifier anywhere. MEASURED 2026-10-01: Chromium, front and
    /// focused, ignored the V with only the flag; with the ⌘'s own events around it, it pasted.
    func testThePasteShortcutIsCommandDownVDownVUpCommandUp() {
        let events = WindowInputInjector.pasteShortcutEvents(source: nil)
        XCTAssertEqual(events.map { $0.type }, [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 9, 9, 55])   // kVK_Command, kVK_ANSI_V
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        XCTAssertEqual(events.map { $0.flags.intersection(mods) }, [.maskCommand, .maskCommand, .maskCommand, []])
    }

    /// A modifier HELD ON THE STRIP stays out of the chord — ⌘⇧V is "paste and match style" — and is put back
    /// by the last event, which is what tells the app which modifiers are down once the ⌘ is up (§4.2).
    func testAModifierHeldOnTheStripIsLeftOutAndPutBackAfter() {
        let events = WindowInputInjector.pasteShortcutEvents(source: nil, restoring: .maskShift)
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        XCTAssertEqual(events.map { $0.flags.intersection(mods) }, [.maskCommand, .maskCommand, .maskCommand, .maskShift])
    }

    func testTheWriteLandsOnAPrivatePasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("rdev-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let done = expectation(description: "written")
        WindowPasteboard.write(.text("abc"), to: pb) { ok in
            XCTAssertTrue(ok); XCTAssertTrue(Thread.isMainThread); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(pb.string(forType: .string), "abc")
    }
}
