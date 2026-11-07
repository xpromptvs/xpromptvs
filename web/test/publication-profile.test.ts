import {it,expect,vi} from 'vitest';
vi.mock('../src/shared/product-features',()=>({productFeatures:{graphicalAgents:false,glasses:false}}));
import {chooseLayoutMode} from '../src/client/layout-mode';
import {createPresentation} from '../src/client/instance/presentation';
import {paletteModel,type PaletteCtx} from '../src/client/command-palette';
const square={width:600,height:600,coarsePointer:false,screen:{width:600,height:600}};
it('publication cannot activate glasses through viewport detection or explicit override',()=>{
 expect(chooseLayoutMode(square,null)).toBe('floating');
 expect(chooseLayoutMode(square,'glasses')).toBe('floating');
 expect(chooseLayoutMode({...square,coarsePointer:true},'glasses')).toBe('tabbed');
});
it('direct embedded presentation cannot bypass disabled glasses',()=>{
 const root=document.createElement('div'),p=createPresentation(root,'glasses');
 expect(p.layout()).toBe('floating');p.setLayout('glasses');expect(p.layout()).toBe('floating');
});
it('publication palette refuses agent discovery even when caller advertises it',()=>{
 const ctx={active:true,sources:[],subscribed:new Set(),focused:null,thumbs:new Map(),tmux:[],openTmux:new Set(),agents:true,agentProviders:['claude'],agentSessions:[{id:'agent-session',name:'Private agent'}]} as unknown as PaletteCtx;
 expect(paletteModel(ctx,'').actions.some(a=>a.id.startsWith('agent:')||a.id==='action:new-claude')).toBe(false);
});
it('unsupported remote agent state renders a terminal without mutating host state',async()=>{
 const {supportedViewSet}=await import('../src/client/product-state');
 const state={subs:[],focused:null,windows:[],view:{surface:'agents'},version:3,agents:[{id:'a',title:'Agent',cwd:'/tmp'}],selectedAgent:'a',tabOrder:['pty:1','agent:a','pty:2']} as any;
 const next=supportedViewSet(state);
 expect(next.view.surface).toBe('terminal');expect(next.agents).toEqual([]);expect(next.selectedAgent).toBeNull();expect(next.tabOrder).toEqual(['pty:1','pty:2']);
 expect(state.agents).toHaveLength(1);expect(state.view.surface).toBe('agents');
});
