import { expect,it } from 'vitest';
import { parseWorkspaceFormat,parseAppsState } from '../src/client/source-picker';
import { windowViews } from '../src/client/window-manager';
import { controlOpenMessages } from '../src/client/session-control';
import { DEFAULT_CLIENT_PREFS } from '../src/shared/client-prefs';
const format={format:'workspace-rgb-alpha-hit-v1',logicalWidth:1280,logicalHeight:800,capturedWidth:1280,capturedHeight:800,codedWidth:3840,codedHeight:800,codec:'av1'};
it('refuses Apps activation while parked even when an old caller opts in',()=>{
 const messages=controlOpenMessages({appsPackedV1:true,intendedRecoveryBp:null,intendedPlayoutDelayMs:null,intendedPlayoutWindowMs:null,delivery:'rtp',termPalette:null,pageHidden:false,prefs:DEFAULT_CLIENT_PREFS});
 expect(messages).toContainEqual({t:'apps-capabilities',packedV1:false});
 expect(messages.some(m=>m.t==='apps-list')).toBe(false);
 expect(messages.at(-1)?.t).toBe('client-hello');
});
it('requires the full workspace descriptor and approved source kind',()=>{
 expect(parseWorkspaceFormat(format)).toEqual(format);expect(parseWorkspaceFormat({...format,codedWidth:1280})).toBeNull();
 const vs={windows:[{source:'apps:a',minimized:false}],subs:[{source:'apps:a',fps:60,scale:1,bitrateBps:8000000,presentation:format}],focused:'apps:a'};
 expect(windowViews(vs,[])[0]?.presentation).toBeUndefined();
 expect(windowViews({...vs,subs:[{...vs.subs[0]!,activeCodec:'h264'}]},[{id:'apps:a',kind:'application-workspace',name:'Apps',running:true,inputCapable:true}])[0]?.presentation).toBeUndefined();
 expect(windowViews(vs,[{id:'apps:a',kind:'application-workspace',name:'Apps',running:true,inputCapable:true}])[0]?.presentation).toEqual(format);
});
it('parses app inventory and failure state without guessing missing format',()=>{
 expect(parseAppsState({t:'apps-state',applications:[],members:[],availability:'disabled',format,recoveryCount:0})?.availability).toBe('disabled');
 expect(parseAppsState({t:'apps-state',applications:[],members:[],availability:'available',format:{}})).toBeNull();
});
it('states disabled packed capability before final hello and never for a windowless session',()=>{
 const intent={appsPackedV1:true,intendedRecoveryBp:null,intendedPlayoutDelayMs:null,intendedPlayoutWindowMs:null,delivery:'rtp' as const,termPalette:null,pageHidden:false,prefs:DEFAULT_CLIENT_PREFS};
 const messages=controlOpenMessages(intent);expect(messages.at(-1)?.t).toBe('client-hello');expect(messages).toContainEqual({t:'apps-capabilities',packedV1:false});expect(messages.at(-2)).toEqual({t:'apps-capabilities',packedV1:false});
 expect(controlOpenMessages({...intent,windowless:true}).some(x=>x.t==='apps-capabilities')).toBe(false);
});

import { paletteModel, type PaletteCtx } from '../src/client/command-palette';
it('shows cold journal failures and manual recovery even without members or inventory',()=>{
 const ctx:PaletteCtx={active:true,sources:[],subscribed:new Set(),focused:null,thumbs:new Map(),display:null,tmux:null,openTmux:new Set(),activeTmux:null,
  apps:parseAppsState({t:'apps-state',applications:[],members:[],availability:'failed',format,recoveryCount:2,error:'Unresolved workspace journal. Restore windows manually before archiving this journal.'})};
 const model=paletteModel(ctx,'');
 expect(model.notice?.title).toContain('Apps');
 expect(model.notice?.detail).toContain('Restore windows manually');
 expect(model.notice?.detail).toContain('2');
 expect(model.actions.some(a=>a.id.startsWith('apps-add:'))).toBe(false);
});
it('offers process-scoped app actions only to a driver, retains restore after a workspace failure',()=>{
 const ctx:PaletteCtx={active:true,sources:[],subscribed:new Set(),focused:null,thumbs:new Map(),display:null,tmux:null,openTmux:new Set(),activeTmux:null,
  apps:parseAppsState({t:'apps-state',applications:[{id:'new-process',name:'New app'},{id:'shared-process',name:'Shared app'}],members:[{app:{id:'shared-process',name:'Shared app'},phase:'shared'}],availability:'available',format,recoveryCount:0})};
 const actions=paletteModel(ctx,'').actions;
 expect(actions.find(a=>a.id==='apps-add:new-process')?.hint).toContain('After a host crash');
 expect(actions.some(a=>a.id==='apps-add:shared-process')).toBe(false);
 expect(actions.some(a=>a.id==='apps-remove:shared-process')).toBe(true);
 expect(actions.some(a=>a.id==='action:apps-restore-all')).toBe(true);
 expect(paletteModel({...ctx,active:false},'').actions.map(a=>a.id)).toEqual(['action:claim']);
 expect(paletteModel({...ctx,apps:{...ctx.apps!,availability:'failed'}},'').actions.some(a=>a.id.startsWith('apps-add:'))).toBe(false);
 expect(paletteModel({...ctx,apps:{...ctx.apps!,availability:'failed'}},'').actions.some(a=>a.id==='action:apps-restore-all')).toBe(true);
});
