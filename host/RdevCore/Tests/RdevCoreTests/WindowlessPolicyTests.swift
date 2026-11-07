import XCTest
@testable import RdevCore

/// A WINDOW-LESS client — one whose connection carries no media — may drive the terminal and nothing
/// that acts on windows, the picture or the machine (docs/sources-and-focus.md, "Window-less clients").
/// Every message a client can send, BY ITS WIRE NAME, with its verdict. Each row goes through
/// `parseInbound`, so a row whose JSON stopped parsing fails loudly rather than testing nothing.
final class WindowlessPolicyTests: XCTestCase {
    private static let ansi = (0..<16).map { "\"#0000\(String(format: "%02x", $0))\"" }.joined(separator: ",")

    private static let table: [(json: String, permitted: Bool)] = [
        (#"{"t":"av1-ref-bound","source":"win:1","epoch":"e","trackId":"track"}"#, false),
        (#"{"t":"av1-ref-reset","source":"win:1","epoch":"e","reason":"timestamps-unavailable"}"#, false),
        (#"{"t":"key","data":"a","term":"pty:1"}"#, true),
        (#"{"t":"term-reply","data":"\u001b[0n","term":"pty:1"}"#, true),
        (#"{"t":"claim-control"}"#, true),
        (#"{"t":"resize","cols":80,"rows":24}"#, true),
        (#"{"t":"term-mode","mode":"raw"}"#, true),
        (#"{"t":"terminal-pause"}"#, true),
        (#"{"t":"terminal-resume"}"#, true),
        ("{\"t\":\"term-palette\",\"fg\":\"#ececec\",\"bg\":\"#000000\",\"cursor\":\"#ececec\",\"ansi\":[\(ansi)]}", true),
        (#"{"t":"list-terminals"}"#, true),
        (#"{"t":"open-terminal"}"#, true),
        (#"{"t":"reopen-terminal"}"#, true),
        (#"{"t":"close-terminal","id":"pty:1"}"#, true),
        (#"{"t":"switch-terminal","id":"pty:1"}"#, true),
        (#"{"t":"list-tmux"}"#, true),
        (#"{"t":"open-tmux","session":"$1"}"#, true),
        (#"{"t":"new-tmux"}"#, true),
        (#"{"t":"kill-tmux","session":"$1"}"#, true),
        (#"{"t":"client-hello","prefs":{}}"#, true),
        (#"{"t":"set-prefs","prefs":{}}"#, true),
        // The BAR's order and its names: they arrange the session's bar and touch no window of the Mac —
        // and a window-less client shows no window tabs, so it never names one.
        (#"{"t":"move-tab","tab":"pty:1","before":null}"#, true),
        (#"{"t":"move-tab","tab":"pty:1","before":"win:1"}"#, true),
        (#"{"t":"rename-tab","tab":"pty:1","name":"build"}"#, true),
        (#"{"t":"rename-tab","tab":"tmux:$1","name":"build"}"#, true),
        (#"{"t":"touch","x":0.5,"y":0.5,"phase":"down"}"#, false),
        // A SIMULATOR's touch, text and intents act on a picture a window-less client does not have.
        (#"{"t":"sim-touch","phase":"down","points":[{"x":0.5,"y":0.5}]}"#, false),
        (#"{"t":"sim-text","text":"hi"}"#, false),
        (#"{"t":"sim-action","source":"sim:9B45C574-451C-475D-8498-66BD68AEE17D","action":"home"}"#, false),
        (#"{"t":"hover","x":0.5,"y":0.5}"#, false),
        (#"{"t":"scroll","x":0.5,"y":0.5,"dx":0,"dy":1}"#, false),
        (#"{"t":"scroll-fling","x":0.5,"y":0.5,"vx":0,"vy":1}"#, false),
        (#"{"t":"win-key","down":true,"code":"KeyA"}"#, false),
        (#"{"t":"win-keys-release"}"#, false),
        (#"{"t":"request-thumbs"}"#, false),
        (#"{"t":"list-sources"}"#, false),
        (#"{"t":"subscribe","source":"win:1"}"#, false),
        (#"{"t":"unsubscribe","source":"win:1"}"#, false),
        (#"{"t":"reattach-source","source":"win:1"}"#, false),
        (#"{"t":"minimize-window","source":"win:1"}"#, false),
        (#"{"t":"restore-window","source":"win:1"}"#, false),
        (#"{"t":"set-window-position","source":"win:1","x":10,"y":20}"#, false),
        (#"{"t":"set-view","surface":"windows"}"#, false),
        (#"{"t":"focus-source","source":"win:1"}"#, false),
        (#"{"t":"request-keyframe","source":"win:1"}"#, false),
        (#"{"t":"set-source-prefs","source":"win:1","scale":0.5}"#, false),
        (#"{"t":"set-source-size","source":"win:1","w":800,"h":600}"#, false),
        (#"{"t":"set-recovery","overrideBp":500}"#, false),
        (#"{"t":"set-playout-delay","minMs":10}"#, false),
        (#"{"t":"set-source-audio","source":"win:1","enabled":true}"#, false),
        (#"{"t":"set-visibility","hidden":true}"#, false),
        (#"{"t":"rx-stats","line":"x"}"#, false),
        (#"{"t":"curtain","on":false}"#, false),
        (#"{"t":"paste-begin","id":"p1","to":{"term":"pty:1"},"items":[{"kind":"file","name":"a","type":"","size":1}]}"#, true),
        (#"{"t":"paste-begin","id":"p2","to":{"win":"win:1"},"items":[{"kind":"text","size":1}]}"#, false),
        (#"{"t":"paste-begin","id":"p3","to":{"win":"win:1"},"at":{"x":0.5,"y":0.5},"items":[{"kind":"file","name":"a","type":"","size":1}]}"#, false),
        (#"{"t":"paste-data","id":"p1","item":0,"seq":0,"data":"aGk="}"#, true),
        (#"{"t":"paste-end","id":"p1"}"#, true),
        (#"{"t":"file-get","id":"f1","term":"pty:1","path":"shot.png"}"#, true),
        (#"{"t":"paste-cancel","id":"p1"}"#, true),
    ]

    func testEveryWireMessageIsClassified() throws {
        for row in Self.table {
            let message = try XCTUnwrap(parseInbound(Data(row.json.utf8)), "does not parse: \(row.json)")
            XCTAssertEqual(WindowlessPolicy.permits(message), row.permitted, row.json)
        }
    }
}
