import type { ChannelLike } from "../lib/channel";
import {
  overCaps, pasteBegin, pasteCancel, pasteData, pasteEnd, PASTE_CHUNK_BYTES,
  type PasteErrorReason, type PasteItemDecl, type PastePoint, type PasteReply, type PasteTo,
} from "./paste-wire";

/// THE UPLOADER (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3): one DELIVERY at a time, in
/// the order asked; its items' bytes in 16 KiB pieces on `bulk` (on `control` until control joined the lane —
/// docs/terminal.md, "The lane"), PACED so the channel never holds more than 256 KiB unsent, and only
/// once the Mac has ACCEPTED the delivery (`paste-accepted`). It always ends: done, a host error, a cancel,
/// the channel closing, no acceptance within `ACCEPT_TIMEOUT_MS`, or no answer within `REPLY_TIMEOUT_MS`.

export type PasteSource = { kind: "file"; name: string; type: string; blob: Blob } | { kind: "text"; text: string };
export interface Delivery { to: PasteTo; at?: PastePoint; items: PasteSource[] }
export type Outcome =
  | { ok: true; how: "paste" | "drop" }
  | { ok: false; reason: PasteErrorReason | "cancelled" | "closed" | "timeout" | "unanswered" };

export const PACE_HIGH_BYTES = 256 * 1024;
/// From `paste-end` to the Mac's answer: its work on a big image (a HEIC's conversion, a drop) can take seconds.
export const REPLY_TIMEOUT_MS = 60_000;
/// From `paste-begin` to `paste-accepted`: one round trip and the paste queue's turn — never the upload.
export const ACCEPT_TIMEOUT_MS = 5_000;
/// How often the progress is read once every piece is handed over, while the channel still holds some.
export const DRAIN_POLL_MS = 200;

export interface UploaderDeps {
  /// The CURRENT `bulk` channel. A different one mid-upload (a rebuild) fails the upload.
  channel(): ChannelLike | null;
  send(msg: unknown): void;
  /// Bytes the channel has actually SENT (handed over minus still buffered), of the delivery's total.
  onProgress?(sent: number, total: number, d: Delivery): void;
  sleep?(ms: number): Promise<void>;
  newId?(): string;
}

interface Current { id: string; ch: ChannelLike; done: Outcome | null; settle(o: Outcome): void; accept(): void }

const utf8 = new TextEncoder();

export class PasteUploader {
  private chain: Promise<unknown> = Promise.resolve();
  private current: Current | null = null;
  private seq = 0;
  constructor(private readonly deps: UploaderDeps) {}

  get busy(): boolean { return this.current !== null; }

  deliver(d: Delivery): Promise<Outcome> {
    const run = this.chain.then(() => this.run(d));
    this.chain = run.catch(() => undefined);
    return run;
  }

  cancel(): void {
    const c = this.current;
    if (!c || c.done) return;
    try { this.deps.send(pasteCancel(c.id)); } catch { /* the channel is gone; the cancel is what settles it */ }
    c.settle({ ok: false, reason: "cancelled" });
  }

  onReply(r: PasteReply): void {
    const c = this.current;
    if (!c || r.id !== c.id) return;
    if (r.t === "paste-accepted") { c.accept(); return; }
    c.settle(r.t === "paste-done" ? { ok: true, how: r.how } : { ok: false, reason: r.reason });
  }

  /// Control moved to another device: whatever is in flight is abandoned.
  fail(reason: "not-driver"): void;
  /// THAT channel closed: only a delivery running ON IT fails. An old `bulk` channel's `close` is a task
  /// after its pc is torn down and can land once the rebuilt one already carries the next delivery
  /// (rtc-connection.ts, `rebuildPc`) — maybe past its paste-end, which the host goes on to paste.
  fail(reason: "closed", ch: ChannelLike): void;
  fail(reason: "closed" | "not-driver", ch?: ChannelLike): void {
    const c = this.current;
    if (!c || (reason === "closed" && c.ch !== ch)) return;
    c.settle({ ok: false, reason });
  }

  private async run(d: Delivery): Promise<Outcome> {
    const texts = d.items.map((it) => (it.kind === "text" ? utf8.encode(it.text) : null));
    const decls: PasteItemDecl[] = d.items.map((it, i) => it.kind === "text"
      ? { kind: "text", size: texts[i]!.length }
      : { kind: "file", name: it.name, type: it.type, size: it.blob.size });
    if (overCaps(decls)) return { ok: false, reason: "too-large" };
    const ch = this.deps.channel();
    if (!ch || ch.readyState !== "open") return { ok: false, reason: "closed" };
    const id = this.deps.newId?.() ?? `p${Date.now().toString(36)}${(++this.seq).toString(36)}`;
    let settle!: (o: Outcome) => void;
    const replied = new Promise<Outcome>((r) => { settle = r; });
    let accept!: () => void;
    const accepted = new Promise<void>((r) => { accept = r; });
    const cur: Current = { id, ch, done: null, settle: (o) => { if (!cur.done) { cur.done = o; settle(o); } }, accept: () => accept() };
    this.current = cur;
    const sleep = this.deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
    const total = decls.reduce((s, x) => s + x.size, 0);
    let handed = 0;
    let sinceYield = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let acceptTimer: ReturnType<typeof setTimeout> | undefined;
    try {
      this.deps.send(pasteBegin(id, d.to, decls, d.at));
      // NOT A PIECE BEFORE THE MAC SAYS THE DELIVERY IS OPEN (2026-10-02). A Mac whose Xpromptvs predates paste
      // ignores every `paste-*`: the whole upload went, the note froze at 94%, and only the 60 s reply timeout
      // ended it, saying nothing useful. One round trip here costs such a Mac no upload, and 5 s with no
      // `paste-accepted` (nor a `paste-error` — a refusal answers the begin instead) fails fast. The cancel is
      // harmless to a Mac that ignores it, and frees a Mac that is only slow. A channel no longer current or open
      // by then is the CONNECTION's failure (a rebuild whose close never reached us), never "may need updating".
      // Not a session-scope timer: cleared with the scope it would leave this promise pending for good; at the
      // session's end its settle is harmless (PasteUI returns on `signal.aborted`, a dead channel sends nothing).
      acceptTimer = setTimeout(() => {
        if (cur.done) return;
        try { this.deps.send(pasteCancel(id)); } catch { /* the channel is gone; settling is what matters */ }
        cur.settle({ ok: false, reason: this.deps.channel() !== ch || ch.readyState !== "open" ? "closed" : "unanswered" });
      }, ACCEPT_TIMEOUT_MS);
      this.deps.onProgress?.(0, total, d);               // the note is up while it waits, not only once bytes go
      await Promise.race([accepted, replied]);
      clearTimeout(acceptTimer);
      for (let i = 0; i < d.items.length && !cur.done; i++) {
        const it = d.items[i]!;
        const size = decls[i]!.size;
        for (let off = 0, seq = 0; off < size && !cur.done; off += PASTE_CHUNK_BYTES, seq++) {
          while (!cur.done && (ch.bufferedAmount ?? 0) > PACE_HIGH_BYTES && ch.readyState === "open") await sleep(8);
          if (cur.done) break;
          if (this.deps.channel() !== ch || ch.readyState !== "open") { cur.settle({ ok: false, reason: "closed" }); break; }
          const end = Math.min(size, off + PASTE_CHUNK_BYTES);
          const bytes = it.kind === "text" ? texts[i]!.subarray(off, end) : new Uint8Array(await it.blob.slice(off, end).arrayBuffer());
          if (cur.done) break;
          this.deps.send(pasteData(id, i, seq, bytes));
          handed += bytes.length;
          // Yield one macrotask per 256 KiB handed over, whatever the transport: over This Mac's bridge
          // `bufferedAmount` is always 0, so pacing never waits and a 4 MiB text would hold the page. Not
          // per piece — nested timers clamp to ~4 ms and would throttle a 50 MB upload to seconds.
          sinceYield += bytes.length;
          if (sinceYield >= PACE_HIGH_BYTES) { sinceYield = 0; await sleep(0); }
          this.deps.onProgress?.(Math.max(0, handed - (ch.bufferedAmount ?? 0)), total, d);
        }
      }
      if (!cur.done) {
        this.deps.send(pasteEnd(id));
        timer = setTimeout(() => cur.settle({ ok: false, reason: "timeout" }), REPLY_TIMEOUT_MS);
      }
      // THE PROGRESS FOLLOWS THE QUEUE TO THE END. Reported only as pieces were handed over, it froze after the
      // last one at whatever was still queued (94%); read on here while the channel drains, it reaches every
      // byte, which `PasteUI` shows as waiting for the Mac. Never past the answer — the poll races it — and
      // not once the channel closes or is replaced: that is the close's to settle. Its sleeps are not session-scope
      // timers either, for the acceptance timer's reason: a scope-cleared one would leave this loop waiting forever.
      while (!cur.done && (ch.bufferedAmount ?? 0) > 0) {
        await Promise.race([sleep(DRAIN_POLL_MS), replied]);
        if (cur.done || this.deps.channel() !== ch || ch.readyState !== "open") break;
        this.deps.onProgress?.(Math.max(0, handed - (ch.bufferedAmount ?? 0)), total, d);
      }
      return await replied;
    } catch {
      // A send throws InvalidStateError once the channel is not open (it can close between the check and
      // the send). The uploader always settles: nothing more is sent, and the caller is told "closed".
      cur.settle({ ok: false, reason: "closed" });
      return await replied;
    } finally {
      clearTimeout(acceptTimer);
      clearTimeout(timer);
      this.current = null;
    }
  }
}
