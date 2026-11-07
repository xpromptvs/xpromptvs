import type { AgentObject } from "./protocol";

export class AgentStore {
  thread: string | null = null;
  metadata: AgentObject = {};
  activeTurn: string | null = null;
  readonly requests = new Map<string, AgentObject>();
  private records = new Map<string, AgentObject>();
  private turns: string[] = [];
  private live = new Set<string>();
  private hydrating = false;
  private buffered: AgentObject[] = [];
  private order = 0;
  private ended = new Set<string>();
  private bufferedBytes = 0;
  private finalItems = new Set<string>();
  private awaitingCompletion = new Set<string>();
  needsResnapshot = false;
  select(thread: string): void {
    this.thread = thread; this.metadata = {}; this.activeTurn = null; this.requests.clear();
    this.records.clear(); this.turns = []; this.live.clear(); this.buffered = []; this.hydrating = false; this.order = 0;
    this.ended.clear();this.bufferedBytes=0;this.needsResnapshot=false;
    this.finalItems.clear();this.awaitingCompletion.clear();
  }
  beginHydration(): void { this.hydrating = true; this.buffered = [];this.bufferedBytes=0; }
  hydrate(turns: AgentObject[]): void {
    const replacing=this.hydrating,snapshotItems=new Set<string>(),completeItems=new Set<string>();
    if(replacing){this.activeTurn=null;this.needsResnapshot=false;}
    // Server pages are newest-first. Keep chronological turn order, including older pages.
    const ids = [...turns].reverse().map(t => String(t.id));
    this.turns = [...ids.filter(id => !this.turns.includes(id)), ...this.turns];
    for (const turn of [...turns].reverse()) {
      if(replacing){for(const[key,item]of this.records)if(item._turn===turn.id){this.records.delete(key);this.live.delete(key);}}
      if (turn.status === "inProgress"&&!this.ended.has(turn.id)) this.activeTurn = turn.id;
      // Item paging can split one turn. Newly loaded older items belong before its
      // existing records; preserve live records and overlap identities.
      const existing=[...this.records.values()].filter(i=>i._turn===turn.id);
      let olderOrder=Math.min(0,...existing.map(i=>i._order))-(turn.items?.length??0);
      for (const item of turn.items ?? []) {
        const key=`${turn.id}:${item.id}`;snapshotItems.add(key);
        if(item.status!=="inProgress"){completeItems.add(key);this.finalItems.add(key);}
        else if(replacing&&(item.text||item.aggregatedOutput))this.awaitingCompletion.add(key);
        const absent=!this.records.has(key);
        this.upsert(turn.id,item,false);
        if(!replacing&&absent&&existing.length){const record=this.records.get(key);if(record)record._order=olderOrder++;}
      }
      this.outcome(turn,false);
    }
    this.hydrating = false;
    const buffered = this.buffered; this.buffered = [];this.bufferedBytes=0;
    for (const event of buffered) {
      const p=event.params??{},key=`${p.turnId}:${p.itemId??p.item?.id}`;
      // Persisted completed items already represent their buffered deltas. Active items absent
      // from persistence retain the stream; never guess overlap from matching text suffixes.
      if(event.method==="item/started"&&snapshotItems.has(key))continue;
      if(event.method?.endsWith("/delta")&&completeItems.has(key))continue;
      this.event(event);
    }
  }
  abortHydration():void{this.hydrating=false;const buffered=this.buffered;this.buffered=[];this.bufferedBytes=0;for(const event of buffered)this.event(event);this.needsResnapshot=true;}
  private outcome(turn:AgentObject,isLive:boolean):void{
    if(typeof turn.id!=="string")return;
    if(["failed","interrupted"].includes(turn.status))this.upsert(turn.id,{id:`${turn.id}-outcome`,type:"turnOutcome",status:turn.status,error:turn.error},isLive);
    if(["completed","interrupted","failed"].includes(turn.status)){
      const duration=typeof turn.durationMs==="number"&&Number.isFinite(turn.durationMs)&&turn.durationMs>=0?turn.durationMs:null;
      const completed=typeof turn.completedAt==="number"&&Number.isFinite(turn.completedAt)&&turn.completedAt>0?turn.completedAt:null;
      if(duration!=null||completed!=null)this.upsert(turn.id,{id:`${turn.id}-completion`,type:"turnCompletion",durationMs:duration,completedAt:completed},isLive);
    }
  }
  private upsert(turn: string, item: AgentObject, isLive: boolean): void {
    if (typeof item.id !== "string") return;
    const key = `${turn}:${item.id}`;
    if (!isLive && this.live.has(key)) return;
    if (!this.turns.includes(turn)) this.turns.push(turn);
    const old = this.records.get(key);
    let record:AgentObject={ ...old, ...item, _turn: turn, _order: old?._order ?? this.order++ };
    for(const[field,value]of Object.entries(record))if(typeof value==="string"&&value.length>262144){record[field]=value.slice(-262144);record._truncated=true;}
    const encoded=JSON.stringify(record);
    if(encoded.length>524288){record={id:item.id,type:item.type,_turn:turn,_order:record._order,_truncated:true,_preview:encoded.slice(0,262144)};}
    this.records.set(key,record);
    if (isLive) this.live.add(key);
    // Retain all loaded pages: evicting either end removes reading anchors and
    // makes back-and-forth navigation incomplete. VirtualList bounds mounted DOM;
    // individual record previews and hydration buffering remain bounded here.
  }
  event(event: AgentObject): void {
    const p = event.params ?? {}, thread = p.threadId ?? p.thread?.id;
    if (thread && thread !== this.thread) return;
    if (this.hydrating && event.method !== "xpromptvs/request" && event.method !== "serverRequest/resolved") {
      const size=JSON.stringify(event).length*2;
      if(this.buffered.length<4096&&this.bufferedBytes+size<=4*1024*1024){this.buffered.push(event);this.bufferedBytes+=size;}
      else this.needsResnapshot=true;
      return;
    }
    const turn = p.turnId ?? p.turn?.id ?? this.activeTurn ?? "session";
    switch (event.method) {
      case "turn/started": this.activeTurn = p.turn.id;this.ended.delete(p.turn.id); break;
      case "turn/completed": this.ended.add(p.turn?.id);if (this.activeTurn === p.turn?.id) this.activeTurn = null;for(const item of p.turn?.items??[])this.upsert(turn,item,true);this.outcome(p.turn??{},true);break;
      case "thread/status/changed": this.metadata.status = p.status; if (p.status?.type === "idle") this.activeTurn = null; break;
      case "thread/tokenUsage/updated": this.metadata.tokenUsage = p.tokenUsage; break;
      case "thread/goal/updated": this.metadata.goal = p.goal; break;
      case "thread/goal/cleared": this.metadata.goal = null; break;
      case "thread/queue/changed": this.metadata.queue = p; break;
      case "thread/settings/updated": {const runtime=p.threadSettings??p;Object.assign(this.metadata,runtime);if("effort"in runtime)this.metadata.reasoningEffort=runtime.effort;break;}
      case "item/started": if(!this.finalItems.has(`${turn}:${p.item?.id}`))this.upsert(turn,p.item,true);break;
      case "item/completed": this.finalItems.add(`${turn}:${p.item?.id}`);this.awaitingCompletion.delete(`${turn}:${p.item?.id}`);this.upsert(turn,{...p.item,_partial:false,_synchronizing:false},true);break;
      case "item/agentMessage/delta": case "item/plan/delta": case "item/commandExecution/outputDelta": case "item/fileChange/outputDelta": {
        const key = `${turn}:${p.itemId}`, old = this.records.get(key);
        if(this.finalItems.has(key))break;
        if(this.awaitingCompletion.has(key)){this.upsert(turn,{...old,id:p.itemId,_synchronizing:true},true);break;}
        const command = event.method.includes("commandExecution"), field = command ? "aggregatedOutput" : "text";
        this.upsert(turn, { id: p.itemId, type: old?.type ?? (command ? "commandExecution" : event.method.includes("/plan/") ? "plan" : "agentMessage"),
          [field]: String(old?.[field] ?? "") + String(p.delta ?? ""), _partial:old?._partial??!old }, true);
        break;
      }
      case "item/reasoning/summaryTextDelta": case "item/reasoning/textDelta": {
        const old = this.records.get(`${turn}:${p.itemId}`);
        this.upsert(turn, { id: p.itemId, type: "reasoning", text: String(old?.text ?? "") + String(p.delta ?? "") }, true); break;
      }
      case "turn/plan/updated": this.upsert(turn, { id: `${turn}-plan`, type: "plan", ...p }, true); break;
      case "turn/diff/updated": this.upsert(turn, { id: `${turn}-diff`, type: "fileChange", diff: p.diff }, true); break;
      case "xpromptvs/request": {
        const requestThread = p.request?.params?.threadId;
        if (requestThread === this.thread) this.requests.set(p.key, p.request); break;
      }
      case "serverRequest/resolved": this.requests.delete(typeof p.requestId === "string" ? `s:${p.requestId}` : String(p.requestId)); break;
      default:
        if (event.method?.endsWith("/updated") || event.method?.includes("/progress") || event.method === "error") {
          this.upsert(turn, { id: p.itemId ?? event.method, type: "event", method: event.method, ...p }, true);
        }
    }
  }
  items(): AgentObject[] {
    return [...this.records.values()].sort((a, b) => this.turns.indexOf(a._turn) - this.turns.indexOf(b._turn) || a._order - b._order);
  }
}
