import Foundation

/// The playout-delay FLOOR a client may ask for, in milliseconds.
///
/// WHAT THE FLOOR IS FOR. The playout-delay header extension carries two bounds. The MAXIMUM only
/// PERMITS a receiver to buffer; the MINIMUM FORCES it to. That distinction is the whole reason this
/// control exists: WebKit honours the sender's extension over the page's own `jitterBufferTarget`, so
/// on Safari neither the ceiling nor the receiver-side request can make it hold anything. Measured on
/// an iPhone — ceiling raised to 200 ms and `jitterBufferTarget` set to 100 and then 200, and `jbuf`
/// never left 0.1-1.9 ms. Only the floor moved it.
///
/// The product starts with a 20 ms floor; its smooth-video toggle requests 100 ms.
/// Explicit diagnostic requests still support the full range, including zero.
public let defaultPlayoutDelayMinMs = 20
public let maximumPlayoutDelayMinMs = 500

/// Clamp a requested floor into range. nil passes through as nil, which is Auto — a DIFFERENT
/// setting from a forced 0, even though the two behave alike until an adaptive mode exists.
public func clampPlayoutDelayMinMs(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    return min(max(raw, 0), maximumPlayoutDelayMinMs)
}
