const LIMIT=1_048_576,CHUNK=8192;
interface Message {term:string;epoch:string;copy:string;seq:number;count:number;bytes:number;data:string}
interface Copy {message:Message;text:string;generation:number}
interface Pending {message:Message;next:number;parts:Uint8Array[];timer:ReturnType<typeof setTimeout>}
interface Dependencies {
  current(term:string,epoch:bigint):boolean;
  write(text:string):Promise<void>;
  offer(available:boolean):void;
}
function parse(raw:unknown):Message|null {
  const m=raw as Record<string,unknown>|null;
  if(!m||typeof m!=='object'||typeof m.term!=='string'||!/^tmux:\$\d+$/.test(m.term)||m.term.length>128||
     typeof m.epoch!=='string'||!/^(0|[1-9]\d{0,19})$/.test(m.epoch)||
     typeof m.copy!=='string'||!m.copy||m.copy.length>128||typeof m.data!=='string'||m.data.length>10924||
     typeof m.bytes!=='number'||!Number.isInteger(m.bytes)||m.bytes<0||m.bytes>LIMIT||
     typeof m.count!=='number'||m.count!==Math.max(1,Math.ceil(m.bytes/CHUNK))||
     typeof m.seq!=='number'||!Number.isInteger(m.seq)||m.seq<0||m.seq>=m.count)return null;
  return m as unknown as Message;
}
/** One bounded, atomic clipboard offer. No initial copy, snapshots or reconnect replay. */
export class TermClipboardReceiver {
  private pending?:Pending;
  private offered?:Copy;
  private generation=0;
  private seen=new Set<string>();
  readonly stats={received:0,written:0,offered:0};
  constructor(private readonly deps:Dependencies){}
  receive(raw:unknown):boolean {
    if((raw as {t?:unknown}|null)?.t!=='term-clipboard')return false;
    const m=parse(raw);if(!m)return true;
    this.stats.received++;
    if(!this.current(m)){this.reset();return true;}
    if(this.seen.has(m.copy))return true;
    let part:Uint8Array;
    try {const bytes=atob(m.data);part=Uint8Array.from(bytes,c=>c.charCodeAt(0));}catch{return true;}
    const expected=m.seq<m.count-1?CHUNK:m.bytes-CHUNK*(m.count-1);
    if(part.length!==expected)return true;
    if(m.seq===0){
      this.clearPending();this.generation++;this.offered=undefined;this.deps.offer(false);
      const pending:Pending={message:m,next:0,parts:[],timer:setTimeout(()=>{if(this.pending===pending)this.clearPending();},5000)};
      this.pending=pending;
    }
    const p=this.pending;
    if(!p||p.message.copy!==m.copy||p.message.term!==m.term||p.message.epoch!==m.epoch||p.message.bytes!==m.bytes||p.message.count!==m.count||p.next!==m.seq){this.clearPending();return true;}
    p.parts.push(part);p.next++;
    if(p.next!==m.count)return true;
    const bytes=new Uint8Array(m.bytes);let offset=0;for(const part of p.parts){bytes.set(part,offset);offset+=part.length;}
    this.clearPending();
    let text:string;try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);}catch{return true;}
    this.seen.add(m.copy);if(this.seen.size>256)this.seen.delete(this.seen.values().next().value!);
    void this.apply({message:m,text,generation:this.generation});return true;
  }
  private current(m:Message):boolean {return this.deps.current(m.term,BigInt(m.epoch));}
  private valid(copy:Copy):boolean {return copy.generation===this.generation&&this.current(copy.message);}
  private async apply(copy:Copy):Promise<void> {
    if(!this.valid(copy))return;
    try {
      // Invoked synchronously by retry's click handler, before any await, for Safari activation.
      await this.deps.write(copy.text);
      if(this.valid(copy)){this.stats.written++;this.offered=undefined;this.deps.offer(false);}
    }catch{
      if(this.valid(copy)){this.stats.offered++;this.offered=copy;this.deps.offer(true);}
    }
  }
  retry():Promise<void> {const copy=this.offered;return copy?this.apply(copy):Promise.resolve();}
  refresh():void {if(this.pending&&!this.current(this.pending.message)||this.offered&&!this.valid(this.offered))this.reset();}
  private clearPending():void {if(this.pending)clearTimeout(this.pending.timer);this.pending=undefined;}
  reset():void {this.generation++;this.clearPending();this.offered=undefined;this.seen.clear();this.deps.offer(false);}
}
