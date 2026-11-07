import { afterEach, describe, expect, it } from "vitest";
import { installGlassesNav } from "../src/client/glasses-nav";
import { chooserBackPending, pushScreenEntry } from "../src/client/glasses-chooser";

// The pinch (Enter) half of the D-pad layer, in jsdom: which focused control gets which activation.
// The sweep and the layout are e2e/glasses-nav-check.mjs's; this is only the per-element dispatch.

let uninstall: (() => void) | null = null;
// Async: a chooser closed here schedules a `history.back()`, whose popstate must land before the
// next test opens one (an open waits for it — see glasses-chooser.ts).
afterEach(async () => {
  uninstall?.(); uninstall = null; document.body.replaceChildren();
  await new Promise((r) => setTimeout(r, 30));
});

function pinch(el: HTMLElement): void {
  el.focus();
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true, cancelable: true }));
}

function select(id: string): HTMLSelectElement {
  const s = document.createElement("select");
  s.dataset.navId = id;
  for (const v of ["a", "b", "c"]) { const o = document.createElement("option"); o.value = v; s.append(o); }
  return s;
}

describe("installGlassesNav — pinch activation", () => {
  it("a pinch on a CHECKBOX toggles it (a text field keeps Enter; a checkbox has nothing to commit)", () => {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.dataset.navId = "home:reduce-motion";
    document.body.append(box);
    uninstall = installGlassesNav(() => ["home:reduce-motion"]);
    pinch(box);
    expect(box.checked).toBe(true);
    pinch(box);
    expect(box.checked).toBe(false);
  });

  it("a pinch on a TEXT field is left to the field", () => {
    const field = document.createElement("input");
    field.type = "text";
    field.dataset.navId = "home:input";
    let clicked = 0;
    field.addEventListener("click", () => clicked++);
    document.body.append(field);
    uninstall = installGlassesNav(() => ["home:input"]);
    pinch(field);
    expect(clicked).toBe(0);
  });

  it("a pinch STEPS a DASHBOARD select and says so with `change`", () => {
    const welcome = document.createElement("div");
    welcome.id = "welcome";
    const s = select("home:theme");
    let changes = 0;
    s.addEventListener("change", () => changes++);
    welcome.append(s);
    document.body.append(welcome);
    uninstall = installGlassesNav(() => ["home:theme"]);
    pinch(s);
    expect(s.value).toBe("b");
    expect(changes).toBe(1);
  });

  // A SESSION select is often a host-side setting — a codec change renegotiates the track — so a
  // pinch must not step it through every option on the way to the one wanted.
  it("a pinch never steps a SESSION select", () => {
    const panel = document.createElement("div");
    panel.className = "win-settings";
    const s = select("win:settings:codec");
    let changes = 0;
    s.addEventListener("change", () => changes++);
    panel.append(s);
    document.body.append(panel);
    uninstall = installGlassesNav(() => ["win:settings:codec"]);
    pinch(s);
    expect(s.value).toBe("a");
    expect(changes).toBe(0);
    document.getElementById("glasses-chooser")?.remove();
  });
});

// A pinch on a SESSION select opens the CHOOSER: the wearer walks the options with the D-pad and a
// pinch on one commits it ONCE — the gear panel's codec renegotiates on every `change`, so the count
// of change events IS the count of renegotiations.
describe("installGlassesNav — the session select chooser", () => {
  // jsdom has no `CSS.escape`, which the D-pad step uses to address `[data-nav-id="…"]`.
  const g = globalThis as { CSS?: { escape?: (s: string) => string } };
  g.CSS ??= {};
  g.CSS.escape ??= (s: string) => s.replace(/["\\]/g, "\\$&");

  function press(key: string): void {
    const t = (document.activeElement as HTMLElement | null) ?? document.body;
    t.dispatchEvent(new KeyboardEvent("keydown", { key, code: key, bubbles: true, cancelable: true }));
  }
  const focusedId = () => (document.activeElement as HTMLElement | null)?.dataset?.navId ?? null;

  function sessionSelect(): { s: HTMLSelectElement; changes: string[] } {
    const panel = document.createElement("div");
    panel.className = "win-settings";
    const row = document.createElement("label");
    row.className = "win-settings-row";
    const name = document.createElement("span");
    name.className = "win-settings-label";
    name.textContent = "Codec";
    const s = document.createElement("select");
    s.dataset.navId = "win:settings:codec";
    for (const v of ["auto", "av1", "h265", "h264"]) {
      const o = document.createElement("option"); o.value = v; o.textContent = v.toUpperCase(); s.append(o);
    }
    s.value = "av1";
    const changes: string[] = [];
    s.addEventListener("change", () => changes.push(s.value));
    row.append(name, s);
    panel.append(row);
    document.body.append(panel);
    uninstall = installGlassesNav(() => ["win:settings:codec", "win:settings:close"]);
    // A fresh entry with nothing forward of it, so `history.length` counts this test's pushes only.
    history.pushState({ screenProbe: true }, "");
    return { s, changes };
  }
  const chooser = () => document.getElementById("glasses-chooser");
  /// Pinch, and insist the sheet is up — every "closes without a change" below is vacuous otherwise.
  function openOn(s: HTMLSelectElement): void {
    pinch(s);
    expect(chooser()).not.toBeNull();
  }

  // Close, then let any back() the close scheduled land, so no test sees another's popstate.
  afterEach(async () => {
    uninstall?.(); uninstall = null;
    chooser()?.remove();
    await new Promise((r) => setTimeout(r, 30));
  });

  it("a pinch OPENS a chooser listing every option, focus on the current value, and changes nothing", () => {
    const { s, changes } = sessionSelect();
    pinch(s);
    const c = chooser();
    expect(c).not.toBeNull();
    expect(c!.querySelector(".glasses-chooser-title")!.textContent).toBe("Codec");
    const opts = [...c!.querySelectorAll<HTMLElement>(".glasses-chooser-option")];
    expect(opts.map((o) => o.textContent)).toEqual(["AUTO", "AV1", "H265", "H264"]);
    expect(opts.every((o) => o.dataset.navId)).toBe(true);        // ids AT THE RENDER SITE
    expect(c!.querySelector('[data-current="true"]')!.textContent).toBe("AV1");
    expect(focusedId()).toBe("chooser:opt:1");
    expect(s.value).toBe("av1");
    expect(changes).toEqual([]);
  });

  it("the D-pad walks the options and is TRAPPED in the sheet, cancel included", () => {
    const { s } = sessionSelect();
    openOn(s);
    const walked: (string | null)[] = [];
    for (let i = 0; i < 6; i++) { press("ArrowDown"); walked.push(focusedId()); }
    expect(walked).toEqual(["chooser:opt:2", "chooser:opt:3", "chooser:cancel",
                            "chooser:opt:0", "chooser:opt:1", "chooser:opt:2"]);
    press("ArrowUp");
    expect(focusedId()).toBe("chooser:opt:1");
  });

  it("a pinch on an option COMMITS it with exactly ONE change, closes, and hands focus back", () => {
    const { s, changes } = sessionSelect();
    openOn(s);
    press("ArrowDown"); press("ArrowDown");                          // AV1 → H265 → H264
    press("Enter");
    expect(s.value).toBe("h264");
    expect(changes).toEqual(["h264"]);                               // ONE renegotiation, not two
    expect(chooser()).toBeNull();
    expect(document.activeElement).toBe(s);
  });

  it("picking the value already selected closes and fires NOTHING", () => {
    const { s, changes } = sessionSelect();
    openOn(s);
    press("Enter");
    expect(chooser()).toBeNull();
    expect(changes).toEqual([]);
    expect(s.value).toBe("av1");
  });

  it("BACK (the real history.back()) closes without a change, even after walking", async () => {
    const { s, changes } = sessionSelect();
    openOn(s);
    press("ArrowDown");
    history.back();                                                   // the glasses' back gesture
    await new Promise((r) => setTimeout(r, 30));
    expect(chooser()).toBeNull();
    expect(changes).toEqual([]);
    expect(s.value).toBe("av1");
    expect(document.activeElement).toBe(s);
  });

  it("the Cancel button closes without a change", () => {
    const { s, changes } = sessionSelect();
    openOn(s);
    let guard = 0;
    while (focusedId() !== "chooser:cancel" && guard++ < 10) press("ArrowDown");
    press("Enter");
    expect(chooser()).toBeNull();
    expect(changes).toEqual([]);
  });

  it("pushes ONE history entry for back to consume", () => {
    const { s } = sessionSelect();
    const before = history.length;
    openOn(s);
    expect(history.length).toBe(before + 1);
    // The entry names the chooser that pushed it (its generation), which is what ties a popstate to it.
    expect(typeof (history.state as { rdevChooser?: unknown } | null)?.rdevChooser).toBe("number");
  });

  it("a select that leaves the document under the sheet commits nothing", () => {
    const { s, changes } = sessionSelect();
    openOn(s);
    press("ArrowDown");
    s.closest(".win-settings")!.remove();
    press("Enter");
    expect(chooser()).toBeNull();
    expect(changes).toEqual([]);
  });

  // WindowManager closes every settings panel on ANY document pointerdown (the desktop dismissal).
  // The chooser is body-level, so a real pointer inside it (a mouse driving `?layout=glasses`) must
  // not reach that listener — it would hide the panel, and the select focus returns to with it.
  it("a pointerdown inside the chooser never reaches a document-level listener", () => {
    const { s } = sessionSelect();
    let dismissed = 0;
    const onDown = () => dismissed++;
    document.addEventListener("pointerdown", onDown);
    try {
      openOn(s);
      for (const el of [chooser()!, chooser()!.querySelector(".glasses-chooser-title")!,
                        chooser()!.querySelector(".glasses-chooser-option")!]) {
        el.dispatchEvent(new Event("pointerdown", { bubbles: true, cancelable: true }));
      }
      expect(dismissed).toBe(0);
      expect(chooser()).not.toBeNull();
    } finally {
      document.removeEventListener("pointerdown", onDown);
    }
  });

  // `history.back()` is ASYNC. A chooser re-opened before the previous one's back() lands must be
  // neither closed by that stale popstate nor left with an orphaned entry.
  it("re-opening before the previous close's back() resolves keeps the NEW chooser, and back still closes it", async () => {
    const { s, changes } = sessionSelect();
    const base = history.length;
    openOn(s);
    press("ArrowDown");
    press("Enter");                                                   // commit H265: close → back() pending
    expect(changes).toEqual(["h265"]);
    pinch(s);                                                         // re-open at once
    await new Promise((r) => setTimeout(r, 50));                      // let the stale back() land
    expect(chooser()).not.toBeNull();
    expect((history.state as { rdevChooser?: unknown } | null)?.rdevChooser).toBeTruthy();
    expect(history.length).toBe(base + 1);                            // no orphaned second entry
    history.back();                                                   // the wearer's back gesture
    await new Promise((r) => setTimeout(r, 50));
    expect(chooser()).toBeNull();
    expect(changes).toEqual(["h265"]);
    expect((history.state as { rdevChooser?: unknown } | null)?.rdevChooser).toBeFalsy();
  });

  // The close above resolves in well under a millisecond in jsdom. A REAL back() can also just be
  // SLOW rather than stuck — nothing distinguishes the two from inside `close()` — so the 500 ms bound
  // must let a re-open through before landing, and the landing must still be recognized correctly
  // whenever it finally arrives. RED before the fix: the bound reset `pendingBack` outright, so the
  // late popstate was checked against the chooser that opened meanwhile and closed IT instead.
  it("a back() that lands LATE (> 500 ms) does not close whatever opened while it was in flight", async () => {
    const { s, changes } = sessionSelect();
    const realBack = window.history.back.bind(window.history);
    try {
      openOn(s);
      press("ArrowDown");                                             // AV1 → H265
      window.history.back = () => { setTimeout(realBack, 700); };     // a real browser, just slow
      press("Enter");                                                 // commit H265: close() calls the slow back()
      expect(changes).toEqual(["h265"]);
      pinch(s);                                                       // re-open at once: deferred
      await new Promise((r) => setTimeout(r, 550));                   // past the 500 ms bound
      expect(chooser()).not.toBeNull();                               // the bound let the re-open through
      expect(typeof (history.state as { rdevChooser?: unknown } | null)?.rdevChooser).toBe("number");
      await new Promise((r) => setTimeout(r, 300));                   // the slow back() (700 ms) now lands
      expect(chooser()).not.toBeNull();                               // still open — the late landing was not misread
      expect(changes).toEqual(["h265"]);                              // no second, unwanted commit
      // The browser may have hopped the position onto the stale entry underneath on its way here
      // (MEASURED: Chromium and WebKit both land a delayed back() on the entry it was called for, not
      // below it, once something else was pushed on top first) — invisible here, and proven harmless
      // just below: ONE real back() still closes the sheet that is actually showing.
    } finally {
      window.history.back = realBack;                                 // never leak the stub past this test
    }
    history.back();                                                   // the wearer's own back, closing the re-opened sheet
    await new Promise((r) => setTimeout(r, 50));
    expect(chooser()).toBeNull();
  });

  // A REAL back() can also never resolve at all (a sandboxed or stubbed history): the deferred
  // re-open must still go through — the bound buys forward progress, not just a correctness window —
  // and an eventual, very late confirmation must still be recognized rather than swallowed as a fresh
  // press on the chooser that opened while it was stuck.
  it("a back() that NEVER lands still lets a deferred re-open through, and is recognized whenever it does", async () => {
    const { s } = sessionSelect();
    const realBack = window.history.back.bind(window.history);
    try {
      openOn(s);
      press("ArrowDown");
      window.history.back = () => { /* the browser never gets to it */ };
      press("Enter");                                                 // commit: close() calls the stuck back()
      expect(chooserBackPending()).toBe(true);
      pinch(s);                                                       // re-open: deferred
      await new Promise((r) => setTimeout(r, 550));                   // past the 500 ms bound
      expect(chooser()).not.toBeNull();                               // forward progress despite the stuck back()
    } finally {
      window.history.back = realBack;                                 // never leak the stub past this test
    }
    // The stuck back() finally happens, long after the bound already let the re-open through.
    history.back();
    await new Promise((r) => setTimeout(r, 50));
    expect(chooserBackPending()).toBe(false);                         // recognized …
    expect(chooser()).not.toBeNull();                                 // … without closing the re-opened sheet
  });

  // A SCREEN change under an open sheet: a `view-set` removed the last source, so its window (and the
  // select) went and `main.ts` moved to the terminal screen, pushing an entry ABOVE the chooser's.
  // Cancel then issued no back() (its entry was not current) and the next back landed on the stale
  // chooser entry — a back press that did nothing visible. The screen's entry takes the chooser's
  // place instead, and the sheet goes with its window.
  it("a screen change under an open chooser closes it and TAKES OVER its entry", async () => {
    const { s, changes } = sessionSelect();
    const base = history.length;
    openOn(s);
    s.closest(".win-settings")?.remove();                             // the window went
    pushScreenEntry({ rdevScreen: "terminal" });                      // main.ts's showTerminalSurface
    await new Promise((r) => setTimeout(r, 50));
    expect(chooser()).toBeNull();
    expect(history.length).toBe(base + 1);                            // no stale chooser entry beneath
    expect((history.state as { rdevScreen?: unknown } | null)?.rdevScreen).toBe("terminal");
    history.back();                                                   // ONE back leaves the terminal screen
    await new Promise((r) => setTimeout(r, 50));
    expect((history.state as { screenProbe?: unknown } | null)?.screenProbe).toBe(true);
    expect(changes).toEqual([]);
  });

  // The same with the chooser's close in flight: a screen pushed before that back() lands would be
  // the entry the back() pops. It waits for the landing, which the screen layer ignores.
  it("a screen change while a closed chooser's back() is in flight is pushed after it lands", async () => {
    const { s, changes } = sessionSelect();
    const base = history.length;
    openOn(s);
    press("ArrowDown");
    press("Enter");                                                   // commit: close → back() pending
    expect(chooserBackPending()).toBe(true);
    pushScreenEntry({ rdevScreen: "terminal" });
    await new Promise((r) => setTimeout(r, 50));
    expect(chooserBackPending()).toBe(false);
    expect(history.length).toBe(base + 1);
    expect((history.state as { rdevScreen?: unknown } | null)?.rdevScreen).toBe("terminal");
    expect(changes).toEqual(["h265"]);
  });

  // TWO screen changes inside that wait each get their entry, in order: one slot kept only the last,
  // so the wearer's back from it skipped the screen between.
  it("two screen changes while a closed chooser's back() is in flight are BOTH pushed, in order", async () => {
    const { s } = sessionSelect();
    const base = history.length;
    openOn(s);
    press("ArrowDown");
    press("Enter");                                                   // commit: close → back() pending
    expect(chooserBackPending()).toBe(true);
    pushScreenEntry({ rdevScreen: "terminal" });
    pushScreenEntry({ rdevScreen: "window" });
    await new Promise((r) => setTimeout(r, 50));
    expect(history.length).toBe(base + 2);
    expect((history.state as { rdevScreen?: unknown } | null)?.rdevScreen).toBe("window");
    history.back();
    await new Promise((r) => setTimeout(r, 50));
    expect((history.state as { rdevScreen?: unknown } | null)?.rdevScreen).toBe("terminal");
  });

  // An open that waited for that landing belonged to the screen it was asked on. When its select has
  // left the document by then (the window went), it must not open a sheet — or push an entry — for it.
  it("a deferred open whose select left the document opens nothing", async () => {
    const { s } = sessionSelect();
    const base = history.length;
    openOn(s);
    press("ArrowDown");
    press("Enter");                                                   // commit: close → back() pending
    pinch(s);                                                         // re-open: deferred
    s.closest(".win-settings")!.remove();                             // the window went meanwhile
    await new Promise((r) => setTimeout(r, 50));
    expect(chooser()).toBeNull();
    // Back on the probe entry; the closed chooser's popped entry is only FORWARD history.
    expect((history.state as { screenProbe?: unknown } | null)?.screenProbe).toBe(true);
    expect(history.length).toBe(base + 1);
  });

  // And a SCREEN change inside the wait drops that open: it was the leaving screen's.
  it("a screen change while an open is deferred drops the open and pushes only the screen", async () => {
    const { s } = sessionSelect();
    const base = history.length;
    openOn(s);
    press("ArrowDown");
    press("Enter");
    pinch(s);                                                         // deferred open, select still here
    pushScreenEntry({ rdevScreen: "terminal" });
    await new Promise((r) => setTimeout(r, 50));
    expect(chooser()).toBeNull();
    expect(history.length).toBe(base + 1);
    expect((history.state as { rdevScreen?: unknown } | null)?.rdevScreen).toBe("terminal");
  });

  // A HELD pinch (key auto-repeat) must not fan out into open/commit/close cycles.
  it("a held pinch opens the chooser ONCE and commits nothing", () => {
    const { s, changes } = sessionSelect();
    const base = history.length;
    pinch(s);
    for (let i = 0; i < 4; i++) {
      (document.activeElement as HTMLElement).dispatchEvent(new KeyboardEvent("keydown",
        { key: "Enter", code: "Enter", repeat: true, bubbles: true, cancelable: true }));
    }
    expect(chooser()).not.toBeNull();
    expect(focusedId()).toBe("chooser:opt:1");
    expect(history.length).toBe(base + 1);
    expect(changes).toEqual([]);
  });

  it("uninstalling the nav (leaving the glasses layout) takes the sheet with it", () => {
    const { s } = sessionSelect();
    openOn(s);
    uninstall?.(); uninstall = null;
    expect(chooser()).toBeNull();
  });

  it("a DASHBOARD select still steps and opens no chooser", () => {
    const welcome = document.createElement("div");
    welcome.id = "welcome";
    const s = select("home:theme");
    welcome.append(s);
    document.body.append(welcome);
    uninstall = installGlassesNav(() => ["home:theme"]);
    pinch(s);
    expect(chooser()).toBeNull();
    expect(s.value).toBe("b");
  });
});
