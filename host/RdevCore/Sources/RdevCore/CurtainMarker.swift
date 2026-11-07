import Foundation

/// Identity stamp carried by every CGEvent rdev's window injector posts, set once on the injector's
/// `CGEventSource` via `CGEventSourceSetUserData` and read back at the curtain's event tap via the
/// event's `.eventSourceUserData` field.
///
/// The curtain (screen blackout + local-input lockout) runs a `.cghidEventTap` that SWALLOWS every
/// event EXCEPT those carrying this value — so the local keyboard/trackpad go dead while rdev's own
/// injected input passes straight through. The two sides MUST agree on this constant, which is why it
/// lives here (RdevCore) rather than being duplicated in the injector and the tap.
///
/// Value = ASCII "RDEVIN\0\0" — distinctive in a log, and 0 (the default userData for every other
/// source) can never collide with it.
public let curtainInputMarker: Int64 = 0x5244_4556_494E_5000
