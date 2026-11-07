import type { WinKeyWire } from "./keys";
import type { Mod } from "./held-mods";

/// The window half of the on-screen key strip: which keys exist, and how a strip press or a
/// soft-keyboard character becomes `{t:"win-key"}`. No new message type — the host's
/// `planKeyInjection` already maps every code used here.

export interface WinKeyDef {
  id: string; label: string; aria: string; kind: "key";
  /// A W3C `code` name. MUST be one `macVirtualKeys` knows, or the host drops it as "unmapped code".
  code: string;
  /// The `key` value. For a named key this is the name; the host uses it only for the unicode
  /// override, which a named key never triggers (it is more than one scalar).
  key: string;
  repeat?: boolean;
}
export interface WinModDef { id: string; label: string; aria: string; kind: "mod"; mod: Mod }
export type WinStripDef = WinKeyDef | WinModDef;

const key = (id: string, label: string, aria: string, code: string, k: string,
             repeat = false): WinKeyDef => ({ id, label, aria, kind: "key", code, key: k, repeat });
const mod = (id: string, label: string, aria: string, m: Mod): WinModDef =>
  ({ id, label, aria, kind: "mod", mod: m });

export const WINDOW_KEYS: readonly WinStripDef[] = [
  key("esc", "Esc", "Escape", "Escape", "Escape"),
  key("tab", "Tab", "Tab", "Tab", "Tab"),
  mod("ctrl", "Ctrl", "Control", "ctrl"),
  mod("alt", "⌥", "Option", "alt"),
  mod("meta", "⌘", "Command", "meta"),
  mod("shift", "⇧", "Shift", "shift"),
  key("left", "←", "Left", "ArrowLeft", "ArrowLeft", true),
  key("down", "↓", "Down", "ArrowDown", "ArrowDown", true),
  key("up", "↑", "Up", "ArrowUp", "ArrowUp", true),
  key("right", "→", "Right", "ArrowRight", "ArrowRight", true),
];

export const WINDOW_KEYS_MORE: readonly WinStripDef[] = [
  key("home", "Home", "Home", "Home", "Home"),
  key("end", "End", "End", "End", "End"),
  key("pgup", "PgUp", "Page Up", "PageUp", "PageUp", true),
  key("pgdn", "PgDn", "Page Down", "PageDown", "PageDown", true),
  // W3C "Delete" is FORWARD delete (mac keycode 117). Backspace is on the soft keyboard already.
  key("del", "Del", "Forward Delete", "Delete", "Delete"),
  ...Array.from({ length: 12 }, (_, i) =>
    key(`f${i + 1}`, `F${i + 1}`, `F${i + 1}`, `F${i + 1}`, `F${i + 1}`)),
];

/// Left-hand physical codes for each modifier. `planKeyInjection` maps all eight left/right codes and
/// returns `.flagsChanged` for any of them; left is the conventional choice and nothing distinguishes
/// them once the flags are set.
export const MOD_CODES: Record<Mod, { code: string; key: string }> = {
  shift: { code: "ShiftLeft", key: "Shift" },
  ctrl: { code: "ControlLeft", key: "Control" },
  alt: { code: "AltLeft", key: "Alt" },
  meta: { code: "MetaLeft", key: "Meta" },
};

const LETTERS = "abcdefghijklmnopqrstuvwxyz";
const PUNCT: Record<string, string> = {
  " ": "Space", "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight",
  "\\": "Backslash", ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period",
  "/": "Slash", "`": "Backquote",
};

/// The physical `code` a character sits on, or "" when unknown.
///
/// LOAD-BEARING — this NEVER infers Shift from case. `planKeyInjection` drops the unicode override
/// when ⌘ or ⌃ is present and goes keycode-only, so "C" + meta must resolve to KeyC with no shift
/// bit, or ⌘C silently becomes ⌘⇧C. With no ⌘/⌃ the override types the character exactly as sent,
/// so the case is already carried by `key`. Shift reaches the host only from the strip's ⇧.
///
/// "" for an unknown character is not a failure: the host types it through the unicode override on
/// keycode 0, which is the documented behaviour for an unmapped physical key that produced a
/// character. It is also why a shifted symbol like "!" is left unmapped — "Digit1" would be a lie
/// about which key was pressed, and the override types "!" correctly anyway.
export function charToCode(ch: string): string {
  if (ch.length !== 1) return "";
  const lower = ch.toLowerCase();
  if (LETTERS.includes(lower)) return `Key${lower.toUpperCase()}`;
  if (lower >= "0" && lower <= "9") return `Digit${lower}`;
  return PUNCT[ch] ?? "";
}

const wire = (down: boolean, code: string, k: string, mods: number): WinKeyWire =>
  ({ t: "win-key", down, code, key: k, repeat: false, mods });

/// A strip key press: down then up, both carrying the latched mask. Two messages rather than one
/// because the host posts a real keyDown and keyUp, and an app that watches for the release (a
/// key-repeat guard, a modal dismiss) sees nothing from a down alone.
export function winKeyMessages(def: WinKeyDef, mask: number): WinKeyWire[] {
  return [wire(true, def.code, def.key, mask), wire(false, def.code, def.key, mask)];
}

/// One character from the soft keyboard, via `beforeinput`.
export function charMessages(ch: string, mask: number): WinKeyWire[] {
  const code = charToCode(ch);
  return [wire(true, code, ch, mask), wire(false, code, ch, mask)];
}

/// A modifier arming or clearing.
///
/// THIS IS WHAT MAKES ⌘-CLICK WORK. `planKeyInjection` returns `.flagsChanged` for a modifier code,
/// and `WindowInputInjector.key` assigns `currentFlags` from the message's own `mods` — which
/// `inject(touch…)` and `move(…)` then stamp onto every mouse event. Without this message the
/// modifier would apply to keystrokes only, and ⇧-click / ⌘-click / ⌥-drag would stay unreachable
/// from a touchscreen.
export function modifierMessage(m: Mod, down: boolean, mask: number): WinKeyWire {
  const { code, key: k } = MOD_CODES[m];
  return wire(down, code, k, mask);
}
