import { SyncFrameGate, type SyncFrameTimers } from "./sync-frames";

/// Server bytes for the terminal, applied as FEW writes as possible.
///
/// xterm.js parses one `write()` in a single synchronous pass and paints once, but it yields to the
/// renderer between writes. So text delivered as many small messages — a full-screen redraw arrives
/// one line per message; a phone returning from the background drains everything queued while it was
/// away — painted line by line when each message was its own awaited write. Here, text that arrives
/// while a write is queued or in flight is appended to the pending text, and the next write takes all
/// of it at once. Order is preserved: text is only ever appended, and one drain is queued at a time.
export class WriteCoalescer {
  private pending = "";
  private scheduled = false;

  constructor(
    /// Runs tasks one after another (main.ts's `enqueue`), so a drain never overlaps another write.
    private readonly schedule: (task: () => Promise<void>) => void,
    private readonly apply: (text: string) => Promise<void>,
  ) {}

  push(text: string): void {
    if (text === "") return;
    this.pending += text;
    if (this.scheduled) return;
    this.scheduled = true;
    this.schedule(async () => {
      this.scheduled = false;
      const t = this.pending;
      this.pending = "";
      await this.apply(t);
    });
  }
}

/// A tab generation's writer as the session builds it: a synchronized frame is held until it is WHOLE
/// (sync-frames.ts — xterm.js skips the paint while one is open), then everything goes through the
/// coalescer. `dispose` drops a held frame and its timer.
export function termWriter<T>(
  schedule: (task: () => Promise<void>) => void,
  apply: (text: string) => Promise<void>,
  timers: SyncFrameTimers<T>,
): { push(text: string): void; dispose(): void } {
  const coalescer = new WriteCoalescer(schedule, apply);
  return new SyncFrameGate((text) => coalescer.push(text), timers);
}
