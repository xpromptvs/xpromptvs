import { expect, it } from "vitest";
import { SessionScope } from "../src/client/session-scope";
import { observeClientViewport } from "../src/client/instance/viewport";

it("maps scrolled and offset containers in their own coordinate space", () => {
  const a = document.createElement("div"), b = document.createElement("div");
  let rect = new DOMRect(110, 90, 600, 400);
  a.getBoundingClientRect = () => rect;
  b.getBoundingClientRect = () => new DOMRect(800, 30, 300, 500);
  const scope = new SessionScope();
  const va = observeClientViewport(a, scope, () => {}), vb = observeClientViewport(b, scope, () => {});
  expect(va.toLocal(120, 110)).toEqual({x:10,y:20});
  expect(vb.toLocal(820, 110)).toEqual({x:20,y:80});
  rect = new DOMRect(110, -50, 600, 400);
  expect(va.toLocal(120, 110)).toEqual({x:10,y:160});
  expect(vb.size()).toEqual({width:300,height:500});
  scope.dispose();
});
it("recovers geometry when an initially hidden container becomes visible", () => {
  const el = document.createElement("div"), scope = new SessionScope();
  let rect = new DOMRect(0,0,0,0); el.getBoundingClientRect = () => rect;
  const v = observeClientViewport(el,scope,()=>{});
  expect(v.size()).toEqual({width:0,height:0});
  rect = new DOMRect(50,100,320,480);
  expect(v.size()).toEqual({width:320,height:480}); scope.dispose();
});
