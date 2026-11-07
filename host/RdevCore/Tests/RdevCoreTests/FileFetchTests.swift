import XCTest
@testable import RdevCore

/// AN IMAGE PATH IN THE TERMINAL OPENS ON THE CLIENT, the wire and its rules (docs/terminal.md, "An image path opens on
/// the client"): what a `file-get` must be, how a printed path becomes an absolute one, which files are images, and
/// what the host answers with.
final class FileFetchTests: XCTestCase {
    private func parse(_ s: String) -> FileGet? {
        guard case .fileGet(let g)? = parseInbound(Data(s.utf8)) else { return nil }
        return g
    }

    func testAFileGetIsParsed() {
        XCTAssertEqual(parse(#"{"t":"file-get","id":"f1","term":"tmux:$4","path":"shots/a b.png"}"#),
                       FileGet(id: "f1", term: .tmux("$4"), path: "shots/a b.png"))
        for s in [#"{"t":"file-get","term":"pty:1","path":"a.png"}"#,
                  #"{"t":"file-get","id":"f 1","term":"pty:1","path":"a.png"}"#,
                  #"{"t":"file-get","id":"f1","term":"1","path":"a.png"}"#,
                  #"{"t":"file-get","id":"f1","term":"pty:1","path":""}"#,
                  #"{"t":"file-get","id":"f1","term":"pty:1"}"#,
                  #"{"t":"file-get","id":"f1","term":"pty:1","path":"a\u0000.png"}"#] {
            XCTAssertNil(parse(s), s)
        }
        XCTAssertNil(parse(#"{"t":"file-get","id":"f1","term":"pty:1","path":"\#(String(repeating: "a", count: 4097))"}"#), "over the cap")
    }

    func testAPrintedPathResolves() {
        let home = "/Users/me", dir = "/Users/me/code"
        XCTAssertEqual(FileFetch.resolve("/tmp/a.png", directory: dir, home: home), "/tmp/a.png")
        XCTAssertEqual(FileFetch.resolve("~/Desktop/a.png", directory: dir, home: home), "/Users/me/Desktop/a.png")
        XCTAssertEqual(FileFetch.resolve("shots/a.png", directory: dir, home: home), "/Users/me/code/shots/a.png")
        XCTAssertEqual(FileFetch.resolve("./a.png", directory: dir, home: home), "/Users/me/code/a.png")
        XCTAssertEqual(FileFetch.resolve("../other/a.png", directory: dir, home: home), "/Users/me/other/a.png")
        XCTAssertNil(FileFetch.resolve("a.png", directory: nil, home: home), "relative, with no directory to be relative to")
        XCTAssertNil(FileFetch.resolve("a.png", directory: "code", home: home), "a directory that is not absolute is none")
    }

    func testWhichFilesAreImages() {
        XCTAssertEqual(FileFetch.kind(ofPath: "/a/Shot.PNG"), .shown(mime: "image/png"))
        XCTAssertEqual(FileFetch.kind(ofPath: "a.jpeg"), .shown(mime: "image/jpeg"))
        XCTAssertEqual(FileFetch.kind(ofPath: "IMG_1.HEIC"), .converted)
        XCTAssertEqual(FileFetch.kind(ofPath: "scan.tif"), .converted)
        for p in ["notes.txt", "png", "a.png.bak", "Makefile"] { XCTAssertEqual(FileFetch.kind(ofPath: p), .none, p) }
    }

    func testTheAnswersShapes() throws {
        func obj(_ d: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any]) }
        let begin = try obj(FileFetch.beginJSON(id: "f1", name: "a.png", mime: "image/png", size: 3, path: "/x/a.png"))
        XCTAssertEqual(begin as NSDictionary, ["t": "file-begin", "id": "f1", "name": "a.png", "mime": "image/png", "size": 3, "path": "/x/a.png"])
        let data = try obj(FileFetch.dataJSON(id: "f1", seq: 2, bytes: Data([1, 2, 255])))
        XCTAssertEqual(data["seq"] as? Int, 2)
        XCTAssertEqual(Data(base64Encoded: data["data"] as? String ?? ""), Data([1, 2, 255]))
        XCTAssertEqual(try obj(FileFetch.endJSON(id: "f1")) as NSDictionary, ["t": "file-end", "id": "f1"])
        XCTAssertEqual(try obj(FileFetch.errorJSON(id: "f1", reason: .notFound)) as NSDictionary,
                       ["t": "file-error", "id": "f1", "reason": "not-found"])
    }
}
