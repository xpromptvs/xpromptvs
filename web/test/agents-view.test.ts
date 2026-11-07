import { it, expect } from "vitest";
import { AgentsView } from "../src/client/agents/view";

const tick = async () => { for(let i=0;i<8;i++) await Promise.resolve(); };
it("browses a session without resuming and joins only on Take over", async () => {
  const root = document.createElement("div"), button = document.createElement("button"), sent: any[]=[];
  document.body.append(root,button);
  const view = new AgentsView({root,button,send:m=>sent.push(m)}); view.setActive(true);
  view.open(); await tick();
  const answer = async (op:string,result:any) => {
    const message = [...sent].reverse().find(m=>m.op===op); expect(message).toBeTruthy();
    view.receive({t:"agent-response",id:message.id,epoch:"7",result}); await tick();
  };
  await answer("hello",{available:true,joined:[],pending:[]});
  expect(root.querySelector('[data-agent="notice"]')?.textContent).toContain("Loading Codex sessions");
  await answer("list",{data:[{id:"live",name:"Fix bug",cwd:"/repo",status:{type:"active"}}],nextCursor:null});
  expect(root.querySelector('[data-agent="notice"]')?.textContent).toBe("");
  (root.querySelector('[data-thread="live"]') as HTMLButtonElement).click(); await tick();
  await answer("read",{thread:{id:"live",name:"Fix bug",status:{type:"active"}}});
  await answer("history",{data:[]});
  expect(sent.some(m=>m.op==="join"||m.op==="resume")).toBe(false);
  (root.querySelector('[data-action="join"]') as HTMLButtonElement).click(); await tick();
  expect([...sent].reverse().find(m=>m.op==="join")?.thread).toBe("live");
  await answer("join",{thread:{id:"live",name:"Fix bug",status:{type:"idle"}},model:"model"});
  await answer("history",{data:[]});await answer("hello",{available:true,joined:["live"],pending:[]});
  const message=root.querySelector('[data-agent="message"]') as HTMLTextAreaElement;
  message.value="first message";message.dispatchEvent(new Event("input"));
  (root.querySelector('[data-agent="composer"]') as HTMLFormElement).requestSubmit();await tick();
  message.value="new draft while sending";message.dispatchEvent(new Event("input"));
  await answer("send",{turn:{id:"turn"}});
  expect(message.value).toBe("new draft while sending");
  view.dispose(); root.remove(); button.remove();
});
it("hides agent data and invalidates forms when the client loses control", () => {
  const root=document.createElement("div"),button=document.createElement("button");
  const view=new AgentsView({root,button,send:()=>{}}); view.setActive(true);
  view.setActive(false);
  expect(button.disabled).toBe(true); expect(root.hidden).toBe(true);
  view.dispose();
});

it("closing Agents during hello cannot start hidden subagent polling",async()=>{
 const root=document.createElement("div"),button=document.createElement("button"),sent:any[]=[];
 const view=new AgentsView({root,button,send:m=>sent.push(m)});view.setActive(true);view.open();await tick();view.hide();
 const answer=async(op:string,result:any)=>{const message=[...sent].reverse().find(m=>m.op===op);expect(message).toBeTruthy();view.receive({t:"agent-response",id:message.id,epoch:"7",result});await tick();};
 try{await answer("hello",{available:true,joined:[],pending:[],selected:"parent"});if(sent.some(m=>m.op==="list"))await answer("list",{data:[{id:"parent",status:{type:"active"}}]});expect(sent.some(m=>m.op==="children")).toBe(false);}
 finally{view.dispose();}
});

it("returning to Sessions stops live discovery until a session is selected again",async()=>{
 const root=document.createElement("div"),button=document.createElement("button"),sent:any[]=[];
 const view=new AgentsView({root,button,send:m=>sent.push(m)});view.setActive(true);view.open();await tick();
 const answer=async(op:string,result:any)=>{const message=[...sent].reverse().find(m=>m.op===op);view.receive({t:"agent-response",id:message.id,epoch:"7",result});await tick();};
 try{await answer("hello",{joined:[],pending:[],selected:"parent"});await answer("list",{data:[{id:"parent",status:{type:"active"}}]});await answer("read",{thread:{id:"parent",status:{type:"active"}}});await answer("history",{data:[]});await answer("children",{data:[{id:"child",parentThreadId:"parent",agentNickname:"Ada",status:{type:"active"}}]});
 (root.querySelector('[data-agent="back"]')as HTMLButtonElement).click();expect((root.querySelector('[data-agent="subagents"]')as HTMLElement).hidden).toBe(true);
 }finally{view.dispose();}
});

it("a regular live tab attaches immediately and preserves approvals from the fresh join",async()=>{
 const root=document.createElement("div"),button=document.createElement("button"),sent:any[]=[];
 const view=new AgentsView({root,button,send:m=>sent.push(m)});view.setActive(true);view.showSession("live");await tick();
 const answer=async(op:string,result:any)=>{const message=[...sent].reverse().find(m=>m.op===op);expect(message).toBeTruthy();view.receive({t:"agent-response",id:message.id,epoch:"7",result});await tick();};
 try{
  await answer("hello",{joined:[],pending:[]});
  await answer("read",{thread:{id:"live",name:"Build",status:{type:"active"}}});await answer("history",{data:[]});
  expect(sent.filter(m=>m.op==="join")).toHaveLength(1);expect(sent.some(m=>m.op==="resume")).toBe(false);
  await answer("join",{thread:{id:"live",status:{type:"active"}}});await answer("history",{data:[]});
  await answer("hello",{joined:["live"],pending:[{id:101,method:"item/tool/requestUserInput",params:{threadId:"live",questions:[{id:"q",header:"Ready",question:"Proceed?",options:[]}]}}]});
  expect(root.querySelector('[data-agent="requests"]')?.textContent).toContain("Proceed?");
  view.hide();view.showSession("saved");await tick();await answer("hello",{joined:["live"],pending:[]});
  await answer("read",{thread:{id:"saved",status:{type:"notLoaded"}}});await answer("history",{data:[]});
  expect(sent.some(m=>m.op==="resume")).toBe(false);expect(root.querySelector('[data-action="join"]')?.textContent).toBe("Resume");
 }finally{view.dispose();}
});

it("successful selection of an already-selected host tab restores its conversation without a view-set",async()=>{
 const root=document.createElement("div"),button=document.createElement("button"),sent:any[]=[];
 const view=new AgentsView({root,button,send:m=>sent.push(m)});view.setActive(true);
 const answer=async(op:string,result:any)=>{const message=[...sent].reverse().find(m=>m.op===op);expect(message).toBeTruthy();view.receive({t:"agent-response",id:message.id,epoch:"7",result});await tick();};
 try{
  const opening=view.tabAction("select-tab","saved");await tick();await answer("hello",{joined:[],pending:[]});await answer("select-tab",{});await opening;await tick();
  expect(view.selectedTab).toBe("saved");expect(root.classList.contains("agent-tab-mode")).toBe(true);
 }finally{view.dispose();}
});

it("automatically pages earlier history near the top, deduplicates, and stops on exhaustion",async()=>{
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});view.setActive(true);view.showSession('saved');await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op)!;view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 const history=()=>sent.filter(m=>m.op==='history');
 try{
  await answer('hello',{joined:[],pending:[]});await answer('read',{thread:{id:'saved',status:{type:'notLoaded'}}});
  await answer('history',{data:[{id:'t',items:[{id:'recent',type:'agentMessage',text:'Recent'}]}],nextCursor:'page1'});await answer('models',{data:[]});
  const scroll=root.querySelector<HTMLElement>('[data-agent="scroll"]')!;
  Object.defineProperties(scroll,{clientHeight:{value:400},scrollHeight:{value:4000}});
  scroll.scrollTop=2000;scroll.dispatchEvent(new Event('scroll'));await tick();expect(history()).toHaveLength(1);
  scroll.scrollTop=250;for(let i=0;i<5;i++)scroll.dispatchEvent(new Event('scroll'));await tick();
  expect(history()).toHaveLength(2);expect(history().at(-1).args).toEqual({cursor:'page1'});
  expect(root.querySelector('[data-agent="older"]')!.classList.contains('is-loading')).toBe(true);
  expect(root.querySelector('[data-agent="older"]')!.tagName).toBe('DIV');
  await answer('history',{data:[{id:'older',items:[{id:'early',type:'agentMessage',text:'Earlier'}]}],nextCursor:null});
  expect(root.textContent).toContain('Earlier');for(let i=0;i<5;i++)scroll.dispatchEvent(new Event('scroll'));await tick();expect(history()).toHaveLength(2);
 }finally{view.dispose();root.remove();}
});
it("pauses automatic history retries after errors until scrolling away and back",async()=>{
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});view.setActive(true);view.showSession('saved');await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op)!;view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 try{
  await answer('hello',{joined:[],pending:[]});await answer('read',{thread:{id:'saved',status:{type:'notLoaded'}}});await answer('history',{data:[],nextCursor:'older'});await answer('models',{data:[]});
  const scroll=root.querySelector<HTMLElement>('[data-agent="scroll"]')!;Object.defineProperties(scroll,{clientHeight:{value:400},scrollHeight:{value:4000}});
  scroll.scrollTop=100;scroll.dispatchEvent(new Event('scroll'));await tick();const failed=sent.filter(m=>m.op==='history').at(-1)!;
  view.receive({t:'agent-response',id:failed.id,epoch:'7',error:'Offline'});await tick();
  scroll.dispatchEvent(new Event('scroll'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
  expect(root.querySelector('[data-agent="older"]')!.classList.contains('is-loading')).toBe(false);
  scroll.scrollTop=800;scroll.dispatchEvent(new Event('scroll'));scroll.scrollTop=100;scroll.dispatchEvent(new Event('scroll'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(3);
  await answer('history',{data:[],nextCursor:'older'});scroll.dispatchEvent(new Event('scroll'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(3);
 }finally{view.dispose();root.remove();}
});

it('does not chain earlier-history requests while native overscroll defers the prepend correction',async()=>{
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});view.setActive(true);view.showSession('saved');await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op)!;view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 try{
  await answer('hello',{joined:[],pending:[]});await answer('read',{thread:{id:'saved',status:{type:'notLoaded'}}});
  await answer('history',{data:[{id:'recent',items:Array.from({length:30},(_,i)=>({id:'r'+i,type:'agentMessage',text:'Recent '+i}))}],nextCursor:'page1'});await answer('models',{data:[]});
  const scroll=root.querySelector<HTMLElement>('[data-agent="scroll"]')!,content=root.querySelector<HTMLElement>('[data-agent="transcript"]')!;
  Object.defineProperties(scroll,{clientHeight:{value:400},scrollHeight:{value:4000}});content.getBoundingClientRect=()=>({top:-scroll.scrollTop,width:600} as DOMRect);
  scroll.scrollTop=2000;scroll.dispatchEvent(new Event('scroll'));scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));await tick();
  expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
  scroll.scrollTop=-30;scroll.dispatchEvent(new Event('scroll'));
  await answer('history',{data:[{id:'older',items:Array.from({length:20},(_,i)=>({id:'o'+i,type:'agentMessage',text:'Earlier '+i}))}],nextCursor:'page2'});
  expect(scroll.scrollTop).toBe(-30);expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
  scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));scroll.dispatchEvent(new Event('scrollend'));await tick();
  expect(scroll.scrollTop).toBeGreaterThan(400);expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
 }finally{view.dispose();root.remove();}
});
it('starts an earlier-history request after a fast overscroll settles at the top',async()=>{
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});view.setActive(true);view.showSession('saved');await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op)!;view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 try{
  await answer('hello',{joined:[],pending:[]});await answer('read',{thread:{id:'saved',status:{type:'notLoaded'}}});
  await answer('history',{data:[{id:'recent',items:[{id:'r',type:'agentMessage',text:'Recent'}]}],nextCursor:'page1'});await answer('models',{data:[]});
  const scroll=root.querySelector<HTMLElement>('[data-agent="scroll"]')!;Object.defineProperties(scroll,{clientHeight:{value:400},scrollHeight:{value:4000}});
  scroll.scrollTop=2000;scroll.dispatchEvent(new Event('scroll'));scroll.scrollTop=-30;scroll.dispatchEvent(new Event('scroll'));await tick();
  expect(sent.filter(m=>m.op==='history')).toHaveLength(1);
  scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(1);
  scroll.dispatchEvent(new Event('scrollend'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
 }finally{view.dispose();root.remove();}
});

it('keeps following latest while a short initial page is automatically filled with earlier history',async()=>{
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});view.setActive(true);view.showSession('saved');await tick();
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op)!;view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 try{
  await answer('hello',{joined:[],pending:[]});await answer('read',{thread:{id:'saved',status:{type:'notLoaded'}}});
  await answer('history',{data:[{id:'recent',items:[{id:'r',type:'agentMessage',text:'Latest'}]}],nextCursor:'page1'});await answer('models',{data:[]});
  const scroll=root.querySelector<HTMLElement>('[data-agent="scroll"]')!,content=root.querySelector<HTMLElement>('[data-agent="transcript"]')!;let top=0;
  Object.defineProperties(scroll,{clientHeight:{value:400},scrollHeight:{get:()=>Math.max(400,[...content.children].reduce((sum,node)=>sum+(node.classList.contains('agent-virtual-gap')?parseFloat((node as HTMLElement).style.height):100),0))},scrollTop:{get:()=>top,set:(value:number)=>{top=Math.max(0,Math.min(value,scroll.scrollHeight-400));}}});
  content.getBoundingClientRect=()=>({top:-top,width:600} as DOMRect);
  scroll.dispatchEvent(new Event('scroll'));await tick();expect(sent.filter(m=>m.op==='history')).toHaveLength(2);
  await answer('history',{data:[{id:'older',items:Array.from({length:20},(_,i)=>({id:'o'+i,type:'agentMessage',text:'Earlier '+i}))}],nextCursor:null});
  expect(scroll.scrollTop).toBe(scroll.scrollHeight-scroll.clientHeight);
  expect(root.querySelector<HTMLElement>('[data-agent="latest"]')!.hidden).toBe(true);
 }finally{view.dispose();root.remove();}
});
