import {it,expect,vi} from 'vitest';
import {AgentsView} from '../src/client/agents/view';
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve()};
it('loads Claude models after explicit saved resume and recovers when its process exits',async()=>{
 const root=document.createElement('div');document.body.append(root);const id='claude:00000000-0000-4000-8000-000000000001';let joined=false;
 const call=vi.fn(async(op:string)=>{
  if(op==='hello')return{joined:joined?[id]:[],pending:[]};
  if(op==='read'||op==='resume'){if(op==='resume')joined=true;return{thread:{id,name:'Claude session',status:{type:joined?'idle':'notLoaded'},capabilities:{attachments:false,steer:false}}}};
  if(op==='history'||op==='children')return{data:[]};
  if(op==='models')return{data:joined?[{model:'sonnet',displayName:'Sonnet',supportedReasoningEfforts:[]}]:[]};return{};
 });
 const view=new AgentsView({root,persistent:true,send:()=>{},wire:{epoch:'1',call,reset(){}} as any});
 try{
  view.setActive(true);view.showSession(id);await tick();
  const model=root.querySelector<HTMLSelectElement>('[data-agent="model"]')!;expect(model.options).toHaveLength(1);
  root.querySelector<HTMLButtonElement>('[data-agent="join"]')!.click();await tick();
  expect([...model.options].some(o=>o.value==='sonnet')).toBe(true);
  expect(root.querySelector<HTMLButtonElement>('[data-agent="attach"]')!.disabled).toBe(true);
  view.notify({method:'thread/status/changed',params:{threadId:id,status:{type:'notLoaded'}}});await tick();
  expect(root.querySelector<HTMLButtonElement>('[data-agent="send"]')!.disabled).toBe(true);
  expect(root.querySelector<HTMLButtonElement>('[data-agent="join"]')!.hidden).toBe(false);
  expect(root.querySelector('[data-agent="join"]')!.textContent).toBe('Resume');
 }finally{view.dispose();root.remove()}
});
