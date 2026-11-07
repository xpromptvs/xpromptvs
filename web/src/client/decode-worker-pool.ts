/// Decode workers, created at page load and handed out when a track arrives.
///
/// WHY A POOL RATHER THAN ONE PER ATTACH. `new RTCRtpScriptTransform(worker, …)` on a worker that has
/// not finished evaluating its module never delivers — `onrtctransform` simply does not fire, while
/// the receiver's `transform` property reads set on the correct live track. Waiting for the worker to
/// report ready does not fix it either, because that pushes the attach past `createAnswer`, and by
/// then the receiver's pipeline is built.
///
/// A throwaway probe that DID receive frames created its worker at page load and attached seconds
/// later, so the worker was long since running at attach time. This reproduces that: workers are
/// created and warmed as soon as the renderer is selected, and `take()` hands over one that has
/// already installed its handler.
///
/// TESTING PATH ONLY — nothing is created unless `?render=webcodecs` is on.
const POOL_SIZE = 4;   // rdev's cap-N is unbounded in principle, a handful in practice

interface Pooled { worker: Worker; ready: Promise<void> }

let pool: Pooled[] = [];

export function warmDecodeWorkers(): void {
  if (pool.length > 0) return;
  pool = Array.from({ length: POOL_SIZE }, () => {
    const worker = new Worker(new URL("./decode-worker.ts", import.meta.url), { type: "module" });
    const ready = new Promise<void>((resolve) => {
      const onMessage = (e: MessageEvent) => {
        if ((e.data as { type?: string })?.type === "ready") {
          worker.removeEventListener("message", onMessage);
          resolve();
        }
      };
      worker.addEventListener("message", onMessage);
    });
    return { worker, ready };
  });
}

/// A warmed worker, or null when the pool is exhausted. The caller must await `ready` before
/// installing a transform on it.
export function takeDecodeWorker(): Pooled | null {
  return pool.shift() ?? null;
}

/// Return a worker's slot by warming a replacement — the taken worker belongs to its pacer now and is
/// terminated with it.
export function replaceDecodeWorker(): void {
  const worker = new Worker(new URL("./decode-worker.ts", import.meta.url), { type: "module" });
  const ready = new Promise<void>((resolve) => {
    const onMessage = (e: MessageEvent) => {
      if ((e.data as { type?: string })?.type === "ready") {
        worker.removeEventListener("message", onMessage);
        resolve();
      }
    };
    worker.addEventListener("message", onMessage);
  });
  pool.push({ worker, ready });
}
