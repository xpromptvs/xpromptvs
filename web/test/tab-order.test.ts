import { describe, expect, it } from "vitest";
import { moveTab, PendingTabs, tabBarOrder, tabKind } from "../src/client/tab-order";

describe("tabKind", () => {
  it("reads the kind off the PREFIX, as every other id in the protocol does", () => {
    expect(tabKind("pty:3")).toBe("terminal");
    expect(tabKind("tmux:$2")).toBe("terminal");
    expect(tabKind("win:4711")).toBe("window");
    expect(tabKind("dsp:1")).toBe("window");
    expect(tabKind("sim:abc")).toBeNull();
    expect(tabKind("pty")).toBeNull();
  });
});

describe("tabBarOrder", () => {
  it("with no order from the host, is today's bar: the terminals, then the windows", () => {
    expect(tabBarOrder(["pty:1", "tmux:$2"], ["win:7", "dsp:1"], [])).toEqual(["pty:1", "tmux:$2", "win:7", "dsp:1"]);
  });

  it("follows the host's order, interleaved", () => {
    expect(tabBarOrder(["pty:1", "pty:2"], ["win:7"], ["pty:2", "win:7", "pty:1"])).toEqual(["pty:2", "win:7", "pty:1"]);
  });

  it("drops keys this client does not know, and a duplicate", () => {
    expect(tabBarOrder(["pty:1"], ["win:7"], ["pty:9", "win:7", "win:7", "pty:1", "win:8"])).toEqual(["win:7", "pty:1"]);
  });

  it("places a terminal the order does not name yet right after the LAST terminal — where the host will", () => {
    // A term-list lands ahead of the view-set that orders its tab: the tab must not jump when it does.
    expect(tabBarOrder(["pty:1", "pty:2", "pty:3"], ["win:7", "win:8"], ["pty:1", "win:7", "pty:2", "win:8"]))
      .toEqual(["pty:1", "win:7", "pty:2", "pty:3", "win:8"]);
  });

  it("puts a new terminal FIRST when the bar has none, and a new window LAST when it has none", () => {
    expect(tabBarOrder(["pty:4"], ["win:7"], ["win:7"])).toEqual(["pty:4", "win:7"]);
    expect(tabBarOrder(["pty:1"], ["win:9"], ["pty:1"])).toEqual(["pty:1", "win:9"]);
  });

  it("places several new tabs of one kind in their own list's order", () => {
    expect(tabBarOrder(["pty:1", "pty:5", "pty:6"], ["win:7", "win:8", "win:9"], ["win:7", "pty:1"]))
      .toEqual(["win:7", "win:8", "win:9", "pty:1", "pty:5", "pty:6"]);
  });

  it("places by which LIST a key came from, not by its prefix", () => {
    // The headless test pattern's one source is not a `win:` id; it is still a window.
    expect(tabBarOrder(["pty:1"], ["test"], [])).toEqual(["pty:1", "test"]);
    expect(tabBarOrder(["pty:1"], ["test", "other"], ["test"])).toEqual(["pty:1", "test", "other"]);
  });
});

describe("moveTab — the host's moveTab, so the bar can show a drop at once", () => {
  const order = ["pty:1", "win:7", "pty:2", "win:8"];
  it("moves a tab to just before another", () => {
    expect(moveTab(order, "win:8", "pty:1")).toEqual(["win:8", "pty:1", "win:7", "pty:2"]);
    expect(moveTab(order, "pty:1", "win:8")).toEqual(["win:7", "pty:2", "pty:1", "win:8"]);
  });
  it("moves a tab to the END with no `before`", () => {
    expect(moveTab(order, "pty:1", null)).toEqual(["win:7", "pty:2", "win:8", "pty:1"]);
  });
  it("refuses what the host refuses", () => {
    expect(moveTab(order, "pty:9", null)).toBeNull();
    expect(moveTab(order, "pty:1", "pty:9")).toBeNull();
    expect(moveTab(order, "pty:1", "pty:1")).toBeNull();
  });
  it("does not touch its input", () => {
    const copy = [...order];
    moveTab(order, "pty:1", null);
    expect(order).toEqual(copy);
  });
});

describe("PendingTabs — a drop and a rename show at once, until the host says the same", () => {
  it("shows a moved order until the host's agrees, then the host's", () => {
    const p = new PendingTabs();
    p.moved(["pty:2", "pty:1"], 0);
    expect(p.barOrder(["pty:1", "pty:2"], 10)).toEqual(["pty:2", "pty:1"]);
    expect(p.barOrder(["pty:2", "pty:1", "win:7"], 20)).toEqual(["pty:2", "pty:1", "win:7"]);   // confirmed: the host's, new tab and all
    expect(p.barOrder(["pty:1", "pty:2"], 30)).toEqual(["pty:1", "pty:2"]);                     // and it is gone
  });

  it("gives a move the host never echoes (a refusal) up after HOLD_MS", () => {
    const p = new PendingTabs();
    p.moved(["pty:2", "pty:1"], 1000);
    expect(p.barOrder(["pty:1", "pty:2"], 1000 + PendingTabs.HOLD_MS - 1)).toEqual(["pty:2", "pty:1"]);
    expect(p.barOrder(["pty:1", "pty:2"], 1000 + PendingTabs.HOLD_MS)).toEqual(["pty:1", "pty:2"]);
    expect(p.nextExpiry(1000 + PendingTabs.HOLD_MS)).toBeNull();
  });

  it("is confirmed by a host order that agrees on every key the two share", () => {
    const p = new PendingTabs();
    p.moved(["pty:2", "win:7", "pty:1"], 0);
    // pty:1 closed meanwhile and pty:3 opened: what is left of the move is in the host's order.
    expect(p.barOrder(["pty:2", "pty:3", "win:7"], 5)).toEqual(["pty:2", "pty:3", "win:7"]);
    expect(p.nextExpiry(5)).toBeNull();
  });

  it("is NOT confirmed by a host order from before the move", () => {
    const p = new PendingTabs();
    p.moved(["pty:2", "win:7", "pty:1"], 0);
    expect(p.barOrder(["pty:1", "pty:2", "win:7"], 5)).toEqual(["pty:2", "win:7", "pty:1"]);
  });

  it("shows a new name while the host's label is still the one it replaced", () => {
    const p = new PendingTabs();
    p.renamed("pty:1", "build", "zsh", 0);
    expect(p.label("pty:1", "zsh", 10)).toBe("build");
    expect(p.label("pty:2", "zsh", 10)).toBe("zsh");
    expect(p.label("pty:1", "build", 20)).toBe("build");       // the host's echo
    expect(p.label("pty:1", "zsh", 30)).toBe("zsh");           // and the pending one is gone
  });

  it("lets the host's label win as soon as it CHANGES — tmux sanitises a name", () => {
    const p = new PendingTabs();
    p.renamed("tmux:$3", "a:b", "work", 0);
    expect(p.label("tmux:$3", "a_b", 10)).toBe("a_b");
  });

  it("gives a rename the host refused up after HOLD_MS", () => {
    const p = new PendingTabs();
    p.renamed("tmux:$3", "taken", "work", 0);
    expect(p.nextExpiry(0)).toBe(PendingTabs.HOLD_MS);
    expect(p.label("tmux:$3", "work", PendingTabs.HOLD_MS)).toBe("work");
    expect(p.nextExpiry(PendingTabs.HOLD_MS)).toBeNull();
  });

  it("forgets a name the host REFUSED at once (tmux-error rename-failed), not after the hold", () => {
    const p = new PendingTabs();
    p.renamed("tmux:$3", "taken", "work", 0);
    p.refused("tmux:$3");
    expect(p.label("tmux:$3", "work", 10)).toBe("work");
    expect(p.nextExpiry(10)).toBeNull();
  });

  // REGRESSION (found by tab-menu-check's `expiry` negative control): an entry nothing READS again — a
  // name for a tab that closed, an order while a rename holds the bar — never expired, so `nextExpiry`
  // kept answering a time already past and the caller's timer re-armed every millisecond, forever.
  it("never answers an expiry in the past — an entry nobody reads again still goes", () => {
    const p = new PendingTabs();
    p.renamed("pty:9", "gone", "zsh", 0);                     // its tab closes; nothing asks for its label again
    p.moved(["pty:2", "pty:1"], 0);                          // and nothing draws the bar meanwhile
    expect(p.nextExpiry(10)).toBe(PendingTabs.HOLD_MS);
    expect(p.nextExpiry(PendingTabs.HOLD_MS)).toBeNull();
    expect(p.barOrder(["pty:1", "pty:2"], PendingTabs.HOLD_MS)).toEqual(["pty:1", "pty:2"]);
  });
});
