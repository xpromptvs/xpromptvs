import { afterEach, describe, expect, it, vi } from 'vitest';
import { NativeSourceWindows } from '../src/client/native-source/owner';
import type { NativeSourceWindowAPI, NativeSourceEvent } from '../src/client/native-source/api';
import type { SourceWindowController } from '../src/client/native-source/types';
import type { ViewSetMsg } from '../src/client/source-picker';
const cleanups:(()=>void)[]=[];
afterEach(()=>{for(const cleanup of cleanups.splice(0).reverse())cleanup();});
function setup() {
  let event:(event:NativeSourceEvent)=>void=()=>{};let incarnation=0;
  const endpoint={connect:vi.fn<SourceWindowController['connect']>(()=>true),update:vi.fn<SourceWindowController['update']>(),dispose:vi.fn(),video:vi.fn(),action:vi.fn(()=>true),autoDebug:()=>({}),viewDebug:()=>({}),pacerStats:()=>({}),releaseInput:vi.fn()} satisfies SourceWindowController;
  const api:NativeSourceWindowAPI={
    nativeSourceWindowsInfo:vi.fn(async()=>({supported:true,generation:1,revision:0,visible:true,keyWindow:false})),
    syncSourceWindows:vi.fn(async value=>({supported:true,generation:value.generation,revision:value.revision,visible:true,keyWindow:false})),
    prepareSourceWindow:vi.fn(async(source,generation)=>({ticket:'fixture',url:'app://client/source-window.html?ticket=fixture',key:{owner:11,generation,source,incarnation:++incarnation}})),
    resetSourceWindows:vi.fn(async()=>({supported:true,generation:2,revision:0,visible:true,keyWindow:false})),
    sourceWindowCommand:vi.fn(async()=>true),onSourceWindowEvent(cb){event=cb;return()=>{event=()=>{};};},
  };
  const container=document.body.appendChild(document.createElement('div'));
  const focus=vi.fn(), input=vi.fn(), resize=vi.fn();
  const manager=new NativeSourceWindows(container,{onResize:resize,onFocus:focus,onClose(){},onMinimize(){},onPrefs(){},onRecovery(){},onPlayoutDelay(){},inputChannel:Object.assign(new EventTarget(),{label:'input',readyState:'open',binaryType:'arraybuffer',send(){}}) as never,pc:()=>null,nowMs:()=>0},api,
    {input,focus:vi.fn(),restore:vi.fn(),open:()=>({__rdevSourceController:endpoint} as unknown as Window)});
  cleanups.push(()=>{manager.clear();container.remove();});
  const state:ViewSetMsg={windows:[{source:'win:1',minimized:false},{source:'sim:abc',minimized:true}],subs:[],focused:'win:1',view:{surface:'windows',fullscreen:null},version:1,tabOrder:[]};
  return{manager,api,endpoint,container,focus,input,resize,state,event:(value:NativeSourceEvent)=>event(value)};
}
describe('native owner presentation backend',()=>{
  it('retires an unready document and retries instead of leaving a dead tab forever',async()=>{
    vi.useFakeTimers();
    try {
      const t=setup();
      t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
      await vi.advanceTimersByTimeAsync(0);
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(5001);
      expect(t.api.sourceWindowCommand).toHaveBeenCalledWith(expect.objectContaining({source:'win:1',incarnation:1}),'close');
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(2);
      t.manager.clear();
      const calls=vi.mocked(t.api.prepareSourceWindow).mock.calls.length;
      await vi.advanceTimersByTimeAsync(30000);
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(calls);
    } finally {vi.useRealTimers();}
  });
  it('retries a ready notification with no usable controller',async()=>{
    const t=setup();
    t.endpoint.connect.mockReturnValueOnce(false);
    t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(1));
    t.event({type:'ready',key:{owner:11,generation:1,source:'win:1',incarnation:1}});
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(2));
  });
  it('bounds readiness retries and lets a later tab activation try again',async()=>{
    vi.useFakeTimers();
    try {
      const t=setup();t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
      await vi.advanceTimersByTimeAsync(30000);
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(4);
      t.manager.activate('win:1');await vi.advanceTimersByTimeAsync(0);
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(5);
      t.event({type:'ready',key:{owner:11,generation:1,source:'win:1',incarnation:5}});
      await vi.advanceTimersByTimeAsync(30000);
      expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(5);
    } finally {vi.useRealTimers();}
  });
  it('confirms an unchanged remote size after a refused native resize, once',async()=>{
    const t=setup();t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
    t.manager.sync([{source:'win:1',name:'Editor',focused:true,fps:60,scale:1,bitrateBps:1}],new Map());
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(1));
    const key={owner:11,generation:1,source:'win:1',incarnation:1};t.event({type:'ready',key});
    t.manager.setSourceSize('win:1',400,300);vi.mocked(t.api.sourceWindowCommand).mockClear();
    t.event({type:'action',key,name:'resize',width:740,height:540});
    expect(t.resize).toHaveBeenCalledWith('win:1',740,540);
    t.manager.setSourceSize('win:1',400,300);
    expect(t.api.sourceWindowCommand).toHaveBeenCalledWith(key,'confirmSize',{width:400,height:300});
    vi.mocked(t.api.sourceWindowCommand).mockClear();t.manager.setSourceSize('win:1',400,300);
    expect(t.api.sourceWindowCommand).not.toHaveBeenCalled();
  });
  it('sends full membership and creates no parent media elements',async()=>{
    const t=setup();t.manager.setSessionState(t.state,[],true,'dark',true);
    t.manager.sync([{source:'win:1',name:'Editor',focused:true,fps:60,scale:1,bitrateBps:2000000}],new Map());
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(2));
    expect(t.container.querySelector('video')).toBe(null);
    expect(t.api.syncSourceWindows).toHaveBeenLastCalledWith(expect.objectContaining({sources:expect.arrayContaining([expect.objectContaining({source:'sim:abc',minimized:true})])}));
    expect(t.focus).not.toHaveBeenCalled();expect(t.endpoint.connect).not.toHaveBeenCalled();
  });
  it('coalesces track updates until ready and refuses callbacks after retirement',async()=>{
    const t=setup();t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
    const view={source:'win:1',name:'Editor',focused:true,fps:60,scale:1,bitrateBps:2000000};
    const first={} as MediaStream, latest={} as MediaStream;
    t.manager.sync([view],new Map([['win:1',first]]));
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(1));
    t.manager.sync([view],new Map([['win:1',latest]]));
    const key={owner:11,generation:1,source:'win:1',incarnation:1};
    t.event({type:'ready',key});
    expect(t.endpoint.connect).toHaveBeenCalledTimes(1);
    expect(t.endpoint.update.mock.lastCall?.[0].stream).toBe(latest);
    const connection=t.endpoint.connect.mock.lastCall?.[0];
    t.manager.setSessionState({...t.state,windows:[],focused:null},[],true,'dark',true);
    expect(connection?.current()).toBe(false);
    connection?.sendInput('old');expect(t.input).not.toHaveBeenCalled();
    t.event({type:'ready',key});expect(t.endpoint.connect).toHaveBeenCalledTimes(1);
    expect(t.endpoint.dispose).toHaveBeenCalledTimes(1);
  });
  it('retiring a generation closes its endpoints and never falls back to owner input',async()=>{
    const t=setup();t.manager.setSessionState({...t.state,windows:t.state.windows.slice(0,1)},[],true,'dark',true);
    t.manager.sync([{source:'win:1',name:'Editor',focused:true,fps:60,scale:1,bitrateBps:1}],new Map());
    await vi.waitFor(()=>expect(t.api.prepareSourceWindow).toHaveBeenCalledTimes(1));
    const key={owner:11,generation:1,source:'win:1',incarnation:1};t.event({type:'ready',key});
    const connection=t.endpoint.connect.mock.lastCall?.[0];
    t.event({type:'reset',generation:2,reason:'handoff'});
    expect(connection?.current()).toBe(false);expect(t.endpoint.dispose).toHaveBeenCalledOnce();
    t.event({type:'key',key,keyWindow:true});connection?.sendInput('stale');
    expect(t.input).not.toHaveBeenCalled();
  });
});
