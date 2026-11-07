import {it,expect,vi} from 'vitest';
import {AgentsView} from '../src/client/agents/view';
const tick=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
it('sends on Enter while Shift Enter and IME composition keep editing',async()=>{
 const root=document.createElement('div'),view=new AgentsView({root,send:()=>{}});
 const composer=root.querySelector<HTMLFormElement>('[data-agent="composer"]')!;
 const submit=vi.spyOn(composer,'requestSubmit').mockImplementation(()=>{});
 const message=root.querySelector<HTMLTextAreaElement>('[data-agent="message"]')!;
 try{
  for(const options of [{shiftKey:true},{isComposing:true}]){
   const key=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true,...options});
   message.dispatchEvent(key);expect(key.defaultPrevented).toBe(false);
  }
  expect(submit).not.toHaveBeenCalled();
  const enter=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true});message.dispatchEvent(enter);
  expect(enter.defaultPrevented).toBe(true);expect(submit).toHaveBeenCalledTimes(1);
 }finally{view.dispose();}
});
it('uses one exploration presentation for replay and live updates and preserves open output',async()=>{
 vi.useFakeTimers();const root=document.createElement('div'),button=document.createElement('button'),sent:any[]=[];document.body.append(root,button);
 const view=new AgentsView({root,button,send:m=>sent.push(m)});
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op);expect(m).toBeTruthy();view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 const read=(id:string)=>({id,type:'commandExecution',command:'cat '+id,commandActions:[{type:'read',name:id}],status:'completed',exitCode:0,aggregatedOutput:'one\ntwo\nthree\nfour'});
 try{
  view.setActive(true);view.open();await tick();await answer('hello',{joined:[],pending:[]});await answer('list',{data:[{id:'s',name:'Session',status:{type:'active'}}]});(root.querySelector('[data-thread="s"]')as HTMLElement).click();await tick();await answer('read',{thread:{id:'s',status:{type:'active'}}});await answer('history',{data:[{id:'t',status:'inProgress',items:[read('one'),read('two')]}]});
  expect(root.querySelectorAll('.agent-transcript > .agent-exploration')).toHaveLength(1);
  const group=root.querySelector<HTMLDetailsElement>('[data-disclosure="explore:one:activity"]')!;group.open=true;const output=root.querySelector<HTMLDetailsElement>('[data-disclosure="one:output"]')!;output.open=true;
  const focused=group.querySelector('summary')!;focused.focus();expect(document.activeElement).toBe(focused);
  view.receive({t:'agent-event',epoch:'7',event:{method:'item/completed',params:{threadId:'s',turnId:'t',item:read('three')}}});await vi.advanceTimersByTimeAsync(20);
  expect(root.querySelectorAll('.agent-transcript > .agent-exploration')).toHaveLength(1);expect(root.querySelector<HTMLDetailsElement>('[data-disclosure="explore:one:activity"]')?.open).toBe(true);expect(root.querySelector<HTMLDetailsElement>('[data-disclosure="one:output"]')?.open).toBe(true);
  expect(document.activeElement).toBe(root.querySelector('[data-disclosure="explore:one:activity"] > summary'));
  const selected=root.querySelector('.agent-exploration-preview')!,range=document.createRange();range.selectNodeContents(selected);document.getSelection()!.removeAllRanges();document.getSelection()!.addRange(range);expect(document.getSelection()!.isCollapsed).toBe(false);
  view.receive({t:'agent-event',epoch:'7',event:{method:'item/completed',params:{threadId:'s',turnId:'t',item:read('four')}}});await vi.advanceTimersByTimeAsync(20);
  expect(selected.isConnected).toBe(false);expect(root.querySelector('.agent-exploration-preview')?.textContent).toContain('Read four');
  document.getSelection()!.removeAllRanges();

 }finally{view.dispose();root.remove();button.remove();vi.useRealTimers();}
});

it('shows CLI Working status for a live turn and stops for waits, completion and disconnect',async()=>{
 vi.useFakeTimers();const root=document.createElement('div'),sent:any[]=[];
 const view=new AgentsView({root,send:m=>sent.push(m)});
 const answer=async(op:string,result:any)=>{const m=[...sent].reverse().find(m=>m.op===op);expect(m).toBeTruthy();view.receive({t:'agent-response',id:m.id,epoch:'7',result});await tick();};
 const event=async(method:string,params:any)=>{view.receive({t:'agent-event',epoch:'7',event:{method,params:{threadId:'live',...params}}});await vi.advanceTimersByTimeAsync(20);};
 try{
  view.setActive(true);view.showSession('live');await tick();await answer('hello',{joined:['live'],pending:[]});await answer('read',{thread:{id:'live',status:{type:'active',activeFlags:[]}}});await answer('history',{data:[{id:'t',status:'inProgress',items:[]}]});await answer('hello',{joined:['live'],pending:[]});await answer('models',{data:[]});
  const status=root.querySelector<HTMLElement>('[data-agent="working"]');expect(status).not.toBeNull();expect(status!.textContent).toContain('Working…');expect(status!.hidden).toBe(false);
  await event('thread/status/changed',{status:{type:'active',activeFlags:['waitingOnApproval']}});expect(status!.hidden).toBe(true);
  await event('thread/status/changed',{status:{type:'active',activeFlags:['waitingOnUserInput']}});expect(status!.hidden).toBe(true);
  await event('thread/status/changed',{status:{type:'active',activeFlags:[]}});expect(status!.hidden).toBe(false);
  await event('turn/completed',{turn:{id:'t',status:'completed',items:[]}});expect(status!.hidden).toBe(true);
  await event('turn/started',{turn:{id:'next',status:'inProgress'}});expect(status!.hidden).toBe(false);
  await event('xpromptvs/disconnected',{});expect(status!.hidden).toBe(true);
 }finally{view.dispose();vi.useRealTimers();}
});
