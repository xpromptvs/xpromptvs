import {it,expect} from 'vitest';
import {FastCarrierPolicy} from '../src/fast-carrier';
it('requires a same-carrier reply on every eligible stream before migration',()=>{
 const p=new FastCarrierPolicy();for(const s of [0,1,2] as const)p.channelState('webRTC',s,true,0);
 const probes=p.tick(0).filter(x=>x.kind==='sendProbe');expect(probes).toHaveLength(3);
 for(const r of probes)p.probeReply('webSocket',r.stream,r.nonce,1);
 expect(p.selected).toBe('webSocket');
 for(const r of probes.slice(0,2))p.probeReply('webRTC',r.stream,r.nonce,2);
 expect(p.selected).toBe('webSocket');
 expect(p.probeReply('webRTC',probes[2]!.stream,probes[2]!.nonce,2)).toEqual([{kind:'select',carrier:'webRTC'}]);
});
it('falls back after a closed carrier and re-probes without timer catchup bursts',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,1);
 expect(p.selected).toBe('webRTC');
 expect(p.channelState('webRTC',0,false,10)).toEqual([{kind:'select',carrier:'webSocket'}]);
 expect(p.tick(60000).filter(x=>x.kind==='sendProbe').length).toBeLessThanOrEqual(6);
});
it('blackholed data falls back only when the alternative has a recent proof',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,0);
 expect(p.selected).toBe('webRTC');p.tick(1000);
 const recent=p.tick(2000);for(const r of recent)if(r.kind==='sendProbe'&&r.carrier==='webSocket')p.probeReply(r.carrier,r.stream,r.nonce,2999);
 expect(p.selected).toBe('webRTC');
 expect(p.tick(3000).some(x=>x.kind==='select'&&x.carrier==='webSocket')).toBe(true);
});
it('falls back on stalled application data even when probes keep answering',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,0);
 p.setOutstanding(0,true,0);
 for(let t=1000;t<5000;t+=1000)for(const r of p.tick(t))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,t);
 expect(p.selected).toBe('webRTC');expect(p.tick(5000).some(x=>x.kind==='select'&&x.carrier==='webSocket')).toBe(true);
 // No immediate return to a path that acknowledged probes but not the actual data.
 for(const r of p.tick(6000))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,6000);
 expect(p.selected).toBe('webSocket');
});

it('control ACKs cannot mask a stalled terminal stream',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,0);
 p.setOutstanding(0,true,0);
 for(let t=1000;t<5000;t+=1000){
  p.dataProgress('webRTC',2,t);
  for(const r of p.tick(t))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,t);
 }
 expect(p.tick(5000)).toContainEqual({kind:'select',carrier:'webSocket'});
});

it('uses one RTC heartbeat after all streams prove migration, retaining per-stream data stall checks',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,0);
 expect(p.selected).toBe('webRTC');
 expect(p.tick(1000).filter(r=>r.kind==='sendProbe'&&r.carrier==='webRTC')).toHaveLength(1);
 for(let t=2000;t<=10000;t+=1000)for(const r of p.tick(t))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,t);
 expect(p.selected).toBe('webRTC');
});

it('uses advancing data ACKs as steady-state liveness without redundant probes',()=>{
 const p=new FastCarrierPolicy();for(const c of ['webSocket','webRTC'] as const)for(const s of [0,1,2] as const)p.channelState(c,s,true,0);
 for(const r of p.tick(0))if(r.kind==='sendProbe')p.probeReply(r.carrier,r.stream,r.nonce,0);
 p.dataProgress('webRTC',0,999);
 expect(p.tick(1000).filter(r=>r.kind==='sendProbe'&&r.carrier==='webRTC')).toEqual([]);
 expect(p.tick(1999).filter(r=>r.kind==='sendProbe'&&r.carrier==='webRTC')).toHaveLength(1);
});
