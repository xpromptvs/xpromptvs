import type {Delivery} from '../paste-upload';
import { mountNativeSourceTextInput } from './text-input';
import { createClientSurface } from '../instance/surface';
import { createClientContext } from '../instance/context';
import { createMemoryPreferences } from '../instance/preferences';
import { WindowManager } from '../window-manager';
import { PasteUI } from '../paste-ui';
import { localPasteApi } from '../paste-local';
import { createPasteDialogs } from '../paste-dialogs';
import { StatusNote } from '../status-note';
import { NativeSourceScroll } from './scroll';
import {encodeJson} from '../../lib/codec';
import type { ChannelLike } from '../../lib/channel';
import { sameSourceWindowKey, validSourceWindowKey, type NativeSourceDocumentBridge,
  type SourceWindowConnection, type SourceWindowController, type SourceWindowSnapshot } from './types';

/** Runs in the child module realm: viewport, clipboard activation, IME, menus and DOM all belong here.
 * The owner supplies capabilities and existing received streams, never a peer or transplanted nodes. */
export function createSourceWindowController(container: HTMLElement, bridge: NativeSourceDocumentBridge): SourceWindowController {
  if (!validSourceWindowKey(bridge.key)) throw Error('Invalid source document identity');
  const key = Object.freeze({ ...bridge.key });
  const surface = createClientSurface(container);
  const context = createClientContext(`source:${key.owner}:${key.generation}:${key.incarnation}`, surface.root,
    surface.ui, createMemoryPreferences(), { layout: 'floating' });
  const style = container.ownerDocument.createElement('style');
  style.textContent = `
    .client-root { --tabbar-h: 0px; --statusbar-h: 0px; }
    #tabbar, #statusbar, #term-surface, #palette, #claim, .win-titlebar, .win-resize, .win-fullscreen-exit { display: none !important; }
    #stage, #windows { position: absolute; inset: 0; }
    .source-window.fullscreen { border: 0; border-radius: 0; }
    #toasts { top: 10px; }
    .source-input-note { padding: 8px 12px; border-radius: 8px; background: var(--surface); color: var(--muted); font: 12px var(--font-ui); }
    .source-input-note[hidden] { display: none; }
  `;
  surface.root.appendChild(style);
  const inputStatus=container.ownerDocument.createElement('span');
  inputStatus.className='source-input-note';inputStatus.setAttribute('role','status');inputStatus.hidden=true;
  context.get('toasts').appendChild(inputStatus);
  const note = new StatusNote(() => context.get('sim-status-note'), {
    now: () => performance.now(), setTimer: (fn, ms) => setTimeout(fn, ms), clearTimer: handle => clearTimeout(handle as ReturnType<typeof setTimeout>),
  });
  const dialogs = createPasteDialogs(context);
  let connection: SourceWindowConnection | undefined, latest: SourceWindowSnapshot | undefined;
  let manager: WindowManager | undefined, paste: PasteUI | undefined;
  let activeDelivery: Delivery | undefined;
  let editor:ReturnType<typeof mountNativeSourceTextInput>|undefined;
  let disposed = false, updating = false;
  const current = () => !disposed && !!connection?.current();
  const enabled = () => current() && latest?.driving === true && !latest.minimized;
  // A local EventTarget, not the owner's channel object. The owner gate scopes every final event.
  const input = Object.assign(new EventTarget(), {
    label: 'input', binaryType: 'arraybuffer' as BinaryType,
    send(data: string | ArrayBuffer | ArrayBufferView) { if (enabled()) connection?.sendInput(data); },
  }) as ChannelLike;
  // Object.assign evaluates getters immediately; channel state must follow each owner snapshot.
  Object.defineProperty(input, 'readyState', {get: () => enabled() ? 'open' : 'closed'});
  const nativeScrollEnabled=()=>bridge.nativeScrollEnabled===true&&!!bridge.onScroll&&enabled()&&
    latest?.inputState?.scrollGestures?.includes(key.source.startsWith('sim:')?'simulator':key.source.startsWith('dsp:')?'display':'window')===true;
  const remoteScroll=new NativeSourceScroll({enabled:nativeScrollEnabled,
    viewport:()=>({width:container.ownerDocument.defaultView!.innerWidth,height:container.ownerDocument.defaultView!.innerHeight}),
    target:(x,y)=>{
      if(!latest?.nativeKey)return;
      const target=context.root.elementFromPoint(x,y);
      if(!target?.closest('.win-body')||target.closest('.win-settings,.ctx-menu,[role="dialog"]'))return;
      return manager?.scrollGeometry(key.source);
    },
    send:message=>{if(current())input.send(encodeJson(message));},
  });
  if(bridge.onScroll)context.scope.defer(bridge.onScroll(batch=>remoteScroll.handle(batch)),'native-source-scroll');
  // Native observation never consumes the original NSEvent. Suppress only the remote picture's
  // DOM sender; local menus/dialogs keep WebKit default scrolling and its own momentum tail.
  context.scope.listen(context.root,'wheel',event=>{
    const target=event.composedPath()[0] as Element|undefined;
    if(remoteScroll.suppressesDOM()&&target?.closest?.('.win-body')&&!target.closest('.win-settings,.ctx-menu,[role="dialog"]')){
      event.preventDefault();event.stopImmediatePropagation();
    }
  },{capture:true,passive:false});
  const releaseInput = () => { remoteScroll.cancel();editor?.release(); manager?.releaseInput(); };
  // Local WindowManager focus is always true for its one source, so its ordinary "unfocused"
  // callback cannot initiate/retry a native lease. Capture the picture press before it emits input.
  context.scope.listen(context.root, 'pointerdown', event => {
    const target=event.composedPath()[0] as Element | undefined;
    if(enabled()&&target?.closest?.('.win-body'))connection?.options.onFocus(key.source);
  }, {capture:true});
  function initialize(snapshot: SourceWindowSnapshot) {
    const options = connection!.options;
    const sourceAction = (fn: ((source: string) => void) | undefined) => (source: string) => {
      if (enabled() && source === key.source) fn?.(source);
    };
    if (connection!.paste) {
      const uploader = connection!.paste.uploader;
      paste = new PasteUI({
        signal: context.scope.signal, owner: context.ui, enabled,
        visibleTab: () => null, terminal: () => null, hostTabs: () => ({ ids: [], active: null }), showTab() {},
        // Even delayed clipboard/file reads cannot deliver to a retired or different source.
        uploader: { get busy() { return uploader.busy; },
          onReply: r => { if (current()) uploader.onReply(r); },
          fail: (reason: 'closed' | 'not-driver', channel?: ChannelLike) => {
            if (current()) { if (reason === 'not-driver') uploader.fail(reason); else if (channel) uploader.fail(reason, channel); }
          },
          cancel: () => { if (current()) uploader.cancel(); },
          deliver: delivery => {
            if(!enabled() || !('win' in delivery.to) || delivery.to.win !== key.source)return Promise.resolve({ok:false,reason:'no-target'});
            if(uploader.busy)return uploader.deliver(delivery);
            activeDelivery=delivery;
            return uploader.deliver(delivery).finally(()=>{if(activeDelivery===delivery)activeDelivery=undefined;});
          },
        },
        note: text => note.flash(text), fail: text => note.flash(text),
        progress: text => { if (text) note.show(text); else note.dismiss(); },
        confirm: dialogs.confirm, chooseFolder: dialogs.chooseFolder,
        local: localPasteApi(bridge), sameMac: false,
      });
      const offProgress=connection!.paste.subscribeProgress?.((sent,total,delivery)=>{
        if(current()&&delivery===activeDelivery)paste?.progress(sent,total,delivery);
      });
      if(offProgress)context.scope.defer(offProgress,'native-source-upload-progress');
    }
    manager = new WindowManager(context.get('windows'), {
      ...options, workspaceSupported: false, workspaceActive: () => false,
      prefs: snapshot.prefs, inputChannel: input,
      onFocus: sourceAction(options.onFocus), onClose: sourceAction(options.onClose), onMinimize: sourceAction(options.onMinimize),
      onPrefs: (source, patch) => { if (enabled() && source === key.source) options.onPrefs(source, patch); },
      onDevicePrefs: prefs => { if (!updating && enabled()) options.onDevicePrefs?.(prefs); },
      onRecovery: value => { if (!updating && enabled()) options.onRecovery(value); },
      onPlayoutDelay: value => { if (!updating && enabled()) options.onPlayoutDelay(value); },
      onCurtain: value => { if (enabled()) options.onCurtain?.(value); },
      onSourceAudio: (source, value) => { if (enabled() && source === key.source) options.onSourceAudio?.(source, value); },
      audioIsMuted: () => latest?.locallyMuted ?? false,
      // Content always fills this child. Native NSWindow fullscreen is owned separately by the parent.
      onFullscreen() {}, onMoved() {}, onResize() {},
      canPaste: enabled,
      onWindowMenu: (source, at) => { if (enabled() && source === key.source) paste?.openWindowMenu(source, at); },
      onWindowDrop: (source, at, dt) => { if (enabled() && source === key.source) paste?.windowDrop(source, at, dt); },
      onSimAction: (source, action) => { if (enabled() && source === key.source) options.onSimAction?.(source, action); },
    });
  }
  context.scope.defer(context.smooth.subscribe(value => { if (!updating && enabled()) connection?.smoothChanged?.(value); }));
  if (bridge.onResizeHold) context.scope.defer(bridge.onResizeHold(held => {
    if (current()) context.resizeSettle.setActive(held);
  }));
  context.scope.listen(container.ownerDocument.defaultView!, "blur", releaseInput);
  const controller: SourceWindowController = {
    connect(next) {
      if (disposed || connection || !next.current()) return false;
      connection = next; return true;
    },
    update(snapshot) {
      if (!current() || !sameSourceWindowKey(snapshot.key, key) || snapshot.view.source !== key.source
          || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0
          || (latest && snapshot.revision <= latest.revision)) return;
      const previous = latest; latest = snapshot; updating = true;
      try {
        context.ui.dataset.theme = snapshot.theme;
        const state=snapshot.inputState;
        inputStatus.hidden=!state||state.state==='ready'||state.state==='inactive';
        inputStatus.textContent=state?.state==='waiting'?'Waiting for the Mac…':state?.reason==='host-update-required'
          ?'Update Xpromptvs on the remote Mac to control this window.':'Couldn’t focus this window on the remote Mac. Click to try again.';
        if (context.smooth.enabled() !== snapshot.smooth) context.smooth.set(snapshot.smooth);
        if (!manager) initialize(snapshot);
        else if (JSON.stringify(previous?.prefs) !== JSON.stringify(snapshot.prefs)) manager.changeDevicePrefs(snapshot.prefs);
        if (previous?.nativeKey && !snapshot.nativeKey || !enabled()) releaseInput();
        if (snapshot.size && (snapshot.size.w !== previous?.size?.w || snapshot.size.h !== previous?.size?.h)) manager!.setSourceSize(key.source, snapshot.size.w, snapshot.size.h);
        if (snapshot.pixelSize && (snapshot.pixelSize.w !== previous?.pixelSize?.w || snapshot.pixelSize.h !== previous?.pixelSize?.h)) manager!.setSourcePixelSize(key.source, snapshot.pixelSize.w, snapshot.pixelSize.h);
        manager!.setLiveness(new Map(snapshot.live === undefined ? [] : [[key.source, snapshot.live]]));
        manager!.setSimStates(new Map(snapshot.simState === undefined ? [] : [[key.source, snapshot.simState]]));
        if (snapshot.recovery !== undefined) manager!.setRecoveryOverride(snapshot.recovery);
        if (snapshot.playoutDelay !== undefined) manager!.setPlayoutDelayMin(snapshot.playoutDelay);
        if (snapshot.curtain !== undefined) manager!.setCurtainUp(snapshot.curtain);
        if (snapshot.cursor) manager!.setCursor(snapshot.cursor.url, snapshot.cursor.x, snapshot.cursor.y, snapshot.cursor.overlay);
        // The native key/lease gate is the input authority. Local focus avoids losing the first key
        // while the host's ordinary view-set still names the previous source during activation.
        manager!.sync([{ ...snapshot.view, focused: true }], new Map(snapshot.stream ? [[key.source, snapshot.stream]] : []));
        if(!editor){
          const body=context.root.querySelector<HTMLElement>('.win-body');
          if(body)editor=mountNativeSourceTextInput(context,body,key.source,input,enabled);
        }
        manager!.setFullscreen(key.source, { browser: false });
        const video = manager!.focusedVideo();
        if (video) {
          video.muted = true; // audio has exactly one sink, in the owner session
          if (!snapshot.stream && video.srcObject) { video.pause(); video.srcObject = null; }
        }
        connection?.presentationChanged?.();
      } finally { updating = false; }
    },
    action(action) {
      if (!current() || !manager) return false;
      switch (action.type) {
        case 'settings': context.root.querySelector<HTMLElement>('.win-gear')?.click(); break;
        case 'menu': if (enabled()) paste?.openWindowMenu(key.source, { x: action.x, y: action.y }); break;
        case 'fit': manager.toggleFit(key.source); break;
        case 'releaseInput': releaseInput(); break;
        case 'resendDerived': manager.resendDerived(); break;
        case 'pointerMode': manager.togglePointerMode(); break;
        case 'resetView': manager.resetView(key.source); break;
        case 'viewMode': manager.setViewMode(key.source, action.value); break;
        case 'closeSettings': manager.closeAllSettings(); break;
        case 'suspendWorkspaces': manager.suspendWorkspaces(); break;
        case 'attachPacer': manager.attachPacer(key.source); break;
        case 'failPacer': manager.failPacer(key.source); break;
        case 'releasePacer': manager.releasePacer(key.source); break;
        case 'pacerMargin': manager.setPacerMargin(action.value); break;
        case 'resetPacerStats': manager.resetPacerStats(); break;
        case 'resizeHold': context.resizeSettle.setActive(action.value); break;
      }
      return true;
    },
    video: () => disposed ? undefined : manager?.focusedVideo(),
    autoDebug: () => manager?.autoDebug() ?? {}, viewDebug: () => manager?.viewDebug() ?? {}, pacerStats: () => manager?.pacerStats() ?? {},
    releaseInput,
    dispose() {
      if (disposed) return;
      remoteScroll.cancel();
      // Remove bindings without ever stopping the owner's received track.
      disposed = true; editor?.dispose();
      for (const video of manager?.videos() ?? []) { video.pause(); video.srcObject = null; }
      try { manager?.clear(); }
      finally { context.resizeSettle.cancel(controller); context.scope.dispose(); note.dismiss(); surface.destroy(); connection = undefined; latest = undefined; }
    },
  };
  return controller;
}
