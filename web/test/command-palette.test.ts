import { describe, it, expect } from "vitest";
import { paletteModel, paletteItemSurface, shouldCloseTab, shouldOpenPalette, shouldReopenTerminal, CommandPalette, type PaletteCtx } from "../src/client/command-palette";
import type { Source } from "../src/client/source-picker";
import type { ThumbEntry } from "../src/client/source-gallery";

const sources: Source[] = [
  { id: "win:1", kind: "window", name: "Safari — Anthropic", inputCapable: true, running: true },
  { id: "win:2", kind: "window", name: "Activity Monitor", inputCapable: true, running: true },
  { id: "win:3", kind: "window", name: "Notes — groceries", inputCapable: true, running: false },
];
const thumbs = new Map<string, ThumbEntry>([["win:1", { dataUrl: "data:image/jpeg;base64,QQ" }]]);
const ctx: PaletteCtx = {
  active: true, sources, subscribed: new Set(["win:1"]), focused: "win:1", thumbs, display: null,
  tmux: null, openTmux: new Set(), activeTmux: null,
};

const simulatorSources: Source[] = [
  { id: "sim:on", kind: "simulator", name: "iPhone Running", running: true, inputCapable: true, simState: "booted" },
  { id: "sim:off", kind: "simulator", name: "iPhone Stopped", running: false, inputCapable: true, simState: "shutdown" },
  { id: "sim:starting", kind: "simulator", name: "iPhone Starting", running: false, inputCapable: true, simState: "booting" },
];

describe("paletteModel", () => {
  it("hides stopped simulators from the main grid and offers a launch command", () => {
    const m = paletteModel({ ...ctx, sources: [...sources, ...simulatorSources] }, "");
    expect(m.tiles.map(t => t.id)).toEqual(["win:1", "win:2", "win:3", "sim:on"]);
    expect(m.actions).toContainEqual(expect.objectContaining({ id: "action:launch-simulator", label: "Launch iOS Simulator" }));
  });

  it("offers native simulators with a sleeping host display, never ordinary windows", () => {
    const sim: Source = { id: "sim:abc", kind: "simulator", name: "iPhone", running: true, inputCapable: true };
    const m = paletteModel({ ...ctx, nativeSimulators: true, sources: [...sources, sim], display: { availability: "asleep", locked: false } }, "");
    expect(m.tiles.map(t => t.id)).toEqual(["sim:abc"]);
    expect(m.notice).toBeUndefined();
  });
  it("puts New terminal first and every source in the grid", () => {
    const m = paletteModel(ctx, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:new-terminal"]);
    expect(m.tiles.map((t) => t.id)).toEqual(["win:1", "win:2", "win:3"]);
  });

  it("carries tile state through from galleryTiles", () => {
    const m = paletteModel(ctx, "");
    expect(m.tiles[0]).toMatchObject({ id: "win:1", subscribed: true, focused: true });
    expect(m.tiles[0]?.thumb).toEqual({ kind: "image", dataUrl: "data:image/jpeg;base64,QQ" });
    expect(m.tiles[1]).toMatchObject({ id: "win:2", subscribed: false, focused: false });
    expect(m.tiles[1]?.thumb).toEqual({ kind: "loading" });      // running, capture in flight
    expect(m.tiles[2]?.thumb).toEqual({ kind: "placeholder" });  // not running, no capture coming
  });

  it("filters the grid by app/window name, case-insensitively", () => {
    expect(paletteModel(ctx, "safari").tiles.map((t) => t.id)).toEqual(["win:1"]);
    expect(paletteModel(ctx, "SAFARI").tiles.map((t) => t.id)).toEqual(["win:1"]);
    expect(paletteModel(ctx, "monitor").tiles.map((t) => t.id)).toEqual(["win:2"]);
    // the name is "App — Title", so a title word matches too
    expect(paletteModel(ctx, "groceries").tiles.map((t) => t.id)).toEqual(["win:3"]);
  });

  it("filters actions by label, so a source query hides New terminal", () => {
    expect(paletteModel(ctx, "safari").actions).toEqual([]);
    expect(paletteModel(ctx, "term").actions.map((a) => a.id)).toEqual(["action:new-terminal"]);
  });

  it("returns an empty model rather than throwing when nothing matches", () => {
    const m = paletteModel(ctx, "zzzzz");
    expect(m.actions).toEqual([]);
    expect(m.tiles).toEqual([]);
  });

  it("a PASSIVE client gets only Move here, and no grid it cannot act on", () => {
    const m = paletteModel({ ...ctx, active: false }, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:claim"]);
    expect(m.tiles).toEqual([]);
  });
});

describe("shouldOpenPalette", () => {
  const ev = (init: Partial<KeyboardEvent>) => init as KeyboardEvent;
  it("opens on Cmd+K regardless of where focus is", () => {
    expect(shouldOpenPalette(ev({ key: "k", metaKey: true }), true)).toBe(true);
    expect(shouldOpenPalette(ev({ key: "K", metaKey: true }), false)).toBe(true);
  });
  it("opens on Ctrl+K ONLY outside the terminal — Ctrl+K is readline's kill-line", () => {
    expect(shouldOpenPalette(ev({ key: "k", ctrlKey: true }), false)).toBe(true);
    expect(shouldOpenPalette(ev({ key: "k", ctrlKey: true }), true)).toBe(false);
  });
  it("ignores a bare k and other modifiers", () => {
    expect(shouldOpenPalette(ev({ key: "k" }), false)).toBe(false);
    expect(shouldOpenPalette(ev({ key: "j", metaKey: true }), false)).toBe(false);
    expect(shouldOpenPalette(ev({ key: "k", altKey: true }), false)).toBe(false);
  });
  it("opens on Cmd+T as on Cmd+K, terminal or not — never Ctrl+T (transpose-chars) or Cmd+Shift+T", () => {
    expect(shouldOpenPalette(ev({ key: "t", metaKey: true }), true)).toBe(true);
    expect(shouldOpenPalette(ev({ key: "t", metaKey: true }), false)).toBe(true);
    expect(shouldOpenPalette(ev({ key: "t", ctrlKey: true }), false)).toBe(false);
    expect(shouldOpenPalette(ev({ key: "T", metaKey: true, shiftKey: true }), true)).toBe(false);
    expect(shouldOpenPalette(ev({ key: "t", metaKey: true, altKey: true }), true)).toBe(false);
  });
});

// ⌘W closes the tab in the app (docs/desktop-app.md, "⌘W closes the tab"); ⇧⌘W is the app's Close Window.
describe("shouldCloseTab", () => {
  const ev = (init: Partial<KeyboardEvent>) => init as KeyboardEvent;
  it("is Cmd+W, whatever case the key reports", () => {
    expect(shouldCloseTab(ev({ key: "w", metaKey: true }))).toBe(true);
    expect(shouldCloseTab(ev({ key: "W", metaKey: true }))).toBe(true);
  });
  it("is not Cmd+Shift+W (Close Window), Ctrl+W (the shell's word erase) or a chord with Option", () => {
    expect(shouldCloseTab(ev({ key: "W", metaKey: true, shiftKey: true }))).toBe(false);
    expect(shouldCloseTab(ev({ key: "w", ctrlKey: true }))).toBe(false);
    expect(shouldCloseTab(ev({ key: "w", metaKey: true, altKey: true }))).toBe(false);
    expect(shouldCloseTab(ev({ key: "w" }))).toBe(false);
  });
});

describe("shouldReopenTerminal", () => {
  const ev = (init: Partial<KeyboardEvent>) => init as KeyboardEvent;
  it("is Cmd+Shift+T, whatever case the key reports", () => {
    expect(shouldReopenTerminal(ev({ key: "T", metaKey: true, shiftKey: true }))).toBe(true);
    expect(shouldReopenTerminal(ev({ key: "t", metaKey: true, shiftKey: true }))).toBe(true);
  });
  it("is not Cmd+T, Ctrl+Shift+T or a chord with Option", () => {
    expect(shouldReopenTerminal(ev({ key: "t", metaKey: true }))).toBe(false);
    expect(shouldReopenTerminal(ev({ key: "T", ctrlKey: true, shiftKey: true }))).toBe(false);
    expect(shouldReopenTerminal(ev({ key: "T", metaKey: true, shiftKey: true, altKey: true }))).toBe(false);
    expect(shouldReopenTerminal(ev({ key: "T", metaKey: true, shiftKey: true, ctrlKey: true }))).toBe(false);
  });
});

describe("CommandPalette", () => {
  const mount = () => {
    document.body.innerHTML = `
      <div id="palette" class="hidden">
        <input id="palette-input" />
        <div id="palette-actions"></div><div id="palette-tmux-note" class="hidden"></div>
        <div id="palette-grid"></div>
        <div id="palette-empty" class="hidden"></div>
        <div id="palette-notice" class="hidden">
          <strong id="palette-notice-title"></strong><span id="palette-notice-detail"></span>
        </div>
        <button id="palette-close"></button>
      </div>`;
    const els = {
      overlay: document.getElementById("palette") as HTMLElement,
      input: document.getElementById("palette-input") as HTMLInputElement,
      actions: document.getElementById("palette-actions") as HTMLElement,
      grid: document.getElementById("palette-grid") as HTMLElement,
      empty: document.getElementById("palette-empty") as HTMLElement,
      close: document.getElementById("palette-close") as HTMLButtonElement,
      notice: document.getElementById("palette-notice") as HTMLElement,
      noticeTitle: document.getElementById("palette-notice-title") as HTMLElement,
      noticeDetail: document.getElementById("palette-notice-detail") as HTMLElement,
      tmuxNote: document.getElementById("palette-tmux-note") as HTMLElement,
    };
    const ran: string[] = [];
    return { els, ran, p: new CommandPalette(els, { onRun: (id) => { ran.push(id); } }) };
  };

  it("launches only after choosing a stopped device in the second step", () => {
    const { els, ran, p } = mount();
    p.open({ ...ctx, nativeSimulators: true, sources: simulatorSources });
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:launch-simulator"]')!.click();
    expect(p.isOpen).toBe(true);
    expect(ran).toEqual([]);
    expect(els.grid.children.length).toBe(1);
    expect(els.actions.textContent).toContain("iPhone Stopped");
    expect(els.actions.textContent).not.toContain("iPhone Running");
    expect(els.actions.textContent).not.toContain("iPhone Starting");
    els.input.value = "STOPPED";
    els.input.dispatchEvent(new Event("input"));
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    expect(ran).toEqual(["launch:sim:off"]);
    expect(p.isOpen).toBe(false);
  });

  it("shows running simulators with refreshed thumbnails in the launch picker and opens them normally", () => {
    const { els, ran, p } = mount();
    const context = { ...ctx, nativeSimulators: true, sources: [...sources, ...simulatorSources] };
    p.open(context);
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:launch-simulator"]')!.click();
    expect([...els.grid.querySelectorAll<HTMLElement>(".source-tile")].map(t => t.dataset.source)).toEqual(["sim:on"]);
    expect(els.grid.querySelector(".source-tile-img.loading")).not.toBeNull();
    els.input.value = "Running";
    els.input.dispatchEvent(new Event("input"));
    p.refresh({ ...context, thumbs: new Map([["sim:on", { dataUrl: "data:image/jpeg;base64,QQ" }]]) });
    expect(els.input.value).toBe("Running");
    expect(els.grid.querySelector("img")?.getAttribute("src")).toBe("data:image/jpeg;base64,QQ");
    expect(els.actions.textContent).not.toContain("iPhone Stopped");
    els.grid.querySelector<HTMLButtonElement>(".source-tile")!.click();
    expect(ran).toEqual(["source:sim:on"]);
    expect(p.isOpen).toBe(false);
  });

  it("refreshes the device picker without losing its query and never offers it to a windowless client", () => {
    const { els, p } = mount();
    p.open({ ...ctx, sources: simulatorSources });
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:launch-simulator"]')!.click();
    els.input.value = "Stopped";
    els.input.dispatchEvent(new Event("input"));
    p.refresh({ ...ctx, sources: simulatorSources.filter(s => s.id !== "sim:off") });
    expect(els.input.value).toBe("Stopped");
    expect(els.actions.textContent).not.toContain("iPhone Stopped");
    expect(els.empty.classList.contains("hidden")).toBe(false);
    expect(els.actions.textContent).toContain("Back");
    p.open({ ...ctx, windowless: true, sources: simulatorSources });
    expect(els.actions.textContent).not.toContain("Launch iOS Simulator");
  });

  it("returns with Escape or Back, resets on reopening, and discards the step on loss of control", () => {
    const { els, ran, p } = mount();
    const context = { ...ctx, sources: simulatorSources };
    const enter = () => document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:launch-simulator"]')!.click();
    p.open(context); enter();
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(p.isOpen).toBe(true);
    expect(els.grid.children.length).toBe(1);
    enter();
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:back"]')!.click();
    expect(els.grid.children.length).toBe(1);
    enter(); p.close(); p.open(context);
    expect(els.grid.children.length).toBe(1);
    enter(); p.refresh({ ...context, active: false });
    expect(els.actions.textContent).toContain("Move here");
    expect(els.actions.textContent).not.toContain("iPhone Stopped");
    expect(ran).toEqual([]);
  });

  it("a pick the session WAITS for keeps the palette up (busy) until it lands, then closes it; another pick meanwhile does nothing", async () => {
    const { els } = mount();
    let land = () => {};
    const ran: string[] = [];
    const p = new CommandPalette(els, {
      onRun: (id) => { ran.push(id); return id === "action:new-terminal" ? new Promise<void>((r) => { land = r; }) : undefined; },
      waits: (id) => id === "action:new-terminal",
    });
    p.open(ctx);
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:new-terminal"]')!.click();
    expect(p.isOpen, "up while the terminal is made").toBe(true);
    expect(els.overlay.getAttribute("aria-busy")).toBe("true");
    document.querySelector<HTMLButtonElement>(".source-tile")!.click();
    expect(ran, "the second pick did nothing").toEqual(["action:new-terminal"]);
    land();
    await Promise.resolve(); await Promise.resolve();
    expect(p.isOpen, "closed when it landed").toBe(false);
    expect(els.overlay.hasAttribute("aria-busy")).toBe(false);
  });

  it("every other pick closes the palette FIRST, as before", () => {
    const { els } = mount();
    const openAtRun: boolean[] = [];
    const p = new CommandPalette(els, { onRun: () => { openAtRun.push(p.isOpen); }, waits: () => false });
    p.open(ctx);
    document.querySelector<HTMLButtonElement>('[data-nav-id="palette:action:new-terminal"]')!.click();
    expect(openAtRun).toEqual([false]);
  });

  it("shows the tmux note when tmux is unavailable and hides it otherwise", () => {
    const { els, p } = mount();
    p.open({ ...ctx, tmux: { available: false, sessions: [] } });
    expect(els.tmuxNote.classList.contains("hidden")).toBe(false);
    expect(els.tmuxNote.textContent).toBe("tmux is not installed on the Mac");
    p.refresh({ ...ctx, tmux: { available: true, sessions: [] } });
    expect(els.tmuxNote.classList.contains("hidden")).toBe(true);
  });

  it("groups terminal sessions separately while keyboard navigation follows the visual order", () => {
    const { els, ran, p } = mount();
    p.open({ ...ctx, tmux: { available: true, sessions: [{ id: "main", name: "main", windows: 1, attached: 0 }] } });
    expect([...els.actions.querySelectorAll("h2")].map(el => el.textContent)).toEqual(["Commands", "Open terminals"]);
    for (let i = 0; i < 2; i++) els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown" }));
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    expect(ran).toEqual(["tmux:main"]);
    p.open(ctx);
    expect([...els.actions.querySelectorAll("h2")].map(el => el.textContent)).toEqual(["Commands"]);
  });

  it("renders the action row and one tile per source", () => {
    const { p } = mount();
    p.open(ctx);
    expect(document.querySelectorAll(".pal-row").length).toBe(1);   // New terminal
    expect(document.querySelectorAll(".source-tile").length).toBe(3);
  });

  it("typing filters the grid in place", () => {
    const { els, p } = mount();
    p.open(ctx);
    els.input.value = "safari";
    els.input.dispatchEvent(new Event("input"));
    expect(document.querySelectorAll(".source-tile").length).toBe(1);
    expect(document.querySelectorAll(".pal-row").length).toBe(0);
  });

  it("Enter runs the selected entry; selection starts on the first action", () => {
    const { els, ran, p } = mount();
    p.open(ctx);
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    expect(ran).toEqual(["action:new-terminal"]);
  });

  it("ArrowDown walks from the actions into the grid as one list", () => {
    const { els, ran, p } = mount();
    p.open(ctx);
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    expect(ran).toEqual(["source:win:1"]);
  });

  it("refresh(ctx) re-renders an OPEN palette so late thumbnails appear", () => {
    const { p } = mount();
    p.open({ ...ctx, sources: [], thumbs: new Map() });
    expect(document.querySelectorAll(".source-tile").length).toBe(0);
    p.refresh(ctx);
    expect(document.querySelectorAll(".source-tile").length).toBe(3);
  });

  it("keeps the keyboard selection when a late thumbnail refresh arrives", () => {
    const { els, ran, p } = mount();
    p.open(ctx);
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown" }));
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown" }));
    p.refresh({ ...ctx, thumbs: new Map([["win:2", { dataUrl: "data:image/jpeg;base64,Qg" }]]) });
    els.input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    expect(ran).toEqual(["source:win:2"]);
  });

  it("refresh is a no-op while closed, so a background list can't populate a hidden overlay", () => {
    const { p } = mount();
    p.refresh(ctx);
    expect(document.querySelectorAll(".source-tile").length).toBe(0);
  });

it("renders the notice and suppresses \"No matches\" when the host cannot capture", () => {
    const { p } = mount();
    p.open({ ...ctx, display: { availability: "asleep" } });
    expect(document.getElementById("palette-notice")!.classList.contains("hidden")).toBe(false);
    expect(document.getElementById("palette-notice-title")!.textContent).toMatch(/asleep/i);
    expect(document.querySelectorAll(".source-tile").length).toBe(0);
    // "No matches" beside an explanation is noise.
    expect(document.getElementById("palette-empty")!.classList.contains("hidden")).toBe(true);
  });

  it("hides the notice again for a healthy host", () => {
    const { p } = mount();
    p.open(ctx);
    expect(document.getElementById("palette-notice")!.classList.contains("hidden")).toBe(true);
  });
});

describe("paletteModel — host display availability", () => {
  it("a sleeping host display replaces the grid with an explanation", () => {
    const m = paletteModel({ ...ctx, display: { availability: "asleep" } }, "");
    expect(m.tiles).toHaveLength(0);              // every tile would stream nothing
    expect(m.notice?.title).toMatch(/asleep/i);
    expect(m.actions.map((a) => a.id)).toContain("action:new-terminal");   // the terminal still works
  });

  it("no display attached says so, and names the remedy", () => {
    const m = paletteModel({ ...ctx, display: { availability: "none" } }, "");
    expect(m.tiles).toHaveLength(0);
    expect(m.notice?.detail).toMatch(/display emulator|dummy HDMI/i);
  });

  it("a LOCKED but awake host keeps the grid and adds a banner", () => {
    // LOAD-BEARING: windows genuinely DO capture through a lock screen — measured, thumbnails of
    // Safari and Xcode came back off a locked Mac. Hiding them would throw away a working session;
    // what is broken there is INPUT, and that is what the notice says.
    const m = paletteModel({ ...ctx, display: { availability: "ok", locked: true } }, "");
    expect(m.tiles).toHaveLength(3);
    expect(m.notice?.title).toMatch(/locked/i);
  });

  it("a healthy host has no notice at all", () => {
    expect(paletteModel({ ...ctx, display: { availability: "ok", locked: false } }, "").notice).toBeUndefined();
    expect(paletteModel({ ...ctx, display: null }, "").notice).toBeUndefined();
  });

  it("a passive client still gets only Move here", () => {
    const m = paletteModel({ ...ctx, active: false, display: { availability: "asleep" } }, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:claim"]);
    expect(m.tiles).toHaveLength(0);
  });
});

describe("paletteModel — tmux", () => {
  it("lists tmux sessions as rows and offers New tmux terminal", () => {
    const m = paletteModel({ ...ctx, tmux: { available: true, sessions: [
      { id: "$0", name: "work", windows: 3, attached: 1 }, { id: "$1", name: "idle", windows: 1, attached: 0 }] } }, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:new-tmux", "action:new-terminal", "tmux:$0", "tmux:$1"]);
    expect(m.actions[2]).toMatchObject({ glyph: "$", label: "work", hint: "" });
    expect(m.actions[3]?.hint).toBe("");
  });

  it("open sessions have no status hint, and the query filters sessions by name", () => {
    const m = paletteModel({ ...ctx, tmux: { available: true, sessions: [{ id: "$0", name: "work", windows: 1, attached: 1 }] },
      openTmux: new Set(["$0"]) }, "wor");
    expect(m.actions.map((a) => a.id)).toEqual(["tmux:$0"]);
    expect(m.actions[0]?.hint).toBe("");
  });

  it("tmux unavailable: no tmux rows, a note", () => {
    const m = paletteModel({ ...ctx, tmux: { available: false, sessions: [] } }, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:new-terminal"]);
    expect(m.tmuxNote).toBe("tmux is not installed on the Mac");
  });

  it("no tmux-list yet: nothing tmux, and no note", () => {
    const m = paletteModel(ctx, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:new-terminal"]);
    expect(m.tmuxNote).toBeUndefined();
  });

  it("a PASSIVE client sees no tmux rows", () => {
    const m = paletteModel({ ...ctx, active: false, tmux: { available: true, sessions: [{ id: "$0", name: "w", windows: 1, attached: 0 }] } }, "");
    expect(m.actions.map((a) => a.id)).toEqual(["action:claim"]);
  });

  it("never offers Kill tmux session, including while a tmux tab is active", () => {
    const tmux = { available: true, sessions: [] };
    const ids = (activeTmux: string | null) => paletteModel({ ...ctx, tmux, activeTmux }, "").actions.map((a) => a.id);
    expect(ids("$2")).not.toContain("action:kill-tmux");
    expect(ids(null)).not.toContain("action:kill-tmux");
  });
});

/// Which surface a palette pick lands on. A WINDOW pick on a phone showing the terminal subscribed and
/// focused the source but left `data-tab` on the terminal — the window opened behind it, unseen.
describe("paletteItemSurface", () => {
  it("a window or display pick shows the WINDOW surface", () => {
    expect(paletteItemSurface("source:win:42")).toBe("window");
    expect(paletteItemSurface("source:dsp:1")).toBe("window");
    expect(paletteItemSurface("launch:sim:off")).toBe("window");
  });
  it("a terminal or tmux pick shows the TERMINAL surface", () => {
    for (const id of ["action:new-terminal", "action:new-tmux", "tmux:$3"]) expect(paletteItemSurface(id)).toBe("terminal");
  });
  it("actions that open nothing leave the surface alone", () => {
    for (const id of ["action:claim", "action:kill-tmux", "action:launch-simulator", "action:back", "nonsense"]) expect(paletteItemSurface(id)).toBeNull();
  });
});

describe("smooth scrolling is not a palette command", () => {
  it("is never offered — it is a setting (Terminal Settings, the dashboards' Settings)", () => {
    for (const q of ["", "smooth", "scroll"]) {
      expect(paletteModel(ctx, q).actions.some((a) => /smooth/i.test(a.label))).toBe(false);
    }
  });
});


describe("a window-less session", () => {
  it("offers the terminal's actions and no tiles, whatever the host lists", () => {
    const m = paletteModel({ ...ctx, windowless: true }, "");
    expect(m.tiles).toEqual([]);
    expect(m.notice).toBeUndefined();
    expect(m.actions.map((a) => a.id)).toContain("action:new-terminal");
  });
});

it("offers agent search results as distinct regular session picks", () => {
  const m = paletteModel({...ctx, agents:true, agentSessions:[{id:"one",name:"Build renderer",cwd:"/work/render",status:{type:"active"}}]}, "render");
  expect(m.actions).toContainEqual(expect.objectContaining({id:"agent:one",label:"Build renderer",hint:expect.stringContaining("/work/render")}));
  expect(paletteModel({...ctx, active:false, agents:true, agentSessions:[{id:"one",name:"Build"}]}, "").actions.some(a=>a.id==="agent:one")).toBe(false);
});
it('offers Claude creation only after the host advertises its provider',()=>{
 const legacy=paletteModel({...ctx,active:true,agents:true},'New Claude');
 expect(legacy.actions.some(a=>a.id==='action:new-claude')).toBe(false);
 const supported=paletteModel({...ctx,active:true,agents:true,agentProviders:['codex','claude']},'New Claude');
 expect(supported.actions.some(a=>a.id==='action:new-claude')).toBe(true);
});
