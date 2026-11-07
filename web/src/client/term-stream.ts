// Decode the shared zstd stream before deciding whether a tab generation needs a record.
import { TermWireDecoder } from './term-wire';
import { TERM_CLOSED, TERM_HISTORY_CHUNK, TERM_HISTORY_END, TERM_OUTPUT, TERM_SCREEN_CHUNK, TERM_SCREEN_END,
         TERM_SNAPSHOT_CHUNK, type TermFrame } from './term-frame';

export interface TermStreamSink {
  /// `historyFollows`: a snapshot of the SCREEN alone — the tab's full snapshot follows as `history`.
  snapshotStart(tab: string, cols: number, rows: number, gen: number, historyFollows?: boolean): void;
  /// `fromSnapshot`: decoded from the generation's snapshot (not its live output) — what a rebuild must not replay.
  bytes(tab: string, gen: number, text: string, fromSnapshot?: boolean): void;
  /// THE LATE HISTORY of generation `gen` (docs/terminal.md, "Scrollback comes after the screen"): the tab's FULL
  /// snapshot as text, taken where that generation's screen snapshot was — whole, assembled after shared decoding.
  history?(tab: string, gen: number, cols: number, rows: number, text: string): void;
  snapshotEnd(tab: string, gen: number): void;
  closed(tab: string): void;
  /// A shared codec failure; tab is empty and gen is zero because every tab is invalidated.
  failed(tab: string, gen: number, err: unknown): void;
  /// A validated RZT1 START: partial old generations are gone; displayed pictures remain.
  wireStart?(): void;
}

interface TabStream { gen: number; decoder: TextDecoder; inSnapshot: boolean; historyFollows: boolean }
interface HistoryStream { gen: number; parts: string[]; decoder: TextDecoder }
const isSnapshotChunk = (k: number) => k === TERM_SNAPSHOT_CHUNK || k === TERM_SCREEN_CHUNK;

/** One shared wire decoder, followed by independent tab display generations. */
export class TermStreamRouter {
  private tabs = new Map<string, TabStream>();
  private histories = new Map<string, HistoryStream>();
  private nextGen = 1;
  private readonly wire: TermWireDecoder;
  readonly stats = { messages: 0, bytes: 0, inflated: 0, decoded: 0, sinkErrors: 0 };

  constructor(private readonly sink: TermStreamSink) {
    this.wire = new TermWireDecoder({
      start: () => this.beginWire(),
      record: frame => { this.stats.inflated += frame.payload.length; this.route(frame); },
      failed: error => { this.clear(); this.call(() => this.sink.failed('', 0, error)); },
    });
  }
  get currentEpoch(): bigint | null { return this.wire.currentEpoch; }
  receive(bytes: Uint8Array): void {
    this.stats.messages++; this.stats.bytes += bytes.length;
    this.wire.receive(bytes);
  }
  beginWire(): void { this.clear(); this.call(() => this.sink.wireStart?.()); }
  resync(): void { this.clear(); this.wire.invalidate(); }
  reset(): void { this.clear(); this.wire.reset(); }
  private clear(): void { this.tabs.clear(); this.histories.clear(); }

  private route(f: TermFrame): void {
    let st = this.tabs.get(f.tab);
    if (f.kind === TERM_CLOSED) {
      this.tabs.delete(f.tab); this.histories.delete(f.tab);
      this.call(() => this.sink.closed(f.tab)); return;
    }
    if (f.kind === TERM_OUTPUT) { if (st) this.feed(f.tab, st, f.payload, false); return; }
    if (f.kind === TERM_HISTORY_CHUNK || f.kind === TERM_HISTORY_END) {
      this.receiveHistory(f, st); return;
    }
    const screen = f.kind === TERM_SCREEN_CHUNK || f.kind === TERM_SCREEN_END;
    if (!st || !st.inSnapshot) st = this.start(f.tab, f.cols ?? 0, f.rows ?? 0, screen);
    st.inSnapshot = isSnapshotChunk(f.kind);
    this.feed(f.tab, st, f.payload, true);
    if (!st.inSnapshot && this.tabs.get(f.tab) === st) this.call(() => this.sink.snapshotEnd(f.tab, st!.gen));
  }
  private feed(tab: string, st: TabStream, payload: Uint8Array, snapshot: boolean): void {
    if (this.tabs.get(tab) !== st) return;
    const text = st.decoder.decode(payload, { stream: true });
    this.stats.decoded += utf8Length(text);
    if (text) this.call(() => this.sink.bytes(tab, st.gen, text, snapshot));
  }
  private start(tab: string, cols: number, rows: number, historyFollows: boolean): TabStream {
    const st: TabStream = { gen: this.nextGen++, decoder: new TextDecoder(), inSnapshot: false, historyFollows };
    this.histories.delete(tab); this.tabs.set(tab, st);
    this.call(() => this.sink.snapshotStart(tab, cols, rows, st.gen, historyFollows));
    return st;
  }
  private receiveHistory(f: TermFrame, st: TabStream | undefined): void {
    // Obsolete history has ALREADY passed through the shared decoder.
    if (!st || !st.historyFollows || st.inSnapshot) return;
    let h = this.histories.get(f.tab);
    if (!h || h.gen !== st.gen) {
      h = { gen: st.gen, parts: [], decoder: new TextDecoder() }; this.histories.set(f.tab, h);
    }
    const text = h.decoder.decode(f.payload, { stream: true });
    this.stats.decoded += utf8Length(text); h.parts.push(text);
    if (f.kind !== TERM_HISTORY_END) return;
    const tail = h.decoder.decode(); this.stats.decoded += utf8Length(tail);
    this.histories.delete(f.tab); st.historyFollows = false;
    const whole = h.parts.join('') + tail;
    this.call(() => this.sink.history?.(f.tab, st.gen, f.cols ?? 0, f.rows ?? 0, whole));
  }
  private call(fn: () => void): void { try { fn(); } catch { this.stats.sinkErrors++; } }
}

export function utf8Length(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) { n += 4; i++; }
    else n += 3;
  }
  return n;
}


const channelGenerations = new WeakMap<TermStreamRouter, object>();
/** A replacement transport gets a fresh epoch namespace and fences all old listeners. */
export function attachTermChannel(router: TermStreamRouter, channel: Pick<EventTarget, 'addEventListener'>): void {
  const token = {}; channelGenerations.set(router, token);
  router.reset(); router.resync();
  channel.addEventListener('message', e => {
    if (channelGenerations.get(router) === token) router.receive(new Uint8Array((e as MessageEvent).data as ArrayBuffer));
  });
}
