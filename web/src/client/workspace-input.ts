import { isApplePlatform, pointerButton, scrollToWire, type PointerHandle } from './input';
import type { ClientRect } from './pointer-map';

/** Capture on the SESSION ancestor, never synthesize terminal events. Transparent presses remain
 * trusted events on their original targets; remote presses stop before reaching xterm. Mouse only. */
export function attachWorkspaceInput(root: HTMLElement, opts: {
  accepts(e: Event): boolean; hit(e: MouseEvent): boolean | null;
  point(e: MouseEvent): { x: number; y: number }; rect(): ClientRect; drawScale(): number;
  active(): boolean; focused(): boolean; focus(): void; send(message: unknown): void;
}): PointerHandle & { dispose(): void } {
  const abort=new AbortController(), signal=abort.signal;
  const owners=new Map<number,{remote:boolean;sent:boolean;button:'left'|'right';point:{x:number;y:number};sequence:number}>();
  let sequence=0;
  const consume=(e:Event)=>{e.preventDefault();e.stopImmediatePropagation();};
  const send=(owner:{button:'left'|'right';point:{x:number;y:number};sequence:number},phase:string)=>opts.send({t:'touch',phase,id:owner.sequence,...owner.point,ts:Math.floor(performance.now()),...(owner.button==='right'?{button:'right'}:{})});
  const cancelGesture=()=>{const previous=[...owners];owners.clear();for(const [id,o] of previous){if(o.sent)send(o,'up');try{root.releasePointerCapture(id);}catch{}}owners.clear();};
  root.addEventListener('pointerdown',e=>{
    if(!opts.accepts(e)||!opts.active())return;
    const occupied=opts.hit(e),remote=occupied!==false;
    const o={remote,sent:false,button:pointerButton(e,isApplePlatform()),point:opts.point(e),sequence:++sequence};
    owners.set(e.pointerId,o);
    if(!remote)return;
    consume(e);try{root.setPointerCapture(e.pointerId);}catch{}
    if(occupied!==true||e.pointerType!=='mouse')return;
    const focused=opts.focused();opts.focus();
    if(focused){o.sent=true;send(o,'down');}
  },{capture:true,signal});
  root.addEventListener('pointermove',e=>{
    const o=owners.get(e.pointerId);
    if(o){if(!o.remote)return;consume(e);if(!opts.active()){cancelGesture();return;}o.point=opts.point(e);if(o.sent)send(o,'move');return;}
    // A terminal selection that started outside the workspace must never turn into a remote hover.
    if(e.buttons||e.pointerType!=='mouse'||!opts.active()||!opts.accepts(e))return;
    if(opts.hit(e)!==true||!opts.focused())return;
    consume(e);opts.send({t:'hover',...opts.point(e)});
  },{capture:true,signal});
  const end=(e:PointerEvent)=>{const o=owners.get(e.pointerId);if(!o)return;owners.delete(e.pointerId);if(!o.remote)return;consume(e);if(o.sent){o.point=opts.point(e);send(o,'up');}try{root.releasePointerCapture(e.pointerId);}catch{}};
  root.addEventListener('pointerup',end,{capture:true,signal});root.addEventListener('pointercancel',end,{capture:true,signal});
  root.addEventListener('lostpointercapture',end,{capture:true,signal});
  root.addEventListener('wheel',e=>{
    if(!opts.active()||!opts.accepts(e))return;const occupied=opts.hit(e);if(occupied===false)return;
    consume(e);if(occupied===true&&opts.focused()&&!e.ctrlKey)opts.send(scrollToWire(e,opts.rect(),opts.drawScale()));
  },{capture:true,passive:false,signal});
  root.addEventListener('contextmenu',e=>{if(opts.active()&&opts.accepts(e)&&opts.hit(e)!==false)consume(e);},{capture:true,signal});
  // File transfer is not implemented for workspaces. Refuse occupied/unknown drops, leaving gaps
  // to the terminal's existing drop route. Never let the browser navigate to a dropped file.
  for(const type of ['dragover','drop'])root.addEventListener(type,e=>{if(opts.active()&&opts.accepts(e)&&opts.hit(e as DragEvent)!==false)consume(e);},{capture:true,signal});
  root.ownerDocument.defaultView?.addEventListener('blur',cancelGesture,{signal});
  root.ownerDocument.addEventListener('visibilitychange',()=>{if(root.ownerDocument.hidden)cancelGesture();},{signal});
  return {cancelGesture,dispose(){cancelGesture();abort.abort();}};
}
