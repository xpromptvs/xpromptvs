import {it,expect,vi} from "vitest";
import {AgentSearch} from "../src/client/agents/search";
it("ignores stale searches and matches recent projects while querying indexed titles",async()=>{
 vi.useFakeTimers();const pending=new Map<string,(v:any[])=>void>();let rows:any[]=[];
 const search=new AgentSearch(q=>new Promise(resolve=>pending.set(q,resolve)),r=>{rows=r;});
 search.query("");await vi.advanceTimersByTimeAsync(200);pending.get("")!([{id:"recent",name:"Build",cwd:"/work/render"}]);await Promise.resolve();
 search.query("old");await vi.advanceTimersByTimeAsync(200);
 search.query("render");await vi.advanceTimersByTimeAsync(200);
 pending.get("render")!([{id:"new",name:"Render now"}]);await Promise.resolve();
 pending.get("old")!([{id:"stale",name:"Old"}]);await Promise.resolve();
 expect(rows.map(r=>r.id)).toEqual(["new","recent"]);
 search.reset();vi.useRealTimers();
});
