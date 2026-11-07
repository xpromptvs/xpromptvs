import { describe, expect, it } from "vitest";
import type { DirectorySession } from "@rdev/protocol";
import { FOLLOW_POLL_MAX_MS, FOLLOW_POLL_MIN_MS, HostFollow, nextRoom, type Room } from "../src/lib/host-follow";

const MAC = "mac-device-id";
const row = (code: string, device_id = MAC): DirectorySession => ({ code, token: `tok-${code}`, label: "Mac", device_id });

describe("nextRoom", () => {
  it("names the Mac's room when it is not this one", () => {
    expect(nextRoom([row("other", "x"), row("NEW")], MAC, "OLD")).toEqual({ code: "NEW", token: "tok-NEW" });
  });
  it("is nothing while the Mac is listed where this connection already is (a blip)", () => {
    expect(nextRoom([row("OLD")], MAC, "OLD")).toBeNull();
  });
  it("is nothing while the Mac is not listed, whatever else is", () => {
    expect(nextRoom([row("NEW", "another-mac")], MAC, "OLD")).toBeNull();
    expect(nextRoom([], MAC, "OLD")).toBeNull();
  });
});

/// A clock and a directory the test drives.
function rig(opts: { watch?: boolean } = {}) {
  let now = 0;
  const timers: Array<{ at: number; fn: () => void; id: number }> = [];
  let nextId = 1;
  let listing: DirectorySession[] | null = [row("OLD")];
  let lists = 0;
  const found: Room[] = [];
  const watchers: Array<{ onRows: (rows: readonly DirectorySession[]) => void; signal: AbortSignal }> = [];
  const follow = new HostFollow("OLD", {
    list: async () => { lists += 1; return listing; },
    ...(opts.watch === false ? {} : { watch: (onRows: (rows: readonly DirectorySession[]) => void, signal: AbortSignal) => { watchers.push({ onRows, signal }); } }),
    schedule: (fn, ms) => { const id = nextId++; timers.push({ at: now + ms, fn, id }); return id; },
    clear: (t) => { const i = timers.findIndex((x) => x.id === t); if (i >= 0) timers.splice(i, 1); },
    found: (r) => found.push(r),
  });
  /** Advance the clock, running each timer due (and letting its lookup settle). */
  const advance = async (ms: number): Promise<void> => {
    const end = now + ms;
    for (;;) {
      timers.sort((a, b) => a.at - b.at);
      const t = timers[0];
      if (!t || t.at > end) break;
      timers.shift();
      now = t.at;
      t.fn();
      await new Promise((r) => setTimeout(r, 0));
    }
    now = end;
  };
  return {
    follow, found, watchers, advance,
    get lists() { return lists; },
    get pending() { return timers.length; },
    set listing(v: DirectorySession[] | null) { listing = v; },
  };
}

describe("HostFollow", () => {
  it("looks for nothing until a session has said which Mac this is", async () => {
    const r = rig();
    r.follow.arm(0);
    await r.advance(60_000);
    expect(r.lists).toBe(0);
    expect(r.watchers).toHaveLength(0);
    expect(r.follow.isArmed).toBe(false);
  });

  it("follows the Mac once it is listed in another room — from the poll", async () => {
    const r = rig({ watch: false });
    r.follow.learn(MAC);
    r.follow.arm(0);
    await r.advance(0);
    expect(r.lists).toBe(1);
    expect(r.found).toEqual([]);          // still listed in this room: a blip, recovery's
    r.listing = [row("NEW")];
    await r.advance(FOLLOW_POLL_MIN_MS);
    expect(r.found).toEqual([{ code: "NEW", token: "tok-NEW" }]);
    expect(r.follow.isArmed).toBe(false);
    expect(r.pending).toBe(0);
  });

  it("follows the moment the stream lists it, and only once", async () => {
    const r = rig();
    r.follow.learn(MAC);
    r.follow.arm(3000);
    expect(r.watchers).toHaveLength(1);
    r.watchers[0]!.onRows([row("NEW")]);
    r.watchers[0]!.onRows([row("NEW")]);
    expect(r.found).toEqual([{ code: "NEW", token: "tok-NEW" }]);
    expect(r.watchers[0]!.signal.aborted).toBe(true);
    await r.advance(60_000);
    expect(r.lists).toBe(0);              // its poll was never due
  });

  it("the room it moved to is the one it is in: the next arming looks past it", async () => {
    const r = rig();
    r.follow.learn(MAC);
    r.follow.arm(0);
    r.watchers[0]!.onRows([row("NEW")]);
    r.follow.arm(0);
    r.watchers[1]!.onRows([row("NEW")]);
    expect(r.found).toHaveLength(1);
    r.watchers[1]!.onRows([row("THIRD")]);
    expect(r.found.map((f) => f.code)).toEqual(["NEW", "THIRD"]);
  });

  it("backs off while the Mac stays away, and a kick looks now", async () => {
    const r = rig({ watch: false });
    r.follow.learn(MAC);
    r.listing = [];
    r.follow.arm(0);
    await r.advance(0);
    const times: number[] = [];
    for (let elapsed = 0; elapsed < 200_000; elapsed += 1000) {
      const before = r.lists;
      await r.advance(1000);
      if (r.lists > before) times.push(elapsed + 1000);
    }
    const gaps = times.map((t, i) => t - (i === 0 ? 0 : times[i - 1]!));
    expect(gaps.slice(0, 4)).toEqual([2000, 4000, 8000, 16000]);
    expect(Math.max(...gaps)).toBe(FOLLOW_POLL_MAX_MS);
    const before = r.lists;
    r.follow.kick();
    await r.advance(0);
    expect(r.lists).toBe(before + 1);
  });

  it("a failed listing is only another try", async () => {
    const r = rig({ watch: false });
    r.follow.learn(MAC);
    r.listing = null;
    r.follow.arm(0);
    await r.advance(0);
    r.listing = [row("NEW")];
    await r.advance(FOLLOW_POLL_MIN_MS);
    expect(r.found).toHaveLength(1);
  });

  it("disarming — the connection live again — stops the poll, the stream and a lookup in flight", async () => {
    const r = rig();
    r.follow.learn(MAC);
    r.listing = [row("NEW")];
    r.follow.arm(0);
    const watcher = r.watchers[0]!;
    r.follow.disarm();
    expect(watcher.signal.aborted).toBe(true);
    await r.advance(60_000);
    watcher.onRows([row("NEW")]);
    expect(r.found).toEqual([]);
    expect(r.lists).toBe(0);
  });

  it("a listing that lands after the connection came back follows nowhere", async () => {
    let answer: (rows: DirectorySession[]) => void = () => {};
    const found: Room[] = [];
    const follow = new HostFollow("OLD", {
      list: () => new Promise((resolve) => { answer = resolve; }),
      schedule: (fn) => { fn(); return 1; },
      clear: () => {},
      found: (r) => found.push(r),
    });
    follow.learn(MAC);
    follow.arm(0);
    follow.disarm();
    answer([row("NEW")]);
    await new Promise((r) => setTimeout(r, 0));
    expect(found).toEqual([]);
  });

  it("arming again brings a later lookup forward, never back", async () => {
    const r = rig({ watch: false });
    r.follow.learn(MAC);
    r.follow.arm(3000);
    r.follow.arm(3000);                    // a second non-live transition: the first lookup keeps its time
    await r.advance(2999);
    expect(r.lists).toBe(0);
    r.follow.arm(0);                       // the relay says the host left: now
    await r.advance(0);
    expect(r.lists).toBe(1);
  });

  it("disposed, it never arms again", async () => {
    const r = rig();
    r.follow.learn(MAC);
    r.follow.dispose();
    r.follow.arm(0);
    await r.advance(60_000);
    expect(r.lists).toBe(0);
    expect(r.watchers).toHaveLength(0);
  });
});
