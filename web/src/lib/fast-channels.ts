import {FastDelivery,FastCarrierPolicy,encodeFastRecord,decodeFastRecord,type FastRecord,type FastStream,type FastCarrierKind,type DeliveryEffect,type CarrierEffect} from '@rdev/protocol';
import {whenOpen,type Channels,type ChannelLike} from './channel';
const labels=['terminal','input','control','bulk'] as const;
class FastChannel extends EventTarget implements ChannelLike {
 binaryType:BinaryType='arraybuffer';readyState:RTCDataChannelState='connecting';
 constructor(readonly label:typeof labels[number],private owner:FastChannels,readonly slot:number){super();}
 get bufferedAmount():number{return this.owner.buffered(this.slot);}
 send(data:string|ArrayBuffer|ArrayBufferView):void{
  if(this.readyState!=='open')throw new DOMException(`${this.label} unavailable`,'InvalidStateError');
  const bytes=typeof data==='string'?new TextEncoder().encode(data):data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(data.buffer,data.byteOffset,data.byteLength);
  this.owner.send(this.slot,bytes);
 }
 deliver(bytes:Uint8Array):void{this.dispatchEvent(new MessageEvent('message',{data:bytes.slice().buffer}));}
}
export class FastChannels {
 readonly channels:Channels;
 private slots:FastChannel[];
 private engine:FastDelivery;private policy=new FastCarrierPolicy();
 private ws:((bytes:Uint8Array)=>boolean)|null=null;private rtc:Partial<Channels>={};
 private ready=false;private closed=false;private retry=false;private timer:ReturnType<typeof setInterval>;
 private readonly now:()=>number;
 constructor(readonly generation:Uint8Array,private opts:{onFailure:(reason:string)=>void;onCarrier?:(carrier:FastCarrierKind)=>void;now?:()=>number}){
  this.now=opts.now??(()=>performance.now());this.engine=new FastDelivery(generation,this.now());
  this.slots=labels.map((label,i)=>new FastChannel(label,this,i));
  this.channels={terminal:this.slots[0]!,input:this.slots[1]!,control:this.slots[2]!,bulk:this.slots[3]!};
  this.timer=setInterval(()=>this.tick(),20);
 }
 get selected():FastCarrierKind{return this.policy.selected;}
 get isReady():boolean{return this.ready&&!this.closed;}
 get isUsable():boolean{return this.isReady&&(!!this.ws||(this.selected==='webRTC'&&['terminal','input','control'].every(label=>this.rtc[label as keyof Channels]?.readyState==='open')));}
 replayPending():void{this.replay();}
 receiveOffsets():readonly bigint[]{return this.engine.receiveOffsets();}
 setWebSocketSender(send:((bytes:Uint8Array)=>boolean)|null):void{
  this.ws=send;for(const s of [0,1,2] as const)this.carrierEffects(this.policy.channelState('webSocket',s,!!send&&this.ready,this.now()));
 }
 markReady():void{
  if(this.ready||this.closed)return;this.ready=true;
  for(const s of [0,1,2] as const){this.slots[s]!.readyState='open';this.carrierEffects(this.policy.channelState('webSocket',s,!!this.ws,this.now()));}
  for(const s of [0,1,2] as const)this.slots[s]!.dispatchEvent(new Event('open'));
 }
 attachWebRTC(ch:Partial<Channels>):void{
  for(const label of labels){const raw=ch[label];if(!raw||this.rtc[label]===raw)continue;this.rtc[label]=raw;const s=labels.indexOf(label);
   raw.addEventListener('message',e=>{
    if(this.closed||this.rtc[label]!==raw)return;
    const b=e.data instanceof ArrayBuffer?new Uint8Array(e.data):ArrayBuffer.isView(e.data)?new Uint8Array(e.data.buffer,e.data.byteOffset,e.data.byteLength):null;
    if(!b)return;if(s===3){this.slots[3]!.deliver(b);return;}
    const r=decodeFastRecord(b);if(r&&r.stream===s)this.receive(r,'webRTC');
   });
   whenOpen(raw,()=>{if(this.closed||this.rtc[label]!==raw)return;if(s===3){this.slots[3]!.readyState='open';this.slots[3]!.dispatchEvent(new Event('open'));}else this.carrierEffects(this.policy.channelState('webRTC',s as FastStream,true,this.now()));});
   raw.addEventListener('close',()=>{if(this.rtc[label]!==raw)return;if(s===3){this.slots[3]!.readyState='connecting';this.slots[3]!.dispatchEvent(new Event('close'));}else this.carrierEffects(this.policy.channelState('webRTC',s as FastStream,false,this.now()));});
  }
 }
 detachWebRTC():void{
  this.rtc={};for(const s of [0,1,2] as const)this.carrierEffects(this.policy.channelState('webRTC',s,false,this.now()));
  if(this.slots[3]!.readyState==='open'){this.slots[3]!.readyState='connecting';this.slots[3]!.dispatchEvent(new Event('close'));}
 }
 buffered(slot:number):number{return slot===3?this.rtc.bulk?.bufferedAmount??0:this.engine.bufferedAmount(slot as FastStream);}
 send(slot:number,bytes:Uint8Array):void{
  if(slot===3){if(this.rtc.bulk?.readyState!=='open')throw new DOMException('bulk unavailable','InvalidStateError');this.rtc.bulk.send(bytes);return;}
  const result=this.engine.send(slot as FastStream,bytes,this.now());
  if(result.kind!=='accepted'){this.fail(`fast-data ${result.kind}`);return;}
  this.effects(result.effects);this.outstanding();
 }
 receive(r:FastRecord,carrier:FastCarrierKind):void{
  if(!this.isReady||r.generation.length!==16||r.generation.some((b,i)=>b!==this.generation[i]))return;
  if(carrier==='webSocket'&&!this.ws)return;
  if(r.kind===3){this.transmit({...r,kind:4},carrier);return;}
  if(r.kind===4){this.carrierEffects(this.policy.probeReply(carrier,r.stream,r.value,this.now()));return;}
  // Match TermPath's 250 ms headroom: sparse terminal ACKs must not teach a one-second queue budget.
  const rtcAckDelay=r.stream===0?250:1000;
  const before=this.engine.bufferedAmount(r.stream);this.effects(this.engine.receive(r,this.now(),carrier==='webRTC'?rtcAckDelay:20));
  if(this.engine.bufferedAmount(r.stream)<before)this.policy.dataProgress(carrier,r.stream,this.now());this.outstanding();
 }
 private outstanding():void{for(const s of [0,1,2] as const)this.policy.setOutstanding(s,this.buffered(s)>0,this.now());}
 private effects(effects:DeliveryEffect[]):void{for(const e of effects){if(this.closed)return;if(e.kind==='transmit')this.transmit(e.record,this.selected);else if(e.kind==='deliver')this.slots[e.stream]!.deliver(e.message);else this.fail(e.reason);}}
 private carrierEffects(effects:CarrierEffect[]):void{for(const e of effects){if(e.kind==='sendProbe')this.transmit({kind:3,generation:this.generation,stream:e.stream,value:e.nonce,bytes:new Uint8Array()},e.carrier);else{this.opts.onCarrier?.(e.carrier);this.replay();}}}
 private replay():void{this.retry=false;for(const s of [2,1,0] as const)for(const r of this.engine.replay(s))this.transmit(r,this.selected);}
 private transmit(r:FastRecord,c:FastCarrierKind):void{
  if(this.closed)return;const bytes=encodeFastRecord(r);let sent=false;
  try {
   if(c==='webSocket')sent=this.ws?.(bytes)??false;
   else{const raw=this.rtc[labels[r.stream]];if(raw?.readyState==='open'){raw.send(bytes);sent=true;}}
  } catch { /* A close racing send leaves original-offset data retained for replay. */ }
  if(!sent&&r.kind===1)this.retry=true;
 }
 private tick():void{if(!this.isReady)return;this.effects(this.engine.poll(this.now()));this.carrierEffects(this.policy.tick(this.now()));if(this.retry&&(this.ws||this.rtc.control?.readyState==='open'))this.replay();}
 private fail(reason:string):void{if(this.closed)return;this.close();this.opts.onFailure(reason);}
 close():void{if(this.closed)return;this.closed=true;clearInterval(this.timer);this.ws=null;this.rtc={};for(const ch of this.slots){ch.readyState='closed';ch.dispatchEvent(new Event('close'));}}
}
// TEST-ONLY: same prototype hook as LaneChannel, so gates observe application frames after deframing.
(globalThis as { __rdevFastChannel?: unknown }).__rdevFastChannel = FastChannel;
