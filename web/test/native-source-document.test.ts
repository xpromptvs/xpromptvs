import {decodeJson} from '../src/lib/codec';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { WindowManager } from '../src/client/window-manager';
import { createSourceWindowController } from '../src/client/native-source/document';
import type { SourceWindowSnapshot, SourceWindowConnection } from '../src/client/native-source/types';
import { DEFAULT_CLIENT_PREFS } from '../src/shared/client-prefs';
import type {NativeScrollBatch} from '../src/client/native-source/scroll';
const key = { owner: 1, generation: 1, source: 'win:42', incarnation: 1 };
const cleanups: (() => void)[] = [];
beforeEach(() => {
  vi.spyOn(HTMLMediaElement.prototype, 'play').mockResolvedValue(undefined);
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {});
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
});
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });
function setup(paste?: SourceWindowConnection['paste'], onScroll?:(callback:(batch:NativeScrollBatch)=>void)=>()=>void) {
  const root = document.body.appendChild(document.createElement('div'));
  const controller = createSourceWindowController(root, { key, onScroll, nativeScrollEnabled:!!onScroll });
  let current = true;
  const sendInput = vi.fn(), focus = vi.fn(), globalPrefs = vi.fn(), derived = vi.fn();
  const connection: SourceWindowConnection = {
    current: () => current, sendInput, paste,
    options: { onFocus: focus, onClose() {}, onMinimize() {}, onPrefs: derived,
      onDevicePrefs: globalPrefs, onRecovery() {}, onPlayoutDelay() {}, nowMs: () => 100, pc: () => null },
  };
  expect(controller.connect(connection)).toBe(true);
  cleanups.push(() => { controller.dispose(); root.remove(); });
  const track = { id: 'received', stop: vi.fn(), kind: 'video' } as unknown as MediaStreamTrack;
  const stream = { getVideoTracks: () => [track] } as unknown as MediaStream;
  const snapshot: SourceWindowSnapshot = { key, revision: 1,
    view: { source: key.source, name: 'Remote', focused: false, fps: 60, scale: 1, bitrateBps: 2000000 },
    stream, driving: true, nativeKey: false, minimized: false, prefs: DEFAULT_CLIENT_PREFS,
    theme: 'dark', smooth: true, locallyMuted: false };
  return { root, controller, snapshot, track, stream, focus, sendInput, globalPrefs, invalidate: () => { current = false; } };
}
describe('source-only document controller', () => {
  it('keeps its keyboard editor focused when a picture press begins with Command held',()=>{
    const t=setup();t.controller.update({...t.snapshot,nativeKey:true});
    const body=t.controller.video()!.closest<HTMLElement>('.win-body')!;
    body.setPointerCapture=()=>{};body.releasePointerCapture=()=>{};
    const root=t.root.querySelector('[data-client-host]')!.shadowRoot!;
    const editor=root.querySelector<HTMLTextAreaElement>('.native-source-text-input')!;
    editor.focus();editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Meta',code:'MetaLeft',metaKey:true,bubbles:true,cancelable:true}));
    t.sendInput.mockClear();
    body.dispatchEvent(new MouseEvent('pointerdown',{clientX:20,clientY:20,buttons:1,metaKey:true,bubbles:true,composed:true,cancelable:true}));
    expect(root.activeElement).toBe(editor);
    const messages=t.sendInput.mock.calls.map(([data])=>decodeJson<{t:string}>(data));
    expect(messages.filter(m=>m.t==='win-keys-release')).toEqual([]);
    const mouseDown=new MouseEvent('mousedown',{bubbles:true,cancelable:true});
    body.dispatchEvent(mouseDown);expect(mouseDown.defaultPrevented).toBe(true);
  });

  it('uses native phases once over the picture while old hosts retain ordinary DOM wheel input',()=>{
    let native:((batch:NativeScrollBatch)=>void)|undefined;
    const t=setup(undefined,cb=>{native=cb;return()=>{native=undefined;};});
    t.controller.update({...t.snapshot,nativeKey:true,size:{w:400,h:300},inputState:{state:'ready',scrollGestures:['window']}});
    const body=t.controller.video()!.closest<HTMLElement>('.win-body')!;
    Object.defineProperties(body,{clientWidth:{value:400},clientHeight:{value:300}});
    vi.spyOn(body,'getBoundingClientRect').mockReturnValue({left:0,top:0,width:400,height:300,right:400,bottom:300,x:0,y:0,toJSON(){}});
    const shadow=t.root.querySelector('[data-client-host]')!.shadowRoot!;
    Object.defineProperty(shadow,'elementFromPoint',{value:()=>body});
    t.sendInput.mockClear(); // Initial fullscreen/layout setup releases any inherited keys.
    const wheel=new WheelEvent('wheel',{bubbles:true,composed:true,cancelable:true,clientX:200,clientY:150,deltaY:10});
    body.dispatchEvent(wheel);expect(wheel.defaultPrevented).toBe(true);expect(t.sendInput).not.toHaveBeenCalled();
    expect(native).toBeTypeOf('function');
    native?.({sequence:1,gesture:1,x:200/innerWidth,y:150/innerHeight,width:innerWidth,height:innerHeight,mods:0,
      events:[{kind:'begin'},{kind:'scroll',dx:0,dy:10,precise:true},{kind:'end',vx:0,vy:500}]});
    expect(t.sendInput).toHaveBeenCalledTimes(3);
    t.sendInput.mockClear();t.controller.update({...t.snapshot,revision:2,nativeKey:true,inputState:{state:'ready'}});
    body.dispatchEvent(new WheelEvent('wheel',{bubbles:true,composed:true,cancelable:true,clientX:200,clientY:150,deltaY:10}));
    expect(t.sendInput).toHaveBeenCalledTimes(1);
    t.controller.dispose();expect(native).toBeUndefined();
  });
  it('shows progress only for this document’s in-flight drop and unsubscribes on disposal', async () => {
    let progress: (sent:number,total:number,d:import('../src/client/paste-upload').Delivery)=>void = ()=>{};
    let finish!: (out:import('../src/client/paste-upload').Outcome)=>void;
    const off = vi.fn();
    let busy=false;
    const deliver = vi.fn((_delivery:import('../src/client/paste-upload').Delivery) => {if(busy)return Promise.resolve<import('../src/client/paste-upload').Outcome>({ok:false,reason:'busy'});busy=true;return new Promise<import('../src/client/paste-upload').Outcome>(resolve=>{finish=resolve;});});
    const t = setup({uploader:{get busy(){return busy;},onReply(){},fail(){},cancel(){},deliver},subscribeProgress(listener){progress=listener;return off;}});
    t.controller.update(t.snapshot);
    const body=t.controller.video()!.closest('.win-body')!;
    const event=new Event('drop',{bubbles:true,cancelable:true});
    Object.defineProperty(event,'dataTransfer',{value:{files:[new File(['data'],'probe.txt')],getData:()=>''}});
    body.dispatchEvent(event);
    await vi.waitFor(()=>expect(deliver).toHaveBeenCalledTimes(1));
    const delivery=deliver.mock.calls[0]![0];
    const note=t.root.querySelector('[data-client-host]')!.shadowRoot!.getElementById('sim-status-note')!;
    progress(20,100,{...delivery});expect(note.textContent).not.toContain('Sending');
    progress(20,100,delivery);expect(note.textContent).toContain('Sending probe.txt — 20%');
    body.dispatchEvent(event);await vi.waitFor(()=>expect(deliver).toHaveBeenCalledTimes(2));
    progress(100,100,delivery);expect(note.textContent).toContain('Sending probe.txt — waiting for the Mac');
    finish({ok:true,how:'drop'});await Promise.resolve();await Promise.resolve();
    t.controller.dispose();expect(off).toHaveBeenCalledTimes(1);
  });
  it('updates channel availability across ownership snapshots and retirement', () => {
    let channel: {readyState: string} | undefined;
    const sync = WindowManager.prototype.sync;
    vi.spyOn(WindowManager.prototype, 'sync').mockImplementation(function (this: WindowManager, ...args) {
      channel = (this as unknown as {opts: {inputChannel: {readyState: string}}}).opts.inputChannel;
      return sync.apply(this, args);
    });
    const t = setup(); t.controller.update(t.snapshot);
    expect(channel?.readyState).toBe('open');
    t.controller.update({...t.snapshot, revision: 2, driving: false});
    expect(channel?.readyState).toBe('closed');
    t.controller.update({...t.snapshot, revision: 3, driving: true});
    expect(channel?.readyState).toBe('open');
    t.invalidate(); expect(channel?.readyState).toBe('closed');
  });
  it('binds the exact received stream, keeps video muted, and never activates on arrival', () => {
    const t = setup(); t.controller.update(t.snapshot);
    expect(t.controller.video()?.srcObject).toBe(t.stream);
    expect(t.controller.video()?.muted).toBe(true);
    expect(t.focus).not.toHaveBeenCalled();
    expect(t.globalPrefs).not.toHaveBeenCalled();
    expect(document.querySelector('audio')).toBe(null);
  });
  it('rejects stale revisions, foreign sources and retired incarnations', () => {
    const t = setup(); t.controller.update(t.snapshot);
    t.controller.update({ ...t.snapshot, revision: 2, key: { ...key, incarnation: 2 } });
    t.controller.update({ ...t.snapshot, revision: 2, view: { ...t.snapshot.view, source: 'win:77' } });
    t.controller.update({ ...t.snapshot, revision: 1, stream: undefined });
    expect(t.controller.video()?.srcObject).toBe(t.stream);
    t.invalidate(); t.controller.update({ ...t.snapshot, revision: 3, stream: undefined });
    expect(t.controller.video()?.srcObject).toBe(t.stream);
    expect(t.controller.action({ type: 'settings' })).toBe(false);
  });
  it('clears a missing/replaced track and never stops the owner track during retirement', () => {
    const t = setup(); t.controller.update(t.snapshot);
    const video = t.controller.video()!;
    t.controller.update({ ...t.snapshot, revision: 2, stream: undefined });
    expect(video.srcObject).toBe(null);
    t.controller.update({ ...t.snapshot, revision: 3 });
    expect(video.srcObject).toBe(t.stream);
    t.controller.dispose(); t.controller.dispose();
    expect(video.srcObject).toBe(null);
    expect(t.track.stop).not.toHaveBeenCalled();
    expect(t.controller.connect({} as SourceWindowConnection)).toBe(false);
  });
  it('reports local settings changes once and applies owner preference snapshots silently', () => {
    const t = setup(); t.controller.update(t.snapshot);
    t.controller.update({ ...t.snapshot, revision: 2, prefs: { ...t.snapshot.prefs, fps: 30 } });
    expect(t.globalPrefs).not.toHaveBeenCalled();
    expect(t.controller.action({ type: 'pointerMode' })).toBe(true);
    expect(t.globalPrefs).toHaveBeenCalledTimes(1);
  });
});
