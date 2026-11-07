/// A tab's NAME — what Rename sends (`rename-tab`), and the rule the host checks it against
/// (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md §2.3; `TabName.isValid` in Swift,
/// both asserted against `protocol/fixtures/tab-names.json`).
///
/// BYTES, NOT CHARACTERS: Swift counts graphemes and JavaScript UTF-16 units, so a character limit would
/// draw two different lines. UTF-8 bytes are one number in both.

export const TAB_NAME_MAX_BYTES = 256;

/// Unicode general category Cc — C0, DEL and C1. A name is a label; none of these can be one.
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
const CONTROLS = /[\u0000-\u001f\u007f-\u009f]/g;
/// A surrogate half with no partner. No host string can hold one; `TextEncoder` would send U+FFFD.
const LONE_SURROGATE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;

const utf8Bytes = (s: string): number => new TextEncoder().encode(s).length;

/// At most `TAB_NAME_MAX_BYTES` of UTF-8 and no control character. Empty is valid: it CLEARS a name.
export function isValidTabName(name: string): boolean {
  return !CONTROL.test(name) && utf8Bytes(name) <= TAB_NAME_MAX_BYTES;
}

/// What the field sends for what was typed: control characters become spaces, surrounding space goes,
/// and a name past the limit is cut at the last whole character that fits. Always valid.
export function tidyTabName(raw: string): string {
  let s = raw.replace(LONE_SURROGATE, "").replace(CONTROLS, " ").trim();
  if (utf8Bytes(s) <= TAB_NAME_MAX_BYTES) return s;
  let out = "";
  for (const ch of s) {                       // by code point: a surrogate pair is never split
    if (utf8Bytes(out + ch) > TAB_NAME_MAX_BYTES) break;
    out += ch;
  }
  s = out.trim();
  return s;
}

/// What the rename field opens with and what an empty one means.
export interface RenameField {
  /// The label the tab shows now — the field opens holding it, all selected.
  value: string;
  /// What an EMPTY field leaves the tab called: its automatic label (a tmux tab: its session's name).
  placeholder: string;
  /// The tab carries a name the driver gave it — so an empty field asks for it to be CLEARED.
  named: boolean;
  /// False for a tmux tab: its label IS its session's name, and tmux has no unnamed session.
  clearable: boolean;
}

/// The name a committed field asks the host for — `""` clears one — or null when there is nothing to ask:
/// the name it opened with, or empty where empty means nothing.
export function renameIntent(f: RenameField, typed: string): string | null {
  const name = tidyTabName(typed);
  if (name === tidyTabName(f.value)) return null;
  if (name === "") return f.clearable && f.named ? "" : null;
  return name;
}
