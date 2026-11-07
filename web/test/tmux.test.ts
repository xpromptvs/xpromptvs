import { describe, expect, it } from "vitest";
import { parseTmuxList, parseTmuxClosed, parseTmuxError } from "../src/client/tmux";

describe("tmux wire", () => {
  it("parses a list and refuses malformed ones", () => {
    const sessions = [{ id: "$0", name: "a", windows: 2, attached: 1 }];
    expect(parseTmuxList({ t: "tmux-list", available: true, sessions })).toEqual({ available: true, sessions });
    expect(parseTmuxList({ t: "tmux-list", available: false, sessions: [] })).toEqual({ available: false, sessions: [] });
    expect(parseTmuxList({ t: "tmux-list", available: true, sessions: [{ id: 0, name: "a", windows: 1, attached: 0 }] })).toBeNull();
    expect(parseTmuxList({ t: "tmux-list", sessions })).toBeNull();
    expect(parseTmuxList({ t: "term-list", available: true, sessions })).toBeNull();
    expect(parseTmuxList(null)).toBeNull();
  });

  it("parses tmux-closed and tmux-error", () => {
    expect(parseTmuxClosed({ t: "tmux-closed", session: "$3", reason: "ended" })).toEqual({ session: "$3", reason: "ended" });
    expect(parseTmuxClosed({ t: "tmux-closed", reason: "ended" })).toBeNull();
    expect(parseTmuxError({ t: "tmux-error", session: null, reason: "unavailable" })).toEqual({ session: null, reason: "unavailable" });
    expect(parseTmuxError({ t: "tmux-error", session: "$2", reason: "session-gone" })).toEqual({ session: "$2", reason: "session-gone" });
    expect(parseTmuxError({ t: "tmux-error", session: 2, reason: "x" })).toBeNull();
  });
});
