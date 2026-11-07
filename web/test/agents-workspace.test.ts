import {it,expect} from "vitest";
import {AgentWorkspace} from "../src/client/agents/workspace";
const tick=async()=>{for(let i=0;i<18;i++)await Promise.resolve();};
it("keeps tab views, drafts and hidden updates while restoring recycled row state without refetching",async()=>{
 const root=document.createElement("div"),sent:any[]=[];document.body.append(root);
 const w=new AgentWorkspace({root,send:m=>sent.push(m)});w.setActive(true);w.syncTabs(["a","b"]);
 const answer=async(op:string,result:any,thread?:string)=>{const m=[...sent].reverse().find(m=>m.op===op&&(!thread||m.thread===thread));expect(m).toBeTruthy();w.receive({t:"agent-response",id:m.id,epoch:"7",result});await tick();};
 const load=async(id:string)=>{w.showSession(id);await tick();await answer("hello",{joined:["a","b"],pending:[]});await answer("read",{thread:{id,status:{type:"idle"}}},id);await answer("history",{data:[{id:"t",status:"inProgress",items:[{id:"message",type:"agentMessage",text:"Initial",status:"completed"}]}]},id);if(sent.at(-1)?.op==="hello")await answer("hello",{joined:["a","b"],pending:[]});await answer("models",{data:[]});};
 try{
  await load("a");const a=root.querySelector<HTMLElement>('.agent-surface:not([hidden])')!;
  const message=a.querySelector<HTMLTextAreaElement>('[data-agent="message"]')!;message.value="unsent draft";message.dispatchEvent(new Event("input"));
  const scroll=a.querySelector<HTMLElement>('[data-agent="scroll"]')!;Object.defineProperties(scroll,{scrollHeight:{value:1000,configurable:true},clientHeight:{value:100,configurable:true}});scroll.scrollTop=125;
  const detail=a.querySelector<HTMLDetailsElement>("details")!;detail.open=true;
  const count=sent.filter(m=>["read","history","join","resume"].includes(m.op)).length;
  w.hide();w.receive({t:"agent-event",epoch:"7",event:{method:"item/completed",params:{threadId:"a",turnId:"t",item:{id:"hidden",type:"agentMessage",text:"Finished while hidden"}}}});
  w.showSession("a");await tick();expect(root.querySelector('.agent-surface:not([hidden])')).toBe(a);expect(message.value).toBe("unsent draft");expect(a.textContent).toContain("Finished while hidden");
  expect(scroll.scrollTop).toBe(125);expect(detail.isConnected).toBe(false);expect(a.querySelector<HTMLDetailsElement>("details")?.open).toBe(true);
  expect(sent.filter(m=>["read","history","join","resume"].includes(m.op))).toHaveLength(count);
  await load("b");const calls=()=>sent.filter(m=>m.op!=="children");const before=calls().length;w.showSession("a");await tick();expect(calls()).toHaveLength(before);expect(root.querySelector('.agent-surface:not([hidden])')).toBe(a);expect(message.value).toBe("unsent draft");
  w.syncTabs(["b"]);expect(a.isConnected).toBe(false);
 }finally{w.dispose();root.remove();}
});

it("finishes initial hydration while hidden instead of starting it again on return",async()=>{
 const root=document.createElement("div"),sent:any[]=[];const w=new AgentWorkspace({root,send:m=>sent.push(m)});w.setActive(true);w.syncTabs(["a"]);w.showSession("a");await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op);expect(m).toBeTruthy();w.receive({t:"agent-response",id:m.id,epoch:"7",result});await tick();};
 try{
  await answer("hello",{joined:[],pending:[]});w.hide();
  await answer("read",{thread:{id:"a",status:{type:"notLoaded"}}});await answer("history",{data:[]});await answer("models",{data:[]});
  const before=sent.filter(m=>m.op!=="children").length;w.showSession("a");await tick();
  expect(sent.filter(m=>m.op!=="children")).toHaveLength(before);expect(sent.filter(m=>m.op==="history")).toHaveLength(1);
 }finally{w.dispose();}
});

it("offers explicit recovery and refreshes its own tab rather than another globally selected session",async()=>{
 const root=document.createElement("div"),sent:any[]=[];const w=new AgentWorkspace({root,send:m=>sent.push(m)});w.setActive(true);w.syncTabs(["a","b"]);w.showSession("a");await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op);expect(m).toBeTruthy();w.receive({t:"agent-response",id:m.id,epoch:"7",result});await tick();};
 try{
  await answer("hello",{joined:[],pending:[]});await answer("read",{thread:{id:"a",status:{type:"notLoaded"}}});await answer("history",{data:[]});await answer("models",{data:[]});
  w.receive({t:"agent-event",epoch:"7",event:{method:"xpromptvs/resnapshot",params:{error:"Refresh to synchronize"}}});
  const refresh=root.querySelector<HTMLButtonElement>('.agent-heading [data-agent="refresh-tab"]');expect(refresh).not.toBeNull();refresh!.click();await tick();
  await answer("hello",{selected:"b",joined:[],pending:[]});
  if(sent.at(-1)?.op==="list")await answer("list",{data:[]});
  expect([...sent].reverse().find(m=>m.op==="read")?.thread).toBe("a");
  expect([...sent].reverse().find(m=>m.op==="history")?.thread).toBe("a");
 }finally{w.dispose();}
});
it("creates a host-owned Claude session before opening its regular tab",async()=>{
 const sent:any[]=[];const w=new AgentWorkspace({root:document.createElement('div'),send:m=>sent.push(m)});w.setActive(true);
 const promise=w.createClaudeSession('/tmp/project');await tick();let m=sent.at(-1)!;expect(m.op).toBe('hello');w.receive({t:'agent-response',id:m.id,epoch:'1',result:{providers:['claude']}});await tick();
 m=sent.at(-1)!;expect(m.op).toBe('new-thread');expect(m.args).toEqual({cwd:'/tmp/project',provider:'claude'});w.receive({t:'agent-response',id:m.id,epoch:'1',result:{thread:{id:'claude:uuid'}}});await tick();
 m=sent.at(-1)!;expect(m.op).toBe('open-tab');expect(m.thread).toBe('claude:uuid');w.receive({t:'agent-response',id:m.id,epoch:'1',result:{}});await promise;w.dispose();
});
