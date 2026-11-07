/// Everything ONE browser session registers, released in one call.
///
/// **WHY THIS EXISTS.** A session used to be a DOCUMENT — the dashboard made an iframe per
/// connection, and removing it released the connection's listeners, timers, observers and decoders by
/// construction. The session runs in the dashboard's own document now
/// (docs/superpowers/specs/2026-09-27-session-without-iframe-design.md), so that release has to be
/// written down, and it is written down HERE, once: every listener a session adds carries this
/// scope's `signal`, every timer is one of its wrappers, every observer is `observe`d and every other
/// teardown is `defer`red. `dispose()` is synchronous and idempotent — immediate cancellation.
///
/// `guard(fn)` is the fence for LATE events: a callback that arrives after dispose (a promise that
/// resolved, a timer a browser had already queued) becomes a no-op.

type Timer = ReturnType<typeof setTimeout>;

interface Disposer { fn: () => void; label: string }

export class SessionScope {
  private readonly controller = new AbortController();
  private readonly disposers: Disposer[] = [];
  private readonly intervals = new Set<Timer>();
  private readonly timeouts = new Set<Timer>();
  private readonly frames = new Set<number>();
  private readonly observers = new Set<{ disconnect(): void }>();
  private done = false;

  /// Aborted by `dispose()`. Pass it to anything that takes one (a `fetch`, a listener this class
  /// does not add itself).
  get signal(): AbortSignal { return this.controller.signal; }

  get disposed(): boolean { return this.done; }

  listen<K extends keyof WindowEventMap>(target: Window, type: K, fn: (e: WindowEventMap[K]) => void,
                                         options?: boolean | AddEventListenerOptions): void;
  listen<K extends keyof DocumentEventMap>(target: Document, type: K, fn: (e: DocumentEventMap[K]) => void,
                                           options?: boolean | AddEventListenerOptions): void;
  listen<K extends keyof HTMLElementEventMap>(target: HTMLElement, type: K,
                                              fn: (e: HTMLElementEventMap[K]) => void,
                                              options?: boolean | AddEventListenerOptions): void;
  listen(target: EventTarget, type: string, fn: (e: Event) => void,
         options?: boolean | AddEventListenerOptions): void;
  listen(target: EventTarget, type: string, fn: (e: never) => void,
         options?: boolean | AddEventListenerOptions): void {
    if (this.done) return;
    // `capture` survives: it is part of a listener's identity, and the signal removes it either way.
    const base: AddEventListenerOptions = typeof options === "boolean" ? { capture: options } : { ...options };
    target.addEventListener(type, fn as unknown as EventListener, { ...base, signal: this.controller.signal });
  }

  interval(fn: () => void, ms: number): Timer | undefined {
    if (this.done) return undefined;
    const id = setInterval(fn, ms);
    this.intervals.add(id);
    return id;
  }

  clearInterval(id: Timer | undefined): void {
    if (id === undefined) return;
    clearInterval(id);
    this.intervals.delete(id);
  }

  timeout(fn: () => void, ms: number): Timer | undefined {
    if (this.done) return undefined;
    // Forgotten when it FIRES, so dispose never clears an id the browser may have handed out again.
    const id: Timer = setTimeout(() => { this.timeouts.delete(id); fn(); }, ms);
    this.timeouts.add(id);
    return id;
  }

  clearTimeout(id: Timer | undefined): void {
    if (id === undefined) return;
    clearTimeout(id);
    this.timeouts.delete(id);
  }

  raf(fn: (t: number) => void): number | undefined {
    if (this.done) return undefined;
    const id = requestAnimationFrame((t) => { this.frames.delete(id); fn(t); });
    this.frames.add(id);
    return id;
  }

  observe<T extends { disconnect(): void }>(observer: T): T {
    if (this.done) { observer.disconnect(); return observer; }
    this.observers.add(observer);
    return observer;
  }

  /// A teardown for `dispose()`, run LIFO in its own try/catch. `label` names it in an error and is
  /// what the TEST-ONLY `__rdevSkipDisposer` matches. Registered after dispose, it runs at once.
  defer(fn: () => void, label = ""): void {
    if (this.done) { runDisposer({ fn, label }); return; }
    this.disposers.push({ fn, label });
  }

  guard<A extends unknown[]>(fn: (...args: A) => void): (...args: A) => void {
    return (...args: A) => { if (!this.done) fn(...args); };
  }

  dispose(): void {
    if (this.done) return;
    this.done = true;
    // The inputs first — no event, timer or frame may reach the session while it is torn down.
    this.controller.abort();
    for (const id of this.intervals) clearInterval(id);
    this.intervals.clear();
    for (const id of this.timeouts) clearTimeout(id);
    this.timeouts.clear();
    for (const id of this.frames) cancelAnimationFrame(id);
    this.frames.clear();
    for (const o of this.observers) {
      try { o.disconnect(); } catch (e) { console.error("[session] an observer did not disconnect", e); }
    }
    this.observers.clear();
    // TEST-ONLY, the same category as `__rdevNavState`: `e2e/session-lifecycle-check.mjs`'s MUTATION
    // arm skips one named disposer and requires its leak probe to see the leak. Nothing in the
    // product sets it.
    const skip = (globalThis as { __rdevSkipDisposer?: string }).__rdevSkipDisposer;
    while (this.disposers.length > 0) {
      const d = this.disposers.pop()!;
      if (d.label !== "" && d.label === skip) {
        console.warn(`[session] TEST-ONLY: skipping the "${d.label}" disposer`);
        continue;
      }
      runDisposer(d);
    }
  }
}

function runDisposer(d: Disposer): void {
  try { d.fn(); } catch (e) { console.error(`[session] the ${d.label || "unnamed"} disposer threw`, e); }
}
