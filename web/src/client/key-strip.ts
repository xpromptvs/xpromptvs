import { contextFor, queryRoot, presentationRoot, activeWithin } from "./instance/context";
import type { Mod, ModState } from "./held-mods";

/// The on-screen key strip. Renders from a TABLE and knows nothing about terminals or windows — it
/// reports which def was pressed and lets the caller decide what that means. That is what keeps the
/// two surfaces' behaviour in their own pure modules and makes this file testable with a fake table.
///
/// Rendering from the table (rather than from markup) is deliberate: `spatial-nav.ts` has to pin
/// `TERMINAL_CHIPS` against `CHIP_BYTES` by hand precisely because the glasses chips are markup, and
/// a chip present with no bytes focuses, activates and silently does nothing. Here that cannot
/// happen.

const UNSHIFTED = "1234567890-=[]\\;'`,./";
const SHIFTED = "!@#$%^&*()_+{}|\":~<>?";
export function shiftedCharacter(value: string): string {
  const i = UNSHIFTED.indexOf(value);
  return value.length === 1 && i >= 0 ? SHIFTED[i]! : value.toUpperCase();
}

export interface StripDef {
  id: string; label: string; aria: string;
  kind: "key" | "mod";
  mod?: Mod;
  repeat?: boolean;
  text?: string;
}

/// Press-and-hold: after the delay, a press and then repeats. Only for navigation keys — see
/// `repeat`. **NOTHING FIRES ON TOUCH DOWN**: the strip is a horizontal scroller, so a finger landing
/// on a key may be starting a SCROLL, and the browser only says so later with `pointercancel`. A tap
/// fires on its `click`; a hold starts repeating only once it has outlived the delay unscrolled.
export const REPEAT_DELAY_MS = 500;
export const REPEAT_INTERVAL_MS = 50;

/// `data-keystrip="expanded"` rides the ROOT, alongside data-layout and data-tab.
///
/// LOAD-BEARING: `#xterm` and the terminal strip are siblings, and the grid must shrink when the
/// second row appears. A flag on the strip itself would need a sibling combinator and would break
/// silently if DOM order ever changed; on the root, one `--keystrip-h` drives both.
const EXPANDED_ATTR = "keystrip";

/// The strip's own control, not a key. Namespaced so it can never collide with a table entry.
const MORE_ID = "strip:more";

export interface KeyStripOpts {
  drawer?: {
    active(): boolean;
    systemKeyboard(): void;
    text(value: string): void;
  };
  row: readonly StripDef[];
  more: readonly StripDef[];
  /// Extra controls pinned in the fixed group beside `⋯` (the window strip's `⌨`).
  extra?: readonly StripDef[];
  onPress: (def: StripDef) => void;
  /// A modifier going down or up. Separate from `onPress` because a modifier is HELD, not tapped:
  /// a finger on it is PENDING, and the modifier goes down only when it is USED — another finger
  /// lands anywhere, or a key arrives from the soft keyboard — or, unused, as a down-then-up on
  /// release. A pending modifier whose finger turns out to be scrolling the strip sends nothing.
  onModChange: (mod: Mod, down: boolean) => void;
  modState: (mod: Mod) => ModState;
}

export interface KeyStripHandle {
  el: HTMLElement;
  /// Re-read every modifier's state and repaint. Cheap; call it after any tap.
  refresh(): void;
  cancel(): void;
  destroy(): void;
}

export function mountKeyStrip(parent: HTMLElement, opts: KeyStripOpts): KeyStripHandle {
  const context = contextFor(parent);
  const el = document.createElement("div");
  el.className = "key-strip";

  // The tab bar's structure, for the tab bar's reason: the scroller is CLIPPED where the fixed group
  // begins rather than sliding underneath it. Being outside the scrolling box is strictly stronger
  // than `position: sticky` and needs no opaque background.
  const scroll = document.createElement("div");
  scroll.className = "key-strip-scroll rl-noscroll";
  const fixed = document.createElement("div");
  fixed.className = "key-strip-fixed";
  el.append(scroll, fixed);

  const buttons = new Map<string, HTMLButtonElement>();
  const characters: StripDef[] = [];
  const compactDefs: StripDef[] = [];
  const compactOriginals = new Map<string, StripDef>();
  const make = (def: StripDef): HTMLButtonElement => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = def.kind === "mod" ? "key-cap key-mod" : "key-cap";
    b.dataset.keyId = def.id;
    b.textContent = def.label;
    b.setAttribute("aria-label", def.aria);
    if (def.kind === "mod") { b.dataset.state = "off"; b.setAttribute("aria-pressed", "false"); }
    buttons.set(def.id, b);
    return b;
  };

  for (const def of opts.row) scroll.append(make(def));

  if (opts.drawer) {
    el.classList.add("keyboard-drawer", "keyboard-compact");
    el.inert = true;
    const compact = document.createElement("div"); compact.className = "keyboard-compact-pad";
    const actions = document.createElement("div"); actions.className = "keyboard-compact-actions";
    const dpad = document.createElement("div"); dpad.className = "keyboard-dpad"; dpad.setAttribute("aria-label", "Directional pad");
    for (const id of ["esc", "ctrl-c", "tab", "backspace", "shift", "ctrl", "left", "up", "down", "right", "alt", "space", "enter"]) {
      const original = [...opts.row, ...opts.more].find(d => d.id === id);
      if (!original && (id === "shift" || id === "ctrl" || id === "alt")) continue;
      const def: StripDef = original ? { ...original, id: `compact:${id}` } : {
        id: `compact:${id}`, kind: "key", label: id === "space" ? "␣" : id === "ctrl-c" ? "^C" : id === "enter" ? "↵" : "⌫",
        aria: id === "space" ? "Space" : id === "ctrl-c" ? "Control C" : id === "enter" ? "Return" : "Backspace",
        text: id === "space" ? " " : id === "ctrl-c" ? "\x03" : id === "enter" ? "\r" : "\x7f", repeat: id === "backspace",
      };
      compactDefs.push(def); if (original) compactOriginals.set(def.id, original);
      const button = make(def); button.dataset.padKey = id;
      if (id === "alt") button.textContent = "⌥";
      (["left", "up", "down", "right", "alt", "space", "enter"].includes(id) ? dpad : actions).append(button);
    }
    compact.append(actions, dpad); el.append(compact);
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-label", "Keyboard");
    for (const letters of ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm", "[]=\\;'`", "!@#$%^&*()", "_+{}|\":~?"]) {
      const row = document.createElement("div");
      row.className = "keyboard-letter-row";
      if (!["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"].includes(letters)) row.classList.add("keyboard-symbol-row");
      for (const text of letters) {
        const def: StripDef = { id: `char:${text}`, label: text, aria: text, kind: "key", text };
        characters.push(def); row.append(make(def));
      }
      if (letters === "asdfghjkl" || letters === "zxcvbnm" || letters.startsWith("_+") || letters.startsWith("[]=")) {
        const back = letters === "zxcvbnm" || letters.startsWith("[]=");
        const def: StripDef = { id: back ? (letters.startsWith("[]=") ? "symbol:backspace" : "char:backspace") : letters.startsWith("_+") ? "symbol:enter" : "char:enter", label: back ? "⌫" : letters.startsWith("_+") ? "↵" : "return",
          aria: back ? "Backspace" : "Return", kind: "key", text: back ? "\x7f" : "\r", repeat: back };
        characters.push(def); row.append(make(def));

      }
      el.insertBefore(row, scroll);
    }
    const row = document.createElement("div"); row.className = "keyboard-letter-row keyboard-space-row";
    const symbols = document.createElement("button"); symbols.type = "button"; symbols.className = "key-cap";
    symbols.textContent = "#+="; symbols.setAttribute("aria-label", "Symbols"); symbols.setAttribute("aria-pressed", "false");
    symbols.addEventListener("click", () => { const on = el.classList.toggle("keyboard-symbols"); symbols.textContent = on ? "ABC" : "#+="; symbols.setAttribute("aria-pressed", String(on)); });
    row.append(symbols);
    for (const text of ["-", "/", " ", ".", ","]) {
      const def: StripDef = { id: `char:${text}`, label: text === " " ? "space" : text,
        aria: text === " " ? "Space" : text, kind: "key", text };
      characters.push(def); const b = make(def); if (text === " ") b.classList.add("keyboard-space"); row.append(b);
    }
    el.insertBefore(row, scroll);
  }

  const moreRow = document.createElement("div");
  moreRow.className = "key-strip-more";
  const moreBtn = make({ id: MORE_ID, label: "⋯", aria: "More keys", kind: "key" });
  moreBtn.setAttribute("aria-expanded", "false");
  fixed.append(moreBtn);
  for (const def of opts.extra ?? []) fixed.append(make(def));

  let expanded = false;
  const setExpanded = (on: boolean) => {
    expanded = on;
    if (on) {
      moreRow.replaceChildren(...opts.more.map(make));
      el.prepend(moreRow);
      if (!opts.drawer) presentationRoot(parent).dataset[EXPANDED_ATTR] = "expanded";
    } else {
      for (const def of opts.more) buttons.delete(def.id);
      moreRow.remove();
      if (!opts.drawer) delete presentationRoot(parent).dataset[EXPANDED_ATTR];
    }
    moreBtn.setAttribute("aria-expanded", String(on));
    el.classList.toggle("keyboard-functions", on);
  };

  /// Which pointer is holding which modifier, so a second finger cannot release the first one's key.
  /// `engaged` is whether it has gone DOWN yet: a finger on a modifier is only pending until it is
  /// used, because until then it may be a scroll the browser has not claimed.
  const heldBy = new Map<number, { mod: Mod; engaged: boolean }>();

  const refresh = () => {
    const shift = opts.modState("shift") !== "off" || [...heldBy.values()].some(h => h.mod === "shift");
    for (const def of characters) {
      if (def.text && def.text.trim() && def.text !== "\x7f") {
        const b = buttons.get(def.id);
        if (b) b.textContent = shift ? shiftedCharacter(def.text) : def.label;
      }
    }
    for (const def of [...opts.row, ...opts.more, ...compactDefs]) {
      if (def.kind !== "mod" || !def.mod) continue;
      const b = buttons.get(def.id);
      if (!b) continue;
      // A PENDING finger lights the key exactly as a held one does: only ACTIVATION waits for the
      // chord, never the feedback — the finger is on the key and the key says so.
      const pending = [...heldBy.values()].some((h) => h.mod === def.mod);
      const s = pending ? "held" : opts.modState(def.mod);
      b.dataset.state = s;
      b.setAttribute("aria-pressed", String(s !== "off"));
    }
  };

  const defById = (id: string): StripDef | undefined =>
    [...opts.row, ...opts.more, ...(opts.extra ?? []), ...characters, ...compactDefs].find((d) => d.id === id);

  const idAt = (e: Event): string | undefined =>
    (e.target as HTMLElement | null)?.closest<HTMLElement>("[data-key-id]")?.dataset.keyId;

  // ── press + auto-repeat ────────────────────────────────────────────────────────────────────────
  let delay: ReturnType<typeof setTimeout> | undefined;
  let interval: ReturnType<typeof setInterval> | undefined;
  const stopRepeat = () => {
    if (delay !== undefined) { clearTimeout(delay); delay = undefined; }
    if (interval !== undefined) { clearInterval(interval); interval = undefined; }
  };

  const press = (def: StripDef) => {
    if (def.text !== undefined && opts.drawer) opts.drawer.text(opts.modState("shift") !== "off" ? shiftedCharacter(def.text) : def.text);
    else opts.onPress(compactOriginals.get(def.id) ?? def);
    refresh();
  };

  /// Ids whose hold has already started REPEATING. The click that tails that hold must add nothing,
  /// or a held arrow fires one extra step when the finger lifts.
  const repeated = new Set<string>();
  // Secondary touches need not produce a compatibility click. Activate each released touch
  // explicitly and suppress its possible click, so a second finger can type under held modifiers.
  const touchKeys = new Map<number, string>();
  const touchClicks = new Set<string>();
  const pressedPointers = new Map<number, HTMLElement>();
  const releaseHighlight = (pointerId: number) => {
    const button = pressedPointers.get(pointerId); pressedPointers.delete(pointerId);
    if (button && ![...pressedPointers.values()].includes(button)) button.classList.remove("is-pressed");
  };

  // `click` is the ordinary path: it is what a synthetic activation, a keyboard Enter and a screen
  // reader all produce — and a touch that turned into a scroll produces none. `pointerdown` only
  // ARMS the repeat, which fires nothing until the hold outlives `REPEAT_DELAY_MS`.
  el.addEventListener("click", (e) => {
    const id = idAt(e);
    if (!id) return;
    if (touchClicks.delete(id)) return;
    if (repeated.delete(id)) return;      // already fired on pointerdown
    // ⋯ is the strip's OWN control and is deliberately absent from every table, so it has to be
    // matched before `defById` — which would return undefined and silently do nothing.
    if (id === MORE_ID) { setExpanded(!expanded); return; }
    const def = defById(id);
    // A modifier is HELD, handled on pointerdown/up below. Its click is the tail of that gesture and
    // must not fire a press, or every hold would also send a stray key.
    if (def && def.kind !== "mod") press(def);
  });


  /// Put every pending modifier down. Called for anything that makes a finger on a modifier a
  /// CHORD rather than a scroll: another pointer landing (a strip key, the picture — ⌘-click), or a
  /// key arriving from the soft or a hardware keyboard.
  const engage = (except?: number) => {
    let changed = false;
    for (const [id, h] of heldBy) {
      if (h.engaged || id === except) continue;
      h.engaged = true; changed = true;
      opts.onModChange(h.mod, true);
    }
    if (changed) refresh();
  };
  // CAPTURE on the window, so a pending modifier is down BEFORE the handler that reads it — xterm's
  // `onData`, the hidden input's `keydown`/`beforeinput`, the picture's touch. `passive`: it
  // observes and never cancels.
  const onForeignPointer = (e: Event) => { if (!context || context.input.owns(e)) engage((e as PointerEvent).pointerId); };
  const onKey = (e: Event) => { if (!context || context.input.owns(e)) engage(); };
  window.addEventListener("pointerdown", onForeignPointer, { capture: true, passive: true });
  for (const t of ["keydown", "beforeinput"] as const) window.addEventListener(t, onKey, { capture: true });

  el.addEventListener("pointerdown", (e) => {
    const id = idAt(e);
    const def = id ? defById(id) : undefined;
    if (!def || !id) return;
    touchClicks.delete(id);
    if (opts.drawer) {
      const button = (e.target as Element).closest<HTMLElement>("[data-key-id]");
      if (button) {
        pressedPointers.set(e.pointerId, button); button.classList.add("is-pressed");
        try { button.setPointerCapture(e.pointerId); } catch { /* unavailable in synthetic DOMs */ }
      }
    }
    if (opts.drawer && e.pointerType === "touch" && def.kind === "key") touchKeys.set(e.pointerId, id);

    if (def.kind === "mod" && def.mod) {
      // A duplicated pointerdown must not reset an ENGAGED hold to pending, or its release would
      // be sent as a second tap.
      if (heldBy.has(e.pointerId)) return;
      // POINTER CAPTURE is what makes hold usable. Without it a few pixels of finger drift fires
      // `pointerleave` and drops the modifier mid-chord — a ⌘C that works only sometimes. Captured,
      // the release is delivered to this button wherever the finger actually ends up.
      const target = e.target as HTMLElement | null;
      try { target?.closest<HTMLElement>("[data-key-id]")?.setPointerCapture(e.pointerId); }
      catch { /* no capture support: hold still works, it is just drift-sensitive */ }
      heldBy.set(e.pointerId, { mod: def.mod, engaged: false });
      refresh();
      return;
    }

    if (!def.repeat) return;
    stopRepeat();
    delay = setTimeout(() => {
      repeated.add(id);
      press(def);
      interval = setInterval(() => press(def), REPEAT_INTERVAL_MS);
    }, REPEAT_DELAY_MS);
  });

  /// `cancelled` is the browser claiming the touch for a scroll: an unused modifier then sends
  /// NOTHING, where a lifted one is a tap — down and up, so a bare ⇧ or ⌘ still reaches the Mac.
  const releasePointer = (e: PointerEvent, cancelled: boolean) => {
    releaseHighlight(e.pointerId);
    stopRepeat();
    // A cancelled hold gets no click, so nothing else would clear its mark — and the NEXT tap on
    // that key would be swallowed as the tail of a repeat that ended long ago.
    if (cancelled) repeated.clear();
    const h = heldBy.get(e.pointerId);
    if (h === undefined) return;
    heldBy.delete(e.pointerId);
    if (!h.engaged) {
      if (cancelled) { refresh(); return; }
      opts.onModChange(h.mod, true);
    }
    opts.onModChange(h.mod, false);
    refresh();
  };
  el.addEventListener("pointerup", (e) => {
    const id = touchKeys.get(e.pointerId); touchKeys.delete(e.pointerId);
    if (id) {
      const def = defById(id);
      if (def && !repeated.has(id)) press(def);
      repeated.delete(id); touchClicks.add(id);
    }
    releasePointer(e, false);
  });
  el.addEventListener("pointercancel", (e) => { touchKeys.delete(e.pointerId); releasePointer(e, true); });
  el.addEventListener("lostpointercapture", e => {
    if (!pressedPointers.has(e.pointerId)) return;
    touchKeys.delete(e.pointerId); releasePointer(e, true);
  });
  // `pointerleave` only stops an auto-repeat. A held MODIFIER is released by pointerup/pointercancel
  // alone — with capture set, those arrive here even when the finger has wandered off the button.
  el.addEventListener("pointerleave", stopRepeat);

  // LOAD-BEARING — DO NOT LET A KEY TAP STEAL DOM FOCUS.
  //
  // `mousedown`'s default action IS the focus transfer, and on iOS focus leaving the hidden input
  // (or xterm's textarea) closes the soft keyboard. Tapping any key therefore dismissed the keyboard
  // the strip exists to complement, and you had to reopen it after every Esc.
  //
  // It must be `mousedown`, NOT `pointerdown`: preventing the pointer event suppresses the
  // compatibility mouse events and the `click` with them, which would stop every key working.
  // Programmatic focus is unaffected, so the ⌨ toggle still raises and dismisses deliberately.
  el.addEventListener("mousedown", (e) => e.preventDefault());

  (opts.drawer ? queryRoot(parent).getElementById("session") ?? parent : parent).append(el);
  const cancel = () => {
    stopRepeat(); repeated.clear(); touchKeys.clear(); touchClicks.clear();
    for (const id of [...pressedPointers.keys()]) releaseHighlight(id);
    for (const h of heldBy.values()) if (h.engaged) opts.onModChange(h.mod, false);
    heldBy.clear(); refresh();
  };
  const stopRelease = context?.input.onRelease(cancel);
  let disposeDrawer = () => {};
  if (opts.drawer) {
    const trigger = queryRoot(parent).getElementById("keyboard-open");
    const abort = new AbortController();
    const signal = abort.signal;
    const close = () => {
      if (!el.classList.contains("is-open")) return;
      stopRepeat(); repeated.clear(); touchKeys.clear(); touchClicks.clear();
      for (const id of [...pressedPointers.keys()]) releaseHighlight(id);
      for (const h of heldBy.values()) if (h.engaged) opts.onModChange(h.mod, false);
      heldBy.clear(); refresh();
      el.inert = true;
      el.classList.remove("is-open"); trigger?.setAttribute("aria-expanded", "false");
    };
    const header = document.createElement("div"); header.className = "keyboard-drawer-head";
    const title = document.createElement("span"); title.className = "keyboard-drag";
    title.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">' +
      [3, 8, 13].flatMap(y => [3, 8, 13].map(x => `<circle cx="${x}" cy="${y}" r="1.2"/>`)).join("") + '</svg>';
    title.setAttribute("aria-label", "Drag keyboard"); title.title = "Drag to move";
    const mode = document.createElement("div"); mode.className = "keyboard-mode";
    mode.setAttribute("role", "group"); mode.setAttribute("aria-label", "Keyboard layout");
    for (const [label, compact] of [["Compact", true], ["Full", false]] as const) {
      const button = document.createElement("button"); button.type = "button";
      button.textContent = label; button.setAttribute("aria-pressed", String(compact));
      button.addEventListener("click", () => {
        el.classList.toggle("keyboard-compact", compact);
        for (const option of mode.querySelectorAll("button[aria-pressed]")) option.setAttribute("aria-pressed", String(option === button));
        const focused = activeWithin(parent);
        if (!compact && focused instanceof HTMLElement) focused.blur();
        clampPosition();
      });
      mode.append(button);
    }
    const system = document.createElement("button"); system.type = "button"; system.className = "keyboard-system"; system.textContent = "System"; system.setAttribute("aria-label", "System keyboard"); system.title = "System keyboard";
    system.addEventListener("click", () => { close(); opts.drawer!.systemKeyboard(); });
    mode.append(system);
    const dismiss = document.createElement("button"); dismiss.type = "button";
    dismiss.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 6 4 4 4-4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    dismiss.setAttribute("aria-label", "Hide keyboard"); dismiss.addEventListener("click", close);
    header.append(title, mode, dismiss); el.prepend(header);
    // #session is display:contents. Use the actual positioning box, not its zero-sized rect.
    let position: { x: number; y: number } | undefined;
    const clampPosition = () => {
      if (!position || !el.classList.contains("is-open")) return;
      const bounds = (el.offsetParent ?? document.body).getBoundingClientRect();
      const status = trigger?.closest("footer")?.getBoundingClientRect().height ?? 38;
      position.x = Math.max(8, Math.min(position.x, bounds.width - el.offsetWidth - 8));
      position.y = Math.max(8, Math.min(position.y, bounds.height - status - el.offsetHeight - 8));
      el.style.left = `${position.x}px`; el.style.top = `${position.y}px`;
      el.style.right = "auto"; el.style.bottom = "auto";
    };
    let drag: { id: number; x: number; y: number; left: number; top: number } | undefined;
    header.addEventListener("pointerdown", e => {
      if ((e.target as Element).closest("button") || e.button !== 0) return;
      const rect = el.getBoundingClientRect(), bounds = (el.offsetParent ?? document.body).getBoundingClientRect();
      drag = { id: e.pointerId, x: e.clientX, y: e.clientY, left: rect.left - bounds.left, top: rect.top - bounds.top };
      header.setPointerCapture(e.pointerId); e.preventDefault();
    });
    header.addEventListener("pointermove", e => {
      if (!drag || e.pointerId !== drag.id) return;
      position = { x: drag.left + e.clientX - drag.x, y: drag.top + e.clientY - drag.y }; clampPosition();
    });
    for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) header.addEventListener(event, () => { drag = undefined; });
    window.addEventListener("resize", clampPosition, { signal });
    moreBtn.textContent = "Fn";
    trigger?.addEventListener("mousedown", e => e.preventDefault(), { signal });
    trigger?.addEventListener("click", () => {
      if (!opts.drawer!.active()) { close(); return; }
      if (el.classList.contains("is-open")) { close(); return; }
      const focused = activeWithin(parent);
      if (!el.classList.contains("keyboard-compact") && focused instanceof HTMLElement) focused.blur();
      el.inert = false;
      el.classList.add("is-open"); clampPosition(); trigger.setAttribute("aria-expanded", "true");
    }, { signal });
    window.addEventListener("blur", close, { signal });
    document.addEventListener("visibilitychange", () => { if (document.hidden) close(); }, { signal });
    // A floating input palette stays open while the person interacts with the content.
    const observer = new MutationObserver(() => { if (!opts.drawer!.active()) close(); });
    observer.observe(presentationRoot(parent), { attributes: true, attributeFilter: ["data-tab"] });
    disposeDrawer = () => { close(); abort.abort(); observer.disconnect(); };
  }
  refresh();

  return {
    el,
    refresh,
    cancel,
    destroy() {
      stopRelease?.();
      cancel();
      disposeDrawer();
      stopRepeat();
      window.removeEventListener("pointerdown", onForeignPointer, { capture: true });
      for (const t of ["keydown", "beforeinput"] as const) window.removeEventListener(t, onKey, { capture: true });
      if (expanded) setExpanded(false);
      el.remove();
    },
  };
}
