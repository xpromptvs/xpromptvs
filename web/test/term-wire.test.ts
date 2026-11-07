import { describe, it, expect } from 'vitest';
import fixture from '../../protocol/fixtures/term-zstd-wire.json';
import { TermWireDecoder } from '../src/client/term-wire';
import type { TermFrame } from '../src/client/term-frame';

const records = fixture.records as {name: string; raw: string; compressed: string}[];
const bytes = (s: string) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
function envelope(index: number, epoch = 1n, sequence = BigInt(index - 1)): Uint8Array {
  const payload = bytes(records[index]!.compressed);
  const head = index === 0 ? 13 : 25;
  const b = new Uint8Array(head + payload.length);
  b.set([82, 90, 84, 49, index === 0 ? 0 : 1]);
  const v = new DataView(b.buffer); v.setBigUint64(5, epoch);
  if (index) { v.setBigUint64(13, sequence); v.setUint32(21, bytes(records[index]!.raw).length); }
  b.set(payload, head); return b;
}
function receiver() {
  const seen: TermFrame[] = [], epochs: bigint[] = [], errors: Error[] = [];
  const decoder = new TermWireDecoder({start: e => epochs.push(e), record: r => seen.push(r), failed: e => errors.push(e)});
  return { decoder, seen, epochs, errors };
}

describe('one shared terminal wire', () => {
  it('decodes native interleaved records exactly in the same receive call', () => {
    const r = receiver();
    for(let i=0;i<records.length;i++) { r.decoder.receive(envelope(i)); expect(r.seen.length).toBe(i); }
    expect(r.errors).toEqual([]);
    expect(r.seen.map(f=>f.tab)).toEqual(['pty:1','pty:2','pty:1','pty:1','pty:2','pty:1','pty:1','pty:2']);
    expect([...r.seen[2]!.payload]).toEqual([33]);
    expect([...r.seen[3]!.payload]).toEqual([0xe4]);
  });
  it('keeps 64-bit epochs exact and ignores retired epochs before decompression', () => {
    const r = receiver(), epoch = 9007199254740993n;
    r.decoder.receive(envelope(0, epoch)); r.decoder.receive(envelope(0, epoch+1n));
    r.decoder.receive(envelope(1, epoch)); r.decoder.receive(envelope(1, epoch+1n));
    expect(r.epochs).toEqual([epoch,epoch+1n]); expect(r.seen).toHaveLength(1); expect(r.errors).toEqual([]);
  });
  it.each(['gap','duplicate','zero','old-format','length','window','end','inner-start'])('fails %s once and waits for a new epoch', mode => {
    const r=receiver();r.decoder.receive(envelope(0));
    let bad=envelope(1);
    if(mode==='gap')new DataView(bad.buffer).setBigUint64(13,2n);
    if(mode==='duplicate'){r.decoder.receive(bad);bad=envelope(1);}
    if(mode==='zero')new DataView(bad.buffer).setBigUint64(5,0n);
    if(mode==='old-format')bad=new Uint8Array([4,0]);
    if(mode==='length')new DataView(bad.buffer).setUint32(21,65536);
    if(mode==='window'){bad=envelope(0,2n);bad[18]=0xff;}
    if(mode==='end')bad[25]=bad[25]!|1;
    // This raw block describes an inner legacy wire-start; decoding it is forbidden.
    if(mode==='inner-start'){
      bad=new Uint8Array(30);bad.set([82,90,84,49,1]);const v=new DataView(bad.buffer);v.setBigUint64(5,1n);v.setUint32(21,2);
      bad.set([16,0,0,4,0],25);
    }
    r.decoder.receive(bad);expect(r.errors).toHaveLength(1);r.decoder.receive(envelope(2));expect(r.errors).toHaveLength(1);
    const before=r.seen.length;r.decoder.receive(envelope(0,3n));r.decoder.receive(envelope(1,3n));
    expect(r.seen).toHaveLength(before+1);
  });
  it('rejects malformed UTF-8 tab ids and mismatched declared output lengths immediately', () => {
    for (const malformed of [true, false]) {
      const r=receiver();r.decoder.receive(envelope(0));
      const raw=new Uint8Array(malformed ? [0,1,255,65] : [0,1,97,65]);
      const b=new Uint8Array(28+raw.length);b.set([82,90,84,49,1]);const v=new DataView(b.buffer);
      v.setBigUint64(5,1n);v.setUint32(21,raw.length+(malformed?0:1));
      b.set([raw.length<<3,0,0],25);b.set(raw,28);
      r.decoder.receive(b);expect(r.errors).toHaveLength(1);expect(r.seen).toHaveLength(0);
    }
  });
  it('bounds callback-reentrant record queues and can recover with a new epoch', () => {
    const errors:Error[]=[];let count=0;
    const d=new TermWireDecoder({start:e=>{if(e===1n)for(let i=0;i<65_536;i++)d.receive(envelope(1));},record:()=>count++,failed:e=>errors.push(e)});
    d.receive(envelope(0));expect(errors).toHaveLength(1);expect(count).toBe(0);
    d.receive(envelope(0,2n));d.receive(envelope(1,2n));expect(count).toBe(1);
  });
  it('does not invoke a stale callback after callback-driven replacement', () => {
    const epochs: bigint[]=[];const frames: TermFrame[]=[];
    const d=new TermWireDecoder({start: e=>{epochs.push(e);if(e===1n)d.receive(envelope(0,2n));},record:f=>frames.push(f),failed:e=>{throw e}});
    d.receive(envelope(0));d.receive(envelope(1,2n));
    expect(epochs).toEqual([1n,2n]);expect(frames).toHaveLength(1);
  });
});
