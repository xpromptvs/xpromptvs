import {it,expect,vi} from 'vitest';
import {AgentsView} from '../src/client/agents/view';
const tick=async()=>{for(let i=0;i<40;i++)await Promise.resolve();};
async function fixture(shadow=false){
 const host=document.createElement('div'),root=document.createElement('div'),sent:any[]=[];document.body.append(host);
 (shadow?host.attachShadow({mode:'open'}):host).append(root);
 let view:AgentsView;
 view=new AgentsView({root,send:m=>{sent.push(m);queueMicrotask(()=>view.receive({t:'agent-response',id:m.id,epoch:'7',result:m.op==='hello'?{joined:['live'],pending:[]}:m.op==='read'?{thread:{id:'live',status:{type:'idle'}}}:m.op==='history'?{data:[]}:m.op==='models'?{data:[]}: {}}));}});
 view.setActive(true);view.showSession('live');await tick();
 return{host,root,sent,view,dispose(){view.dispose();host.remove();}};
}
it('opens mobile options using the existing settings controls and restores focus on close',async()=>{
 const f=await fixture(),{root,sent}=f;
 try{
  const toggle=root.querySelector<HTMLButtonElement>('[data-agent="options"]');expect(toggle).not.toBeNull();
  const model=root.querySelector('[data-agent="model"]');
  toggle!.click();expect(toggle!.getAttribute('aria-expanded')).toBe('true');
  expect(root.querySelector('[data-agent="options-panel"]')?.contains(model)).toBe(true);
  expect(root.querySelector<HTMLElement>('[data-agent="scroll"]')!.inert).toBe(true);
  const plan=root.querySelector<HTMLInputElement>('[data-agent="plan"]')!;plan.checked=true;plan.dispatchEvent(new Event('change'));await tick();
  expect(sent.some(m=>m.op==='settings'&&m.args.plan===true)).toBe(true);
  root.querySelector<HTMLButtonElement>('[data-agent="options-close"]')!.click();
  expect(toggle!.getAttribute('aria-expanded')).toBe('false');expect(document.activeElement).toBe(toggle);
  expect(root.querySelector<HTMLElement>('[data-agent="scroll"]')!.inert).toBe(false);
 }finally{f.dispose();}
});
it('traps focus in the containing shadow root',async()=>{
 const f=await fixture(true);try{
  f.root.querySelector<HTMLButtonElement>('[data-agent="options"]')!.click();
  const panel=f.root.querySelector('[data-agent="options-panel"]')!;
  for(const control of panel.querySelectorAll<HTMLElement>('button,input,select'))vi.spyOn(control,'getClientRects').mockReturnValue([new DOMRect()] as unknown as DOMRectList);
  const close=f.root.querySelector<HTMLButtonElement>('[data-agent="options-close"]')!;close.focus();
  const key=new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true});close.dispatchEvent(key);
  expect(key.defaultPrevented).toBe(true);
  expect((f.root.getRootNode() as ShadowRoot).activeElement).toBe(f.root.querySelector('[data-agent="options-attach"]'));
 }finally{f.dispose();}
});
it('opens the mobile model selector through /model and releases the sheet when a request arrives',async()=>{
 const f=await fixture();vi.stubGlobal('matchMedia',()=>({matches:true}));
 try{
  const message=f.root.querySelector<HTMLTextAreaElement>('[data-agent="message"]')!;message.value='/model';message.dispatchEvent(new Event('input'));
  f.root.querySelector<HTMLFormElement>('[data-agent="composer"]')!.requestSubmit();await tick();
  expect(f.root.querySelector('[data-agent="options"]')!.getAttribute('aria-expanded')).toBe('true');
  expect(document.activeElement).toBe(f.root.querySelector('[data-agent="model"]'));
  vi.useFakeTimers();f.view.notify({method:'xpromptvs/request',params:{key:'s:q',request:{id:'q',method:'item/tool/requestUserInput',params:{threadId:'live',questions:[{id:'q',header:'Layout',question:'Continue?',options:[]}]}}}});
  await vi.advanceTimersByTimeAsync(20);
  expect(f.root.querySelector('[data-agent="options"]')!.getAttribute('aria-expanded')).toBe('false');
  expect(f.root.querySelector<HTMLElement>('[data-agent="requests"]')!.inert).toBe(false);
 }finally{vi.useRealTimers();vi.unstubAllGlobals();f.dispose();}
});
