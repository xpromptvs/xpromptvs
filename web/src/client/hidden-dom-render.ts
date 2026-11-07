import type { Terminal } from '@xterm/xterm';
import { xtermDomRenderer } from './overscan-rows';

/** xterm's selection redraw bypasses its IntersectionObserver pause. Keep parsing,
 * replies, buffers and resize live, but don't build zero-width rows in display:none.
 * Install OUTSIDE the row-cache/overscan wrappers; RevealDraw redraws synchronously
 * before the first paint on return. A replacement (e.g. GPU) renderer is untouched.
 */
export function suppressHiddenDomRendering(term: Terminal): () => void {
 const renderer=xtermDomRenderer(term),el=term.element;
 if(!renderer||!el)return ()=>{};
 const original=renderer.renderRows,own=Object.prototype.hasOwnProperty.call(renderer,'renderRows');
 const guarded:typeof original=function(this: typeof renderer,start,end){
  // The common hidden-tab case needs no synchronous layout read at all. The box
  // check also covers CSS-hidden terminal surfaces and detached clients.
  if(el.closest('.xterm-tab')?.classList.contains('is-hidden')||!el.getClientRects().length)return;
  original.call(this,start,end);
 };
 renderer.renderRows=guarded;
 return ()=>{
  if(renderer.renderRows!==guarded)return;
  if(own)renderer.renderRows=original;
  else delete (renderer as unknown as {renderRows?:typeof original}).renderRows;
 };
}
