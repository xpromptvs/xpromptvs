import { describe, expect, test } from "vitest";
import {
  DEVICE_POLL_MS, LIVE_POLL_MS, RETRY_MS, SHOWN_AGAIN_MIN_MS, devicePollDelay, startDevicePolling,
  type DevicePollEnv,
} from "../src/shared/device-poll";

/** A clock, timers that can be cancelled, and the two event targets the poller listens on. */
function fakeEnv () {
  let t = 0;
  let hidden = false;
  const timers: { fn: () => void; at: number; live: boolean }[] = [];
  const env: DevicePollEnv = {
    setTimeout: (fn, ms) => { timers.push({ fn, at: t + ms, live: true }); return timers.length - 1; },
    clearTimeout: (h) => { timers[h as number]!.live = false; },
    now: () => t,
    hidden: () => hidden,
    document: new EventTarget(),
    window: new EventTarget(),
  };
  /** Advance to the next live timer and fire it; returns how long that was. */
  const next = async (): Promise<number> => {
    const due = timers.filter((x) => x.live).sort((a, b) => a.at - b.at)[0];
    if (!due) throw new Error("no timer pending");
    const waited = due.at - t;
    t = due.at;
    due.live = false;
    due.fn();
    await new Promise((r) => setTimeout(r, 0));
    return waited;
  };
  const pending = (): number => timers.filter((x) => x.live).length;
  return {
    env, next, pending,
    advance: (ms: number) => { t += ms; },
    setHidden: (h: boolean) => { hidden = h; env.document.dispatchEvent(new Event("visibilitychange")); },
  };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("devicePollDelay", () => {
  test("the steady cadence, then a growing retry that stops growing", () => {
    expect(devicePollDelay(0)).toBe(DEVICE_POLL_MS);
    expect(devicePollDelay(1)).toBe(RETRY_MS[0]);
    expect(devicePollDelay(2)).toBe(RETRY_MS[1]);
    expect(devicePollDelay(99)).toBe(RETRY_MS[RETRY_MS.length - 1]);
    // A retry is SOONER than the steady poll — otherwise a blip would outlast the cadence.
    expect(RETRY_MS[0]!).toBeLessThan(DEVICE_POLL_MS);
  });
});

describe("startDevicePolling", () => {
  test("polls on the steady cadence while answers arrive", async () => {
    const f = fakeEnv();
    let polls = 0;
    const p = startDevicePolling({ env: f.env, poll: async () => { polls++; p.settled(false); } });
    expect(await f.next()).toBe(DEVICE_POLL_MS);
    expect(await f.next()).toBe(DEVICE_POLL_MS);
    expect(polls).toBe(2);
  });

  test("backs off after failures and returns to the cadence on the first success", async () => {
    const f = fakeEnv();
    const answers = [true, true, true, false];     // failed?
    const p = startDevicePolling({ env: f.env, poll: async () => { p.settled(answers.shift()!); } });
    expect(await f.next()).toBe(DEVICE_POLL_MS);   // → fails
    expect(await f.next()).toBe(RETRY_MS[0]);      // → fails
    expect(await f.next()).toBe(RETRY_MS[1]);      // → fails
    expect(await f.next()).toBe(RETRY_MS[2]);      // → succeeds
    expect(await f.next()).toBe(DEVICE_POLL_MS);
  });

  // The app's host answers a poll from its cache and fetches behind it, so the fetch's real outcome
  // arrives on one of the app's own reads, outside any run.
  test("a failure observed OUTSIDE a poll brings the next one forward, once", async () => {
    const f = fakeEnv();
    const p = startDevicePolling({ env: f.env, poll: async () => {} });
    p.settled(true);
    p.settled(true);                                // the same cached answer, repainted
    p.settled(true);
    expect(f.pending()).toBe(1);
    expect(await f.next()).toBe(RETRY_MS[0]);
  });

  test("a hidden page does not poll, and polls at once when shown again", async () => {
    const f = fakeEnv();
    let polls = 0;
    startDevicePolling({ env: f.env, poll: async () => { polls++; } });
    f.setHidden(true);
    expect(f.pending()).toBe(0);
    f.advance(SHOWN_AGAIN_MIN_MS);
    f.setHidden(false);
    await flush();
    expect(polls).toBe(1);
    expect(f.pending()).toBe(1);
  });

  test("shown again moments after a poll does not poll twice", async () => {
    const f = fakeEnv();
    let polls = 0;
    const p = startDevicePolling({ env: f.env, poll: async () => { polls++; } });
    await p.now();
    f.setHidden(true);
    f.setHidden(false);
    await flush();
    expect(polls).toBe(1);
    expect(f.pending()).toBe(1);
  });

  test("the network coming back polls at once and forgets the backoff", async () => {
    const f = fakeEnv();
    let failing = true;
    const p = startDevicePolling({ env: f.env, poll: async () => { p.settled(failing); } });
    await f.next(); await f.next(); await f.next();  // three failures deep
    failing = false;
    f.env.window.dispatchEvent(new Event("online"));
    await flush();
    expect(await f.next()).toBe(DEVICE_POLL_MS);
  });

  test("going offline polls at once, so the list can say so", async () => {
    const f = fakeEnv();
    let polls = 0;
    startDevicePolling({ env: f.env, poll: async () => { polls++; } });
    f.env.window.dispatchEvent(new Event("offline"));
    await flush();
    expect(polls).toBe(1);
  });

  test("now() restarts the cadence from the press, and never overlaps a poll in flight", async () => {
    const f = fakeEnv();
    let polls = 0;
    let release: () => void = () => {};
    const p = startDevicePolling({ env: f.env,
                                   poll: () => { polls++; return new Promise<void>((r) => { release = r; }); } });
    const first = p.now();
    void p.now();                                  // pressed again while the first is out
    expect(polls).toBe(1);
    expect(f.pending()).toBe(0);                   // nothing scheduled behind a poll in flight
    release();
    await first;
    expect(f.pending()).toBe(1);
  });

  test("a thrown poll counts as a failure", async () => {
    const f = fakeEnv();
    const p = startDevicePolling({ env: f.env, poll: async () => { throw new Error("x"); } });
    await p.now();
    expect(await f.next()).toBe(RETRY_MS[0]);
  });

  test("an aborted dashboard stops polling", async () => {
    const f = fakeEnv();
    const abort = new AbortController();
    let polls = 0;
    startDevicePolling({ env: f.env, signal: abort.signal, poll: async () => { polls++; } });
    abort.abort();
    expect(f.pending()).toBe(0);
    f.env.window.dispatchEvent(new Event("online"));
    await flush();
    expect(polls).toBe(0);
  });
});

describe("a live stream slows the poll, never stops it", () => {
  test("devicePollDelay: live is 60 s, failures still retry fast", () => {
    expect(devicePollDelay(0, true)).toBe(LIVE_POLL_MS);
    expect(devicePollDelay(1, true)).toBe(RETRY_MS[0]);
  });

  test("setLive reschedules on the slower cadence, and back", async () => {
    const f = fakeEnv();
    const p = startDevicePolling({ env: f.env, poll: async () => {} });
    p.setLive(true);
    expect(await f.next()).toBe(LIVE_POLL_MS);
    p.setLive(false);
    expect(await f.next()).toBe(DEVICE_POLL_MS);
  });
});
