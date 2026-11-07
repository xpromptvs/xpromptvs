import Foundation
import RdevCore

/// One native source of fixtures; readers independently validate the wire and raw bytes.
public enum TermZstdVectors {
    public static func json() throws -> Data {
        let encoder = try TermZstdEncoder()
        let size = TermGridSize(cols: 80, rows: 24)
        let records: [(String, Data)] = [
            ("bootstrap", Data(0..<32)),
            ("screen-a", TermFrame(kind: .screenEnd, tab: "pty:1", size: size, payload: Array("hello".utf8)).encoded()),
            ("screen-b", TermFrame(kind: .snapshotEnd, tab: "pty:2", size: size, payload: Array("world".utf8)).encoded()),
            ("tiny-a", TermFrame(kind: .output, tab: "pty:1", size: nil, payload: [33]).encoded()),
            ("utf8-a-head", TermFrame(kind: .output, tab: "pty:1", size: nil, payload: [0xe4]).encoded()),
            ("output-b", TermFrame(kind: .output, tab: "pty:2", size: nil, payload: [66]).encoded()),
            ("utf8-a-tail", TermFrame(kind: .output, tab: "pty:1", size: nil, payload: [0xb8, 0xad]).encoded()),
            ("history-a", TermFrame(kind: .historyEnd, tab: "pty:1", size: size, payload: Array("history\r\nhello".utf8)).encoded()),
            ("close-b", TermFrame(kind: .closed, tab: "pty:2", size: nil, payload: []).encoded()),
        ]
        let rows = try records.map { name, raw in
            ["name": name, "raw": raw.base64EncodedString(), "compressed": try encoder.flush(raw).base64EncodedString()]
        }
        var json = try JSONSerialization.data(withJSONObject: ["version": 1, "zstd": "1.5.7", "records": rows], options: [.sortedKeys, .prettyPrinted])
        json.append(10)
        return json
    }
}
