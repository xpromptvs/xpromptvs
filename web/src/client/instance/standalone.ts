import { attachBrowserFullscreen } from "../window-fullscreen";
import { onSmoothScrollChange, setSmoothScroll } from "../../shared/smooth-scroll-pref";
import { createClientMount } from './mount';
import { createInstanceController, type InstanceControllerAdapter } from './controller';
import type { ClientContext } from './context';
import type { PreferenceStore } from './types';
import { splitConnectSearch, type SessionController } from '../session-lifecycle';
import { shellScopedIdentity } from '../e2e-identity';
import { signalingBase, shellGrantIssuer, shellIdentity } from '../../lib/signaling-base';
import { workerFetch } from '../../lib/worker-fetch';
import { resumeId } from '../../lib/resume-id';
import { localPasteApi } from '../paste-local';
import { BellChrome, type BellShell } from '../term-bell';
import { installNativeChromeMetrics } from '../../shared/native-chrome';
import { installNativeWindowGrip } from '../native-window-grip';
import { shellstormMotion } from '../shellstorm-motion';
import { ViewportFit } from '../viewport-fit';
import type { ClientPlatform } from './platform';

/** Page effects belong exclusively to this adapter. The client below is the embedding runtime. */
export function mountStandaloneClient(container: HTMLElement, adapter: InstanceControllerAdapter) {
  const shell=(window as Window & {__rdevShell?: ClientPlatform['native'] & BellShell & Parameters<typeof localPasteApi>[0] & Parameters<typeof installNativeWindowGrip>[0]}).__rdevShell;
  const preferences: PreferenceStore={
    get(key){try{return localStorage.getItem(key);}catch{return null;}},
    set(key,value){try{localStorage.setItem(key,value);}catch{}},
    remove(key){try{localStorage.removeItem(key);}catch{}},
  };
  let context!:ClientContext,engine!:SessionController;
  const bell=new BellChrome(document,shell);
  const fullscreenListeners=new Set<()=>void>();
  let fullscreen: ReturnType<typeof attachBrowserFullscreen>;
  const mount=createClientMount((c,report)=>{
    context=c;
    fullscreen=attachBrowserFullscreen({signal:c.scope.signal,onLeft:()=>{for(const fn of fullscreenListeners)fn();}});
    c.scope.defer(()=>fullscreen.exit());
    let fromPage=false;
    c.scope.defer(onSmoothScrollChange(on=>{fromPage=true;try{c.smooth.set(on);}finally{fromPage=false;}}));
    c.scope.defer(c.smooth.subscribe(on=>{if(!fromPage)setSmoothScroll(on);}));
    installNativeChromeMetrics(c.ui);
    if(shell)c.ui.dataset.nativeClient='true';
    for(const side of ['top','right','bottom','left'])c.ui.style.setProperty(`--client-safe-${side}`,`env(safe-area-inset-${side})`);
    const controller=createInstanceController(c,report,{
      motion:shellstormMotion,sessionRoot:container,glassesNav:false,
      pin:()=>matchMedia('(pointer: coarse)').matches?new ViewportFit(document.body,c.ui).start():()=>{},
      resync:()=>{
        shellstormMotion()?.resync?.();
      },
      ...adapter,
      onState:detail=>{document.dispatchEvent(new CustomEvent('shellstorm:connection-state',{detail}));adapter.onState?.(detail);},
    });
    engine=controller.sessionController;
    c.scope.defer(installNativeWindowGrip(shell??{},c.root,c.ui));
    c.scope.defer(()=>bell.restore());
    return controller;
  },{resumeId:resumeId(),preferences,pageHistory:true,pairingCommitted(){
    if(location.hash.includes('pair='))history.replaceState(null,'',location.pathname+location.search);
  }});
  const handle=mount(container,{
    layout:new URLSearchParams(location.search).get('layout') as 'floating'|'tabbed'|'glasses'|undefined || undefined,
    remote:{identity:shellScopedIdentity(),signalingEndpoint:signalingBase(),fetch:workerFetch()},
    platform:{native:shell?{...shell,issueGrant:shellGrantIssuer()??undefined,identity:shellIdentity()??undefined}:undefined,
      requestFullscreen:async()=>fullscreen.enter(),exitFullscreen:()=>fullscreen.exit(),
      onFullscreenLeft:fn=>{fullscreenListeners.add(fn);return()=>{fullscreenListeners.delete(fn);};},
      localPaste:localPasteApi(shell),bell:count=>bell.show(count),reportError:error=>console.error('[client]',error)},
  });
  Object.defineProperty(window,'__rdevClientRoot',{configurable:true,value:context.root});
  Object.defineProperty(window,'__rdev',{configurable:true,get:()=>engine.current?.debug});
  // Existing page consumers keep their route API; all connects pass through the public lifetime handle.
  const controller:SessionController={
    connect(search){const target=splitConnectSearch(search);if(!target)return false;
      return handle.connect({kind:'remote',code:target.code,token:target.token,pairingCarrier:target.carrier??undefined,params:new URLSearchParams(location.search)});},
    connectTransport:transport=>handle.connect({kind:'transport',transport,params:new URLSearchParams(location.search)}),
    cancel:()=>handle.cancel(),disconnect:()=>handle.disconnect(),busy:()=>engine.busy(),
    get current(){return engine.current;},dispose:()=>handle.destroy(),
  };
  return {handle,controller,context};
}
