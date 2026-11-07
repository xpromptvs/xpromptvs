// host/RdevCore/Sources/RdevCore/SdpMunge.swift
import Foundation

/// Pure SDP string transforms for low-latency video. Kept here (not in RdevHost's PeerSession) so
/// they're unit-testable. PeerSession composes these into its offer-munge chain after forceH264.
public enum SdpMunge {
    private static let playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
    private static let colorSpaceURI = "http://www.webrtc.org/experiments/rtp-hdrext/color-space"

    private static func sep(_ sdp: String) -> String { sdp.contains("\r\n") ? "\r\n" : "\n" }

    /// Negotiate the playout-delay RTP header extension on the m=video section (no-op if already
    /// present). This adds the `a=extmap` line required by the extension; it does NOT set min/max
    /// playout delay — those values are carried per-packet by libwebrtc and the receiver-side floor
    /// is controlled via `RTCRtpReceiver.playoutDelayHint`, not encoded in SDP. Uses an extmap id
    /// not already in use.
    public static func addPlayoutDelay(_ sdp: String) -> String {
        if sdp.contains(playoutDelayURI) { return sdp }
        let s = sep(sdp)
        var lines = sdp.components(separatedBy: s)
        guard let mIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }
        var used = Set<Int>()
        for l in lines where l.hasPrefix("a=extmap:") {
            if let id = Int(l.dropFirst("a=extmap:".count).prefix { $0.isNumber }) { used.insert(id) }
        }
        let id = (1...14).first { !used.contains($0) } ?? 13
        // insert just after the m=video line's first extmap (or right after the m= line)
        let insertAt = (lines[mIdx...].firstIndex { $0.hasPrefix("a=extmap:") }) ?? (mIdx + 1)
        lines.insert("a=extmap:\(id) \(playoutDelayURI)", at: insertAt)
        return lines.joined(separator: s)
    }

    /// Drop RED/ULPFEC/FlexFEC: remove their payload types from the m=video line and their a= lines.
    public static func stripFec(_ sdp: String) -> String {
        let s = sep(sdp)
        var lines = sdp.components(separatedBy: s)
        guard let mIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }
        let fecNames: Set<String> = ["RED", "ULPFEC", "FLEXFEC-03"]
        var fecPTs = Set<String>()
        for l in lines where l.hasPrefix("a=rtpmap:") {
            let rest = l.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
            if rest.count == 2, let name = rest[1].split(separator: "/").first,
               fecNames.contains(name.uppercased()) { fecPTs.insert(String(rest[0])) }
        }
        guard !fecPTs.isEmpty else { return sdp }
        let fields = lines[mIdx].split(separator: " ").map(String.init)
        let head = Array(fields[0 ..< 3]), pts = Array(fields[3...]).filter { !fecPTs.contains($0) }
        lines[mIdx] = (head + pts).joined(separator: " ")
        lines = lines.filter { line in
            for p in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] where line.hasPrefix(p) {
                if fecPTs.contains(String(line.dropFirst(p.count).prefix { $0.isNumber })) { return false }
            }
            return true
        }
        return lines.joined(separator: s)
    }

    /// Remove the color-space header extension (advertising it can push Chrome into software decode).
    public static func stripColorSpace(_ sdp: String) -> String {
        let s = sep(sdp)
        return sdp.components(separatedBy: s)
            .filter { !($0.hasPrefix("a=extmap:") && $0.contains(colorSpaceURI)) }
            .joined(separator: s)
    }

    /// Force Constrained Baseline (profile-level-id=42e01f) + packetization-mode=1 on every H264 fmtp.
    public static func pinH264Baseline(_ sdp: String) -> String {
        let s = sep(sdp)
        var lines = sdp.components(separatedBy: s)
        var h264PTs = Set<String>()
        for l in lines where l.hasPrefix("a=rtpmap:") {
            let rest = l.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
            if rest.count == 2, let name = rest[1].split(separator: "/").first,
               name.uppercased() == "H264" { h264PTs.insert(String(rest[0])) }
        }
        for i in lines.indices where lines[i].hasPrefix("a=fmtp:") {
            let pt = String(lines[i].dropFirst("a=fmtp:".count).prefix { $0.isNumber })
            guard h264PTs.contains(pt) else { continue }
            var params = lines[i].split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            params = params.split(separator: ";").map(String.init).filter {
                !$0.hasPrefix("profile-level-id") && !$0.hasPrefix("packetization-mode")
            }.joined(separator: ";")
            var kv = ["profile-level-id=42e01f", "packetization-mode=1"]
            if !params.isEmpty { kv.append(params) }
            lines[i] = "a=fmtp:\(pt) " + kv.joined(separator: ";")
        }
        return lines.joined(separator: s)
    }
}
