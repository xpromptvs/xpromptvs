/// How a touch is interpreted on this DEVICE.
///
/// `direct` is what rdev has always done: a tap lands where you touched. `trackpad` is indirect —
/// the finger moves a cursor and a tap clicks wherever that cursor is, the way every other
/// remote-desktop phone client works, because a Mac's real UI targets are far below a finger's
/// accuracy at phone scale.
///
/// DEVICE-WIDE, not per-source: the mode is a property of the input device, so switching windows
/// must never change what a touch means. SAVED IN THE DEVICE'S PREFERENCE SET since 2026-09-29
/// (`shared/client-prefs.ts`), beside fps and codec, and sent to the host with them — the value under
/// its old key (`rdev.pointerMode`) is migrated once.
export type PointerMode = "direct" | "trackpad";

/// DIRECT, so an existing session is unchanged and the mode is something you opt into.
export const DEFAULT_POINTER_MODE: PointerMode = "direct";
