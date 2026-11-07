import Foundation

public enum TermClipboard {
    public static let maxBytes = 1_048_576
    public static let chunkBytes = 8192
}

/// A one-shot side effect, never part of a snapshot or replay. Each JSON is below16KiB even at the chunk ceiling.
public func termClipboardJSON(term: TermTabID, epoch: UInt64, copy: String, bytes: Data) -> [Data] {
    guard term.tmuxSession != nil, bytes.count <= TermClipboard.maxBytes,
          String(data: bytes, encoding: .utf8) != nil, !copy.isEmpty, copy.utf8.count <= 128 else { return [] }
    let count = max(1, (bytes.count + TermClipboard.chunkBytes - 1) / TermClipboard.chunkBytes)
    return (0..<count).compactMap { seq in
        let start = seq * TermClipboard.chunkBytes, end = min(start + TermClipboard.chunkBytes, bytes.count)
        return try? JSONSerialization.data(withJSONObject: ["t":"term-clipboard", "term":term.wire,
            "epoch":String(epoch), "copy":copy, "seq":seq, "count":count, "bytes":bytes.count,
            "data":bytes.subdata(in:start..<end).base64EncodedString()])
    }
}
