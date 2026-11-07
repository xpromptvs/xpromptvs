/// Terminal copy-to-clipboard that does NOT depend on the browser dispatching a `copy` event.
///
/// xterm.js has exactly one copy path: a `copy` DOM listener on its container that fills
/// `event.clipboardData` from the selection (`CoreBrowserTerminal._initGlobal`). That works on desktop
/// but NOT on iPadOS Safari, where Cmd+C over the terminal does nothing while Cmd+V works fine — the
/// copy event never reaches xterm, because the focused element is xterm's helper textarea and it is
/// EMPTY, so there is no selection for the platform to copy (xterm renders its own selection overlay,
/// it never puts a range in the DOM). Paste is unaffected: it doesn't need a selection.
///
/// So we write the clipboard ourselves from the keydown. Deliberately WITHOUT preventDefault: where the
/// native path already works it still runs and writes the exact same string, which keeps this from being
/// able to regress a working browser.

export type CopyMethod = "async" | "exec" | "none";

export interface CopyResult {
  method: CopyMethod;
  ok: boolean;
  chars: number;
  error?: string;
}

/// ⌘C (Mac/iPadOS) or Ctrl+Shift+C (elsewhere — plain Ctrl+C is SIGINT and must reach the shell).
export function isCopyChord(e: {
  key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean;
}): boolean {
  if (e.key.toLowerCase() !== "c" || e.altKey) return false;
  if (e.metaKey && !e.ctrlKey) return true;
  return e.ctrlKey && e.shiftKey && !e.metaKey;
}

/// Last-resort clipboard write for an insecure origin, where `navigator.clipboard` is undefined —
/// which is the plain-http LAN setup an iPad typically reaches this app over. Uses a throwaway textarea
/// plus the legacy `execCommand`, restoring the document selection and the focused element after (the
/// focus restore keeps xterm's helper textarea live, so the hardware keyboard keeps working).
///
/// LOAD-BEARING, and verified against a real Chromium rather than reasoned about — `execCommand("copy")`
/// returns **true while copying nothing** if you get this wrong, so it fails silently:
///   - `focus()` then `setSelectionRange` is what actually selects the value. Selecting the textarea
///     with a Range does NOT work: a textarea's value lives in an internal shadow tree, so
///     `selectNodeContents` selects the element and copies an empty string (measured — true, clipboard
///     unchanged).
///   - `contentEditable` + a NON-readonly field is the iOS half: WebKit ignores `setSelectionRange`
///     on a readonly input, which is the usual reason this recipe is seen with `readonly` and still
///     fails there.
///   - 16px type stops iOS zooming to the field; it is removed immediately and focus is handed back to
///     xterm's helper textarea, so the hardware keyboard keeps working.
export function execCommandCopy(text: string, doc: Document = document): boolean {
  const active = doc.activeElement as HTMLElement | null;
  const ta = doc.createElement("textarea");
  ta.value = text;
  ta.contentEditable = "true";
  ta.readOnly = false;
  ta.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:none;" +
    "outline:none;box-shadow:none;background:transparent;color:transparent;font-size:16px";
  doc.body.appendChild(ta);
  let ok = false;
  try {
    ta.focus();
    ta.setSelectionRange(0, text.length + 1);   // +1: iOS clips an exact-length range
    ok = doc.execCommand("copy");
  } catch {
    ok = false;
  }
  ta.remove();
  active?.focus();
  return ok;
}

/// Write `text` to the clipboard. MUST be called synchronously from the key event — Safari ties the
/// permission to the gesture, so an awaited call would be refused.
export function writeClipboard(text: string, onResult?: (r: CopyResult) => void): void {
  const done = (method: CopyMethod, ok: boolean, error?: string) =>
    onResult?.({ method, ok, chars: text.length, error });
  const api = navigator.clipboard;
  if (api?.writeText) {
    api.writeText(text).then(
      () => done("async", true),
      (err: unknown) => done("exec", execCommandCopy(text), String(err)),
    );
    return;
  }
  done("exec", execCommandCopy(text));   // insecure origin: no async clipboard at all
}

/// Hand the platform a REAL selection to copy, by mirroring the terminal's selection into xterm's
/// focused helper textarea. This is exactly what xterm does for the right-click menu
/// (`Clipboard.rightClickHandler`: "Get textarea ready to copy from the context menu"), and on iPadOS
/// right-click → Copy demonstrably works — the on-device proof that the platform's copy path is fine
/// and that it is the missing selection which breaks ⌘C.
///
/// Pass "" to clear the mirror.
///
/// ONLY INTO A TEXTAREA THAT HAS FOCUS (2026-10-04): `select()` MOVES FOCUS to the field — measured, WebKit and
/// Chromium alike — so mirroring a selection made with a FINGER (touch-selection.ts) into the unfocused textarea
/// focused it, and on an iPhone, inside the handle's drag, that raised the soft keyboard. The mirror is for ⌘C,
/// which only ever reaches the FOCUSED element, so an unfocused textarea loses nothing; any stale mirror in it is
/// cleared (xterm.js's IME path reads that value).
export function setNativeSelectionMirror(ta: HTMLTextAreaElement | undefined, text: string): boolean {
  if (!ta) return false;
  try {
    if (!text) { if (ta.value) ta.value = ""; return true; }
    if (ta.ownerDocument.activeElement !== ta) { if (ta.value) ta.value = ""; return false; }
    ta.value = text;
    ta.select();
    return true;
  } catch {
    return false;
  }
}

/// Keep the mirror in step with the selection, CONTINUOUSLY rather than at ⌘C time.
///
/// LOAD-BEARING — mirroring on the keydown is not enough on iPadOS. UIKit decides whether ⌘C is even
/// enabled by asking the responder chain (`canPerformAction(copy:)`) — a question that can be settled
/// BEFORE the DOM keydown is dispatched, so a selection installed from the keydown handler arrives too
/// late to make copy available. Mirroring on every selection change means it is already in place by the
/// time any ⌘C is pressed. (⌘A proves ⌘ keydowns do reach the page, so this is about ordering, not
/// delivery.)
export function installSelectionMirror(opts: {
  textarea: () => HTMLTextAreaElement | undefined;
  getSelection: () => string;
  subscribe: (cb: () => void) => { dispose: () => void };
}): () => void {
  const sync = () => setNativeSelectionMirror(opts.textarea(), opts.getSelection());
  const sub = opts.subscribe(sync);
  sync();
  return () => sub.dispose();
}

export interface TerminalCopyOpts {
  hasSelection: () => boolean;
  getSelection: () => string;
  /// xterm's helper textarea (`term.textarea`), for the native-copy mirror above.
  textarea?: () => HTMLTextAreaElement | undefined;
  onResult?: (r: CopyResult) => void;
}

/// Wire the copy chord on the terminal element. Scoped to the terminal (not the window) so it can't
/// hijack copy in the pairing field or the palette query. Returns a disposer.
export function installTerminalCopy(el: HTMLElement, opts: TerminalCopyOpts): () => void {
  let composing = false;
  const onCompositionStart = () => { composing = true; };
  const onCompositionEnd = () => { composing = false; };
  const onKeyDown = (ev: Event) => {
    const e = ev as KeyboardEvent;
    if (!isCopyChord(e) || !opts.hasSelection()) {
      // Anything else typed should not find a mirrored selection sitting in the textarea — xterm's
      // IME/composition path reads `textarea.value` and would send it as input. Never mid-composition,
      // which is the one time that value legitimately belongs to xterm.
      if (!composing && !e.metaKey && !e.ctrlKey) setNativeSelectionMirror(opts.textarea?.(), "");
      return;
    }
    const text = opts.getSelection();
    if (!text) return;
    setNativeSelectionMirror(opts.textarea?.(), text);   // in case the mirror is stale; cheap and idempotent
    writeClipboard(text, opts.onResult);
  };
  el.addEventListener("keydown", onKeyDown, true);   // capture: the event targets the helper textarea inside
  el.addEventListener("compositionstart", onCompositionStart, true);
  el.addEventListener("compositionend", onCompositionEnd, true);
  return () => {
    el.removeEventListener("keydown", onKeyDown, true);
    el.removeEventListener("compositionstart", onCompositionStart, true);
    el.removeEventListener("compositionend", onCompositionEnd, true);
  };
}
