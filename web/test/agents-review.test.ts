import {it,expect} from "vitest";
import {AgentsView} from "../src/client/agents/view";
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
function fixture(){
 const root=document.createElement("div"),button=document.createElement("button"),sent:any[]=[],joined=new Set<string>();document.body.append(root,button);
 let historyText="initial",holdDetails=false;const held:any[]=[];
 const rows=[{id:"a",name:"A",cwd:"/a",status:{type:"idle"},model:"model-a"},{id:"b",name:"B",cwd:"/b",status:{type:"idle"},model:"model-b"}];
 const view=new AgentsView({root,button,send:m=>{sent.push(m);if(holdDetails&&["goal","queue-list","limits"].includes(m.op)){held.push(m);return;}let result:any={};
  switch(m.op){case"hello":result={available:true,joined:[...joined],pending:[]};break;case"list":result={data:rows};break;case"read":result={thread:rows.find(r=>r.id===m.thread)};break;case"history":result={data:[{id:"turn",status:"completed",items:[{id:"message",type:"agentMessage",text:historyText}]}]};break;case"join":joined.add(m.thread);result={thread:rows.find(r=>r.id===m.thread),model:`model-${m.thread}`,collaborationMode:{mode:m.thread==="a"?"plan":"default",settings:{model:`model-${m.thread}`,reasoning_effort:"medium"}}};break;case"models":result={data:[{model:"model-a",supportedReasoningEfforts:[]},{model:"model-b",supportedReasoningEfforts:[]}]};break;}
  queueMicrotask(()=>view.receive({t:"agent-response",id:m.id,epoch:"7",result}));
 }});view.setActive(true);view.open();
 const click=(s:string)=>(root.querySelector(s) as HTMLButtonElement).click();
 return{root,view,sent,click,held,setText:(s:string)=>historyText=s,holdDetails:()=>holdDetails=true,select:async(id:string)=>{await tick();click(`[data-thread="${id}"]`);await tick();},join:async()=>{click('[data-action="join"]');await tick();},dispose:()=>{view.dispose();root.remove();button.remove();}};
}
it("refresh reloads selected history and reopening paints work received while hidden",async()=>{
 const f=fixture();try{await f.select("a");await f.join();f.view.hide();f.setText("finished while hidden");f.view.open();await tick();expect(f.root.querySelector('.agent-transcript')!.textContent).toContain("finished while hidden");expect(f.sent.filter(m=>m.op==="history").length).toBeGreaterThan(2);}finally{f.dispose();}
});
it("untouched composer preserves mode and changing sessions resets model/effort controls",async()=>{
 const f=fixture();try{await f.select("a");await f.join();const model=f.root.querySelector('[data-agent="model"]')as HTMLSelectElement;model.value="model-a";model.dispatchEvent(new Event("change"));await tick();await f.select("b");await f.join();expect(model.value).not.toBe("model-a");const input=f.root.querySelector('[data-agent="message"]')as HTMLTextAreaElement;input.value="continue";(f.root.querySelector('[data-agent="composer"]')as HTMLFormElement).requestSubmit();await tick();const sent=[...f.sent].reverse().find(m=>m.op==="send");expect(sent.args.plan).toBeUndefined();expect(sent.args.model).toBeUndefined();expect(sent.args.effort).toBeUndefined();}finally{f.dispose();}
});
it("switching sessions closes and fences old details actions and late responses",async()=>{
 const f=fixture();try{await f.select("a");await f.join();f.holdDetails();f.click('[data-agent="details"]');await tick();await f.select("b");const panel=f.root.querySelector('[data-agent="details-panel"]')as HTMLElement;expect(panel.hidden).toBe(true);for(const m of f.held)f.view.receive({t:"agent-response",id:m.id,epoch:"7",result:{goal:{objective:"old"}}});await tick();expect(panel.childElementCount).toBe(0);expect(f.sent.filter(m=>m.op==="goal-set")).toHaveLength(0);}finally{f.dispose();}
});
it("shows structured approval choices and sends the exact supplied rule",async()=>{
 const f=fixture();try{await f.select("a");await f.join();const decision={acceptWithExecpolicyAmendment:{execpolicy_amendment:["echo"]}};f.view.receive({t:"agent-event",epoch:"7",event:{method:"xpromptvs/request",params:{key:"7",request:{id:7,method:"item/commandExecution/requestApproval",params:{threadId:"a",availableDecisions:[decision,"decline"],command:"echo check"}}}}});await new Promise(r=>setTimeout(r,30));const button=[...f.root.querySelectorAll<HTMLButtonElement>('.agent-request button')].find(b=>b.textContent==='Allow and save command rule');expect(button).toBeTruthy();button!.click();await tick();expect(f.sent.find(m=>m.op==='answer')?.args.result).toEqual({decision});}finally{f.dispose();}
});
