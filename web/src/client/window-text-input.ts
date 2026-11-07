import { contextFor, activeWithin, presentationRoot } from "./instance/context";
import { mountKeyStrip, type KeyStripHandle } from "./key-strip";
import { attachPressHold } from "./press-hold";
import { HeldMods, type Mod } from "./held-mods";
import type { WinKeyWire } from "./keys";
import {
  charMessages, modifierMessage, winKeyMessages,
  WINDOW_KEYS, WINDOW_KEYS_MORE, type WinKeyDef,
} from "./window-keys";

/// Keyboard input for a projected window on a touch device.
///
/// Two halves. The STRIP carries the keys a soft keyboard does not have — Esc, Tab, the four
/// modifiers, the arrows and an expansion row. The HIDDEN INPUT is what raises the soft keyboard at
/// all: `.win-body` is a focusable div, and focusing one never opens a keyboard on iOS, which is why
/// the window view had no keyboard path before this.
///
/// LOAD-BEARING — the input is a child of `.source-window`, NOT of `.win-body`. `keydown` bubbles,
/// so an input inside the body would fire `attachWindowKeys`' listener as well as this module's and
/// every keystroke would be sent twice. (`focus` does not bubble, so `keys.ts` would not even take
/// ownership in order to release it.)

export interface WindowKeyboardOpts {
  send: (msg: WinKeyWire) => void;
  /// The window must be BOTH focused and driven by this client — the same rule `attachWindowKeys`
  /// applies. Checked at SEND time, not at mount time.
  isActive: () => boolean;
  /// The window is FULL SCREEN, where it has no titlebar: a held finger on `⌨` then opens the window's
  /// paste menu instead (paste-and-drop design §2.2). Read at each press. Absent means never.
  isFullscreen?(): boolean;
  /// This client may paste (it drives, and is not window-less). Absent means it may. Read at each press,
  /// and BEFORE the hold, never after: a hold swallows its click, so a hold that then opened nothing would
  /// leave `⌨` doing nothing at all.
  canPaste?(): boolean;
  /// A held finger on `⌨` in full screen, at where it went down.
  onKeyboardHold?(at: { x: number; y: number }): void;
  /// A SIMULATOR window: what the soft keyboard inserted goes WHOLE as `sim-text`, not as one `win-key` per character —
  /// `charToCode` has no code for é or an emoji, and the host refuses a `win-key` without one. Absent: keys.
  sendText?: (text: string) => void;
}

export interface WindowKeyboardHandle {
  el: HTMLElement;
  input: HTMLInputElement;
  /// The strip's latched modifiers, for `attachWindowKeys`' `extraMods` — an iPad with a hardware
  /// keyboard can arm Ctrl with a finger and press the letter physically.
  mask(): number;
  /// Raise or dismiss the soft keyboard.
  toggle(): void;
  /// Release every held modifier, on the wire as well as in the UI.
  clearMods(): void;
  destroy(): void;
}

/// Named keys a soft keyboard DOES produce, arriving as an inputType rather than as a code.
const INPUT_TYPE_KEYS: Record<string, { code: string; key: string }> = {
  deleteContentBackward: { code: "Backspace", key: "Backspace" },
  deleteContentForward: { code: "Delete", key: "Delete" },
  insertLineBreak: { code: "Enter", key: "Enter" },
  insertParagraph: { code: "Enter", key: "Enter" },
};

export function mountWindowKeyboard(
  win: HTMLElement, opts: WindowKeyboardOpts,
): WindowKeyboardHandle {
  const mods = new HeldMods();

  const input = document.createElement("input");
  input.type = "text";
  input.className = "win-key-input";
  input.setAttribute("aria-label", "Keyboard input for this window");
  input.autocapitalize = "none";
  input.autocomplete = "off";
  input.spellcheck = false;
  // Not in the TS DOM lib, so it goes on as an attribute. `inputmode` is left at its default: a full
  // keyboard is the entire point.
  input.setAttribute("autocorrect", "off");
  win.append(input);

  // BEST EFFORT: a channel already closing under this window (measured: `RTCDataChannel.send` throws
  // `InvalidStateError`) must not make a modifier release throw. `clearMods` runs unconditionally
  // during teardown, from callers with no try/catch of their own (`sync`'s removal loop,
  // `releaseTouchMods`), so the tolerance belongs HERE — the one place every message this module
  // sends passes through — rather than duplicated at each caller.
  const send = (msg: WinKeyWire) => {
    if (!opts.isActive()) return;
    try { opts.send(msg); } catch { /* the channel is closing under us; nothing to deliver into */ }
  };

  /// Send a modifier's key-up. The bare-modifier message is what clears the host's `currentFlags`,
  /// which touch/hover stamp onto mouse events.
  const releaseMods = (list: readonly Mod[]) => {
    for (const m of list) send(modifierMessage(m, false, mods.mask()));
  };

  /// A key press does NOT touch the modifiers: they are held, and stay down until the finger lifts.
  /// That is what lets one finger hold ⌘ while the other taps C and then V.
  const sendKey = (msgs: readonly WinKeyWire[]) => { for (const m of msgs) send(m); };

  // Dismissing hands focus to the PICTURE rather than blurring to <body>: focusing a div opens no
  // keyboard on iOS, and the window keeps DOM focus, so a hardware keyboard's keys still reach it.
  const toggle = () => {
    if (activeWithin(win) === input) {
      const picture = win.querySelector<HTMLElement>(".win-body");
      if (picture) picture.focus({ preventScroll: true }); else input.blur();
    } else input.focus({ preventScroll: true });
  };

  const strip: KeyStripHandle = mountKeyStrip(win, {
    row: WINDOW_KEYS, more: WINDOW_KEYS_MORE,
    drawer: {
      active: () => opts.isActive() && presentationRoot(win).dataset.tab === "sim",
      systemKeyboard: () => input.focus({ preventScroll: true }),
      text: value => {
        if (value === "\x03") {
          sendKey(charMessages("c", mods.mask() | 2));
        } else if (value === "\r" || value === "\x7f") {
          const key = value === "\r" ? "Enter" : "Backspace";
          sendKey(winKeyMessages({ id: key, label: key, aria: key, kind: "key", code: key, key }, mods.mask()));
        } else sendKey(charMessages(value, mods.mask()));
      },
    },
    extra: [{ id: "kbd", label: "⌨", aria: "Show or hide the keyboard", kind: "key" }],
    modState: (m) => mods.state(m),
    onPress: (def) => {
      if (def.id === "kbd") { toggle(); return; }
      sendKey(winKeyMessages(def as WinKeyDef, mods.mask()));
    },
    onModChange: (mod, down) => {
      if (!(down ? mods.down(mod) : mods.up(mod))) return;   // no change ⇒ no wire message
      // THIS MESSAGE IS WHAT MAKES ⌘-CLICK WORK: the host stamps `currentFlags` onto every mouse
      // event and a touch only READS that holder, so the modifier has to reach the wire on its own
      // rather than only riding along with a keystroke.
      send(modifierMessage(mod, down, mods.mask()));
    },
  });

  // FULL SCREEN'S PASTE MENU (§2.2): the titlebar is gone, so `⌨` — the one control a touch screen keeps
  // there — takes the hold. A TAP is still the toggle: the hold fires only after 500 ms still, nothing on
  // touch down (the strip's own rule), and a hold that opened the menu swallows its click, so the menu
  // never comes with the keyboard thrown up under it.
  const holds = new AbortController();
  for (const kbd of strip.el.querySelectorAll<HTMLElement>('[data-key-id="kbd"], .keyboard-system')) {
    attachPressHold(kbd, {
      accepts: () => (opts.isFullscreen?.() ?? false) && (opts.canPaste?.() ?? true) && opts.onKeyboardHold !== undefined,
      onHold: (at) => opts.onKeyboardHold?.(at),
    }, holds.signal);
  }

  input.addEventListener("focus", () => win.classList.add("has-keyboard"));
  input.addEventListener("blur", () => win.classList.remove("has-keyboard"));

  // A hardware keyboard reports a real `code`; the iOS soft keyboard reports "" (and often
  // key "Unidentified"). Handle the first here and let the second fall through to `beforeinput`,
  // which is the only event that reliably carries what a soft keyboard produced.
  input.addEventListener("keydown", (e) => {
    if (!e.code || e.code === "Unidentified") return;
    e.preventDefault();
    const mask = mods.mask();
    sendKey([
      { t: "win-key", down: true, code: e.code, key: e.key, repeat: e.repeat, mods: mask },
      { t: "win-key", down: false, code: e.code, key: e.key, repeat: false, mods: mask },
    ]);
  });

  input.addEventListener("beforeinput", (e) => {
    const ie = e as InputEvent;
    const named = INPUT_TYPE_KEYS[ie.inputType];
    if (named) {
      ie.preventDefault();
      const mask = mods.mask();
      sendKey([
        { t: "win-key", down: true, code: named.code, key: named.key, repeat: false, mods: mask },
        { t: "win-key", down: false, code: named.code, key: named.key, repeat: false, mods: mask },
      ]);
      return;
    }
    if (!ie.data) return;
    ie.preventDefault();
    if (opts.sendText) { opts.sendText(ie.data); return; }
    const mask = mods.mask();
    // One pair PER CHARACTER: dictation and autocorrect commit whole words, and the Mac has to
    // receive them as keystrokes, not as a string.
    for (const ch of ie.data) for (const m of charMessages(ch, mask)) send(m);
  });

  // The field must never accumulate text — it is a keystroke tap, not a composer. Everything above
  // preventDefaults, so this only catches what a platform inserted anyway.
  input.addEventListener("input", () => { input.value = ""; });

  const clearMods = () => { releaseMods(mods.clearAll()); strip.cancel(); strip.refresh(); };
  const stopRelease = contextFor(win)?.input.onRelease(clearMods);
  return {
    el: strip.el,
    input,
    mask: () => mods.mask(),
    toggle,
    clearMods,
    destroy() { stopRelease?.(); clearMods(); holds.abort(); strip.destroy(); input.remove(); },
  };
}
