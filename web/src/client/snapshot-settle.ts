/// **A RESIZE'S SNAPSHOT IS COMMITTED WITH THE PROGRAM'S REDRAW, NOT AHEAD OF IT** (docs/terminal.md,
/// "A HOLD, NOT A PREVIEW"). The host snapshots a tab right after resizing it — before the program in it has
/// answered the size change — and the program's redraw follows as output: traced in the app, `less` sent
/// 268 B ~14 ms after the snapshot's end, which landed just after the commit and painted a frame later, a
/// second layout every time (zsh's own 24 B prompt redraw comes as fast). So the commit of a snapshot that
/// answers a held resize WAITS, with the new instance still hidden and taking the output: for the first byte
/// up to `firstMs` after the end, then until `quietMs` pass without one, never past `maxMs` after the end.
///
/// Pure scheduling: the session feeds it the snapshot ends and the bytes, and commits when told (through its
/// op chain, after the writes queued before it).
export interface SnapshotSettleOpts<T> {
  firstMs: number;
  quietMs: number;
  maxMs: number;
  set(f: () => void, ms: number): T;
  clear(t: T): void;
  commit(tab: string, gen: number): void;
}

interface Wait<T> { gen: number; quiet: T; cap: T }

export const SNAPSHOT_SETTLE = { firstMs: 60, quietMs: 16, maxMs: 150 } as const;

export class SnapshotSettle<T> {
  private readonly waits = new Map<string, Wait<T>>();
  constructor(private readonly o: SnapshotSettleOpts<T>) {}

  /// A held snapshot of `tab` (generation `gen`) ended: commit once its redraw is in.
  end(tab: string, gen: number): void {
    this.drop(tab);
    this.waits.set(tab, {
      gen,
      quiet: this.o.set(() => this.fire(tab, gen), this.o.firstMs),
      cap: this.o.set(() => this.fire(tab, gen), this.o.maxMs),
    });
  }

  /// Output for `tab` in generation `gen` arrived: a waiting commit waits `quietMs` more (up to its cap).
  bytes(tab: string, gen: number): void {
    const w = this.waits.get(tab);
    if (!w || w.gen !== gen) return;
    this.o.clear(w.quiet);
    w.quiet = this.o.set(() => this.fire(tab, gen), this.o.quietMs);
  }

  /// `tab` is waiting for a commit.
  waiting(tab: string): boolean { return this.waits.has(tab); }

  /// Forget a waiting commit WITHOUT committing — a newer snapshot of the tab superseded it, or the tab closed.
  drop(tab: string): void {
    const w = this.waits.get(tab);
    if (!w) return;
    this.o.clear(w.quiet);
    this.o.clear(w.cap);
    this.waits.delete(tab);
  }

  dispose(): void { for (const tab of [...this.waits.keys()]) this.drop(tab); }

  private fire(tab: string, gen: number): void {
    const w = this.waits.get(tab);
    if (!w || w.gen !== gen) return;
    this.drop(tab);
    this.o.commit(tab, gen);
  }
}
