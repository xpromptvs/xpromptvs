import { describe, expect, it, test } from "vitest";
import { agentsFinished, agentTabs, parseTermError, parseTermList, tabLabel, terminalTabViews, termRenameField, TerminalTabs } from "../src/client/terminal-tabs";

test("parseTermError narrows the host's refusal of an open-terminal", () => {
  expect(parseTermError({ t: "term-error", reason: "too-many-tabs" })).toEqual({ reason: "too-many-tabs" });
  expect(parseTermError({ t: "term-error" })).toBeNull();
  expect(parseTermError({ t: "tmux-error", reason: "x" })).toBeNull();
});

test("parseTermList narrows a valid message", () => {
  const tabs = [
    { id: "pty:1", n: 1, title: "~/build/rdev" },
    { id: "pty:5", n: 3, title: "" },
  ];
  expect(parseTermList({ t: "term-list", tabs, activeId: "pty:5" })).toEqual({ tabs, activeId: "pty:5" });
  expect(parseTermList({ t: "term-list", tabs: [], activeId: null })).toEqual({ tabs: [], activeId: null });
});

test("parseTermList rejects malformed messages", () => {
  expect(parseTermList({ t: "control-state" })).toBeNull();
  expect(parseTermList({ t: "term-list" })).toBeNull();
  expect(parseTermList({ t: "term-list", tabs: [{ id: 1, n: 1, title: "" }], activeId: null })).toBeNull();
  expect(parseTermList({ t: "term-list", tabs: [{ id: "pty:1", n: 1 }], activeId: null })).toBeNull();
  expect(parseTermList(null)).toBeNull();
});

test("parseTermList rejects the retired numeric ids", () => {
  expect(parseTermList({ t: "term-list", tabs: [{ id: 1, n: 1, title: "" }], activeId: 1 })).toBeNull();
  expect(parseTermList({ t: "term-list", tabs: [{ id: "pty:1", n: 1, title: "" }], activeId: 1 })).toBeNull();
});

test("tabLabel prefers the title, falls back to the ordinal", () => {
  expect(tabLabel({ id: "pty:1", n: 2, title: "vim" })).toBe("vim");
  expect(tabLabel({ id: "pty:1", n: 2, title: "" })).toBe("Terminal 2");
});

describe("terminalTabViews", () => {
  it("an active driver sees the host's tabs — every one closable (its ×), the last one too", () => {
    const one = terminalTabViews({ tabs: [{ id: "pty:1", n: 1, title: "zsh" }], activeId: "pty:1" }, true);
    expect(one).toEqual([{ id: "pty:1", label: "zsh", selected: true, tmux: false, working: false }]);

    const two = terminalTabViews(
      { tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "tmux:$2", n: 2, title: "work" }], activeId: "tmux:$2" }, true);
    expect(two).toEqual([
      { id: "pty:1", label: "zsh", selected: false, tmux: false, working: false },
      { id: "tmux:$2", label: "work", selected: true, tmux: true, working: false },
    ]);
  });

  it("a PASSIVE client gets no terminal tab — no stand-in for the host's", () => {
    expect(terminalTabViews(
      { tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "pty:2", n: 2, title: "vim" }], activeId: "pty:2" }, false)).toEqual([]);
    expect(terminalTabViews({ tabs: [], activeId: null }, false)).toEqual([]);
  });
});

/// A tab tap must not take focus from the TERMINAL: on a phone that blur closed the soft keyboard before
/// the switch could hand it on, so typing across a tab switch always dropped it. From anything ELSE it
/// must not keep focus: a window's hidden input left focused behind the terminal surface would type
/// into the Mac window while the terminal is on screen.
describe("TerminalTabs tab mousedown", () => {
  const strip = () => {
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {} });
    t.setActive(true);
    t.update({ tabs: [{ id: "pty:1", title: "a" }, { id: "pty:2", title: "b" }], activeId: "pty:1" } as never);
    return root;
  };
  const press = (el: Element) => {
    const e = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    el.dispatchEvent(e);
    return e.defaultPrevented;
  };

  it("keeps focus in the terminal while the terminal holds it", () => {
    const root = strip();
    const xterm = document.createElement("div"); xterm.className = "xterm";
    const ta = document.createElement("textarea"); xterm.append(ta); document.body.append(xterm);
    ta.focus();
    expect(press(root.querySelectorAll("button")[1]!)).toBe(true);
    xterm.remove(); root.remove();
  });

  it("does NOT keep focus anywhere else", () => {
    const root = strip();
    const other = document.createElement("input"); document.body.append(other);
    other.focus();
    expect(press(root.querySelectorAll("button")[1]!)).toBe(false);
    other.remove(); root.remove();
  });
});

describe("a tab's NAME (rename-tab, docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md)", () => {
  test("parseTermList reads `name` when present and refuses one that is not a string", () => {
    const tabs = [{ id: "pty:1", n: 1, title: "zsh", name: "build" }, { id: "pty:2", n: 2, title: "" }];
    expect(parseTermList({ t: "term-list", tabs, activeId: "pty:1" })).toEqual({ tabs, activeId: "pty:1" });
    expect(parseTermList({ t: "term-list", tabs: [{ id: "pty:1", n: 1, title: "", name: 3 }], activeId: null })).toBeNull();
  });

  test("tabLabel prefers the name, then the title, then the ordinal", () => {
    expect(tabLabel({ id: "pty:1", n: 2, title: "vim", name: "editor" })).toBe("editor");
    expect(tabLabel({ id: "pty:1", n: 2, title: "vim", name: "" })).toBe("vim");
    expect(tabLabel({ id: "pty:1", n: 2, title: "", name: "  " })).toBe("Terminal 2");
  });

  test("terminalTabViews labels a named tab by its name", () => {
    expect(terminalTabViews({ tabs: [{ id: "pty:1", n: 1, title: "zsh", name: "api" }], activeId: null }, true)[0]?.label).toBe("api");
  });

  test("termRenameField: a shell tab opens on its label and empties to its automatic one", () => {
    expect(termRenameField({ id: "pty:1", n: 3, title: "zsh" }))
      .toEqual({ value: "zsh", placeholder: "zsh", named: false, clearable: true });
    expect(termRenameField({ id: "pty:1", n: 3, title: "", name: "api" }))
      .toEqual({ value: "api", placeholder: "Terminal 3", named: true, clearable: true });
  });

  test("termRenameField: a tmux tab's name IS its session's — never cleared", () => {
    expect(termRenameField({ id: "tmux:$2", n: 2, title: "work" }))
      .toEqual({ value: "work", placeholder: "work", named: false, clearable: false });
  });
});

describe("TerminalTabs in the arrangeable bar", () => {
  const tabs = { tabs: [{ id: "pty:1", n: 1, title: "a" }, { id: "tmux:$2", n: 2, title: "b" }], activeId: "pty:1" };
  const mount = (extra: Partial<ConstructorParameters<typeof TerminalTabs>[1]> = {}) => {
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {}, ...extra });
    return { root, t };
  };

  it("keys every tab by its id, and draws none while passive", () => {
    const { root, t } = mount();
    t.setActive(true);
    t.update(tabs);
    expect([...root.querySelectorAll<HTMLElement>(".rl-tab")].map((b) => b.dataset.tabKey)).toEqual(["pty:1", "tmux:$2"]);
    t.setActive(false);
    expect(root.querySelectorAll(".rl-tab")).toHaveLength(0);
    root.remove();
  });

  it("DEFERS its rebuild while held, and draws the latest list on refresh", () => {
    let held = true;
    const rendered: number[] = [];
    const { root, t } = mount({ hold: () => held, rendered: () => rendered.push(1) });
    t.setActive(true);                                   // held: nothing is built
    t.update(tabs);
    expect(root.querySelectorAll(".rl-tab").length).toBe(0);
    t.refresh();                                         // still held: still nothing
    expect(root.querySelectorAll(".rl-tab").length).toBe(0);
    held = false;
    t.refresh();
    expect(root.querySelectorAll(".rl-tab").length).toBe(2);
    expect(rendered.length).toBe(1);
    root.remove();
  });

  it("shows a label the caller overrides — a rename on its way to the host", () => {
    const { root, t } = mount({ label: (key, label) => (key === "pty:1" ? "renamed" : label) });
    t.setActive(true);
    t.update(tabs);
    expect([...root.querySelectorAll(".rl-tab-label")].map((l) => l.textContent)).toEqual(["renamed", "b"]);
    root.remove();
  });
});

// IN PLACE, NOT REBUILT (2026-10-01): iOS WebKit DROPS A TAP whose element is replaced between the touch and
// its click — measured in the iOS 26.5 simulator, 1 tap in 20 registered while the strip was rebuilt after
// each press, 20 in 20 without. A redraw keeps every tab's element and changes only what changed.
describe("TerminalTabs redraws in place", () => {
  const list = (activeId: string, title1 = "zsh") => ({
    tabs: [{ id: "pty:1", n: 1, title: title1 }, { id: "pty:2", n: 2, title: "vim" }], activeId,
  });
  const mount = (onSwitch: (id: string) => void = () => {}) => {
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch, onClose: () => {}, onShowTerminal: () => {} });
    t.setActive(true);
    return { root, t };
  };
  const buttons = (root: HTMLElement) => [...root.querySelectorAll<HTMLElement>(".rl-tab")];

  it("keeps every tab's element across a redraw, and changes its label and selection", () => {
    const { root, t } = mount();
    t.update(list("pty:1"));
    const before = buttons(root);
    t.update(list("pty:2", "zsh — ~/src"));
    const after = buttons(root);
    expect(after[0]).toBe(before[0]);
    expect(after[1]).toBe(before[1]);
    expect(after[0]!.querySelector(".rl-tab-label")!.textContent).toBe("zsh — ~/src");
    expect(after.map((b) => b.classList.contains("on"))).toEqual([false, true]);
    expect(after[1]!.getAttribute("aria-selected")).toBe("true");
    root.remove();
  });

  it("leaves a class another module set (the menu's, a drag's) alone", () => {
    const { root, t } = mount();
    t.update(list("pty:1"));
    buttons(root)[1]!.classList.add("menu-open");
    t.refresh();
    expect(buttons(root)[1]!.classList.contains("menu-open")).toBe(true);
    root.remove();
  });

  it("removes a closed tab's element, builds a new tab's, and follows a new order", () => {
    const { root, t } = mount();
    t.update(list("pty:1"));
    const [one] = buttons(root);
    t.update({ tabs: [{ id: "pty:3", n: 3, title: "new" }, { id: "pty:1", n: 1, title: "zsh" }], activeId: "pty:1" });
    const now = buttons(root);
    expect(now.map((b) => b.dataset.tabKey)).toEqual(["pty:3", "pty:1"]);
    expect(now[1]).toBe(one);
    root.remove();
  });

  it("a click acts on the tab's CURRENT state, not the one it was built with", () => {
    const switched: string[] = [];
    const { root, t } = mount((id) => switched.push(id));
    t.update(list("pty:1"));
    buttons(root)[1]!.click();
    expect(switched).toEqual(["pty:2"]);
    t.update(list("pty:2"));
    buttons(root)[1]!.click();                                   // now the selected tab: no switch
    expect(switched).toEqual(["pty:2"]);
    buttons(root)[0]!.click();
    expect(switched).toEqual(["pty:2", "pty:1"]);
    root.remove();
  });

  it("going passive takes the tabs away, and they come back as new", () => {
    const { root, t } = mount();
    t.setActive(true);
    t.update(list("pty:1"));
    const before = buttons(root);
    t.setActive(false);
    expect(buttons(root)).toEqual([]);
    t.setActive(true);
    expect(buttons(root).map((b) => b.dataset.tabKey)).toEqual(["pty:1", "pty:2"]);
    expect(buttons(root)[0], "a new element").not.toBe(before[0]);
    root.remove();
  });
});

// THE BELL'S MARK (term-bell.ts): a tab that rang unseen carries `data-bell`. Put on a held strip too — a
// mark is not a rebuild, and a bell during a drag must not wait for the drop.
describe("TerminalTabs re-keys a tab shown before the host named it (opening-tab.ts)", () => {
  it("keeps the placeholder's element as the host's tab, which switches and closes by its REAL id", () => {
    const root = document.createElement("div");
    document.body.append(root);
    const switched: string[] = [], closed: string[] = [];
    const t = new TerminalTabs(root, { onSwitch: (id) => switched.push(id), onClose: (id) => closed.push(id), onShowTerminal: () => {} });
    t.setActive(true);
    t.update({ tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "opening:1", n: 0, title: "Terminal 2" }], activeId: "opening:1" });
    const placeholder = root.querySelector<HTMLElement>('[data-tab-key="opening:1"]')!;
    t.rekey("opening:1", "pty:7");
    t.update({ tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "pty:7", n: 2, title: "" }], activeId: "pty:1" });
    const tabs = [...root.querySelectorAll<HTMLElement>(".rl-tab")];
    expect(tabs).toHaveLength(2);
    expect(tabs[1]).toBe(placeholder);                                       // the same element, never rebuilt
    expect(placeholder.dataset.tabKey).toBe("pty:7");
    expect(placeholder.querySelector(".rl-tab-label")!.textContent).toBe("Terminal 2");
    placeholder.click();
    placeholder.querySelector<HTMLElement>(".rl-tab-close")!.click();
    expect(switched).toEqual(["pty:7"]);
    expect(closed).toEqual(["pty:7"]);
    root.remove();
  });

  it("re-keys nothing onto a tab that already has an element", () => {
    const root = document.createElement("div");
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {} });
    t.setActive(true);
    t.update({ tabs: [{ id: "pty:1", n: 1, title: "" }, { id: "opening:1", n: 0, title: "" }], activeId: "pty:1" });
    t.rekey("opening:1", "pty:1");
    expect(root.querySelector('[data-tab-key="opening:1"]')).not.toBeNull();
  });
});

describe("TerminalTabs marks a tab that rang", () => {
  const list = { tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "pty:2", n: 2, title: "vim" }], activeId: "pty:1" };
  const marked = (root: HTMLElement) => [...root.querySelectorAll<HTMLElement>(".rl-tab")].map((b) => b.hasAttribute("data-bell"));

  it("draws the mark the caller reports, and takes it away again", () => {
    const rang = new Set<string>(["pty:2"]);
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {}, bell: (k) => rang.has(k) });
    t.setActive(true);
    t.update(list);
    expect(marked(root)).toEqual([false, true]);
    rang.clear();
    t.markBells();
    expect(marked(root)).toEqual([false, false]);
    root.remove();
  });

  it("marks a HELD strip in place, rebuilding nothing", () => {
    let held = false;
    const rang = new Set<string>();
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {},
      hold: () => held, bell: (k) => rang.has(k) });
    t.setActive(true);
    t.update(list);
    const before = [...root.querySelectorAll(".rl-tab")];
    held = true;
    rang.add("pty:1");
    t.markBells();
    expect(marked(root)).toEqual([true, false]);
    expect([...root.querySelectorAll(".rl-tab")]).toEqual(before);
    root.remove();
  });

  it("a passive client has no tab to mark", () => {
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {}, bell: () => true });
    t.update({ tabs: [{ id: "pty:1", n: 1, title: "zsh" }], activeId: "pty:1" });
    t.setActive(false);
    t.markBells();
    expect(marked(root)).toEqual([]);
    root.remove();
  });
});

it("clears terminal selection on the window surface and restores it without switching shells", () => {
  const root = document.createElement("div");
  let shown = true;
  const tabs = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {}, surfaceShown: () => shown });
  tabs.setActive(true);
  tabs.update({ tabs: [{ id: "one", n: 1, title: "zsh" }], activeId: "one" });
  expect(root.querySelector('[aria-selected="true"]')).not.toBeNull();
  shown = false; tabs.refreshSelection();
  expect(root.querySelector('.on')).toBeNull();
  expect(root.querySelector('[aria-selected="true"]')).toBeNull();
  tabs.update({ tabs: [{ id: "one", n: 1, title: "renamed" }], activeId: "one" });
  expect(root.querySelector('.on')).toBeNull();
  shown = true; tabs.refreshSelection();
  expect(root.querySelector('[aria-selected="true"]')?.textContent).toContain("renamed");
});

describe("an agent's activity (the host's read of a tab's screen — AgentActivity.swift)", () => {
  const tab = (id: string, agent?: "working" | "idle") => ({ id, n: 1, title: "t", ...(agent ? { agent } : {}) });
  const list = (...tabs: ReturnType<typeof tab>[]) => ({ tabs, activeId: tabs[0]?.id ?? null });

  it("parses the state, and refuses one it does not know", () => {
    expect(parseTermList({ t: "term-list", tabs: [tab("pty:1", "working"), tab("pty:2", "idle"), tab("pty:3")], activeId: "pty:1" })?.tabs
      .map((t) => t.agent)).toEqual(["working", "idle", undefined]);
    expect(parseTermList({ t: "term-list", tabs: [{ id: "pty:1", n: 1, title: "t", agent: "busy" }], activeId: null })).toBeNull();
  });

  it("a working tab is marked working, and only that", () => {
    expect(terminalTabViews(list(tab("pty:1", "working"), tab("pty:2", "idle"), tab("pty:3")), true).map((v) => v.working))
      .toEqual([true, false, false]);
  });

  it("finished: the tabs that were working and are not — never a new tab, never one that stayed", () => {
    const before = list(tab("pty:1", "working"), tab("pty:2", "working"), tab("pty:3", "idle"), tab("pty:4"));
    const after = list(tab("pty:1", "idle"), tab("pty:2", "working"), tab("pty:3", "working"), tab("pty:4"), tab("pty:5", "idle"));
    expect(agentsFinished(before, after)).toEqual(["pty:1"]);
    expect(agentsFinished(list(tab("pty:1", "working")), list(tab("pty:1"))), "its agent went").toEqual(["pty:1"]);
    expect(agentsFinished({ tabs: [], activeId: null }, after), "a fresh connection finished nothing").toEqual([]);
  });

  it("the strip marks the shimmering title by an attribute, in place, with aria-busy", () => {
    const root = document.createElement("div");
    document.body.append(root);
    const t = new TerminalTabs(root, { onSwitch: () => {}, onClose: () => {}, onShowTerminal: () => {} });
    t.setActive(true);
    t.update(list(tab("pty:1", "working"), tab("pty:2")));
    const els = [...root.querySelectorAll<HTMLElement>(".rl-tab")];
    expect(els.map((b) => b.hasAttribute("data-agent-working"))).toEqual([true, false]);
    expect(els[0]!.getAttribute("aria-busy")).toBe("true");
    expect(els[0]!.querySelector(".rl-tab-label")).not.toBeNull();
    expect(els[0]!.querySelector(".rl-tab-activity")).toBeNull();
    t.update(list(tab("pty:1", "idle"), tab("pty:2")));
    expect([...root.querySelectorAll(".rl-tab")]).toEqual(els);
    expect(els[0]!.hasAttribute("data-agent-working")).toBe(false);
    expect(els[0]!.hasAttribute("aria-busy")).toBe(false);
    root.remove();
  });
});

describe("agentTabs", () => {
  it("names the tabs the host saw an agent in — working or idle — and no other", () => {
    expect([...agentTabs({ tabs: [
      { id: "tmux:$0", n: 1, title: "a", agent: "working" }, { id: "pty:1", n: 2, title: "zsh" },
      { id: "tmux:$1", n: 3, title: "b", agent: "idle" },
    ], activeId: null })]).toEqual(["tmux:$0", "tmux:$1"]);
    expect(agentTabs({ tabs: [], activeId: null }).size).toBe(0);
  });
});

it('reports explicit activation even for an already selected terminal tab',()=>{
 const root=document.createElement('div');document.body.append(root);
 const activated:string[]=[];
 const tabs=new TerminalTabs(root,{onSwitch(){},onClose(){},onShowTerminal(){},onActivate:id=>activated.push(id)});
 tabs.setActive(true);tabs.update({tabs:[{id:'tmux:$1',n:1,title:'Codex'}],activeId:'tmux:$1'});
 root.querySelector<HTMLButtonElement>('.rl-tab')!.click();
 expect(activated).toEqual(['tmux:$1']);root.remove();
});
