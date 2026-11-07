import { describe, it, expect } from "vitest";
import { AgentStore } from "../src/client/agents/store";

describe("graphical agent transcript", () => {
  it("prepends older items from a page within the same turn", () => {
    const store=new AgentStore();store.select("t");store.beginHydration();
    store.hydrate([{id:"turn",items:[{id:"b",type:"agentMessage",text:"second"}]}]);
    store.event({method:"item/completed",params:{threadId:"t",turnId:"turn",item:{id:"c",type:"agentMessage",text:"live"}}});
    store.hydrate([{id:"turn",items:[{id:"a",type:"agentMessage",text:"first"},{id:"b",type:"agentMessage",text:"old"}]}]);
    expect(store.items().map(i=>i.id)).toEqual(["a","b","c"]);
  });
  it("replays streaming updates after history without duplicating the item", () => {
    const store = new AgentStore(); store.select("t"); store.beginHydration();
    store.event({method:"item/agentMessage/delta",params:{threadId:"t",turnId:"turn",itemId:"a",delta:"new"}});
    store.hydrate([{id:"turn",status:"inProgress",items:[]}]);
    expect(store.items().map(x=>x.text)).toEqual(["new"]);
  });
  it("an older history page cannot overwrite a completed live item", () => {
    const store = new AgentStore(); store.select("t");
    store.event({method:"item/completed",params:{threadId:"t",turnId:"turn",item:{id:"a",type:"agentMessage",text:"complete"}}});
    store.hydrate([{id:"turn",items:[{id:"a",type:"agentMessage",text:"partial"}]}]);
    expect(store.items()[0]!.text).toBe("complete");
  });
  it("ignores another thread and retains unknown item details", () => {
    const store = new AgentStore(); store.select("t");
    store.event({method:"item/started",params:{threadId:"other",turnId:"turn",item:{id:"a",type:"userMessage"}}});
    store.hydrate([{id:"turn",items:[{id:"unknown",type:"futureTool",result:{value:42}}]}]);
    expect(store.items()).toHaveLength(1);
    expect(store.items()[0]!.result).toEqual({value:42});
  });
  it("bounds a streaming record explicitly and does not resurrect an ended turn from old history", () => {
    const store=new AgentStore();store.select("t");
    store.event({method:"turn/started",params:{threadId:"t",turn:{id:"turn"}}});
    store.event({method:"item/commandExecution/outputDelta",params:{threadId:"t",turnId:"turn",itemId:"c",delta:"x".repeat(600_000)}});
    expect(store.items()[0]!._truncated).toBe(true);
    expect(store.items()[0]!.aggregatedOutput.length).toBeLessThanOrEqual(262144);
    store.event({method:"turn/completed",params:{threadId:"t",turn:{id:"turn",status:"completed"}}});
    store.hydrate([{id:"turn",status:"inProgress",items:[]}]);
    expect(store.activeTurn).toBeNull();
  });
  it("does not replay buffered deltas or starts over an already-persisted complete item", () => {
    const store=new AgentStore();store.select("t");store.beginHydration();
    store.event({method:"item/started",params:{threadId:"t",turnId:"turn",item:{id:"a",type:"agentMessage",text:"old"}}});
    store.event({method:"item/agentMessage/delta",params:{threadId:"t",turnId:"turn",itemId:"a",delta:"new"}});
    store.event({method:"item/agentMessage/delta",params:{threadId:"t",turnId:"turn",itemId:"b",delta:"after"}});
    store.hydrate([{id:"turn",status:"inProgress",items:[{id:"a",type:"agentMessage",text:"old new",completedAtMs:100}]}]);
    expect(store.items().map(x=>x.text)).toEqual(["old new","after"]);
  });
  it("renders failed and interrupted turns even with no transcript items", () => {
    const store=new AgentStore();store.select("t");
    store.hydrate([{id:"failed",status:"failed",items:[],error:{message:"Provider disconnected"}}]);
    expect(JSON.stringify(store.items())).toContain("Provider disconnected");
    store.event({method:"turn/completed",params:{threadId:"t",turn:{id:"interrupted",status:"interrupted",items:[],error:null}}});
    expect(store.items().some(i=>i.status==="interrupted")).toBe(true);
  });
  it("uses the daemon's nested runtime settings update",()=>{
    const store=new AgentStore();store.select("t");
    store.event({method:"thread/settings/updated",params:{threadId:"t",threadSettings:{model:"new-model",effort:"high",collaborationMode:{mode:"plan"}}}});
    expect(store.metadata.model).toBe("new-model");expect(store.metadata.reasoningEffort).toBe("high");expect(store.metadata.collaborationMode.mode).toBe("plan");
  });
});

it("retains every loaded page beyond 500 records and 8 MiB, including live output",()=>{
 const store=new AgentStore();store.select('long');store.beginHydration();
 const page=(start:number)=>[{id:'turn',items:Array.from({length:400},(_,i)=>({id:String(start+i),type:'agentMessage',text:'x'.repeat(8000)}))}];
 store.hydrate(page(800));store.hydrate(page(400));store.hydrate(page(0));
 expect(store.items().map(i=>i.id)).toEqual(Array.from({length:1200},(_,i)=>String(i)));
 store.event({method:'item/completed',params:{threadId:'long',turnId:'turn',item:{id:'live',type:'agentMessage',text:'Newest'}}});
 expect(store.items()).toHaveLength(1201);expect(store.items()[0]!.id).toBe('0');expect(store.items().at(-1)!.id).toBe('live');
 // Overlap must not duplicate or reorder the retained history.
 store.hydrate(page(400));expect(store.items()).toHaveLength(1201);
 store.select('other');expect(store.items()).toHaveLength(0);
});
