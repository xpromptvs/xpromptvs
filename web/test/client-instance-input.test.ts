import { afterEach, expect, it, vi } from "vitest";
import { createClientMount } from "../src/client/instance/mount";
import type { ClientContext } from "../src/client/instance/context";
import type { ClientHandle } from "../src/client/instance/types";
import { attachWindowKeys } from "../src/client/keys";
import { decodeJson } from "../src/lib/codec";

const handles: ClientHandle[] = [];
afterEach(() => { vi.unstubAllGlobals(); handles.splice(0).forEach(h => h.destroy()); document.body.replaceChildren(); });
function fixture() {
  let context!: ClientContext;
  const handle = createClientMount(c => {context=c; return {connect:()=>false,cancel(){},disconnect(){},destroy(){}};})(document.body.appendChild(document.createElement("div")));
  handles.push(handle);
  const body = context.ui.appendChild(document.createElement("div")); body.tabIndex=0;
  const messages: unknown[]=[];
  const channel = Object.assign(new EventTarget(), {label:"input",readyState:"open" as const,binaryType:"arraybuffer" as const,
    send(data: string | ArrayBuffer | ArrayBufferView) { messages.push(typeof data === "string" ? JSON.parse(data) : decodeJson(ArrayBuffer.isView(data) ? new Uint8Array(data.buffer,data.byteOffset,data.byteLength) : new Uint8Array(data))); }});
  attachWindowKeys(body,channel,()=>true);
  return {handle,context,body,messages};
}
it("switching focus releases old modifiers without forwarding keys to the old client", () => {
  const a=fixture(), b=fixture();
  a.body.focus(); a.body.dispatchEvent(new KeyboardEvent("keydown",{key:"Meta",code:"MetaLeft",metaKey:true,bubbles:true,composed:true}));
  b.body.focus();
  expect(a.messages).toHaveLength(2);
  expect(a.messages[1]).toEqual({t:"win-keys-release"});
  b.body.dispatchEvent(new KeyboardEvent("keydown",{key:"b",code:"KeyB",bubbles:true,composed:true}));
  expect(b.messages).toHaveLength(1); expect(a.messages).toHaveLength(2);
});
it("destroying an unfocused client does not clear the focused client's release callback", () => {
  const a=fixture(), b=fixture(); b.body.focus();
  a.handle.destroy(); window.dispatchEvent(new Event("blur"));
  expect(b.messages).toEqual([{t:"win-keys-release"}]);
});
it("destroying the focused client releases held keys exactly once", () => {
  const a=fixture(); a.body.focus(); a.handle.destroy();
  window.dispatchEvent(new Event("blur"));
  window.dispatchEvent(new Event("blur"));
  expect(a.messages).toEqual([{t:"win-keys-release"}]);
});
it("glasses keyboard suppression follows its own layout rather than the page", () => {
  const contexts: ClientContext[]=[];
  const mount = createClientMount(c=>{contexts.push(c); return {connect:()=>false,cancel(){},disconnect(){},destroy(){}};});
  const a = mount(document.body.appendChild(document.createElement("div")),{layout:"glasses"}); handles.push(a);
  const c=contexts[0]!, body=c.ui.appendChild(document.createElement("div")); body.tabIndex=0;
  let sent=0;
  attachWindowKeys(body,Object.assign(new EventTarget(),{label:"input",readyState:"open" as const,binaryType:"arraybuffer" as const,send(){sent++;}}),()=>true);
  body.focus(); body.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",code:"ArrowDown",bubbles:true,composed:true}));
  expect(sent).toBe(0);
});
it("keys pressed after returning from application blur are released on the next blur", () => {
  const a=fixture(); a.body.focus(); window.dispatchEvent(new Event("blur"));
  a.messages.length=0;
  a.body.dispatchEvent(new KeyboardEvent("keydown",{key:"Meta",code:"MetaLeft",metaKey:true,bubbles:true,composed:true}));
  window.dispatchEvent(new Event("blur"));
  expect(a.messages.at(-1)).toEqual({t:"win-keys-release"});
});

it("page-owned glasses navigation enters the revealed shadow client from outside focus", async () => {
  vi.stubGlobal('CSS',{escape:(value:string)=>value});
  const {installGlassesNav}=await import('../src/client/glasses-nav');
  const a=fixture();a.context.presentation.setLayout('glasses');
  const button=a.context.ui.appendChild(document.createElement('button'));button.dataset.navId='first';
  const outside=document.body.appendChild(document.createElement('input'));outside.focus();
  const stop=installGlassesNav(()=>['first'],()=>a.context.root);
  try{outside.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,composed:true}));expect(a.context.activeElement()).toBe(button);}finally{stop();}
});
