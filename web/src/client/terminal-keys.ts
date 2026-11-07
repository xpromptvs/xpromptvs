import type { Mod } from "./held-mods";

/// The terminal half of the on-screen key strip: which keys exist, and what bytes each one puts on
/// `{t:"key",data,term}` — the SAME message xterm's own onData sends, through the same `sendKey`, so
/// the host learns nothing new and the strip cannot address a different tab than the picture does.
///
/// ⌘ is absent because it means nothing to a PTY. ⇧ is HERE (2026-09-28): the soft keyboard sends no
/// Shift at all, and Shift+Tab (Claude Code's mode cycle), Shift+arrows and Shift+Return are real
/// chords. It was left out once on the argument that the soft keyboard already produces capitals —
/// true of letters and of nothing else.

export interface TermKeyDef {
  id: string; label: string; aria: string; kind: "key";
  /// Literal bytes. Mutually exclusive with `csi`.
  bytes?: string;
  /// A CSI final byte ("A", "H", …) routed through cursor-key mode. See `csiBytes`.
  csi?: string;
  /// Press-and-hold auto-repeats. Only navigation keys — a repeating Esc is a hazard.
  repeat?: boolean;
}
export interface TermModDef { id: string; label: string; aria: string; kind: "mod"; mod: Mod }
export type TermStripDef = TermKeyDef | TermModDef;

const key = (id: string, label: string, aria: string,
             rest: Omit<TermKeyDef, "id" | "label" | "aria" | "kind">): TermKeyDef =>
  ({ id, label, aria, kind: "key", ...rest });
const mod = (id: string, label: string, aria: string, m: Mod): TermModDef =>
  ({ id, label, aria, kind: "mod", mod: m });

/// xterm's own F-key sequences. F1–F4 are SS3, F5+ are CSI ~ with gaps at 16, 22, 27 and 30 — the
/// numbering is historical, not derivable, so it is written out rather than computed.
///
/// Declared BEFORE the table that reads it: `const` is not hoisted, and a table built at module load
/// from a constant defined below it throws on import.
const FN_BYTES: readonly string[] = [
  "\x1bOP", "\x1bOQ", "\x1bOR", "\x1bOS",
  "\x1b[15~", "\x1b[17~", "\x1b[18~", "\x1b[19~",
  "\x1b[20~", "\x1b[21~", "\x1b[23~", "\x1b[24~",
];

export const TERMINAL_KEYS: readonly TermStripDef[] = [
  key("esc", "Esc", "Escape", { bytes: "\x1b" }),
  key("tab", "Tab", "Tab", { bytes: "\t" }),
  mod("ctrl", "Ctrl", "Control", "ctrl"),
  mod("alt", "Opt", "Option", "alt"),
  mod("shift", "⇧", "Shift", "shift"),
  key("left", "←", "Left", { csi: "D", repeat: true }),
  key("down", "↓", "Down", { csi: "B", repeat: true }),
  key("up", "↑", "Up", { csi: "A", repeat: true }),
  key("right", "→", "Right", { csi: "C", repeat: true }),
];

export const TERMINAL_KEYS_MORE: readonly TermStripDef[] = [
  key("ctrl-c", "^C", "Control C", { bytes: "\x03" }),
  key("ctrl-d", "^D", "Control D", { bytes: "\x04" }),
  key("ctrl-z", "^Z", "Control Z", { bytes: "\x1a" }),
  key("home", "Home", "Home", { csi: "H" }),
  key("end", "End", "End", { csi: "F" }),
  key("pgup", "PgUp", "Page Up", { bytes: "\x1b[5~", repeat: true }),
  key("pgdn", "PgDn", "Page Down", { bytes: "\x1b[6~", repeat: true }),
  ...Array.from({ length: 12 }, (_, i) =>
    key(`f${i + 1}`, `F${i + 1}`, `F${i + 1}`, { bytes: FN_BYTES[i] })),
];

/// Arrows and Home/End change shape with DECCKM (`?1h`): CSI normally, SS3 in application cursor
/// mode. The glasses `CHIP_BYTES` table hardcodes CSI and is wrong inside `vi`, `less` and most
/// full-screen TUIs; this is the fix, and `xterm-view` exposes the mode so the caller can pass it.
export function csiBytes(final: string, appCursor: boolean): string {
  return appCursor ? `\x1bO${final}` : `\x1b[${final}`;
}

export function termBytes(def: TermKeyDef, appCursor: boolean): string {
  if (def.csi) return csiBytes(def.csi, appCursor);
  return def.bytes ?? "";
}

/// A strip key's bytes with the strip's HELD modifiers — exactly what xterm.js 6 sends for that chord
/// on a hardware keyboard, MEASURED against a real Terminal (`terminal-keys-xterm.test.ts`), so the
/// strip and a physical keyboard never disagree. `mask` is `HeldMods.mask()` (⇧ 1, Ctrl 2, Opt 4).
///
/// Arrows, Home/End and F1–F4 take xterm's `CSI 1;m X` form, F5–F12 `CSI n;m ~` — in application
/// cursor mode too — with m = 1 + ⇧ + 2·Opt + 4·Ctrl. Tab is `CSI Z` under ⇧ and ignores the rest;
/// Esc is doubled under Opt. PgUp/PgDn change only under Ctrl, and ⇧ is IGNORED there: xterm.js sends
/// nothing for ⇧+PgUp (it scrolls its own viewport), and a strip key that goes dead is worse than one
/// that pages. The single control bytes (^C ^D ^Z) have no keyboard chord: `applyHeldMods` as before.
/// **TEXT-EDITING KEYS, AS A MAC'S TERMINALS SEND THEM** (2026-10-06). Reported: "in regular (non-tmux) terminals
/// Alt+arrows don't work--they produce escape symbols instead", then "ctrl and shift still generate escapes. Check
/// how Ghostty does it". xterm.js sends a modified arrow as `ESC [1;<mod>D`, and so does Ghostty (its `pcStyle`);
/// zsh's emacs keymap binds none of them (measured on the dev Mac: only `^[b`, `^[f`, `^A`, `^E` and the plain
/// arrows), so it printed `;5D`. On macOS Ghostty adds "natural text editing" defaults — `⌥←`/`⌥→` as `ESC b`/
/// `ESC f`, `⌘←`/`⌘→` as `^A`/`^E`, `⌘⌫` as `^U` — and its Ctrl+arrows never arrive (macOS switches Spaces with
/// them). So, each with that ONE modifier held and nothing else:
///   - ⌥← / ⌥→ and Ctrl+← / Ctrl+→: a word back / forward, `ESC b` / `ESC f` (Ctrl by decision, the same day — what
///     Ctrl+arrows mean off a Mac; zsh, readline and the agents all take the pair);
///   - ⌘← / ⌘→: the line's start / end, `^A` / `^E`; ⌘⌫: delete to the line's start, `^U` (Ghostty's).
/// Any other key or combination — Shift+arrows among them — keeps xterm.js's encoding. Every tab alike, so one key
/// never means two things by tab kind. Null when the key is not one of these.
export function textEditingBytes(key: string, mods: { alt: boolean; ctrl: boolean; shift: boolean; meta: boolean }): string | null {
  const only = (alt: boolean, ctrl: boolean, meta: boolean) => mods.alt === alt && mods.ctrl === ctrl && mods.meta === meta && !mods.shift;
  if (key === "ArrowLeft" || key === "ArrowRight") {
    const left = key === "ArrowLeft";
    if (only(true, false, false) || only(false, true, false)) return left ? "\x1bb" : "\x1bf";
    if (only(false, false, true)) return left ? "\x01" : "\x05";
  }
  if (key === "Backspace" && only(false, false, true)) return "\x15";
  return null;
}

export function stripKeyBytes(def: TermKeyDef, appCursor: boolean, mask: number): string {
  const word = def.id === "left" || def.id === "right"
    ? textEditingBytes(def.id === "left" ? "ArrowLeft" : "ArrowRight", { alt: (mask & 4) !== 0, ctrl: (mask & 2) !== 0, shift: (mask & 1) !== 0, meta: false })
    : null;
  if (word !== null) return word;
  const plain = termBytes(def, appCursor);
  const shift = (mask & 1) !== 0, ctrl = (mask & 2) !== 0, alt = (mask & 4) !== 0;
  const m = (withShift: boolean) => 1 + (withShift && shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
  if (def.id === "tab") return shift ? "\x1b[Z" : plain;
  if (def.id === "esc") return alt ? "\x1b\x1b" : plain;
  if (def.id === "pgup" || def.id === "pgdn") return ctrl ? plain.replace(/~$/, `;${m(false)}~`) : plain;
  const n = m(true);
  if (n === 1) return plain;
  if (def.csi) return `\x1b[1;${n}${def.csi}`;
  const ss3 = /^\x1bO([PQRS])$/.exec(plain);
  if (ss3) return `\x1b[1;${n}${ss3[1]}`;
  const tilde = /^\x1b\[(\d+)~$/.exec(plain);
  if (tilde) return `\x1b[${tilde[1]};${n}~`;
  return applyHeldMods(plain, mask);
}

/// The control byte for a character, or null when it has none.
///
/// Returning null rather than a fallback is deliberate: `Ctrl` plus a digit has no control code, and
/// inventing one would silently send a byte the user never asked for.
export function ctrlByte(ch: string): string | null {
  const c = ch.toLowerCase();
  if (c >= "a" && c <= "z" && c.length === 1) return String.fromCharCode(c.charCodeAt(0) - 96);
  const punct: Record<string, string> = {
    "@": "\x00", " ": "\x00", "[": "\x1b", "\\": "\x1c", "]": "\x1d",
    "^": "\x1e", "_": "\x1f", "?": "\x7f",
  };
  return punct[ch] ?? null;
}

/// Apply the strip's HELD modifiers to a chunk xterm is about to send.
///
/// Called at the TOP of xterm's `onData`, before the prediction block — a Ctrl-transformed `\x03`
/// then lands in the existing "Enter / arrows / ctrl → stop predicting" branch instead of being
/// predicted as a printable character.
///
/// Single characters only. A multi-character chunk is a paste or an escape sequence xterm produced
/// itself; prefixing a paste with ESC or control-mapping its first byte is never what was meant.
/// Meta is ignored (⌘ has no PTY meaning). ⇧ makes a typed letter a capital, and ⇧ + Return is
/// ESC CR — what Claude Code's `/terminal-setup` binds Shift+Enter to, a NEW LINE; xterm.js sends a
/// plain CR for Shift+Enter, which would SUBMIT the prompt the user meant to extend.
///
/// The mask is read at the moment the character arrives, so holding Ctrl and typing `c` on the soft
/// keyboard sends `^C` — the modifier is still down when xterm hands the character over.
export function applyHeldMods(data: string, mask: number): string {
  if (data.length !== 1) return data;
  const shift = (mask & 1) !== 0;
  const ctrl = (mask & 2) !== 0;
  const alt = (mask & 4) !== 0;
  if (shift && data === "\r") return "\x1b\r";
  let out = data;
  if (shift) { const up = out.toUpperCase(); if (up.length === 1) out = up; }
  if (ctrl) out = ctrlByte(out) ?? out;
  if (alt) out = `\x1b${out}`;
  return out;
}
