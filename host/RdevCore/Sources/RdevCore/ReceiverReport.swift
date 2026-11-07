import Foundation

/// A receiver-side diagnostic line, rendered by the CLIENT and printed verbatim by the host.
///
/// THE CLIENT IS THE ONLY SOURCE OF THESE NUMBERS. They are its own `getStats()` counters —
/// packetsLost, framesDecoded, jitterBufferMs — and the host has no independent view to reconcile
/// them against, so passing the rendered line through is honest rather than lazy. The host prints it
/// under `[rx]` with the client id, so nobody can mistake it for something the host measured.
///
/// IT EXISTS BECAUSE THE INSTRUMENT CANNOT TRAVEL BY CABLE. Attaching Safari's Web Inspector to the
/// device under test brings up a USB network link, ICE finds it, and the media abandons the Wi-Fi
/// path whose jitter is the thing being measured — so connecting the debugger destroys the symptom.
/// Riding the existing control channel keeps the measurement in band, on the path being measured.
public enum ReceiverReport {
    /// The cap is a whole line's worth of counters for several sources, with room to spare, and far
    /// below anything that could bloat a log.
    public static let maxLength = 2048

    /// Sanitise a client-supplied diagnostic line for a host log.
    ///
    /// NEWLINES AND CONTROL CHARACTERS ARE REMOVED, NOT ESCAPED. The host's stdout is a UI — it
    /// carries the pairing code and the QR — and a client-supplied string containing a newline could
    /// forge a line that reads like the host's own (`[bridge] …`). This is a diagnostic path taking
    /// input from whoever holds the pairing code, so the cheap guard is worth having; there is no
    /// case where a control character in a counter line is meaningful.
    ///
    /// Returns nil for anything with nothing left to print, so an empty report logs nothing at all
    /// rather than an empty `[rx]` line.
    public static func sanitize(_ raw: String) -> String? {
        let stripped = String(raw.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
              || scalar.properties.generalCategory == .paragraphSeparator)
        })
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}
