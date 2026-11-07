import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SnapshotSettle } from "../src/client/snapshot-settle";

// A held resize's snapshot is committed WITH the program's redraw: the output that follows the snapshot is
// written into the still-hidden instance first (traced: `less`'s redraw, 14 ms after the end, otherwise
// painted a frame after the commit — a second layout).
describe("SnapshotSettle", () => {
  let commits: [string, number, number][];
  let settle: SnapshotSettle<ReturnType<typeof setTimeout>>;
  beforeEach(() => {
    vi.useFakeTimers();
    commits = [];
    settle = new SnapshotSettle({
      firstMs: 60, quietMs: 16, maxMs: 150,
      set: (f, ms) => setTimeout(f, ms), clear: (t) => clearTimeout(t),
      commit: (tab, gen) => commits.push([tab, gen, Date.now()]),
    });
  });
  afterEach(() => { vi.useRealTimers(); });
  const t0 = () => Date.now();

  it("commits a frame after the redraw goes quiet", () => {
    const start = t0();
    settle.end("tmux:$0", 3);
    vi.advanceTimersByTime(14);
    settle.bytes("tmux:$0", 3);                       // the program's redraw
    vi.advanceTimersByTime(15);
    expect(commits).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(commits).toEqual([["tmux:$0", 3, start + 30]]);
  });

  it("with no redraw at all, commits after the first wait", () => {
    const start = t0();
    settle.end("pty:1", 2);
    vi.advanceTimersByTime(59);
    expect(commits).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(commits).toEqual([["pty:1", 2, start + 60]]);
  });

  it("a program that keeps printing is committed at the cap", () => {
    const start = t0();
    settle.end("pty:1", 2);
    for (let i = 0; i < 20; i++) { vi.advanceTimersByTime(10); settle.bytes("pty:1", 2); }
    expect(commits).toEqual([["pty:1", 2, start + 150]]);
    vi.advanceTimersByTime(500);
    expect(commits.length, "once").toBe(1);
  });

  it("bytes of another generation or tab change nothing", () => {
    const start = t0();
    settle.end("pty:1", 2);
    vi.advanceTimersByTime(50);
    settle.bytes("pty:1", 1);
    settle.bytes("pty:2", 2);
    vi.advanceTimersByTime(10);
    expect(commits).toEqual([["pty:1", 2, start + 60]]);
  });

  it("a dropped wait never commits; a new end replaces the old one", () => {
    settle.end("pty:1", 2);
    settle.drop("pty:1");
    vi.advanceTimersByTime(500);
    expect(commits).toEqual([]);
    settle.end("pty:1", 3);
    settle.end("pty:1", 4);
    vi.advanceTimersByTime(500);
    expect(commits.map(c => c[1])).toEqual([4]);
  });

  it("dispose leaves no timer", () => {
    settle.end("pty:1", 2);
    settle.end("tmux:$0", 5);
    settle.dispose();
    expect(vi.getTimerCount()).toBe(0);
  });
});
