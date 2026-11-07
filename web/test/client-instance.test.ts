import { afterEach, expect, it, vi } from "vitest";
import { createClientMount } from "../src/client/instance/mount";
import type { ClientContext } from "../src/client/instance/context";
import type { ClientHandle } from "../src/client/instance/types";

const handles: ClientHandle[] = [];
afterEach(() => { for (const h of handles.splice(0)) h.destroy(); document.body.replaceChildren(); });
function container() { return document.body.appendChild(document.createElement("section")); }
const idle = () => ({ connect: () => false, cancel() {}, disconnect() {}, destroy() {} });

it("rejects duplicate mount without changing the first client or unrelated children", () => {
  const mount = createClientMount(idle), el = container();
  const outside = el.appendChild(document.createElement("p"));
  const a = mount(el); handles.push(a);
  const owned = el.lastElementChild;
  expect(() => mount(el)).toThrow(/already mounted/);
  expect(el.firstElementChild).toBe(outside);
  expect(el.lastElementChild).toBe(owned);
  a.destroy(); expect(el.children).toHaveLength(1);
  expect(el.firstElementChild).toBe(outside);
});

it("destroy is idempotent, allows remount, and leaves its sibling live", () => {
  const mount = createClientMount(idle), el = container();
  const a = mount(el), b = mount(container()); handles.push(a, b);
  const states: string[] = []; b.subscribe(s => states.push(s.phase));
  a.destroy(); a.destroy();
  expect(states).toEqual(["idle"]);
  expect(() => a.connect({ kind: "remote", code: "a", token: "b" })).toThrow(/destroyed/);
  const next = mount(el); handles.push(next);
  expect(next.id).not.toBe(a.id);
  expect(next.id).not.toBe(b.id);
});

it("failed mount releases ownership, partial resources and persistent namespace", () => {
  let released = 0;
  const el = container(), options = { persistence: { namespace: "failed", storage: localStorage } };
  expect(() => createClientMount(context => {
    context.scope.defer(() => released++);
    throw new Error("broken initializer");
  })(el, options)).toThrow("broken initializer");
  expect(released).toBe(1); expect(el.children).toHaveLength(0);
  handles.push(createClientMount(idle)(el, options));
});

it("fences callbacks and releases only the destroyed instance", () => {
  const contexts: ClientContext[] = [], events: string[] = [];
  const mount = createClientMount(context => { contexts.push(context); return idle(); });
  const a = mount(container()), b = mount(container()); handles.push(a, b);
  const lateA = contexts[0]!.scope.guard(() => events.push("a"));
  const lateB = contexts[1]!.scope.guard(() => events.push("b"));
  a.destroy(); lateA(); lateB(); expect(events).toEqual(["b"]);
});

it("uses scoped lookup and deepest focus inside nested shadow roots", () => {
  let ctx!: ClientContext;
  handles.push(createClientMount(context => { ctx = context; return idle(); })(container()));
  document.body.insertAdjacentHTML("beforeend", '<input id="duplicate">');
  ctx.ui.innerHTML = '<input id="duplicate"><div id="nested"></div>';
  expect(ctx.get("duplicate")).not.toBe(document.getElementById("duplicate"));
  const nested = ctx.get("nested").attachShadow({ mode: "open" });
  const input = nested.appendChild(document.createElement("input")); input.focus();
  expect(ctx.activeElement()).toBe(input);
});

it("refuses another connection while occupied and filters late state after destruction", () => {
  let report!: (state: {phase: "connected"}) => void;
  let attempts = 0;
  const mount = createClientMount((_ctx, state) => {
    report = state;
    return { ...idle(), connect() { attempts++; return true; } };
  });
  const a = mount(container()); handles.push(a);
  const states: string[] = []; a.subscribe(s => states.push(s.phase));
  const request = { kind: "transport" as const, transport: { carriesMedia: false, sameMac: false, connect() { throw Error("unused"); } } };
  expect(a.connect(request)).toBe(true); expect(a.connect(request)).toBe(false);
  expect(attempts).toBe(1);
  a.destroy(); report({phase: "connected"});
  expect(states).toEqual(["idle", "connecting", "destroyed"]);
});

it("does not connect when a state listener destroys the client synchronously", () => {
  let attempts = 0;
  const a = createClientMount(() => ({ ...idle(), connect() { attempts++; return true; } }))(container());
  handles.push(a);
  a.subscribe(s => { if (s.phase === "connecting") a.destroy(); });
  expect(a.connect({ kind: "remote", code: "room", token: "secret" })).toBe(false);
  expect(attempts).toBe(0);
});

it("throwing controller cleanup cannot strand the container or prevent sibling cleanup", () => {
  const el = container();
  const a = createClientMount(() => ({...idle(), destroy() { throw Error("cleanup failure"); }}))(el);
  handles.push(a); expect(() => a.destroy()).not.toThrow();
  expect(el.children).toHaveLength(0);
  handles.push(createClientMount(idle)(el));
});

it("does not redeliver destroyed state when a listener destroys during notification", () => {
  const a = createClientMount(() => ({...idle(),connect:()=>true}))(container()); handles.push(a);
  const states: string[]=[];
  a.subscribe(s=>{if(s.phase==='connecting')a.destroy();});
  a.subscribe(s=>states.push(s.phase));
  a.connect({kind:'remote',code:'room',token:'secret'});
  expect(states).toEqual(['idle','destroyed']);
});

it("waits for controller closure before accepting a replacement connection", () => {
  let report!: (s: {phase:'idle'})=>void;
  const a=createClientMount((_c,r)=>{report=r;return {...idle(),connect:()=>true};})(container());handles.push(a);
  const states:string[]=[];a.subscribe(s=>states.push(s.phase));
  const target={kind:'remote' as const,code:'room',token:'secret'};
  a.connect(target);a.disconnect();
  expect(states.at(-1)).toBe('closing');
  expect(a.connect(target)).toBe(false);
  report({phase:'idle'});
  expect(a.connect(target)).toBe(true);
});

it('includes own non-enumerable diagnostic getters in the public snapshot',()=>{
 const debug={};Object.defineProperty(debug,'fastData',{get:()=>({carrier:'webRTC'})});
 const h=createClientMount(()=>({...idle(),diagnostics:()=>debug}))(container());handles.push(h);
 expect(h.diagnostics().fastData).toEqual({carrier:'webRTC'});
});

it('does not force layout to select an explicitly supplied layout mode',()=>{
 const read=vi.spyOn(HTMLElement.prototype,'getBoundingClientRect');
 try {
  let ctx!:ClientContext;
  handles.push(createClientMount(c=>{ctx=c;return idle();})(container(),{layout:'tabbed'}));
  expect(ctx.presentation.layout()).toBe('tabbed');
  expect(read).not.toHaveBeenCalled();
 } finally {read.mockRestore();}
});
