// @vitest-environment node
import { describe, expect, it } from 'vitest';
// @ts-expect-error node types are intentionally not in the browser project
import { readFileSync } from 'node:fs';
import { MockTermWire } from './support/term-wire';
import { TermStreamRouter, attachTermChannel, type TermStreamSink } from '../src/client/term-stream';
import { TERM_OUTPUT as OUT, TERM_SNAPSHOT_CHUNK as CHUNK, TERM_SNAPSHOT_END as SNAP,
  TERM_SCREEN_END as SCREEN, TERM_HISTORY_CHUNK as HIST, TERM_HISTORY_END as HEND,
  TERM_CLOSED as CLOSED, type TermFrameKind } from '../src/client/term-frame';
const enc = new TextEncoder();
function harness() {
  const gens = new Map<string,string>(), ends: number[] = [], closed: string[] = [], histories: string[] = [], errors: unknown[] = [];
  const sources: boolean[] = []; let starts = 0;
  const sink: TermStreamSink = {
    snapshotStart: (tab,_c,_r,gen) => gens.set(`${tab}#${gen}`, ''),
    bytes: (tab,gen,text,snapshot) => { const k = `${tab}#${gen}`; gens.set(k,(gens.get(k) ?? '')+text); sources.push(!!snapshot); },
    snapshotEnd: (_tab,gen) => { ends.push(gen); }, closed: tab => { closed.push(tab); },
    history: (_tab,_gen,_c,_r,text) => { histories.push(text); },
    failed: (_tab,_gen,e) => { errors.push(e); }, wireStart: () => { starts++; },
  };
  const router = new TermStreamRouter(sink);
  let epoch = 1n, wire = new MockTermWire(epoch);
  const packet = (kind: TermFrameKind, tab: string, payload: string | Uint8Array = '', cols = 80, rows = 24) =>
    wire.record({kind, tab, cols, rows, payload: typeof payload === 'string' ? enc.encode(payload) : payload});
  const send = (kind: TermFrameKind, tab: string, payload: string | Uint8Array = '') => router.receive(packet(kind,tab,payload));
  const restart = () => { wire = new MockTermWire(++epoch); router.receive(wire.start()); };
  const start = () => router.receive(wire.start());
  const texts = (tab: string) => [...gens].filter(([key]) => key.startsWith(`${tab}#`)).map(([,t])=>t);
  return { router, sink, gens, ends, closed, histories, errors, sources, packet, send, restart, start, texts, starts: () => starts };
}

describe('shared terminal routing', () => {
  it('decodes the native multi-generation fixture through the real codec', () => {
    const h = harness(); const bin = new Uint8Array(readFileSync(new URL('../../protocol/fixtures/term-wire.bin', import.meta.url)));
    const want = JSON.parse(readFileSync(new URL('../../protocol/fixtures/term-wire.json', import.meta.url), 'utf8'));
    const historyByTab: Record<string,string[]> = {};
    h.sink.history = (tab,_gen,_c,_r,text) => { (historyByTab[`${tab}#history`] ??= []).push(text); };
    for (let i = 0; i < bin.length;) {
      const n = new DataView(bin.buffer, bin.byteOffset+i,4).getUint32(0);
      h.router.receive(bin.subarray(i+4,i+4+n)); i += 4+n;
    }
    const byTab: Record<string,string[]> = {};
    for (const [key,text] of h.gens) (byTab[key.slice(0,key.lastIndexOf('#'))] ??= []).push(text);
    expect({...byTab,...historyByTab}).toEqual(want.generations); expect(h.closed).toEqual(want.closed); expect(h.errors).toEqual([]);
  });
  it('drops output before a snapshot and after close, after shared decoding', () => {
    const h = harness(); h.start(); h.send(OUT,'a','early'); expect(h.gens.size).toBe(0);
    h.send(SNAP,'a','A'); h.send(CLOSED,'a'); h.send(OUT,'a','late');
    expect(h.texts('a')).toEqual(['A']); expect(h.closed).toEqual(['a']); expect(h.errors).toEqual([]);
  });
  it('delivers many small records synchronously and in order', () => {
    const h = harness(); h.start(); h.send(SNAP,'a','S|'); let want = 'S|';
    for (let i=0;i<300;i++) { const text=`m${i};`; want+=text; h.send(OUT,'a',text); expect(h.texts('a')).toEqual([want]); }
  });
  it('commits a multi-record snapshot only at its end', () => {
    const h = harness(); h.start(); h.send(CHUNK,'a','one'); h.send(CHUNK,'a','two'); expect(h.ends).toEqual([]);
    h.send(SNAP,'a','three'); expect(h.texts('a')).toEqual(['onetwothree']); expect(h.ends).toEqual([1]);
    h.send(OUT,'a','live'); expect(h.sources).toEqual([true,true,true,false]);
  });
  it('replaces A without resetting B and keeps generations unique', () => {
    const h = harness(); h.start(); h.send(SNAP,'a','A'); h.send(SNAP,'b','B'); h.send(SNAP,'a','new');
    h.send(OUT,'b','live'); h.send(OUT,'a','live'); expect(h.texts('a')).toEqual(['A','newlive']); expect(h.texts('b')).toEqual(['Blive']);
    h.router.reset(); h.restart(); h.send(SNAP,'a','again'); expect(h.ends).toEqual([1,2,3,4]);
  });
  it('keeps split UTF-8 independent between tabs and snapshot records', () => {
    const h = harness(); h.start(); h.send(SNAP,'a',''); h.send(OUT,'a',new Uint8Array([0xe4]));
    h.send(CHUNK,'b',new Uint8Array([0xe4])); h.send(OUT,'a',new Uint8Array([0xb8,0xad]));
    h.send(SNAP,'b',new Uint8Array([0xb8,0xad])); expect(h.texts('a')).toEqual(['中']); expect(h.texts('b')).toEqual(['中']);
  });
  it('counts actual wire bytes and decoded UTF-8 bytes', () => {
    const h = harness(); const wire = new MockTermWire(1n);
    const packets = [wire.start(), wire.record({kind:SNAP,tab:'a',cols:80,rows:24,payload:enc.encode('中')}),
      wire.record({kind:OUT,tab:'a',payload:enc.encode('😀')})];
    packets.forEach(p=>h.router.receive(p));
    expect(h.router.stats).toMatchObject({messages:3,bytes:packets.reduce((n,p)=>n+p.length,0),inflated:7,decoded:7,sinkErrors:0});
  });
  it('invalid inner records fail the whole wire once; only a new START recovers it', () => {
    const h = harness(); h.start(); h.router.receive(h.packet(OUT,'','bad')); h.send(SNAP,'a','discard');
    expect(h.errors).toHaveLength(1); expect(h.gens.size).toBe(0);
    h.restart(); h.send(SNAP,'a','fresh'); expect(h.texts('a')).toEqual(['fresh']);
  });
  it('rejects the old two-byte wire start without a compatibility decoder', () => {
    const h = harness(); h.router.receive(new Uint8Array([4,0])); expect(h.errors).toHaveLength(1); expect(h.starts()).toBe(0);
  });
  it('a reconnect during a sink callback cannot commit the old generation', () => {
    const h = harness(); const original = h.sink.snapshotStart; let first = true;
    h.sink.snapshotStart = (...args) => { original(...args); if (first) { first=false; h.router.reset(); h.restart(); h.send(SNAP,'a','new'); } };
    h.start(); h.send(SNAP,'a','old'); expect(h.texts('a')).toEqual(['','new']); expect(h.ends).toEqual([2]);
  });
  it('queues reentrant receives after the current record without reentering the codec', () => {
    const h = harness(); const original = h.sink.bytes; let once = true;
    h.sink.bytes = (...args) => { original(...args); if (once) { once=false; h.send(OUT,'a','next'); } };
    h.start(); h.send(SNAP,'a','first'); expect(h.texts('a')).toEqual(['firstnext']); expect(h.errors).toEqual([]);
  });
  it('contains throwing sinks and keeps processing', () => {
    const h = harness(); h.sink.snapshotEnd=()=>{throw new Error('renderer');}; h.start(); h.send(SNAP,'a','S'); h.send(OUT,'a','live');
    expect(h.texts('a')).toEqual(['Slive']); expect(h.router.stats.sinkErrors).toBe(1); expect(h.errors).toEqual([]);
  });
  it('resync discards all old data until a new epoch, preserving the last displayed text', () => {
    const h = harness(); h.start(); h.send(SNAP,'a','A'); h.send(CHUNK,'b','partial'); h.router.resync();
    h.send(OUT,'a','old'); h.send(SNAP,'b','old'); expect(h.texts('a')).toEqual(['A']); expect(h.ends).toEqual([1]);
    h.restart(); h.send(SNAP,'b','new'); expect(h.texts('b')).toEqual(['partial','new']); expect(h.starts()).toBe(2);
  });
  it('a new channel ignores data before START and fences the previous channel', () => {
    const h = harness(), a = new EventTarget(), b = new EventTarget(), wa = new MockTermWire(50n), wb = new MockTermWire(1n);
    const deliver = (c:EventTarget,p:Uint8Array)=>c.dispatchEvent(new MessageEvent('message',{data:p.buffer}));
    attachTermChannel(h.router,a); deliver(a,wa.start());
    attachTermChannel(h.router,b); deliver(b,wb.record({kind:SNAP,tab:'b',payload:enc.encode('early'),cols:80,rows:24}));
    expect(h.gens.size).toBe(0); deliver(b,wb.start()); deliver(b,wb.snapshot('b',80,24,'new')[0]!);
    deliver(a,new MockTermWire(100n).start()); expect(h.starts()).toBe(2); expect(h.texts('b')).toEqual(['new']);
  });
  it('assembles late history while live output continues and keeps UTF-8 decoders separate', () => {
    const h = harness(); h.start(); h.send(SCREEN,'a','S'); h.send(OUT,'a',new Uint8Array([0xe4]));
    h.send(HIST,'a',new Uint8Array([0xe4])); h.send(HEND,'a',new Uint8Array([0xb8,0xad]));
    h.send(OUT,'a',new Uint8Array([0xb8,0xad])); expect(h.histories).toEqual(['中']); expect(h.texts('a')).toEqual(['S中']);
  });
  it('discards partly received history after a new snapshot or close', () => {
    const h = harness(); h.start(); h.send(SCREEN,'a','S'); h.send(HIST,'a','old'); h.send(SNAP,'a','new'); h.send(HEND,'a','stale');
    h.send(SCREEN,'b','B'); h.send(HIST,'b','partial'); h.send(CLOSED,'b'); h.send(HEND,'b','stale'); h.send(OUT,'a','live');
    expect(h.histories).toEqual([]); expect(h.texts('a')).toEqual(['S','newlive']); expect(h.errors).toEqual([]);
  });
  it('corrupted history triggers one whole-wire failure, including other tabs', () => {
    const h = harness(); h.start(); h.send(SCREEN,'a','S'); h.send(SNAP,'b','B'); const bad=h.packet(HIST,'a','history'); bad[25]=6;
    h.router.receive(bad); h.send(OUT,'b','discard'); h.send(HEND,'a','discard'); expect(h.errors).toHaveLength(1); expect(h.texts('b')).toEqual(['B']);
    h.restart(); h.send(SNAP,'b','recovered'); expect(h.texts('b')).toEqual(['B','recovered']);
  });
});
