import {it,expect,vi} from 'vitest';
import {FastChannels} from '../src/lib/fast-channels';
import {FastDelivery,decodeFastRecord,encodeFastRecord} from '@rdev/protocol';
it('opens once, keeps bulk unavailable and delivers replayed output once',()=>{
 vi.useFakeTimers();const gen=new Uint8Array(16).fill(3);const out:Uint8Array[]=[];
 const c=new FastChannels(gen,{onFailure:reason=>{throw new Error(reason)}});c.setWebSocketSender(bytes=>{out.push(bytes);return true});
 const open=vi.fn(),messages:unknown[]=[];
 c.channels.control.addEventListener('open',open);
 c.channels.terminal.addEventListener('message',e=>messages.push(Array.from(new Uint8Array(e.data))));
 c.markReady();c.markReady();expect(open).toHaveBeenCalledTimes(1);expect(c.channels.bulk.readyState).toBe('connecting');
 const e=new FastDelivery(gen,0);const r=e.send(0,new Uint8Array([4,5,6]),0);
 if(r.kind==='accepted')for(let i=0;i<2;i++)for(const x of r.effects)if(x.kind==='transmit')c.receive(x.record,'webSocket');
 expect(messages).toEqual([[4,5,6]]);
 c.channels.input.send(new Uint8Array([8]));expect(out.some(b=>decodeFastRecord(b)?.stream===1)).toBe(true);
 c.close();vi.useRealTimers();
});
it('binds receiver before synchronous open sends and never proxies bulk',()=>{
 vi.useFakeTimers();const gen=new Uint8Array(16).fill(4);const c=new FastChannels(gen,{onFailure:()=>{}});
 const host=new FastDelivery(gen,0);const received:unknown[]=[];let count=0;
 c.setWebSocketSender(bytes=>{count++;const r=decodeFastRecord(bytes)!;host.receive(r,0);const reply=host.send(2,new Uint8Array([9]),0);if(reply.kind==='accepted')for(const x of reply.effects)if(x.kind==='transmit')c.receive(x.record,'webSocket');return true;});
 c.channels.control.addEventListener('message',e=>received.push(Array.from(new Uint8Array(e.data))));
 c.channels.control.addEventListener('open',()=>c.channels.control.send(new Uint8Array([1])));
 c.markReady();expect(received).toEqual([[9]]);const before=count;
 expect(()=>c.channels.bulk.send(new Uint8Array([99]))).toThrow();expect(count).toBe(before);
 c.close();vi.useRealTimers();
});
it('reports data unavailable when both carriers are gone while retaining the generation',()=>{
 vi.useFakeTimers();const c=new FastChannels(new Uint8Array(16),{onFailure:()=>{}});
 c.setWebSocketSender(()=>true);c.markReady();expect(c.isUsable).toBe(true);
 c.setWebSocketSender(null);expect(c.isReady).toBe(true);expect(c.isUsable).toBe(false);
 c.setWebSocketSender(()=>true);expect(c.isUsable).toBe(true);c.close();vi.useRealTimers();
});
it('retains accepted input when a carrier send throws and retries without an uncaught exception',()=>{
 vi.useFakeTimers();const c=new FastChannels(new Uint8Array(16),{onFailure:()=>{}});
 c.setWebSocketSender(()=>{throw new Error('socket closed during send')});c.markReady();
 expect(()=>c.channels.input.send(new Uint8Array([7]))).not.toThrow();expect(c.channels.input.bufferedAmount).toBe(1);
 const sent:Uint8Array[]=[];c.setWebSocketSender(b=>{sent.push(b);return true});vi.advanceTimersByTime(20);
 expect(sent.some(b=>decodeFastRecord(b)?.kind===1)).toBe(true);c.close();vi.useRealTimers();
});

it('releases sparse RTC terminal progress within the pacing headroom',()=>{
 vi.useFakeTimers();vi.setSystemTime(0);
 const gen=new Uint8Array(16).fill(8), sent:Uint8Array[]=[];
 const c=new FastChannels(gen,{onFailure:reason=>{throw new Error(reason)},now:()=>Date.now()});
 try {
  c.setWebSocketSender(b=>{sent.push(b);return true});c.markReady();
  const host=new FastDelivery(gen,0), result=host.send(0,new Uint8Array([42]),0);
  if(result.kind==='accepted')for(const e of result.effects)if(e.kind==='transmit')c.receive(e.record,'webRTC');
  expect(sent.some(b=>decodeFastRecord(b)?.kind===2)).toBe(false);
  vi.advanceTimersByTime(280);
  expect(sent.map(decodeFastRecord).some(r=>r?.kind===2&&r.stream===0&&r.value===5n)).toBe(true);
 } finally {c.close();vi.useRealTimers();}
});
