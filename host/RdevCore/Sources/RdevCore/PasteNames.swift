import Foundation

/// A SAVED paste's file name (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6):
/// `YYYYMMDD-HHMMSS-<stem>.<ext>`, every character one a shell reads as itself — the path is TYPED.
/// What the device called the file is only a suggestion: it never reaches the disk unmapped.
public enum PasteNames {
    static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars)
    static let mimeExt: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/heif": "heif", "image/tiff": "tiff", "image/bmp": "bmp",
        "application/pdf": "pdf", "text/plain": "txt", "application/zip": "zip", "application/json": "json",
        "video/mp4": "mp4", "video/quicktime": "mov",
    ]

    /// The name's own extension when it is 1–8 of [A-Za-z0-9] (lowercased), else one from the MIME type.
    public static func ext(name: String, type: String) -> String? {
        if let own = ownExt(name) { return own.lowercased() }
        let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mimeExt[mime]
    }

    private static func ownExt(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let e = name[name.index(after: dot)...]
        guard (1...8).contains(e.count), e.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        return String(e)
    }

    /// The name without its (valid) extension, mapped to the safe set: anything else becomes `-`, runs of
    /// `-` collapse, `-` and `.` are trimmed from both ends, at most 48 characters, `paste` when empty.
    public static func stem(_ name: String) -> String {
        var base = Substring(name)
        if ownExt(name) != nil, let dot = name.lastIndex(of: ".") { base = name[..<dot] }
        var out = ""
        for s in base.unicodeScalars {
            let c: Character = safe.contains(s) ? Character(s) : "-"
            if c == "-" && out.last == "-" { continue }
            out.append(c)
        }
        let trim: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }
        out = trim(out)
        if out.count > 48 { out = trim(String(out.prefix(48))) }
        return out.isEmpty ? "paste" : out
    }

    public static func savedName(original: String, type: String, at date: Date, timeZone: TimeZone = .current,
                                 taken: (String) -> Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(f.string(from: date))-\(stem(original))"
        let suffix = ext(name: original, type: type).map { ".\($0)" } ?? ""
        if !taken(base + suffix) { return base + suffix }
        for n in 2...999 where !taken("\(base)-\(n)\(suffix)") { return "\(base)-\(n)\(suffix)" }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())\(suffix)"
    }
}

/// How the host TYPES saved paths into a tab (§4.1): as Terminal.app types a drag — each path followed by
/// a space — and, when the tab's program enabled ?2004, EACH PATH ITS OWN PASTE: measured 2026-10-01 (P3),
/// Claude Code 2.1.286 attaches several paths in one paste but Codex 0.158.0 only one per paste, and Claude
/// Code attaches nothing typed as plain keystrokes.
public enum PasteTyping {
    static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-".unicodeScalars)

    /// As-is when every character is safe (the paste folder's own paths are); single-quoted otherwise.
    public static func quoted(_ path: String) -> String {
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func pieces(paths: [String]) -> [String] {
        paths.map { quoted($0) + " " }
    }

    public static func asPastes(_ pieces: [String], bracketed: Bool) -> String {
        bracketed ? pieces.map { "\u{1b}[200~" + $0 + "\u{1b}[201~" }.joined() : pieces.joined()
    }
}
