import { contextFor } from "./context";
import type { SessionScope } from "../session-scope";

export function createClientOverlays(root: ShadowRoot, ui: HTMLElement, scope: SessionScope) {
  const content = ui.querySelector<HTMLElement>(".client-body")!;
  const layer = ui.appendChild(ui.ownerDocument.createElement("div"));
  layer.className = "client-overlays";
  const opened = new Map<HTMLDialogElement, { close(): void; wrapper: HTMLElement }>();
  let originalInert = false;
  const pageFocus = () => { let el=ui.ownerDocument.activeElement; while(el?.shadowRoot?.activeElement)el=el.shadowRoot.activeElement; return el; };
  const top = () => [...opened.keys()].at(-1);
  const sync = () => { for (const [dialog,entry] of opened) entry.wrapper.inert = dialog !== top(); };
  const close = (dialog: HTMLDialogElement) => opened.get(dialog)?.close();
  scope.listen(root,"keydown", (event) => {
    const e = event as KeyboardEvent, dialog = top();
    if (!dialog) return;
    if(e.key === "Escape") {
      e.preventDefault();e.stopPropagation();
      if(dialog.dispatchEvent(new Event("cancel",{cancelable:true})))close(dialog);
    } else if(e.key === "Tab") {
      const focusable=[...dialog.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]')].filter(el=>!el.hidden && el.getAttribute("aria-hidden") !== "true");
      const index=focusable.indexOf(root.activeElement as HTMLElement);
      if(focusable.length && ((e.shiftKey && index<=0) || (!e.shiftKey && index===focusable.length-1))) {
        e.preventDefault();e.stopPropagation();(e.shiftKey?focusable.at(-1):focusable[0])?.focus({preventScroll:true});
      }
    }
  });
  scope.defer(()=>{for(const dialog of [...opened.keys()].reverse())close(dialog);layer.remove();},"overlays");
  return {
    close,
    open(dialog: HTMLDialogElement, options: {restoreFocus?: HTMLElement} = {}) {
      const existing=opened.get(dialog); if(existing)return existing.close;
      const parent=dialog.parentNode,next=dialog.nextSibling;
      const restore=options.restoreFocus ?? (root.activeElement instanceof HTMLElement ? root.activeElement : undefined);
      const shouldFocus=!!root.activeElement;
      if(!opened.size)originalInert=content.inert;
      const wrapper=layer.appendChild(ui.ownerDocument.createElement("div"));wrapper.className="client-overlay";
      wrapper.appendChild(dialog);dialog.dataset.clientModal="";dialog.setAttribute("open","");dialog.setAttribute("aria-modal","true");
      content.inert=true;
      let closed=false;
      const finish=()=>{
        if(closed)return;closed=true;
        const focused=!!root.activeElement && wrapper.contains(root.activeElement);
        opened.delete(dialog);dialog.removeAttribute("open");dialog.removeAttribute("data-client-modal");dialog.removeAttribute("aria-modal");
        if(parent)parent.insertBefore(dialog,next?.parentNode===parent?next:null);else dialog.remove();
        wrapper.remove();content.inert=opened.size>0?true:originalInert;sync();
        const afterRemoval=pageFocus();
        dialog.dispatchEvent(new Event("close"));
        if(focused && pageFocus() === afterRemoval && !scope.disposed && restore?.isConnected && !restore.closest("[inert]"))restore.focus({preventScroll:true});
      };
      opened.set(dialog,{close:finish,wrapper});sync();
      wrapper.addEventListener("click",e=>{if(e.target===wrapper && dialog.dispatchEvent(new Event("cancel",{cancelable:true})))finish();});
      if(shouldFocus)dialog.querySelector<HTMLElement>('[autofocus],button:not(:disabled),input:not(:disabled),[tabindex="0"]')?.focus({preventScroll:true});
      return finish;
    },
  };
}

export function openClientDialog(dialog: HTMLDialogElement): void {
  const context=contextFor(dialog);
  if(context){context.overlays.open(dialog);return;}
  if(!dialog.open) { if(typeof dialog.showModal === "function")dialog.showModal();else dialog.setAttribute("open",""); }
}
export function closeClientDialog(dialog: HTMLDialogElement | null | undefined): void {
  if(!dialog)return;
  const context=contextFor(dialog);
  if(context && dialog.hasAttribute("data-client-modal")){context.overlays.close(dialog);return;}
  if(typeof dialog.close === "function")dialog.close();else dialog.removeAttribute("open");
}
