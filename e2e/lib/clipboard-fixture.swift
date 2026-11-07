// Private check helper. Keeps the original pasteboard's flavours in RAM, never stdout or disk.
import AppKit
import Foundation

let board = NSPasteboard.general
let originalCount = board.changeCount
let original = (board.pasteboardItems ?? []).map { item in
    item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
        item.data(forType: type).map { (type, $0) }
    }
}
var ownedCount: Int?
func restore() -> Bool {
    if board.changeCount == originalCount { return true }
    guard let ownedCount, board.changeCount == ownedCount else { return false }
    board.clearContents()
    let items = original.map { flavours in
        let item = NSPasteboardItem()
        for (type, data) in flavours { item.setData(data, forType: type) }
        return item
    }
    return items.isEmpty || board.writeObjects(items)
}
func answer(_ value: [String: Bool]) {
    let data = try! JSONSerialization.data(withJSONObject: value)
    print(String(decoding: data, as: UTF8.self)); fflush(stdout)
}
answer(["ready": true])
defer { _ = restore() }
while let line = readLine(), let data = line.data(using: .utf8),
      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if request["restore"] as? Bool == true { answer(["restored": restore()]); break }
    guard let encoded = request["expected"] as? String, let expected = Data(base64Encoded: encoded) else { continue }
    let matches = board.string(forType: .string).map { Data($0.utf8) == expected } ?? false
    if matches { ownedCount = board.changeCount }
    answer(["matches": matches])
}
