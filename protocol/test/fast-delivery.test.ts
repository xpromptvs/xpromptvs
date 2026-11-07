import { expect, it } from 'vitest';
import { FastDelivery, type DeliveryEffect } from '../src/fast-delivery';
import type { FastRecord } from '../src/fast-data';
const gen = new Uint8Array(16).fill(7);
const sent = (e: DeliveryEffect[]) => e.flatMap(x => x.kind === 'transmit' ? [x.record] : []);
const messages = (e: DeliveryEffect[]) => e.flatMap(x => x.kind === 'deliver' ? [x.message] : []);
const send = (d: FastDelivery, stream: 0|1|2, bytes: Uint8Array) => { const r = d.send(stream, bytes, 0); expect(r.kind).toBe('accepted'); return r.kind === 'accepted' ? sent(r.effects) : []; };
it('delivers reordered fragments once, across replay, with independent streams', () => {
 const a = new FastDelivery(gen,0), b = new FastDelivery(gen,0);
 const data = new Uint8Array(20000).map((_,i)=>i%251);
 const records = send(a,0,data); let effects: DeliveryEffect[]=[];
 effects.push(...b.receive(records[2]!,0));
 const control = send(a,2,new Uint8Array([99]));
 expect(messages(b.receive(control[0]!,0))).toEqual([new Uint8Array([99])]);
 for (const r of [...a.replay(0)].reverse()) effects.push(...b.receive(r,1));
 for (const r of records) effects.push(...b.receive(r,2));
 expect(messages(effects)).toEqual([data]);
 for (const r of sent([...effects,...b.poll(22)])) a.receive(r,22);
 expect(a.bufferedAmount(0)).toBe(0);
 expect(b.receiveOffsets()[0]).toBe(20004n);
});
it('counts payload acknowledgements without frame prefixes and ignores stale acks', () => {
 const a=new FastDelivery(gen,0);send(a,0,new Uint8Array(10));
 const ack=(n:bigint):FastRecord=>({kind:2,generation:gen,stream:0,value:n,bytes:new Uint8Array()});
 a.receive(ack(4n),0); expect(a.bufferedAmount(0)).toBe(10);
 a.receive(ack(9n),0); expect(a.bufferedAmount(0)).toBe(5);
 a.receive(ack(2n),0); expect(a.bufferedAmount(0)).toBe(5);
 expect(a.receive(ack(15n),0).some(x=>x.kind==='failed')).toBe(true);
});
it('bounds each stream while reserving independent control capacity', () => {
 const a=new FastDelivery(gen,0); const m=new Uint8Array(1024*1024);
 expect(a.send(0,m,0).kind).toBe('accepted'); expect(a.send(0,m,0).kind).toBe('accepted');
 expect(a.send(0,new Uint8Array([1]),0).kind).toBe('full');
 expect(a.send(2,new Uint8Array([1]),0).kind).toBe('accepted');
 expect(a.send(1,new Uint8Array(m.length+1),0).kind).toBe('invalid');
});
it('acknowledges within 20 ms and immediately on a gap', () => {
 const a=new FastDelivery(gen,0),b=new FastDelivery(gen,0);const r=send(a,0,new Uint8Array([1]));
 expect(sent(b.receive(r[0]!,0))).toEqual([]); expect(sent(b.poll(19))).toEqual([]);
 expect(sent(b.poll(20))[0]?.value).toBe(5n);
 const c=new FastDelivery(gen,0);const long=send(new FastDelivery(gen,0),0,new Uint8Array(10000));
 expect(sent(c.receive(long[1]!,0))[0]?.value).toBe(0n);
});
it('refuses conflicting overlaps, unbounded offsets and malformed frame lengths', () => {
 const r=(value:bigint,bytes:Uint8Array):FastRecord=>({kind:1,generation:gen,stream:0,value,bytes});
 const b=new FastDelivery(gen,0);b.receive(r(5n,new Uint8Array([1])),0);
 expect(b.receive(r(5n,new Uint8Array([2])),0).some(x=>x.kind==='failed')).toBe(true);
 expect(new FastDelivery(gen,0).receive(r(3000000n,new Uint8Array([1])),0).some(x=>x.kind==='failed')).toBe(true);
 expect(new FastDelivery(gen,0).receive(r(0n,new Uint8Array([0,16,0,1])),0).some(x=>x.kind==='failed')).toBe(true);
 expect(new FastDelivery(gen,0).receive({...r(0n,new Uint8Array([1])),generation:new Uint8Array(16)},0)).toEqual([]);
});
it('does not discard a partially received message when its prefix is acknowledged', () => {
 const a=new FastDelivery(gen,0),b=new FastDelivery(gen,0);const data=new Uint8Array(20000).fill(42);const r=send(a,0,data);
 b.receive(r[0]!,0); for(const ack of sent(b.poll(20))) a.receive(ack,20);
 expect(a.bufferedAmount(0)).toBe(11812);
 const out=a.replay(0).flatMap(record=>b.receive(record,21)); expect(messages(out)).toEqual([data]);
});
it('matches the independently generated delivery trace', async () => {
 const {readFileSync}=await import('node:fs');
 const trace=JSON.parse(readFileSync(new URL('../fixtures/fast-delivery-traces.json',import.meta.url),'utf8'));
 const {decodeFastRecord}=await import('../src/fast-data');
 const d=new FastDelivery(new Uint8Array(Buffer.from(trace.generation,'hex')),0);
 for(const step of trace.steps){
  const r=decodeFastRecord(new Uint8Array(Buffer.from(step.wire,'hex')))!;
  expect(messages(d.receive(r,0)).map(x=>Buffer.from(x).toString('hex'))).toEqual(step.delivered);
  expect(d.receiveOffsets()[0]).toBe(BigInt(step.next));
 }
});
it('bounds tiny-message metadata and refuses a u64 overflow record', () => {
 const a=new FastDelivery(gen,0);
 for(let i=0;i<2048;i++)expect(a.send(0,new Uint8Array([1]),0).kind).toBe('accepted');
 expect(a.send(0,new Uint8Array([1]),0).kind).toBe('full');
 expect(new FastDelivery(gen,0).receive({kind:1,stream:0,generation:gen,value:(1n<<64n)-1n,bytes:new Uint8Array([1])},0)).toEqual([{kind:'failed',reason:'receive-window'}]);
});

it('batches RTC acknowledgements while delivering immediately and acknowledging large progress',()=>{
 const a=new FastDelivery(gen,0), b=new FastDelivery(gen,0), data=new Uint8Array(100);
 expect(messages(b.receive(send(a,0,data)[0]!,0,1000))).toEqual([data]);
 expect(b.poll(999)).toEqual([]);expect(sent(b.poll(1000))[0]?.value).toBe(104n);
 expect(sent(b.receive(send(a,0,new Uint8Array(10000))[0]!,1001,1000))[0]?.value).toBe(104n+8192n);
});

it('acknowledges 2 KiB progress so shared terminal history releases its spare budget',()=>{
 const a=new FastDelivery(gen,0), b=new FastDelivery(gen,0);
 expect(sent(b.receive(send(a,0,new Uint8Array(1020))[0]!,0,1000))).toEqual([]);
 expect(sent(b.receive(send(a,0,new Uint8Array(1020))[0]!,1,1000))[0]?.value).toBe(2048n);
});
