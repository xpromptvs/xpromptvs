import type {FastStream} from './fast-data';
export type FastCarrierKind='webSocket'|'webRTC';
export type CarrierEffect={kind:'sendProbe';carrier:FastCarrierKind;stream:FastStream;nonce:bigint}|{kind:'select';carrier:FastCarrierKind};
class Path {
 open=[false,false,false]; heard=[-Infinity,-Infinity,-Infinity]; lastProbe=-Infinity;
 challenges:Map<bigint,number>[]=[new Map(),new Map(),new Map()];
}
/** Readiness is application evidence on the same carrier, not ICE state. */
export class FastCarrierPolicy {
 private paths={webSocket:new Path(),webRTC:new Path()};
 selected:FastCarrierKind='webSocket';
 private retryAt=0;private pending=[false,false,false];private progress=[0,0,0];
 constructor(private nonce:()=>bigint=()=>{const a=new Uint32Array(2);crypto.getRandomValues(a);return BigInt(a[0]!)*4294967296n+BigInt(a[1]!);}){}
 channelState(c:FastCarrierKind,s:FastStream,open:boolean,now:number):CarrierEffect[]{
  const p=this.paths[c];p.open[s]=open;
  if(!open){p.heard[s]=-Infinity;p.challenges[s]!.clear();}
  return this.evaluate(now);
 }
 setOutstanding(s:FastStream,pending:boolean,now:number):void {if(pending&&!this.pending[s])this.progress[s]=now;this.pending[s]=pending;}
 dataProgress(c:FastCarrierKind,s:FastStream,now:number):void{if(c===this.selected){this.progress[s]=now;if(c==='webRTC')this.paths.webRTC.heard[2]=now;}}
 probeReply(c:FastCarrierKind,s:FastStream,nonce:bigint,now:number):CarrierEffect[]{
  const p=this.paths[c],sent=p.challenges[s]!.get(nonce);if(!p.open[s]||sent===undefined||now-sent>3000)return [];
  p.challenges[s]!.delete(nonce);p.heard[s]=now;return this.evaluate(now);
 }
 tick(now:number):CarrierEffect[]{
  const out=this.evaluate(now);
  for(const c of ['webSocket','webRTC'] as const){const p=this.paths[c];if(now-p.lastProbe<1000||(c==='webRTC'&&this.selected==='webRTC'&&now-p.heard[2]!<1000))continue;p.lastProbe=now;
   for(const s of [0,1,2] as const){const m=p.challenges[s]!;for(const [n,t] of m)if(now-t>=3000)m.delete(n);
    if(!p.open[s]||(c==='webRTC'&&this.selected==='webRTC'&&s!==2))continue;const nonce=this.nonce();m.set(nonce,now);out.push({kind:'sendProbe',carrier:c,stream:s,nonce});
   }
  }return out;
 }
 private healthy(c:FastCarrierKind,now:number):boolean{const p=this.paths[c];return p.open.every(Boolean)&&(c==='webRTC'&&this.selected==='webRTC'?now-p.heard[2]!<3000:p.heard.every(t=>now-t<3000));}
 private evaluate(now:number):CarrierEffect[]{
  if(this.selected==='webRTC'){
   const rtc=this.paths.webRTC;
   const closed=!rtc.open.every(Boolean),stalled=this.pending.some((pending,s)=>pending&&now-this.progress[s]!>=5000);
   if((closed&&this.paths.webSocket.open.every(Boolean))||((stalled||!this.healthy('webRTC',now))&&this.healthy('webSocket',now))){
    this.selected='webSocket';this.retryAt=now+5000;this.progress.fill(now);
    // Every retry must prove a new path; old successful probes cannot cause oscillation.
    rtc.heard=[-Infinity,-Infinity,-Infinity];rtc.challenges.forEach(m=>m.clear());
    return [{kind:'select',carrier:'webSocket'}];
   }
  }else if(now>=this.retryAt&&this.healthy('webRTC',now)){
   this.selected='webRTC';this.progress.fill(now);return [{kind:'select',carrier:'webRTC'}];
  }return [];
 }
}
