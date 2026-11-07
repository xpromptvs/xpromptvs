import { afterEach, expect, it } from "vitest";
import { createClientMount } from "../src/client/instance/mount";
import { createSessionController } from "../src/client/session-lifecycle";
import { createSessionDom } from "../src/client/session-dom";
import type { ClientHandle } from "../src/client/instance/types";
import type { Session, SessionHost, SessionOptions } from "../src/client/session";

const handles: ClientHandle[] = [];
afterEach(() => { handles.splice(0).forEach(h => h.destroy()); document.body.replaceChildren(); });
it("controllers keep state, debug hooks and lifecycle confined to their own instances", () => {
  const made: Array<{ options: SessionOptions; host: SessionHost; disposed: boolean }> = [];
  const globalDebug = { sentinel: true };
  Object.defineProperty(window, "__rdev", { configurable: true, value: globalDebug });
  const pageEvents: Event[] = [];
  const eventListener = (e: Event) => pageEvents.push(e);
  document.addEventListener("shellstorm:connection-state", eventListener);
  const mount = createClientMount((context, report) => {
    const controller = createSessionController({
      context, onState: s => report({ phase: s.state === "connected" ? "connected" : "connecting", text: s.text }),
      pageParams: () => new URLSearchParams(), layout: context.presentation.layout,
      sessionRoot: context.get("session"), welcome: null,
      dom: createSessionDom(context.get("session"), context.ui),
      create(options, host) {
        const entry = {options, host, disposed: false}; made.push(entry);
        return { debug: {role: "client"}, navState: () => ({}), leave() {}, dispose() { entry.disposed = true; }, get disposed() { return entry.disposed; } } as Session;
      },
    });
    return { connect: () => controller.connect("?code=same&token=secret"), cancel: controller.cancel,
      disconnect: controller.disconnect, destroy: controller.dispose };
  });
  try {
    const a = mount(document.body.appendChild(document.createElement("div")));
    const b = mount(document.body.appendChild(document.createElement("div")));
    handles.push(a,b);
    const aStates: string[] = [], bStates: string[] = [];
    a.subscribe(s => aStates.push(s.phase)); b.subscribe(s => bStates.push(s.phase));
    const target = {kind: "remote" as const, code: "same", token: "secret"};
    a.connect(target); b.connect(target);
    expect(made).toHaveLength(2);
    expect(made[0]!.options.context?.resumeId).not.toBe(made[1]!.options.context?.resumeId);
    expect(made[0]!.options.context?.resumeId).toBeTruthy();
    made[0]!.host.state({state:"connected",text:"a"});
    expect(aStates).toEqual(["idle","connecting","connected"]);
    expect(bStates).toEqual(["idle","connecting"]);
    a.destroy(); made[0]!.host.state({state:"connected",text:"late"});
    expect(made[0]!.disposed).toBe(true); expect(made[1]!.disposed).toBe(false);
    expect(pageEvents).toHaveLength(0);
    expect((window as unknown as {__rdev: unknown}).__rdev).toBe(globalDebug);
    expect(document.body.style.position).toBe("");
  } finally { document.removeEventListener("shellstorm:connection-state", eventListener); }
});
