import { describe, expect, it } from "vitest";
import { placeholderKey, predictedShellLabel, resolveOpening, withOpening, type OpeningTab } from "../src/client/opening-tab";
import type { TermListMsg } from "../src/client/terminal-tabs";

const list = (ids: [string, number, string?][], activeId: string | null = ids[0]?.[0] ?? null): TermListMsg =>
  ({ tabs: ids.map(([id, n, title]) => ({ id, n, title: title ?? "" })), activeId });

describe("a picked terminal's tab, shown before the host lists it", () => {
  it("a placeholder key is no host id", () => {
    expect(placeholderKey(3)).toBe("opening:3");
    expect(placeholderKey(3).startsWith("pty:") || placeholderKey(3).startsWith("tmux:")).toBe(false);
  });

  it("an open-tmux is resolved by its own id, once listed", () => {
    const o: OpeningTab = { key: "tmux:$4", label: "xpromptvs", req: { id: "tmux:$4" } };
    expect(resolveOpening(o, list([["pty:1", 1]]))).toBeNull();
    expect(resolveOpening(o, list([["pty:1", 1], ["tmux:$4", 2, "xpromptvs"]]))).toBe("tmux:$4");
  });

  it("a new tab is the first listed one of its kind that was not known when it was asked for", () => {
    const o: OpeningTab = { key: "opening:1", label: "Terminal 3", req: { kind: "pty", known: new Set(["pty:1", "tmux:$2"]) } };
    expect(resolveOpening(o, list([["pty:1", 1], ["tmux:$2", 2]]))).toBeNull();
    expect(resolveOpening(o, list([["pty:1", 1], ["tmux:$2", 2], ["tmux:$9", 3]]))).toBeNull();     // another kind
    expect(resolveOpening(o, list([["pty:1", 1], ["tmux:$2", 2], ["pty:7", 3]]))).toBe("pty:7");
    const t: OpeningTab = { key: "opening:2", label: "New session", req: { kind: "tmux", known: new Set(["tmux:$2"]) } };
    expect(resolveOpening(t, list([["tmux:$2", 2], ["tmux:$9", 3]]))).toBe("tmux:$9");
  });

  it("the strip's list carries the opening tab after the host's, selected as asked, until the host lists it", () => {
    const tl = list([["pty:1", 1, "zsh"]]);
    const o: OpeningTab = { key: "opening:1", label: "Terminal 2", req: { kind: "pty", known: new Set(["pty:1"]) } };
    expect(withOpening(tl, o, "opening:1")).toEqual({
      tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "opening:1", n: 0, title: "Terminal 2" }], activeId: "opening:1",
    });
    expect(withOpening(tl, o, "pty:1").activeId).toBe("pty:1");                                     // switched away from it
    expect(withOpening(tl, null, "pty:1")).toEqual({ tabs: tl.tabs, activeId: "pty:1" });
    const tmux: OpeningTab = { key: "tmux:$4", label: "x", req: { id: "tmux:$4" } };
    expect(withOpening(list([["tmux:$4", 2, "x"]]), tmux, "tmux:$4").tabs).toHaveLength(1);         // listed: never twice
  });

  it("a new shell is guessed one past the highest ordinal listed", () => {
    expect(predictedShellLabel(list([]))).toBe("Terminal 1");
    expect(predictedShellLabel(list([["pty:1", 1], ["tmux:$3", 4], ["pty:2", 2]]))).toBe("Terminal 5");
  });
});
