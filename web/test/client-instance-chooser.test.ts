import { afterEach, expect, it, vi } from "vitest";
import { createClientMount } from "../src/client/instance/mount";
import type { ClientContext } from "../src/client/instance/context";
import type { ClientHandle } from "../src/client/instance/types";
import { openSelectChooser } from "../src/client/glasses-chooser";
const handles:ClientHandle[]=[];
afterEach(()=>{handles.splice(0).forEach(h=>h.destroy());document.body.replaceChildren();vi.restoreAllMocks();});
function fixture(){
 let c!:ClientContext;const h=createClientMount(ctx=>{c=ctx;return {connect:()=>false,cancel(){},disconnect(){},destroy(){}};})(document.body.appendChild(document.createElement('div')),{layout:'glasses'});handles.push(h);
 const select=c.ui.appendChild(document.createElement('select'));select.innerHTML='<option value="one">One</option><option value="two">Two</option>';
 return {c,select,h};
}
it('embedded choosers keep separate selections and never write page history',()=>{
 const a=fixture(),b=fixture(),push=vi.spyOn(history,'pushState'),back=vi.spyOn(history,'back');
 a.select.focus();openSelectChooser(a.select);b.select.focus();openSelectChooser(b.select);
 const left=a.c.root.querySelector<HTMLElement>('[data-value="two"]'),right=b.c.root.querySelector<HTMLElement>('[data-value="two"]');
 expect(left).not.toBeNull();expect(right).not.toBeNull();
 left!.click();expect(a.select.value).toBe('two');expect(b.select.value).toBe('one');expect(b.c.activeElement()?.closest('#glasses-chooser')).not.toBeNull();
 a.h.destroy();expect(right!.isConnected).toBe(true);expect(push).not.toHaveBeenCalled();expect(back).not.toHaveBeenCalled();
});
it('a background chooser does not take focus from its sibling',()=>{
 const a=fixture(),b=fixture();b.select.focus();openSelectChooser(a.select);
 expect(b.c.activeElement()).toBe(b.select);
});
