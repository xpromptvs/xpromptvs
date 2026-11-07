import { afterEach, expect, it } from "vitest";
import { createClientMount } from "../src/client/instance/mount";
import type { ClientContext } from "../src/client/instance/context";
import type { ClientHandle } from "../src/client/instance/types";
import { openClientDialog, closeClientDialog } from "../src/client/instance/overlays";
const handles: ClientHandle[]=[];
afterEach(()=>{handles.splice(0).forEach(h=>h.destroy());document.body.replaceChildren();});
function fixture() {
  let context!: ClientContext;
  handles.push(createClientMount(c=>{context=c;return {connect:()=>false,cancel(){},disconnect(){},destroy(){}};})(document.body.appendChild(document.createElement("div"))));
  return context;
}
it("a dialog blocks only its own content and closing it preserves sibling focus", () => {
  const a=fixture(),b=fixture();
  const da=a.get<HTMLDialogElement>("paste-lines-dialog"), db=b.get<HTMLDialogElement>("paste-lines-dialog");
  const button=b.get<HTMLButtonElement>("palette-open"); button.focus();
  openClientDialog(da);
  expect(da.open).toBe(true); expect(db.open).toBe(false);
  expect(a.root.querySelector<HTMLElement>(".client-body")!.inert).toBe(true);
  expect(b.root.querySelector<HTMLElement>(".client-body")!.inert).not.toBe(true);
  expect(b.activeElement()).toBe(button);
  closeClientDialog(da);
  expect(da.open).toBe(false); expect(b.activeElement()).toBe(button);
});
it("closing one dialog does not close another and restores each original parent", () => {
  const a=fixture(),b=fixture(),da=a.get<HTMLDialogElement>("paste-lines-dialog"),db=b.get<HTMLDialogElement>("paste-lines-dialog");
  const parent=da.parentElement;
  openClientDialog(da);openClientDialog(db);
  expect(da.parentElement).not.toBe(parent);
  closeClientDialog(da);
  expect(da.parentElement).toBe(parent); expect(db.open).toBe(true);
  closeClientDialog(db);
});
it("a close callback moving focus to a sibling wins over focus restoration", () => {
  const a=fixture(),b=fixture(),button=a.get<HTMLButtonElement>("palette-open"),other=b.get<HTMLButtonElement>("palette-open");
  const dialog=a.get<HTMLDialogElement>("paste-lines-dialog");
  button.focus();openClientDialog(dialog);
  dialog.addEventListener("close",()=>other.focus());
  closeClientDialog(dialog);
  expect(b.activeElement()).toBe(other);
});
it("a late identity result cannot reopen a destroyed client's dialog", async () => {
  const {mountE2ESetup}=await import('../src/shared/e2e-setup');
  const a=fixture(),b=fixture(),dialog=a.get<HTMLDialogElement>('e2e-setup');
  let finish!: (value: {ok:true;deviceId:string;rootId:string})=>void;
  mountE2ESetup(dialog,{enroll:()=>new Promise(resolve=>finish=resolve),pending:async()=>({resume:false,discard:false}),discard:async()=>({ok:true}),done(){}},
   {open:d=>openClientDialog(d as HTMLDialogElement),close:d=>closeClientDialog(d as HTMLDialogElement),signal:a.scope.signal});
  [...dialog.querySelectorAll('button')].find(b=>b.textContent==='Create a passkey')!.click();
  b.get<HTMLButtonElement>('palette-open').focus();handles[0]!.destroy();
  finish({ok:true,deviceId:'device',rootId:'identity'});await Promise.resolve();await Promise.resolve();
  expect(dialog.open).toBe(false);expect(b.activeElement()).toBe(b.get('palette-open'));
});
