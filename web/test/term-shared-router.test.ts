import { describe, expect, it } from 'vitest';
import vectors from '../../protocol/fixtures/term-zstd-wire.json';
import { TermStreamRouter, attachTermChannel, type TermStreamSink } from '../src/client/term-stream';

function packet(type: number, epoch: bigint, compressed: Uint8Array, sequence = 0n, size = 0): Uint8Array {
  const header = type === 0 ? 13 : 25;
  const out = new Uint8Array(header + compressed.length); out.set([82,90,84,49,type]);
  const view = new DataView(out.buffer); view.setBigUint64(5, epoch);
  if (type) { view.setBigUint64(13, sequence); view.setUint32(21, size); }
  out.set(compressed, header); return out;
}
const bytes = (b64: string) => Uint8Array.from(atob(b64), c => c.charCodeAt(0));
function wire(epoch = 1n): Uint8Array[] {
  return vectors.records.map((r, i) => packet(i ? 1 : 0, epoch, bytes(r.compressed), BigInt(Math.max(0,i-1)), bytes(r.raw).length));
}
function recorder() {
  const text = new Map<string,string>(); const histories: string[] = []; const errors: unknown[] = []; const starts: number[] = []; const ends: number[] = [];
  const sink: TermStreamSink = {
    snapshotStart: (tab, _c, _r, gen) => { text.set(tab,''); starts.push(gen); },
    bytes: (tab, _gen, t) => text.set(tab, (text.get(tab) ?? '') + t),
    snapshotEnd: (_tab, gen) => ends.push(gen), closed: tab => text.delete(tab),
    history: (_tab,_gen,_c,_r,t) => histories.push(t), failed: (_tab,_gen,e) => errors.push(e),
  };
  return { text, histories, errors, starts, ends, sink };
}
describe('shared native terminal routing', () => {
  it('keeps each tab UTF-8 state while native compressed records interleave', () => {
    const r = recorder(), router = new TermStreamRouter(r.sink);
    for (const p of wire()) router.receive(p);
    expect(r.text.get('pty:1')).toBe('hello!中');
    expect(r.text.has('pty:2')).toBe(false);
    expect(r.histories).toEqual(['history\r\nhello']);
    expect(r.errors).toEqual([]);
  });
  it('obsolete history still passes through shared decoding before routing drops it', () => {
    const r = recorder(), router = new TermStreamRouter(r.sink), packets = wire();
    for (const p of packets.slice(0,7)) router.receive(p);
    router.beginWire(); // discard display generations, keeping the live codec context
    const before = router.stats.inflated;
    router.receive(packets[7]!);
    expect(router.stats.inflated - before).toBe(bytes(vectors.records[7]!.raw).length - 11);
    expect(r.histories).toEqual([]);
    router.receive(packets[8]!); expect(r.errors).toEqual([]);
  });
  it('a corrupt history invalidates the whole wire once, then a new epoch recovers all tabs', () => {
    const r = recorder(), router = new TermStreamRouter(r.sink), packets = wire();
    for (const p of packets.slice(0,7)) router.receive(p);
    const bad = packets[7]!.slice(); bad[25] = 6; // reserved zstd block type
    router.receive(bad); router.receive(packets[8]!);
    expect(r.errors).toHaveLength(1); expect(r.text.has('pty:2')).toBe(true);
    for (const p of wire(2n)) router.receive(p);
    expect(r.errors).toHaveLength(1); expect(r.text.get('pty:1')).toBe('hello!中');
    expect(r.text.has('pty:2')).toBe(false);
  });
  it('replacing transport during snapshotStart fences the old generation callback', () => {
    const r = recorder(), router = new TermStreamRouter(r.sink);
    const start = r.sink.snapshotStart;
    r.sink.snapshotStart = (...args) => { start(...args); router.reset(); };
    const packets = wire(); router.receive(packets[0]!); router.receive(packets[1]!);
    expect(r.text.get('pty:1')).toBe(''); expect(r.ends).toEqual([]);
  });
  it('a retired channel cannot feed even a higher epoch into its replacement', () => {
    const r = recorder(), router = new TermStreamRouter(r.sink);
    const old = new EventTarget(), current = new EventTarget();
    attachTermChannel(router, old); attachTermChannel(router, current);
    for (const p of wire()) current.dispatchEvent(new MessageEvent('message', { data: p.buffer }));
    for (const p of wire(100n)) old.dispatchEvent(new MessageEvent('message', { data: p.buffer }));
    expect(r.starts).toHaveLength(2); expect(r.text.get('pty:1')).toBe('hello!中');
  });
});
