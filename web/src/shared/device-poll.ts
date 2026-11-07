/**
 * **THE DEVICE LIST KEEPS ITSELF CURRENT** — on both dashboards, by polling.
 *
 * Until this existed the browser listed once per mount and the app's host fetched once and then
 * answered from its cache forever, so a Mac that started or stopped sharing appeared or vanished
 * only when somebody pressed refresh — and a single failed listing left "Could not reach the control
 * plane" on screen until they did.
 *
 * **POLLING, NOT SERVER-SENT EVENTS**, on purpose. A listing is a SIGNED request under a one-use
 * challenge (`lib/directory-api.ts`, and the host's twin), so a stream would need its own
 * authorisation, its own reconnect and its own liveness check — each of which is a way to sit on a
 * dead connection believing it is live, which is exactly the failure a weak network produces. A poll
 * is a request that either answers within its deadline or does not; there is no state to strand.
 * And the thing being watched changes on §12.2's 30 s heartbeat against a 90 s TTL, so a 15 s poll
 * is already inside the resolution of the data.
 *
 * The cadence:
 * - `DEVICE_POLL_MS` while answers keep arriving;
 * - `RETRY_MS`, growing, after a failure — soon enough that a blip heals before anyone notices, and
 *   capped so a control plane that is down is not hammered by every open dashboard;
 * - NOTHING while the page is hidden, and one poll at once when it is shown again;
 * - one poll at once when the browser says the network is back, with the backoff forgotten.
 *
 * The refresh button stays. It runs the same poll, and it is what a person reaches for when they
 * have just started sharing on another Mac and do not want to wait fifteen seconds to see it.
 */

/** Between successful polls. */
export const DEVICE_POLL_MS = 15_000;

/** Between polls while a live stream is delivering (`lib/directory-watch.ts`): a safety net, not
 *  the source. The poll never STOPS — a stream that dies silently is exactly what it is there for. */
export const LIVE_POLL_MS = 60_000;

/** After consecutive failures: the Nth failure waits `RETRY_MS[N-1]`, and the last one repeats. */
export const RETRY_MS: readonly number[] = [2_000, 5_000, 10_000, 20_000, 30_000];

/** A page shown again within this long of its last poll does not poll again at once. */
export const SHOWN_AGAIN_MIN_MS = 5_000;

export function devicePollDelay (consecutiveFailures: number, live = false): number {
  if (consecutiveFailures <= 0) return live ? LIVE_POLL_MS : DEVICE_POLL_MS;
  return RETRY_MS[Math.min(consecutiveFailures, RETRY_MS.length) - 1]!;
}

export interface DevicePollEnv {
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (t: unknown) => void;
  now: () => number;
  hidden: () => boolean;
  /** Where `visibilitychange` fires. */
  document: EventTarget;
  /** Where `online` and `offline` fire. */
  window: EventTarget;
}

export interface DevicePoller {
  /** Poll now (the refresh button), and restart the cadence from here. */
  now: () => Promise<void>;
  /**
   * Every answer the dashboard paints, whoever asked for it. The app's host answers a poll with
   * what it ALREADY knows and fetches behind it, so the real outcome of that fetch arrives on one of
   * the app's pushed state (`Dashboard.applyDevices`) — this is how the cadence hears about it.
   */
  settled: (failed: boolean) => void;
  /** The stream is (or is no longer) delivering. Moves the cadence; never stops the poll. */
  setLive: (live: boolean) => void;
}

const browserEnv = (): DevicePollEnv => ({
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (t) => clearTimeout(t as ReturnType<typeof setTimeout>),
  now: () => Date.now(),
  hidden: () => document.visibilityState === "hidden",
  document,
  window,
});

export function startDevicePolling (opts: {
  /** One forced listing. Resolves when its answer has been painted (or discarded). */
  poll: () => Promise<void>;
  signal?: AbortSignal;
  env?: DevicePollEnv;
}): DevicePoller {
  const env = opts.env ?? browserEnv();
  const { signal } = opts;
  const listener = signal ? { signal } : undefined;

  let timer: unknown = null;
  let failures = 0;
  let lastFailed = false;
  let running = false;
  let lastRun = -Infinity;
  let live = false;

  const stop = (): void => {
    if (timer !== null) { env.clearTimeout(timer); timer = null; }
  };

  const schedule = (): void => {
    stop();
    if (signal?.aborted || env.hidden()) return;
    timer = env.setTimeout(() => { timer = null; void run(); }, devicePollDelay(failures, live));
  };

  const run = async (): Promise<void> => {
    if (running || signal?.aborted) return;
    running = true;
    stop();
    lastRun = env.now();
    try {
      await opts.poll();
    } catch {
      lastFailed = true;
    } finally {
      running = false;
    }
    failures = lastFailed ? failures + 1 : 0;
    schedule();
  };

  const settled = (failed: boolean): void => {
    const changed = failed !== lastFailed;
    lastFailed = failed;
    // Inside a run, the run counts it. Outside one, only a CHANGE moves the cadence — the app
    // is pushed the same cached answer with every change to its state, and counting each would be a backoff that
    // measured the renderer rather than the network.
    if (running || !changed) return;
    failures = failed ? Math.max(failures, 1) : 0;
    schedule();
  };

  env.document.addEventListener("visibilitychange", () => {
    if (env.hidden()) { stop(); return; }
    if (env.now() - lastRun >= SHOWN_AGAIN_MIN_MS) void run();
    else schedule();
  }, listener);
  // The network is back: whatever the backoff had grown to is about a path that no longer exists.
  env.window.addEventListener("online", () => { failures = 0; void run(); }, listener);
  // Gone: poll once so the list says "offline" now rather than at the next retry.
  env.window.addEventListener("offline", () => { void run(); }, listener);
  signal?.addEventListener("abort", stop);

  const setLive = (next: boolean): void => {
    if (next === live) return;
    live = next;
    if (!running) schedule();
  };

  schedule();
  return { now: run, settled, setLive };
}
