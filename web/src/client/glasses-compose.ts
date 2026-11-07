import { csiBytes } from "./terminal-keys";

/// Terminal text entry with no keyboard.
///
/// The glasses have no hardware keyboard, so the terminal cannot be driven by `keydown` at all. A
/// real `<input type="text">` opens the on-glasses composer (handwriting + voice) on focus-then-tap,
/// and the committed string arrives on `input`/`change`. That is a LINE editor, not a keystroke
/// stream — which suits a shell, and is why the control bytes get their own chips.
///
/// Platform constraints that shaped this, all of which bite silently:
///   - a programmatic `.focus()` does NOT surface the composer; the wearer must pinch a focused field
///   - `type=password` and non-text input types never open it
///   - on some builds it is unavailable entirely, so the chips must be useful on their own
///   - read the value from `input`/`change`, never from `keydown`

/// Control bytes the composer cannot produce. Same wire shape as xterm's own `onData`.
///
/// The four cursor keys are NOT here — they live in `CHIP_CSI` because their bytes depend on DECCKM.
/// Resolve any chip through `chipBytes`, never by reading either table directly.
export const CHIP_BYTES: Record<string, string> = {
  "chip:enter": "\r",
  "chip:backspace": "\x7f",     // DEL, which is what xterm sends for Backspace
  "chip:tab": "\t",
  "chip:esc": "\x1b",
  "chip:ctrlc": "\x03",
};

/// The wearer's physical D-pad moves FOCUS, so it can never reach the shell: these are the only
/// arrow keys a TUI, a pager or shell history will ever see from the glasses.
///
/// CSI FINAL BYTES, not literal sequences. They used to be hardcoded `\x1b[A` in `CHIP_BYTES`, which
/// is the WRONG sequence inside `vi`, `less` and most full-screen TUIs — exactly the apps a wearer
/// needs arrows for. `csiBytes` picks CSI or SS3 from the terminal's live cursor-key mode.
export const CHIP_CSI: Record<string, string> = {
  "chip:up": "A", "chip:down": "B", "chip:right": "C", "chip:left": "D",
};

/// The bytes a chip sends, or undefined if it is not a chip.
///
/// THE ONE RESOLVER. `TERMINAL_CHIPS` is pinned against this in both directions, so a chip in the
/// nav order that resolves to nothing — a control that focuses, activates and silently does nothing
/// — fails a test rather than shipping.
export function chipBytes(id: string, appCursor: boolean): string | undefined {
  const csi = CHIP_CSI[id];
  if (csi !== undefined) return csiBytes(csi, appCursor);
  return CHIP_BYTES[id];
}

/// Turn a committed composer line into terminal bytes.
///
/// TYPING NEVER SUBMITS. The text goes to the prompt and stops there; the ⏎ chip is the only thing
/// that sends a carriage return. Dictation mishears words and handwriting misreads letters, so a
/// commit that ran the command gave the wearer no chance to look at it first — and on a screen this
/// size, looking at it means reading it at the prompt, not in a 51px field.
///
/// Stripping EVERY trailing newline is part of the same rule, not cosmetics: a \n reaching the PTY
/// is Enter, so a composer that appends its own on commit would auto-submit exactly as appending \r
/// did. Interior newlines survive — those are the wearer's own text.
export function composeToKeys(line: string): string {
  return line.replace(/[\r\n]+$/, "");
}

export function mountCompose(
  els: { input: HTMLInputElement; chips: HTMLElement; appCursor: () => boolean },
  send: (data: string) => void,
): void {
  // `change` fires on commit; `input` fires as the composer streams partial text. Acting on `change`
  // only is what stops a half-dictated command reaching the prompt.
  //
  // The field is cleared because its content now lives at the shell prompt, where the wearer can
  // actually read it — leaving it would resend the same text on the next commit.
  els.input.addEventListener("change", () => {
    const data = composeToKeys(els.input.value);
    if (data) send(data);
    els.input.value = "";
  });
  // Delegated, so the chip set can change without rebinding. `closest` because a pinch activates the
  // <button> but a pointer may land on a child text node.
  els.chips.addEventListener("click", (e) => {
    const id = (e.target as HTMLElement | null)?.closest<HTMLElement>("[data-nav-id]")?.dataset.navId;
    const bytes = id ? chipBytes(id, els.appCursor()) : undefined;
    if (bytes) send(bytes);
  });
}
