import { WindowManager, windowViews, type WindowManagerOptions, type WindowView } from '../window-manager';
import type { SourceFocusState } from './focus';
import { audioBadge } from '../audio';
import { contextFor } from '../instance/context';
import type { Source, ViewSetMsg, SimStateWire } from '../source-picker';
import { SourceWindowSnapshots } from './snapshots';
import { nativeSourceManifest } from './manifest';
import type { NativeSourceWindowAPI, NativeSourceEvent } from './api';
import { sameSourceWindowKey, validSourceWindowKey, type SourceWindowKey, type SourceWindowController,
  type SourceWindowSnapshot, type SourceWindowAction, type SourceWindowConnection } from './types';

interface Entry { key: SourceWindowKey; popup?: Window; ready: boolean; nativeKey: boolean; visible: boolean; minimized: boolean; readyTimer?: ReturnType<typeof setTimeout> }
export interface NativeSourceOwnerHooks {
  input(key: SourceWindowKey, data: string | ArrayBuffer | ArrayBufferView): void;
  focus(key: SourceWindowKey | null): void;
  restore(source: string): void;
  retired?(key: SourceWindowKey): void;
  visibilityChanged?(owner: boolean, children: readonly {key:SourceWindowKey;visible:boolean;minimized:boolean}[]): void;
  presentationChanged?(): void;
  paste?: SourceWindowConnection['paste'];
  open?(url: string): Window | null;
  error?(error: unknown): void;
}
/** State-only owner. Never call super.sync: every media element belongs to its presenting child. */
export class NativeSourceWindows extends WindowManager {
  private readonly entries = new Map<string, Entry>();
  private snapshots?: SourceWindowSnapshots<SourceWindowSnapshot>;
  private generation = 0;
  private revision = 0;
  private running = false;
  private dirty = false;
  private ended = false;
  private ownerVisible = false;
  private sourceState?: {state:ViewSetMsg;sources:readonly Source[];driving:boolean;theme:'dark'|'light';smooth:boolean};
  private sourceViews = new Map<string, WindowView>();
  private sourceStreams = new Map<string, MediaStream>();
  private readonly pendingResizes = new Set<string>();
  private readonly logical = new Map<string,{w:number;h:number}>();
  private readonly pixels = new Map<string,{w:number;h:number}>();
  private sourceLive = new Map<string,boolean>();
  private sourceSimStates = new Map<string,SimStateWire>();
  private readonly inputStates=new Map<string,SourceFocusState>();
  private defaultInputState?: SourceFocusState;
  private sourceCursor?: SourceWindowSnapshot['cursor'];
  private sourceRecovery?: number | null;
  private sourcePlayout?: number | null;
  private sourceCurtain?: boolean | null;
  private nativeFullscreen: string | null = null;
  private pendingActivation?: string;
  private landing?: {source:string;land:boolean};
  private readonly failures=new Map<string,number>();
  private readonly suppressed = new Set<string>();
  private readonly off: () => void;
  constructor(container: HTMLElement, private readonly nativeOptions: WindowManagerOptions,
    private readonly api: NativeSourceWindowAPI, private readonly hooks: NativeSourceOwnerHooks) {
    super(container, nativeOptions);
    this.ownerElement = container;
    this.off = api.onSourceWindowEvent(event => this.event(event));
  }
  setSessionState(state: ViewSetMsg, sources: readonly Source[], driving: boolean, theme: 'dark'|'light', smooth: boolean): void {
    if (this.ended) return;
    this.sourceState = {state,sources,driving,theme,smooth};
    const wanted = new Set(state.windows.map(w=>w.source));
    for (const source of this.suppressed) if (!wanted.has(source)) this.suppressed.delete(source);
    // Invalidate before asynchronous native sync or child disposal can produce a callback.
    for (const entry of [...this.entries.values()]) if (!driving || !wanted.has(entry.key.source)) this.retire(entry);
    this.changed();
  }
  override sync(views: WindowView[], streams: Map<string,MediaStream>, _keysTo?: (typing:boolean)=>void): void {
    this.sourceViews = new Map(views.map(view=>[view.source,view])); this.sourceStreams = new Map(streams);
    this.changed();
  }
  private changed(): void {
    if (this.ended) return;
    this.revision++; this.publish(); this.dirty = true;
    if (!this.running) void this.reconcile();
  }
  private async reconcile(): Promise<void> {
    this.running = true;
    try {
      if (!this.generation) {
        const info = await this.api.nativeSourceWindowsInfo();
        if (this.ended) return;
        if (!info.supported || !Number.isSafeInteger(info.generation) || info.generation < 1) throw Error('Native source windows unavailable');
        this.generation = info.generation; this.ownerVisible = info.visible; this.visibility();
      }
      while (this.dirty && !this.ended) {
        this.dirty = false;
        const state = this.sourceState; if (!state) continue;
        const revision = this.revision, generation = this.generation;
        const audio = new Map([...this.sourceViews].map(([source,view])=>[source,audioBadge(view,this.nativeOptions.audioIsMuted?.(source)) ?? undefined]));
        const manifest = nativeSourceManifest(generation,revision,state.state,state.sources,state.driving,state.theme,this.logical,audio);
        const info = await this.api.syncSourceWindows(manifest);
        if (this.ended) return;
        if (info.generation > this.generation) this.reset(info.generation);
        if (generation !== this.generation || revision !== this.revision) { this.dirty = true; continue; }
        if (!state.driving) continue;
        for (const member of manifest.sources) {
          if (this.ended || revision !== this.revision || generation !== this.generation) break;
          if (this.entries.has(member.source) || this.suppressed.has(member.source)) continue;
          const permit = await this.api.prepareSourceWindow(member.source,generation);
          if (this.ended || generation !== this.generation || !this.wanted(member.source)) continue;
          if (!validSourceWindowKey(permit.key) || permit.key.generation !== generation || permit.key.source !== member.source) throw Error('Invalid native source permit');
          if (!this.snapshots) this.snapshots = new SourceWindowSnapshots(permit.key.owner,generation,(error,key)=>this.childFailed(error,key));
          if (!this.snapshots.begin(permit.key)) throw Error('Conflicting native source identity');
          const entry: Entry = {key:permit.key,ready:false,nativeKey:false,visible:false,minimized:member.minimized};
          this.entries.set(member.source,entry);
          this.publishOne(entry);
          entry.popup = (this.hooks.open ?? (url=>window.open(url,'_blank')))(permit.url) ?? undefined;
          if (!entry.popup) { this.retire(entry); throw Error('Native source document did not open'); }
          // Loading a document does not guarantee its module/bridge handshake will finish. Without
          // a deadline this entry blocks every later tab activation, even though no window appeared.
          if (!entry.ready) entry.readyTimer=setTimeout(()=>{
            if(this.current(entry.key)&&!entry.ready)this.childFailed(Error('Native source document did not become ready'),entry.key);
          },5000);
        }
      }
    } catch (error) { if (!this.ended) this.report(error); }
    finally { this.running = false; }
  }
  private wanted(source: string): boolean {
    return !this.ended && this.sourceState?.driving === true && !this.suppressed.has(source)
      && this.sourceState.state.windows.some(w=>w.source===source) === true;
  }
  private current(key: SourceWindowKey): boolean {
    return this.wanted(key.source) && key.generation === this.generation && sameSourceWindowKey(this.entries.get(key.source)?.key,key);
  }
  private controller(entry: Entry): SourceWindowController | undefined {
    return this.snapshots?.endpoint(entry.key) as SourceWindowController | undefined;
  }
  private publish(): void { for (const entry of this.entries.values()) this.publishOne(entry); }
  private publishOne(entry: Entry): void {
    const state = this.sourceState; if (!state || !this.current(entry.key)) return;
    const member = state.state.windows.find(w=>w.source===entry.key.source)!;
    const view = this.sourceViews.get(entry.key.source) ?? windowViews({...state.state,windows:[{...member,minimized:false}]},[...state.sources])[0];
    if (!view) return;
    this.snapshots?.publish({key:entry.key,revision:this.revision,view,stream:this.sourceStreams.get(entry.key.source),
      driving:state.driving,nativeKey:entry.nativeKey,minimized:member.minimized,prefs:this.devicePrefsNow(),
      inputState:this.inputStates.get(entry.key.source)??this.defaultInputState,
      theme:state.theme,smooth:state.smooth,locallyMuted:this.nativeOptions.audioIsMuted?.(entry.key.source) ?? false,
      size:this.logical.get(entry.key.source),pixelSize:this.pixels.get(entry.key.source),live:this.sourceLive.get(entry.key.source),
      simState:this.sourceSimStates.get(entry.key.source),cursor:this.sourceCursor,recovery:this.sourceRecovery,
      playoutDelay:this.sourcePlayout,curtain:this.sourceCurtain});
  }
  private connection(entry: Entry): SourceWindowConnection {
    return {current:()=>this.current(entry.key),
      options:{...this.nativeOptions,
        onFocus:source=>{if(this.current(entry.key)&&source===entry.key.source)this.hooks.focus(entry.key);},
        onDevicePrefs:prefs=>{if(this.current(entry.key))this.changeDevicePrefs(prefs);}},
      sendInput:data=>{if(this.current(entry.key))this.hooks.input(entry.key,data);},
      paste:this.hooks.paste,
      smoothChanged:enabled=>{
        if(!this.current(entry.key)||!this.sourceState)return;
        // The owner preference remains the single persisted value; children have memory-only stores.
        contextFor(this.ownerContainer)?.smooth.set(enabled);this.sourceState.smooth=enabled;this.changed();
      },
      presentationChanged:()=>{if(this.current(entry.key))this.hooks.presentationChanged?.();},
      reportError:error=>this.report(error)};
  }
  // Keep the owner element only for its explicitly scoped preference context, never child DOM.
  private get ownerContainer(): HTMLElement { return this.ownerElement; }
  private readonly ownerElement: HTMLElement;
  private event(event: NativeSourceEvent): void {
    if (this.ended || !event || typeof event !== 'object') return;
    if (event.type === 'reset') { if(event.generation>this.generation)this.reset(event.generation);if(event.ended)this.clear();return; }
    if (event.type === 'owner-visibility') {
      if(event.generation!==this.generation)return;
      this.ownerVisible=event.visible;if(event.keyWindow)this.hooks.focus(null);this.visibility();return;
    }
    if (!('key' in event) || !validSourceWindowKey(event.key) || !this.current(event.key)) return;
    const entry=this.entries.get(event.key.source)!;
    switch(event.type) {
      case 'created': break;
      case 'ready': {
        if(entry.ready)return;
        const controller=entry.popup?.__rdevSourceController;
        try {
          if(!controller || !controller.connect(this.connection(entry))) { this.childFailed(Error('Native source controller unavailable'),entry.key);return; }
        } catch(error) {this.childFailed(error,entry.key);return;}
        entry.ready=true;if(!this.snapshots?.attach(entry.key,controller))return;this.failures.delete(entry.key.source);
        if(entry.readyTimer!==undefined){clearTimeout(entry.readyTimer);entry.readyTimer=undefined;}
        if(this.pendingActivation===entry.key.source){this.pendingActivation=undefined;this.command(entry,'activate');}
        this.hooks.presentationChanged?.();break;
      }
      case 'gone': this.retire(entry);if(event.reason==='user')this.suppressed.add(entry.key.source);else this.changed();break;
      case 'key':
        if(event.keyWindow)for(const other of this.entries.values())other.nativeKey=false;
        entry.nativeKey=event.keyWindow;
        if(event.keyWindow)this.hooks.focus(entry.key);else {this.controller(entry)?.releaseInput();if(![...this.entries.values()].some(e=>e.nativeKey))this.hooks.focus(null);}
        this.changed();break;
      case 'visibility':
        entry.visible=event.visible;entry.minimized=event.minimized;entry.nativeKey=event.keyWindow;this.visibility();break;
      case 'action':this.actionFromNative(entry,event);break;
    }
  }
  private actionFromNative(entry: Entry, event: Extract<NativeSourceEvent,{type:'action'}>): void {
    const source=entry.key.source;
    switch(event.name) {
      case 'close':
        this.suppressed.add(source);this.retire(entry);this.landing={source,land:event.land===true};
        try{this.nativeOptions.onClose(source);}finally{this.landing=undefined;}break;
      case 'minimize':
        this.hooks.retired?.(entry.key);this.controller(entry)?.releaseInput();this.landing={source,land:event.land===true};
        try{this.nativeOptions.onMinimize(source);}finally{this.landing=undefined;}break;
      case 'restore':this.hooks.restore(source);break;
      case 'resize':if(Number.isInteger(event.width)&&Number.isInteger(event.height)&&event.width!>0&&event.height!>0){this.pendingResizes.add(source);this.nativeOptions.onResize?.(source,event.width!,event.height!);}break;
      case 'fullscreen':this.nativeFullscreen=event.on?source:null;this.nativeOptions.onFullscreen?.(this.nativeFullscreen);break;
      case 'home': case 'keyboard':this.nativeOptions.onSimAction?.(source,event.name);break;
      case 'settings':this.controller(entry)?.action({type:'settings'});break;
      case 'menu':this.controller(entry)?.action({type:'menu',x:event.x??0,y:event.y??0});break;
      case 'fit':this.controller(entry)?.action({type:'resetView'});break;
    }
  }
  private visibility(): void { this.hooks.visibilityChanged?.(this.ownerVisible,[...this.entries.values()].map(e=>({key:e.key,visible:e.visible,minimized:e.minimized}))); }
  private retire(entry: Entry): void {
    if(!sameSourceWindowKey(this.entries.get(entry.key.source)?.key,entry.key))return;
    if(entry.readyTimer!==undefined){clearTimeout(entry.readyTimer);entry.readyTimer=undefined;}
    this.entries.delete(entry.key.source);this.inputStates.delete(entry.key.source);this.pendingResizes.delete(entry.key.source);this.hooks.retired?.(entry.key);this.snapshots?.retire(entry.key);this.visibility();
    this.hooks.presentationChanged?.();
  }
  private reset(generation: number): void {
    for(const entry of [...this.entries.values()])this.retire(entry);
    this.snapshots?.reset(generation);this.failures.clear();this.generation=generation;this.pendingActivation=undefined;
  }
  private command(entry: Entry, command: Parameters<NativeSourceWindowAPI['sourceWindowCommand']>[1], value?: unknown): void {
    if(this.current(entry.key))void this.api.sourceWindowCommand(entry.key,command,value).catch(error=>{if(this.current(entry.key))this.report(error);});
  }
  private childFailed(error:unknown,key?:SourceWindowKey):void {
    this.report(error);if(!key||!this.current(key))return;
    const entry=this.entries.get(key.source)!;
    const failures=(this.failures.get(key.source)??0)+1;this.failures.set(key.source,failures);
    this.retire(entry);if(failures>3)this.suppressed.add(key.source);
    void this.api.sourceWindowCommand(key,'close').catch(()=>{}).finally(()=>{
      if(!this.ended&&this.generation===key.generation&&this.wanted(key.source))this.changed();
    });
  }
  private report(error: unknown): void { (this.hooks.error ?? (e=>console.error('[native-source]',e)))(error); }
  activate(source: string): void {
    if(this.ended)return;
    this.pendingActivation=source;this.suppressed.delete(source);this.failures.delete(source);
    if(!this.wanted(source))return;
    if(!this.entries.has(source))this.changed();
    if(this.sourceState?.state.windows.find(w=>w.source===source)?.minimized)this.hooks.restore(source);
    const entry=this.entries.get(source);if(entry?.ready){this.pendingActivation=undefined;this.command(entry,'activate');}
  }
  setInputState(state:SourceFocusState):void {
    if(state.key){if(!this.current(state.key))return;this.inputStates.set(state.key.source,state);}
    else {this.defaultInputState=state;this.inputStates.clear();}
    this.changed();
  }
  activeKey():SourceWindowKey|null {return [...this.entries.values()].find(e=>e.nativeKey)?.key??null;}
  private allAction(action: SourceWindowAction): void { for(const entry of this.entries.values())this.controller(entry)?.action(action); }
  override videos(): HTMLVideoElement[] { return [...this.entries.values()].flatMap(e=>{const video=this.controller(e)?.video();return video?[video]:[];}); }
  override focusedVideo(): HTMLVideoElement | undefined { const entry=[...this.entries.values()].find(e=>e.nativeKey);return entry&&this.controller(entry)?.video(); }
  override hasWindow(source: string): boolean { return this.entries.has(source); }
  override personAt(source: string, _surface: boolean): boolean { return this.landing?.source===source?this.landing.land:this.entries.get(source)?.nativeKey===true; }
  override setSourceSize(source:string,w:number,h:number):void {const old=this.logical.get(source);this.logical.set(source,{w,h});const entry=this.entries.get(source);const pending=this.pendingResizes.delete(source);if(entry&&(pending||!old||old.w!==w||old.h!==h))this.command(entry,'confirmSize',{width:w,height:h});this.changed();}
  override setSourcePixelSize(source:string,w:number,h:number):void {this.pixels.set(source,{w,h});this.changed();}
  override setStatePositions(_windows:ReadonlyArray<{source:string;x?:number;y?:number}>):void {} // Native position belongs to AppKit, never browser stage coordinates.
  override setLiveness(value:Map<string,boolean>):void {this.sourceLive=new Map(value);this.changed();}
  override setSimStates(value:Map<string,SimStateWire>):void {this.sourceSimStates=new Map(value);this.changed();}
  override setCursor(url:string|null,x:number,y:number,overlay?:{url:string;w:number;h:number}):void {this.sourceCursor={url,x,y,overlay};this.changed();}
  override setRecoveryOverride(value:number|null):void {this.sourceRecovery=value;this.changed();}
  override setPlayoutDelayMin(value:number|null):void {this.sourcePlayout=value;this.changed();}
  override playoutDelayIsAuto():boolean {return false;}
  override setCurtainUp(value:boolean|null):void {this.sourceCurtain=value;this.changed();}
  override changeDevicePrefs(patch:Parameters<WindowManager['changeDevicePrefs']>[0]):void {super.changeDevicePrefs(patch);this.changed();}
  override setFullscreen(source:string|null,_options?:{browser?:boolean}):void {if(this.ended)return;this.nativeFullscreen=source;for(const entry of this.entries.values())this.command(entry,'fullscreen',entry.key.source===source);}
  override fullscreenSource():string|null {return this.nativeFullscreen;}
  override toggleFit(source:string):void {const entry=this.entries.get(source);if(entry)this.command(entry,'fit');}
  override resendDerived():void {this.allAction({type:'resendDerived'});}
  override releaseInput():void {this.allAction({type:'releaseInput'});}
  override releaseTouchMods():void {this.allAction({type:'releaseInput'});}
  override suspendWorkspaces():void {this.allAction({type:'suspendWorkspaces'});}
  override closeAllSettings():void {this.allAction({type:'closeSettings'});}
  override togglePointerMode():void {const next=this.devicePrefsNow().pointerMode==='trackpad'?'direct':'trackpad';this.changeDevicePrefs({pointerMode:next});}
  override setViewMode(source:string,value:'input'|'zoom'):void {this.entries.get(source)&&this.controller(this.entries.get(source)!)?.action({type:'viewMode',value});}
  override resetView(source:string):void {this.entries.get(source)&&this.controller(this.entries.get(source)!)?.action({type:'resetView'});}
  override attachPacer(source:string):void {this.entries.get(source)&&this.controller(this.entries.get(source)!)?.action({type:'attachPacer'});}
  override failPacer(source:string):void {this.entries.get(source)&&this.controller(this.entries.get(source)!)?.action({type:'failPacer'});}
  override releasePacer(source:string):void {this.entries.get(source)&&this.controller(this.entries.get(source)!)?.action({type:'releasePacer'});}
  override setPacerMargin(value:number|'auto'):void {this.allAction({type:'pacerMargin',value});}
  override resetPacerStats():void {this.allAction({type:'resetPacerStats'});}
  override autoDebug():Record<string,unknown> {return Object.assign({},...[...this.entries.values()].map(e=>this.controller(e)?.autoDebug()??{}));}
  override viewDebug():ReturnType<WindowManager['viewDebug']> {return Object.assign({},...[...this.entries.values()].map(e=>this.controller(e)?.viewDebug()??{}));}
  override pacerStats():Record<string,unknown> {return Object.assign({},...[...this.entries.values()].map(e=>this.controller(e)?.pacerStats()??{}));}
  override clear():void {
    if(this.ended)return;this.ended=true;this.off();this.hooks.focus(null);
    for(const entry of [...this.entries.values()])this.retire(entry);
    this.snapshots?.clear();this.sourceStreams.clear();this.sourceViews.clear();
    if(this.generation)void this.api.resetSourceWindows(this.generation).catch(error=>this.report(error));
    super.clear();
  }
}
