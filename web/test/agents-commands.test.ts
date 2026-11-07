import {it,expect} from 'vitest';
import {AgentsView} from '../src/client/agents/view';
const tick=async()=>{for(let i=0;i<16;i++)await Promise.resolve();};
it('discovers and executes goal controls without sending a prompt',async()=>{
 const f=await fixture();try{
  const current={objective:'Finish the feature',status:'active',tokensUsed:120,tokenBudget:1000};
  await f.answer('goal',{goal:current});expect(f.root.querySelector('[data-agent="goal"]')?.textContent).toContain('Finish the feature');
  f.input('/go');expect(f.root.querySelector('[data-agent="commands"]')?.textContent).toContain('/goal');
  f.input('/goal pause');await f.submit();await f.answer('goal',{goal:current});
  expect(f.sent.at(-1)).toMatchObject({op:'goal-set',thread:'live',args:{status:'paused'}});
  await f.answer('goal-set',{goal:{...current,status:'paused'}});expect(f.message.value).toBe('');expect(f.root.querySelector('[data-agent="goal"]')?.textContent).toContain('Paused');
  f.input('/goal Ship this\nwith checks');await f.submit();await f.answer('goal',{goal:{...current,status:'paused'}});
  expect(f.sent.at(-1)).toMatchObject({op:'goal-set',args:{objective:'Ship this\nwith checks',status:'active'}});
  expect(f.sent.at(-1).args.tokenBudget).toBeUndefined();await f.answer('goal-set',{goal:{objective:'Ship this\nwith checks',status:'active'}});
  expect(f.sent.some(m=>m.op==='send'||m.op==='steer')).toBe(false);
 }finally{f.dispose();}
});
it('does not resurrect a goal from a snapshot arriving after a live clear',async()=>{
 const f=await fixture();try{
  f.view.notify({method:'thread/goal/cleared',params:{threadId:'live'}});
  await f.answer('goal',{goal:{objective:'Old goal',status:'active'}});
  expect(f.root.querySelector<HTMLElement>('[data-agent="goal"]')!.hidden).toBe(true);expect(f.root.textContent).not.toContain('Old goal');
 }finally{f.dispose();}
});
it('does not apply an awaited goal command to a different selected session',async()=>{
 const f=await fixture();try{
  const old=f.sent.find(m=>m.op==='goal');f.input('/goal Keep original target');await f.submit();
  f.view.showSession('other');await tick();await f.answer('hello',{joined:['live','other'],pending:[]});
  await f.answer('read',{thread:{id:'other',status:{type:'idle'}}});await f.answer('history',{data:[]});
  f.view.receive({t:'agent-response',id:old.id,epoch:'7',result:{goal:null}});await tick();
  expect(f.sent.some(m=>m.op==='goal-set')).toBe(false);
 }finally{f.dispose();}
});
async function fixture(busy=false){
 const root=document.createElement('div'),sent:any[]=[];document.body.append(root);
 const view=new AgentsView({root,send:m=>sent.push(m)});
 const answer=async(op:string,result:any,error?:string)=>{const m=[...sent].reverse().find(m=>m.op===op);expect(m).toBeTruthy();view.receive({t:'agent-response',id:m.id,epoch:'7',result,error});await tick();};
 view.setActive(true);view.showSession('live');await tick();
 await answer('hello',{joined:['live'],pending:[]});
 await answer('read',{thread:{id:'live',status:{type:busy?'active':'idle'}}});
 await answer('history',{data:busy?[{id:'turn',status:'inProgress',items:[]}]:[]});
 await answer('hello',{joined:['live'],pending:[]});await answer('models',{data:[]});
 const message=root.querySelector<HTMLTextAreaElement>('[data-agent="message"]')!;
 const input=(value:string)=>{message.value=value;message.dispatchEvent(new Event('input'));};
 const submit=async()=>{root.querySelector<HTMLFormElement>('[data-agent="composer"]')!.requestSubmit();await tick();};
 return{root,sent,view,answer,message,input,submit,dispose(){view.dispose();root.remove();}};
}
it('discovers slash commands, selects with Tab, and compacts through the host operation',async()=>{
 const f=await fixture();try{
  f.input('/co');const menu=f.root.querySelector<HTMLElement>('[data-agent="commands"]')!;
  expect(menu).not.toBeNull();expect(menu.hidden).toBe(false);expect(menu.textContent).toContain('/compact');expect(menu.textContent).not.toContain('/model');
  f.message.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));expect(f.message.value).toBe('/compact');
  await f.submit();expect(f.sent.at(-1)).toMatchObject({op:'compact',thread:'live',args:{}});expect(f.sent.some(m=>m.op==='send'||m.op==='steer')).toBe(false);
  f.input('new draft');await f.answer('compact',{});expect(f.message.value).toBe('new draft');
 }finally{f.dispose();}
});
it('retains failed and unknown commands without sending them as prompts',async()=>{
 const f=await fixture();try{
  f.input('/compact');await f.submit();await f.answer('compact',{},'Compaction failed');expect(f.message.value).toBe('/compact');
  f.input('/unknown');await f.submit();expect(f.message.value).toBe('/unknown');expect(f.root.querySelector('[data-agent="notice"]')?.textContent).toContain('Unknown command');
  f.input('/compact extra');await f.submit();expect(f.message.value).toBe('/compact extra');
  expect(f.sent.filter(m=>m.op==='compact')).toHaveLength(1);expect(f.sent.some(m=>m.op==='send'||m.op==='steer')).toBe(false);
 }finally{f.dispose();}
});
it('refuses compact during a turn and provides help and existing model and plan controls',async()=>{
 const f=await fixture(true);try{
  f.input('/compact');await f.submit();expect(f.sent.some(m=>m.op==='compact')).toBe(false);expect(f.message.value).toBe('/compact');
  f.input('/help');await f.submit();expect(f.root.querySelector('[data-agent="notice"]')?.textContent).toContain('/status');expect(f.message.value).toBe('');
  f.input('/model');await f.submit();expect(document.activeElement).toBe(f.root.querySelector('[data-agent="model"]'));
  f.input('/plan');await f.submit();expect(f.sent.at(-1)).toMatchObject({op:'settings',thread:'live',args:{plan:true}});await f.answer('settings',{});expect(f.message.value).toBe('');
 }finally{f.dispose();}
});
it('opens session details with status without starting a turn',async()=>{
 const f=await fixture();try{
  f.input('/status');await f.submit();expect(f.root.querySelector<HTMLElement>('[data-agent="details-panel"]')!.hidden).toBe(false);
  await f.answer('goal',{});await f.answer('queue-list',{data:[]});await f.answer('limits',{});
  expect(f.message.value).toBe('');expect(f.sent.some(m=>m.op==='send')).toBe(false);
 }finally{f.dispose();}
});
it('discards stale command suggestions when a shared view selects another session',async()=>{
 const f=await fixture();try{
  f.input('/co');expect(f.root.querySelector<HTMLElement>('[data-agent="commands"]')!.hidden).toBe(false);
  f.view.showSession('other');await tick();await f.answer('hello',{joined:['live','other'],pending:[]});
  expect(f.message.value).toBe('');expect(f.root.querySelector<HTMLElement>('[data-agent="commands"]')!.hidden).toBe(true);
 }finally{f.dispose();}
});

it.each([['send',false,false],['steer',true,false],['queue',true,false],['send',false,true]] as const)('synchronously follows the tail when submitting %s (busy=%s, attachment=%s)',async(op,busy,attachment)=>{
 const f=await fixture(busy);try{
  const scroll=f.root.querySelector<HTMLElement>('[data-agent="scroll"]')!,transcript=f.root.querySelector<HTMLElement>('[data-agent="transcript"]')!;
  Object.defineProperty(scroll,'clientHeight',{value:400});Object.defineProperty(scroll,'scrollHeight',{value:2000});
  transcript.getBoundingClientRect=()=>({top:-scroll.scrollTop,width:600} as DOMRect);
  if(attachment){const file=f.root.querySelector<HTMLInputElement>('[data-agent="file"]')!;Object.defineProperty(file,'files',{value:[new File(['attached'],'note.txt',{type:'text/plain'})]});file.dispatchEvent(new Event('change'));}
  f.input(attachment?'':'A real message');f.root.querySelector<HTMLSelectElement>('[data-agent="delivery"]')!.value=op==='send'?'steer':op;
  scroll.scrollTop=100;scroll.dispatchEvent(new Event('scroll'));expect(f.root.querySelector<HTMLElement>('[data-agent="latest"]')!.hidden).toBe(false);
  f.root.querySelector<HTMLFormElement>('[data-agent="composer"]')!.requestSubmit();
  // No microtask, timer, upload response or host acknowledgement is allowed before this assertion.
  expect(scroll.scrollTop).toBe(1600);expect(f.root.querySelector<HTMLElement>('[data-agent="latest"]')!.hidden).toBe(true);
  expect(f.sent.some(m=>m.op===op)).toBe(false);
  await tick();
  if(!attachment){scroll.scrollTop=100;scroll.dispatchEvent(new Event('scroll'));await f.answer(op,{});expect(scroll.scrollTop).toBe(100);}
 }finally{f.dispose();}
});
it.each(['   ','/plan'])('does not jump the transcript for an empty draft or a local slash action: %s',async text=>{
 const f=await fixture();try{
  const scroll=f.root.querySelector<HTMLElement>('[data-agent="scroll"]')!;Object.defineProperty(scroll,'clientHeight',{value:400});Object.defineProperty(scroll,'scrollHeight',{value:2000});
  f.input(text);scroll.scrollTop=100;scroll.dispatchEvent(new Event('scroll'));
  f.root.querySelector<HTMLFormElement>('[data-agent="composer"]')!.requestSubmit();expect(scroll.scrollTop).toBe(100);
 }finally{f.dispose();}
});
