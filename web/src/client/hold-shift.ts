// **WHILE A RESIZE IS HELD, THE PICTURE SITS WHERE THE HOST WILL PUT IT** (2026-10-06, asked for: "when changing
// window size, optimistically keep the terminal bottom-aligned, so that there is less motion when e.g. user brings
// up an on-screen keyboard"; docs/terminal.md, "A held resize keeps the picture where the host will put it"). A
// HOLD (`TermDeck.fit`) keeps every instance at its old grid until the host's snapshot at the new one: the soft
// keyboard came up and the old grid stayed TOP-aligned in the smaller area, the prompt under the keyboard, until
// the snapshot moved everything up — the whole picture jumping once per keyboard. Now the held picture is moved,
// at once, by the rows the host's own resize is about to move it, so the snapshot lands on what is already shown.

export interface HoldShiftInput {
  /// The instance's grid rows, and the rows the area now fits.
  rowsOld: number;
  rowsNew: number;
  /// The cursor's row on the screen (0 = the top row), and the lines of scrollback above the screen.
  cursorY: number;
  scrollback: number;
  /// Something is drawn BELOW the cursor — a program's own interface under its input (Claude Code's rules and
  /// footer), which it draws again at the new bottom.
  drawnBelow: boolean;
  /// A full-screen program (the alternate screen) — it redraws for the new size itself.
  alt: boolean;
  /// A `tmux:` tab: tmux's resize, not SwiftTerm's, decides (they differ only when the area grows).
  tmux: boolean;
}

/// The rows the picture moves when the grid goes from `rowsOld` to `rowsNew` — POSITIVE DOWN — as the host's
/// emulator, and the program in it, will move it. xterm.js, SwiftTerm and tmux all resize the same way when the rows
/// SHRINK: the lines below the cursor go first, from the bottom, and only the rest scroll off the top — so a prompt at
/// the bottom moves up by every row lost (bottom-aligned) and a fresh shell's prompt near the top does not move at
/// all. **Unless something is drawn below the cursor** (`drawnBelow`): an agent's input box sits above its own rules
/// and footer (Claude Code: the cursor 4 rows from the bottom, measured 2026-10-06), the emulator drops those rows
/// like blank ones, and the agent draws them again under its input — pushing everything up by them as well, which
/// the snapshot (taken after that redraw, `snapshot-settle.ts`) then showed as a SECOND step ("on mobile opening
/// keyboard looks like a two stepped process"). Such a picture ends bottom-aligned. When
/// the rows GROW, lines come back out of the scrollback, moving the picture down: xterm.js and SwiftTerm only while
/// the cursor is on the last row, tmux whenever it has history. A full-screen program draws its status line and
/// input at the bottom, so its picture is BOTTOM-ALIGNED either way.
export function holdShiftRows(s: HoldShiftInput): number {
  const d = s.rowsNew - s.rowsOld;
  if (d === 0 || s.rowsOld <= 0 || s.rowsNew <= 0) return 0;
  if (s.alt) return d;
  if (d < 0) {
    const lost = -d;
    if (s.drawnBelow) return d;
    const below = Math.max(0, s.rowsOld - 1 - s.cursorY);
    const up = lost - Math.min(lost, below);
    return up === 0 ? 0 : -up;
  }
  const pulls = s.tmux || s.cursorY >= s.rowsOld - 1;
  return pulls ? Math.min(d, Math.max(0, s.scrollback)) : 0;
}
