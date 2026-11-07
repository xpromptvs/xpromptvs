import { FAST_RECORD_MAX, FAST_U64_MAX, type FastRecord, type FastStream } from './fast-data';
export type DeliveryEffect = {kind:'transmit';record:FastRecord} | {kind:'deliver';stream:FastStream;message:Uint8Array} | {kind:'failed';reason:string};
export type SendResult = {kind:'accepted';effects:DeliveryEffect[]} | {kind:'full'|'invalid'};
const MESSAGE_MAX=1048576, PAYLOAD_MAX=2097152, WINDOW=PAYLOAD_MAX+8192, MESSAGE_COUNT_MAX=2048;
interface Pending { start:bigint; bytes:Uint8Array }
class Stream {
 sent=0n; acked=0n; next=0n; lastAck=0n; pending:Pending[]=[]; ackAt:number|null=null;
 ring?:Uint8Array; occupied?:Uint8Array;
 header=0; headerBytes=0; message:Uint8Array|null=null; messageAt=0;
}
/** Pure state owned by a connection generation, not by either carrier. */
export class FastDelivery {
 private streams=[new Stream(),new Stream(),new Stream()];
 private generation:Uint8Array;
 private failed=false;
 constructor(generation:Uint8Array, _nowMs:number) { if(generation.length!==16)throw new Error('invalid generation');this.generation=generation.slice(); }
 send(stream:FastStream,message:Uint8Array,_nowMs:number):SendResult {
  const s=this.streams[stream];
  if(this.failed||!s||message.length<1||message.length>MESSAGE_MAX)return {kind:'invalid'};
  if(this.bufferedAmount(stream)+message.length>PAYLOAD_MAX||s.pending.length>=MESSAGE_COUNT_MAX||s.sent-s.acked+BigInt(message.length+4)>BigInt(WINDOW))return {kind:'full'};
  if(s.sent+BigInt(message.length+4)>FAST_U64_MAX)return {kind:'invalid'};
  const bytes=new Uint8Array(message.length+4);new DataView(bytes.buffer).setUint32(0,message.length);bytes.set(message,4);
  const start=s.sent;s.sent+=BigInt(bytes.length);s.pending.push({start,bytes});
  return {kind:'accepted',effects:this.records(stream,start,bytes).map(record=>({kind:'transmit',record}))};
 }
 private records(stream:FastStream,start:bigint,bytes:Uint8Array):FastRecord[] {
  const out:FastRecord[]=[];for(let i=0;i<bytes.length;i+=FAST_RECORD_MAX)out.push({kind:1,generation:this.generation.slice(),stream,value:start+BigInt(i),bytes:bytes.slice(i,i+FAST_RECORD_MAX)});return out;
 }
 replay(stream:FastStream):FastRecord[] {
  if(this.failed)return [];const s=this.streams[stream];if(!s)return [];
  return s.pending.flatMap(p=>{const skip=Number(s.acked>p.start?s.acked-p.start:0n);return this.records(stream,p.start+BigInt(skip),p.bytes.subarray(skip));});
 }
 bufferedAmount(stream:FastStream):number {
  const s=this.streams[stream];if(!s)return 0;
  return s.pending.reduce((n,p)=>n+p.bytes.length-4-Math.min(p.bytes.length-4,Math.max(0,Number(s.acked-p.start)-4)),0);
 }
 receiveOffsets():readonly bigint[]{return this.streams.map(s=>s.next);}
 private ack(stream:FastStream):DeliveryEffect {
  const s=this.streams[stream]!;s.ackAt=null;s.lastAck=s.next;return {kind:'transmit',record:{kind:2,generation:this.generation.slice(),stream,value:s.next,bytes:new Uint8Array()}};
 }
 private fail(reason:string):DeliveryEffect[]{this.failed=true;return [{kind:'failed',reason}];}
 // RTC repairs below this layer; batch small ACKs, but release pacing at 4 KiB progress.
 receive(r:FastRecord,nowMs:number,ackDelayMs=20):DeliveryEffect[] {
  if(this.failed||r.generation.length!==16||r.generation.some((b,i)=>b!==this.generation[i]))return [];
  const s=this.streams[r.stream];if(!s||r.value<0n||r.value>FAST_U64_MAX)return this.fail('invalid-record');
  if(r.kind===2){
   if(r.value>s.sent)return this.fail('ack-beyond-sent');
   if(r.value>s.acked){s.acked=r.value;s.pending=s.pending.filter(p=>p.start+BigInt(p.bytes.length)>s.acked);}
   return [];
  }
  if(r.kind!==1)return []; // Carrier policy handles probes; delivery handles data only.
  if(r.bytes.length<1||r.bytes.length>FAST_RECORD_MAX)return this.fail('invalid-record');
  const end=r.value+BigInt(r.bytes.length);
  if(end>FAST_U64_MAX||end>s.next+BigInt(WINDOW))return this.fail('receive-window');
  if(end<=s.next)return [this.ack(r.stream)];
  const gap=r.value>s.next;
  s.ring??=new Uint8Array(WINDOW);s.occupied??=new Uint8Array(WINDOW);
  const skip=Number(s.next>r.value?s.next-r.value:0n);
  let pos=Number((r.value+BigInt(skip))%BigInt(WINDOW));
  for(let i=skip;i<r.bytes.length;i++){
   if(s.occupied[pos]&&s.ring[pos]!==r.bytes[i])return this.fail('conflicting-overlap');
   s.ring[pos]=r.bytes[i]!;s.occupied[pos]=1;pos=(pos+1)%WINDOW;
  }
  const out:DeliveryEffect[]=[];pos=Number(s.next%BigInt(WINDOW));
  while(s.occupied[pos]){
   const byte=s.ring[pos]!;s.occupied[pos]=0;s.next++;pos=(pos+1)%WINDOW;
   if(!s.message){
    s.header=s.header*256+byte;s.headerBytes++;
    if(s.headerBytes===4){
     if(s.header<1||s.header>MESSAGE_MAX)return [...out,...this.fail('invalid-message-length')];
     s.message=new Uint8Array(s.header);s.messageAt=0;s.header=0;s.headerBytes=0;
    }
   }else{
    s.message[s.messageAt++]=byte;
    if(s.messageAt===s.message.length){out.push({kind:'deliver',stream:r.stream,message:s.message});s.message=null;}
   }
  }
  // Shared terminal history reserves 2 KiB inside a 4 KiB spare allowance.
  // ACK at 2 KiB so compressed records release capacity without the one-second timer.
  if(gap||(ackDelayMs>20&&s.next-s.lastAck>=2048n))out.push(this.ack(r.stream));else if(s.ackAt===null)s.ackAt=nowMs+ackDelayMs;
  return out;
 }
 poll(nowMs:number):DeliveryEffect[]{
  if(this.failed)return [];const out:DeliveryEffect[]=[];
  for(const stream of [0,1,2] as const){const s=this.streams[stream]!;if(s.ackAt!==null&&nowMs>=s.ackAt)out.push(this.ack(stream));}return out;
 }
}
