// THE LATE HISTORY's live text (docs/terminal.md, "Scrollback comes after the screen").
//
// A generation begun by a SCREEN snapshot expects the tab's full snapshot later. Until the rebuild made from it is
// swapped in, the text APPLIED to the generation's instance beyond its own snapshot is kept here, so the rebuild can be
// written exactly that after the history: nothing lost, nothing twice. Two counts meet: the snapshot's characters,
// counted as the router decodes them (`snapshot`), and every character the writer applies, counted at the apply
// (`applied`, inside the op chain) — the writer only concatenates or holds text, in order, so the first `snapshotChars`
// characters applied are the snapshot's and the rest are live, however its writes cut them. The router decodes a
// generation's whole snapshot before any of its output, and counts each piece before the writer can apply it.
//
// `take` hands over what is kept and keeps counting: the rebuild catches up in steps (each its own op) while the swap
// waits for a moment that disturbs nobody. Past `cap` characters kept, the rebuild is abandoned and the tab keeps its
// screen.

interface Entry { snapshotChars: number; applied: number; live: string[]; liveChars: number; abandoned: boolean }

export class LateHistoryLog {
  private readonly entries = new Map<string, Entry>();   // `${tab}#${gen}`

  constructor(private readonly cap: number, private readonly onAbandon: (tab: string, gen: number) => void) {}

  /// A SCREEN snapshot began generation `gen` of `tab`: an older generation's entry has nothing left to rebuild.
  begin(tab: string, gen: number): void {
    this.drop(tab);
    this.entries.set(key(tab, gen), { snapshotChars: 0, applied: 0, live: [], liveChars: 0, abandoned: false });
  }

  /// `chars` more of the generation's SNAPSHOT were decoded (before the writer applies them).
  snapshot(tab: string, gen: number, chars: number): void {
    const e = this.entries.get(key(tab, gen));
    if (e) e.snapshotChars += chars;
  }

  /// `text` was just applied to the generation's instance: keep what of it is beyond the snapshot.
  applied(tab: string, gen: number, text: string): void {
    const e = this.entries.get(key(tab, gen));
    if (!e || e.abandoned) return;
    const from = Math.max(0, e.snapshotChars - e.applied);
    e.applied += text.length;
    if (from >= text.length) return;
    const live = text.slice(from);
    e.live.push(live);
    e.liveChars += live.length;
    if (e.liveChars > this.cap) {
      e.abandoned = true; e.live = []; e.liveChars = 0;
      this.onAbandon(tab, gen);
    }
  }

  /// The generation still expects its rebuild (begun, not abandoned, not ended).
  wants(tab: string, gen: number): boolean {
    const e = this.entries.get(key(tab, gen));
    return !!e && !e.abandoned;
  }

  /// The live text kept since the last `take`, handed over; counting goes on. Null when the generation wants no rebuild.
  take(tab: string, gen: number): string | null {
    const e = this.entries.get(key(tab, gen));
    if (!e || e.abandoned) return null;
    const live = e.live.join("");
    e.live = []; e.liveChars = 0;
    return live;
  }

  /// The rebuild was swapped in, or given up: stop counting.
  end(tab: string, gen: number): void { this.entries.delete(key(tab, gen)); }

  /// Every generation of `tab` (it closed, or a newer generation began).
  drop(tab: string): void {
    for (const k of [...this.entries.keys()]) if (k.startsWith(`${tab}#`)) this.entries.delete(k);
  }

  /// A new wire or a resync: nothing kept belongs to what comes next.
  clear(): void { this.entries.clear(); }
}

const key = (tab: string, gen: number) => `${tab}#${gen}`;

/// What decides whether swapping a rebuild in NOW would disturb the person at its tab (`swapWouldDisturb`).
export interface SwapMoment {
  tab: string;
  /// The tab on screen.
  visible: string | null;
  /// A resize is held for the host's snapshots: the rebuild is at the old grid.
  holding: boolean;
  /// Predictions are drawn over the instance: a swap drops them.
  predicting: boolean;
  /// A selection is up in the instance: it goes with it.
  selecting: boolean;
  /// The last keystroke sent, and to which tab: an IME composition goes with the instance's textarea.
  lastKey: { term: string; at: number } | null;
  now: number;
  /// How long the swap has already waited.
  waitedMs: number;
}

/// A key typed into the tab this recently holds the swap back.
export const SWAP_QUIET_MS = 1000;
/// The swap waits no longer than this: a selection can stay up for minutes, and a tab that never got its scrollback
/// looks exactly like one whose scrollback was lost.
export const SWAP_PATIENCE_MS = 30_000;

/// Swapping the rebuild of `tab` in now would disturb its person. A hidden tab never waits.
export function swapWouldDisturb(m: SwapMoment): boolean {
  if (m.visible !== m.tab || m.waitedMs >= SWAP_PATIENCE_MS) return false;
  if (m.holding || m.predicting || m.selecting) return true;
  return m.lastKey !== null && m.lastKey.term === m.tab && m.now - m.lastKey.at < SWAP_QUIET_MS;
}
