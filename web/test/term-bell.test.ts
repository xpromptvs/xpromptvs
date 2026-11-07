import { beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readdirSync, readFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
import type { Terminal as XTerm } from "@xterm/xterm";
import { BELL_TITLE_PREFIX, BellChrome, TabBells, bellTitle, hostBellTab, hostBellWindows, parseTermBell, parseWindowBell } from "../src/client/term-bell";
import { loadRdevUnicode } from "../src/client/term-unicode";

/// `looking`: the tab(s) the person looks at — one key, several, or none.
function bells(looking: () => string | readonly string[] | null = () => null) {
  const changes: boolean[] = [];
  const b = new TabBells({
    looking: () => { const l = looking(); return new Set(l === null ? [] : typeof l === "string" ? [l] : l); },
    changed: (rang: boolean) => changes.push(rang),
  });
  return { b, changes };
}

describe("TabBells", () => {
  it("a tab nobody is looking at keeps its bell until it is looked at", () => {
    let looking: string | null = "pty:1";
    const { b, changes } = bells(() => looking);
    b.ring("terminal", "pty:2");
    expect(b.has("pty:2")).toBe(true);
    expect(b.count).toBe(1);
    expect(changes).toEqual([true]);
    b.look();                                              // still on pty:1
    expect(b.has("pty:2")).toBe(true);
    looking = "pty:2";
    b.look();
    expect(b.has("pty:2")).toBe(false);
    expect(b.count).toBe(0);
    expect(changes).toEqual([true, false]);
  });

  it("the tab being looked at does not keep a bell", () => {
    const { b, changes } = bells(() => "pty:1");
    b.ring("terminal", "pty:1");
    expect(b.count).toBe(0);
    expect(changes).toEqual([]);
  });

  it("nobody looking (page hidden or unfocused) keeps the SHOWN tab's bell too", () => {
    let looking: string | null = null;
    const { b } = bells(() => looking);
    b.ring("terminal", "pty:1");
    expect(b.has("pty:1")).toBe(true);
    looking = "pty:1";                                     // the page came back, showing it
    b.look();
    expect(b.has("pty:1")).toBe(false);
  });

  it("a second bell from a tab already marked changes nothing — it is not news", () => {
    const { b, changes } = bells();
    b.ring("terminal", "pty:2");
    b.ring("terminal", "pty:2");
    expect(b.count).toBe(1);
    expect(changes).toEqual([true]);
  });

  it("each tab counts once, and a NEW tab's bell is news again", () => {
    const { b, changes } = bells();
    b.ring("terminal", "pty:2");
    b.ring("terminal", "tmux:$3");
    expect(b.count).toBe(2);
    expect(changes).toEqual([true, true]);
  });

  it("a tab that closed takes its bell with it", () => {
    const { b, changes } = bells();
    b.ring("terminal", "pty:2");
    b.ring("terminal", "pty:3");
    b.retain("terminal", new Set(["pty:3"]));
    expect([b.has("pty:2"), b.has("pty:3"), b.count]).toEqual([false, true, 1]);
    expect(changes).toEqual([true, true, false]);
    b.retain("terminal", new Set(["pty:3"]));                          // nothing left to drop: no change reported
    expect(changes).toEqual([true, true, false]);
  });

  it("clear forgets every bell, and reports only when there was one", () => {
    const { b, changes } = bells();
    b.clear();
    expect(changes).toEqual([]);
    b.ring("terminal", "pty:2");
    b.clear();
    expect(b.count).toBe(0);
    expect(changes).toEqual([true, false]);
  });
});

// A WINDOW'S BELL (docs/window-capture-and-input.md, "A window's bell"): its application raised its Dock
// badge on the host. Every window of that application rings together, unless the person is in one of them.
describe("TabBells — windows", () => {
  it("marks every window of the application, and is not news while the person is in one of them", () => {
    let looking: readonly string[] = ["pty:1"];
    const { b, changes } = bells(() => looking);
    b.ring("window", "win:11", "win:13");
    expect([b.has("win:11"), b.has("win:13"), b.count]).toEqual([true, true, 2]);
    expect(changes).toEqual([true]);
    looking = ["pty:1", "win:13"];                                          // focused one of them
    b.look();
    expect([b.has("win:11"), b.has("win:13")]).toEqual([true, false]);
    b.ring("window", "win:11", "win:13");                                   // rang again while in win:13
    expect(b.has("win:13")).toBe(false);
    expect(changes).toEqual([true, false]);
  });

  it("a window's and a terminal's marks count together, and each list drops only its own kind", () => {
    const { b, changes } = bells();
    b.ring("terminal", "pty:2");
    b.ring("window", "win:11");
    expect(b.count).toBe(2);
    b.retain("terminal", new Set(["pty:9"]));                              // a term-list without pty:2
    expect([b.has("pty:2"), b.has("win:11")]).toEqual([false, true]);
    b.retain("window", new Set(["win:11"]));                               // a view-set still holding it
    expect(b.has("win:11")).toBe(true);
    b.retain("window", new Set());                                         // it left the session
    expect(b.count).toBe(0);
    expect(changes).toEqual([true, true, false, false]);
  });

  it("the KIND is what rang it, never the key's prefix", () => {
    const { b } = bells();
    b.ring("window", "test-pattern");                                       // the headless harness's one source
    b.retain("terminal", new Set());
    expect(b.has("test-pattern")).toBe(true);
    b.retain("window", new Set());
    expect(b.has("test-pattern")).toBe(false);
  });

  it("parses the host's message, and nothing else", () => {
    expect(parseWindowBell({ t: "window-bell", sources: ["win:11", "win:13"] })).toEqual({ sources: ["win:11", "win:13"] });
    expect(parseWindowBell({ t: "window-bell", sources: ["win:11", 3, ""] })).toEqual({ sources: ["win:11"] });
    expect(parseWindowBell({ t: "window-bell", sources: [] })).toBeNull();
    expect(parseWindowBell({ t: "window-bell", sources: "win:11" })).toBeNull();
    expect(parseWindowBell({ t: "term-bell", sources: ["win:11"] })).toBeNull();
    expect(parseWindowBell(null)).toBeNull();
  });

  it("rings only the driver's windows of the session, and nothing on a window-less client", () => {
    const windows = [{ source: "win:11" }, { source: "win:13" }];
    const bell = { sources: ["win:11", "win:13", "win:99"] };
    expect(hostBellWindows(bell, windows, true, false)).toEqual(["win:11", "win:13"]);
    expect(hostBellWindows(bell, windows, false, false)).toEqual([]);      // passive
    expect(hostBellWindows(bell, windows, true, true)).toEqual([]);        // This Mac shows no windows
  });
});

// THE HOST'S BELL (docs/terminal.md, "The bell"): a BEL in output that reached no client context — the page
// hidden, its terminal paused — comes as `term-bell`, and rings exactly as xterm.js's own would have.
describe("term-bell", () => {
  it("parses the host's message, and nothing else", () => {
    expect(parseTermBell({ t: "term-bell", term: "pty:3" })).toEqual({ term: "pty:3" });
    expect(parseTermBell({ t: "term-bell", term: "tmux:$7" })).toEqual({ term: "tmux:$7" });
    expect(parseTermBell({ t: "term-bell" })).toBeNull();
    expect(parseTermBell({ t: "term-bell", term: 3 })).toBeNull();
    expect(parseTermBell({ t: "term-bell", term: "" })).toBeNull();
    expect(parseTermBell({ t: "term-list", term: "pty:3" })).toBeNull();
    expect(parseTermBell(null)).toBeNull();
  });

  it("rings only a tab this client has, and only for the driver", () => {
    const tabs = { tabs: [{ id: "pty:1", n: 1, title: "" }, { id: "tmux:$2", n: 2, title: "w" }], activeId: "pty:1" };
    expect(hostBellTab({ term: "tmux:$2" }, tabs, true)).toBe("tmux:$2");
    expect(hostBellTab({ term: "pty:9" }, tabs, true)).toBeNull();          // a tab it does not have
    expect(hostBellTab({ term: "pty:1" }, tabs, false)).toBeNull();         // passive: not its tabs
  });

  it("a host bell marks the tab as the client's own does — once, until looked at", () => {
    const { b, changes } = bells(() => null);
    b.ring("terminal", "pty:1");                                                        // the host's term-bell
    b.ring("terminal", "pty:1");                                                        // the client's own, later
    expect(b.count).toBe(1);
    expect(changes).toEqual([true]);
  });
});

describe("bellTitle", () => {
  const base = "Xpromptvs — Your workspace, anywhere.";
  it("prefixes the title while a bell is unseen and gives it back after", () => {
    expect(bellTitle(base, true)).toBe(BELL_TITLE_PREFIX + base);
    expect(bellTitle(BELL_TITLE_PREFIX + base, false)).toBe(base);
  });
  it("is idempotent both ways — never two prefixes, never a title eaten", () => {
    expect(bellTitle(bellTitle(base, true), true)).toBe(BELL_TITLE_PREFIX + base);
    expect(bellTitle(base, false)).toBe(base);
  });
});

describe("BellChrome", () => {
  const page = () => {
    document.head.innerHTML = '<link rel="icon" type="image/png" href="/favicon.png">';
    document.title = "Xpromptvs";
    const counts: number[] = [];
    const badges: string[] = [];
    const chrome = new BellChrome(document, { setBell: (n) => counts.push(n) },
      async (href, dot) => { badges.push(`${href} ${dot}`); return "data:image/png;base64,BADGED"; });
    const icon = () => document.querySelector("link[rel=icon]")!.getAttribute("href");
    return { chrome, counts, badges, icon };
  };
  const settle = () => new Promise((r) => setTimeout(r, 0));

  it("titles, badges and tells the app while a bell is unseen, and gives all three back", async () => {
    const { chrome, counts, badges, icon } = page();
    chrome.show(2);
    await settle();
    expect(document.title).toBe(BELL_TITLE_PREFIX + "Xpromptvs");
    expect(icon()).toBe("data:image/png;base64,BADGED");
    expect(counts).toEqual([2]);
    chrome.show(0);
    await settle();
    expect(document.title).toBe("Xpromptvs");
    expect(icon()).toBe("/favicon.png");
    expect(counts).toEqual([2, 0]);
    chrome.show(1);
    await settle();
    expect(badges.length).toBe(1);                         // the badged icon is drawn once
  });

  it("tells the app only a CHANGE of the count", () => {
    const { chrome, counts } = page();
    chrome.show(1); chrome.show(1); chrome.show(0); chrome.show(0);
    expect(counts).toEqual([1, 0]);
  });

  it("a badge that lands after the bell was seen does not stick", async () => {
    const { chrome, icon } = page();
    chrome.show(1);
    chrome.show(0);                                        // seen before the badge was drawn
    await settle();
    expect(icon()).toBe("/favicon.png");
  });

  it("restore leaves the page as it found it", async () => {
    const { chrome, counts, icon } = page();
    chrome.show(3);
    await settle();
    chrome.restore();
    await settle();
    expect([document.title, icon(), counts.at(-1)]).toEqual(["Xpromptvs", "/favicon.png", 0]);
  });
});

// THE SNAPSHOT NEVER RINGS. A bell is a BYTE in the live stream; a restore (TermSnapshotEmitter's output,
// tmux's snapshot) is a SERIALIZED STATE written into a fresh instance — reconnecting, a resume after a
// hidden page, a resize: if those bytes carried a bare BEL, every one of them would mark every tab.
describe("no restore rings the bell", () => {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const FIX = resolve(__dirname, "../../protocol/fixtures");
  let Terminal: typeof XTerm;
  beforeAll(async () => {
    HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;
    ({ Terminal } = await import("@xterm/xterm"));
  });
  const rings = async (bytes: Uint8Array | string): Promise<number> => {
    const t = new Terminal({ cols: 80, rows: 24, scrollback: 5000, allowProposedApi: true });
    loadRdevUnicode(t);
    let n = 0;
    t.onBell(() => { n++; });
    await new Promise<void>((r) => t.write(bytes, r));
    t.dispose();
    return n;
  };
  const emitted = (dir: string) => (readdirSync(resolve(FIX, dir)) as string[]).filter((f) => f.endsWith(".emitted.bin"));

  it("the counter counts: a bare BEL rings, an OSC ended by BEL does not", async () => {
    expect(await rings("a\x07b")).toBe(1);
    expect(await rings("\x1b]0;title\x07")).toBe(0);
  });
  it("covers both emitters' fixtures", () => {
    expect(emitted("term-snapshot").length).toBe(34);
    expect(emitted("tmux-snapshot").length).toBeGreaterThan(0);
  });
  for (const dir of ["term-snapshot", "tmux-snapshot"]) {
    it(`no ${dir} fixture rings`, async () => {
      for (const f of emitted(dir)) {
        expect([f, await rings(new Uint8Array(readFileSync(resolve(FIX, dir, f))))]).toEqual([f, 0]);
      }
    });
  }
});

it('explicit activation acknowledges only that tab even when the page reports no focus',()=>{
 const {b,changes}=bells();
 b.ring('terminal','tmux:$0','tmux:$1');
 b.acknowledge('tmux:$1');
 expect(b.has('tmux:$1')).toBe(false);expect(b.has('tmux:$0')).toBe(true);
 expect(changes).toEqual([true,false]);
 b.acknowledge('tmux:$1');expect(changes).toEqual([true,false]);
});
