import {decodeJson} from '../../lib/codec';
import {randomUUID} from '../../lib/resume-id';
import {sameSourceWindowKey,validSourceWindowKey,type SourceWindowKey} from './types';
export interface SourceFocusState {
  key?: SourceWindowKey;
  state: 'inactive' | 'waiting' | 'ready' | 'unavailable';
  reason?: string;
  scrollGestures?: readonly string[];
}
interface Dependencies {
  control(message: Record<string,unknown>): void;
  input(message: Record<string,unknown>): void;
  now(): number;
  requestId?(): string;
  state?(state: SourceFocusState): void;
}
type InputEvent = Record<string,unknown> & {t:string};
const TYPES=new Set(['touch','hover','scroll','scroll-fling','scroll-gesture','win-key','win-keys-release','sim-touch','sim-text']);
const MAX_EVENTS=64, MAX_WAIT_MS=500;
function inputEvent(data:string|ArrayBuffer|ArrayBufferView):InputEvent|undefined {
  try {
    const size=typeof data==='string'?new TextEncoder().encode(data).length:data.byteLength;
    if(size>65536)return;
    const event:unknown=typeof data==='string'?JSON.parse(data):decodeJson(new Uint8Array(ArrayBuffer.isView(data)?data.buffer:data,
      ArrayBuffer.isView(data)?data.byteOffset:0,data.byteLength));
    if(!event||typeof event!=='object'||Array.isArray(event))return;
    const record=event as Record<string,unknown>;
    return typeof record.t==='string'&&TYPES.has(record.t)?record as InputEvent:undefined;
  }catch{return;}
}
const motion=(event:InputEvent)=>event.t==='hover'||(event.t==='touch'||event.t==='sim-touch')&&event.phase==='move';
/** The sole native media input sender. One source incarnation, one current host commit, no fallback.
 * Focus incurs a commit round trip; ready input goes directly over the existing input channel. */
export class SourceFocusGate {
  private capable=false;
  private scrollGestures:string[]=[];
  private leaseScrollGestures?:string[];
  private driving=false;
  private desired: SourceWindowKey|null|undefined;
  private request?: string;
  private lease?: string;
  private sequence=0;
  private lifetime=0;
  private pendingStarted=false;
  private queue:InputEvent[]=[];
  private started=0;
  private discarded=false;
  private timer?:ReturnType<typeof setTimeout>;
  private ended=false;
  private receivedEvents=0;
  private emittedEvents=0;
  private emittedTypes:Record<string,number>={};
  private failed=false;
  private capabilityTimer?:ReturnType<typeof setTimeout>;
  private admission=0;
  private capabilityTimedOut=false;
  constructor(private readonly deps:Dependencies){}
  /** Every control admission must negotiate again, even if its source IDs are unchanged. */
  open():void {
    if(this.ended)return;
    this.invalidate(false);this.capable=false;this.scrollGestures=[];this.failed=false;
    if(this.capabilityTimer)clearTimeout(this.capabilityTimer);
    this.capabilityTimedOut=false;const admission=++this.admission;
    this.capabilityTimer=setTimeout(()=>{if(!this.ended&&this.admission===admission&&!this.capable){this.capabilityTimedOut=true;this.notify('unavailable','host-update-required');}},2000);
    this.deps.control({t:'source-input-capabilities',v:1});
    this.issue();
  }
  close():void {
    if(this.ended)return;
    if(this.capabilityTimer)clearTimeout(this.capabilityTimer);this.capabilityTimer=undefined;this.admission++;
    this.invalidate(false);this.capable=false;this.scrollGestures=[];this.failed=false;this.notify(this.desired?'waiting':'inactive');
  }
  setDriving(value:boolean):void {
    if(this.ended||this.driving===value)return;
    this.invalidate(this.driving);this.driving=value;
    if(value)this.issue();else this.notify('inactive');
  }
  activate(key:SourceWindowKey|null):void {
    if(this.ended||(key!==null&&!validSourceWindowKey(key)))return;
    if((key===null&&this.desired===null||key!==null&&sameSourceWindowKey(this.desired??undefined,key))&&!this.failed)return;
    this.invalidate(true);this.desired=key===null?null:Object.freeze({...key});this.failed=false;this.issue();
  }
  retire(key:SourceWindowKey):void {if(sameSourceWindowKey(this.desired??undefined,key))this.activate(null);}
  receive(message:unknown):boolean {
    if(this.ended||!message||typeof message!=='object')return false;
    const m=message as Record<string,unknown>;
    if(m.t==='source-input-capabilities') {
      if(m.v!==1)return true;
      this.scrollGestures=Array.isArray(m.scrollGestures)?[...new Set(m.scrollGestures.filter((kind):kind is string=>typeof kind==='string'&&['window','display','simulator'].includes(kind)))]:[];
      if(!this.capable){this.capable=true;this.capabilityTimedOut=false;if(this.capabilityTimer)clearTimeout(this.capabilityTimer);this.capabilityTimer=undefined;this.issue();}return true;
    }
    if(m.t!=='source-focus')return false;
    if(!this.capable||!this.driving||!this.request||m.request!==this.request||m.source!==(this.desired?.source??null))return true;
    if(typeof m.error==='string') {
      this.invalidate(false);this.failed=true;this.notify('unavailable',m.error);return true;
    }
    if(this.desired===null){this.invalidate(false);this.notify('inactive');return true;}
    if(!this.desired||typeof m.lease!=='string'||!m.lease.length||new TextEncoder().encode(m.lease).length>128)return true;
    // A duplicate commit cannot replay a queue or replace an already admitted lease.
    if(this.lease)return true;
    this.lease=m.lease;
    this.leaseScrollGestures=Array.isArray(m.scrollGestures)?m.scrollGestures.filter((kind):kind is string=>typeof kind==='string'&&['window','display','simulator'].includes(kind)):undefined;
    if(this.timer)clearTimeout(this.timer);this.timer=undefined;
    const queue=!this.discarded&&this.deps.now()-this.started<=MAX_WAIT_MS?this.queue:[];
    const key=this.desired,request=this.request,lease=this.lease;
    this.queue=[];this.notify('ready');
    for(const event of queue) {
      // A callback may synchronously change ownership while the queue is being flushed.
      if(this.request!==request||this.lease!==lease||!sameSourceWindowKey(this.desired??undefined,key))break;
      this.emit(key,event,lease);
    }
    return true;
  }
  send(key:SourceWindowKey,data:string|ArrayBuffer|ArrayBufferView):void {
    this.receivedEvents++;
    if(this.ended||!this.driving||!sameSourceWindowKey(this.desired??undefined,key)||this.failed)return;
    const event=inputEvent(data);if(!event)return;
    if(this.capable&&this.lease){this.emit(key,event,this.lease);return;}
    // Capability negotiation shares the same bounded first-chord window. An old host never gets input.
    if(!this.pendingStarted||this.discarded)return;
    if(this.deps.now()-this.started>MAX_WAIT_MS){this.dropQueue();return;}
    const last=this.queue.at(-1);
    if(last&&motion(event)&&motion(last)&&last.t===event.t)this.queue[this.queue.length-1]=event;
    else if(this.queue.length>=MAX_EVENTS)this.dropQueue();else this.queue.push(event);
  }
  private issue():void {
    if(this.ended||!this.driving||this.desired===undefined){this.notify('inactive');return;}
    if(!this.pendingStarted) {
      this.pendingStarted=true;this.started=this.deps.now();
      const lifetime=this.lifetime;
      this.timer=setTimeout(()=>{if(this.lifetime===lifetime)this.dropQueue();},MAX_WAIT_MS);
    }
    if(!this.capable&&this.capabilityTimedOut){this.notify('unavailable','host-update-required');return;}
    this.notify('waiting');if(!this.capable||this.request)return;
    this.request=`${(this.deps.requestId?.()??randomUUID()).slice(0,40)}-${++this.sequence}`;
    this.deps.control({t:'source-focus',source:this.desired?.source??null,request:this.request});
  }
  private emit(key:SourceWindowKey,event:InputEvent,lease:string):void {
    this.emittedEvents++;this.emittedTypes[event.t]=(this.emittedTypes[event.t]??0)+1;this.deps.input({t:'source-input',source:key.source,lease,event});
  }
  private dropQueue():void {this.queue=[];this.discarded=true;}
  private invalidate(release:boolean):void {
    const key=this.desired,lease=this.lease;
    this.lifetime++;this.pendingStarted=false;
    this.request=undefined;this.lease=undefined;this.queue=[];this.discarded=false;
    this.leaseScrollGestures=undefined;
    if(this.timer)clearTimeout(this.timer);this.timer=undefined;
    if(release&&this.driving&&key&&lease)this.emit(key,{t:'win-keys-release'},lease);
  }
  private notify(state:SourceFocusState['state'],reason?:string):void {
    this.deps.state?.({key:this.desired??undefined,state,reason,scrollGestures:[...(this.leaseScrollGestures??this.scrollGestures)]});
  }
  debug():Record<string,unknown> {
    return {capable:this.capable,driving:this.driving,desired:this.desired,ready:!!this.lease,
      pending:!!this.request&&!this.lease,failed:this.failed,buffered:this.queue.length,discarded:this.discarded,
      receivedEvents:this.receivedEvents,emittedEvents:this.emittedEvents,emittedTypes:{...this.emittedTypes}};
  }
  dispose():void {
    if(this.ended)return;
    if(this.capabilityTimer)clearTimeout(this.capabilityTimer);this.capabilityTimer=undefined;this.admission++;
    this.invalidate(true);this.ended=true;this.desired=undefined;this.capable=false;this.driving=false;this.notify('inactive');
  }
}
