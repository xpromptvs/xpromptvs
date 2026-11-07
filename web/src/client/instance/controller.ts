import {productFeatures} from "../../shared/product-features";
import { installGlassesNav } from "../glasses-nav";
import { navOrder } from "../spatial-nav";
import { createSessionController, type ControllerDeps, type SessionController } from "../session-lifecycle";
import { createSessionDom } from "../session-dom";
import type { ClientContext } from "./context";
import type { ClientController } from "./mount";
import type { ClientState } from "./types";

export type InstanceControllerAdapter = Partial<Pick<ControllerDeps, "transport" | "sessionRoot" | "welcome" | "motion" | "pin" | "onState" | "onClosed" | "onDisconnect" | "onMoved" | "onRestartFailed">> & {resync?():void; glassesNav?:boolean};
export function createInstanceController(context: ClientContext, report: (state: ClientState) => void, adapter: InstanceControllerAdapter = {}): ClientController & {sessionController:SessionController} {
  let params = new URLSearchParams();
  const controller = createSessionController({
    ...adapter, context, pageParams: () => params, layout: context.presentation.layout,
    dom: createSessionDom(context.get("session"), context.ui, adapter.resync), sessionRoot: adapter.sessionRoot ?? context.get("session"), welcome: adapter.welcome ?? null,
    onState: detail => { report({phase: detail.state === "connected" ? "connected" : detail.state === "error" ? "error" : "connecting", text: detail.text}); adapter.onState?.(detail); },
    onClosed: () => { report({phase: "idle"}); adapter.onClosed?.(); },
    onRestartFailed: text => { report({phase: "error", text}); adapter.onRestartFailed?.(text); },
  });
  let stopNav: (()=>void) | undefined;
  let mode: string | undefined;
  const layout = () => { const next=context.presentation.layout(); if(next===mode)return;mode=next;stopNav?.();stopNav=productFeatures.glasses && adapter.glassesNav !== false && next === "glasses" ? installGlassesNav(()=>controller.current ? navOrder(controller.current.navState()) : [],context.root) : undefined; };
  layout();context.scope.defer(context.onResize(layout));context.scope.defer(()=>stopNav?.());
  return {
    sessionController: controller,
    connect(target) {
      params = new URLSearchParams(target.params);
      if (target.kind === "transport") return controller.connectTransport(target.transport);
      if (!context.options.remote) throw Error("Remote client identity and signaling endpoint are required");
      const pairing = new URLSearchParams({code: target.code, token: target.token});
      return controller.connect(`?${pairing}${target.pairingCarrier ? `#${new URLSearchParams({pair: target.pairingCarrier})}` : ""}`);
    },
    cancel: controller.cancel,
    disconnect: controller.disconnect,
    destroy: controller.dispose,
    diagnostics: () => controller.current?.debug as unknown as Readonly<Record<string, unknown>> ?? {},
  };
}
