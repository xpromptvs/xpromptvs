import { randomUUID } from "../../lib/resume-id";
import { createClientContext, type ClientContext, type ClientEnvironment } from "./context";
import { reservePreferences } from "./preferences";
import { createClientSurface } from "./surface";
import type { ClientConnection, ClientHandle, ClientOptions, ClientState } from "./types";

export interface ClientController {
  connect(connection: ClientConnection): boolean;
  cancel(): void;
  disconnect(): void;
  destroy(): void;
  diagnostics?(): Readonly<Record<string, unknown>>;
}
type ControllerFactory = (context: ClientContext, report: (state: ClientState) => void) => ClientController;
const mounted = new WeakSet<HTMLElement>();

/** Internal composition seam: the public embed entry binds the real session controller here. */
export function createClientMount(create: ControllerFactory, environment: ClientEnvironment = {}) {
  return function mountClient(container: HTMLElement, options: ClientOptions = {}): ClientHandle {
    if (mounted.has(container)) throw Error("Client container is already mounted");
    const preferences = reservePreferences(options.persistence);
    let surface: ReturnType<typeof createClientSurface>;
    try { surface = createClientSurface(container); }
    catch (error) { preferences.release(); throw error; }
    const { host, root, ui } = surface;
    const id = randomUUID();
    let context: ClientContext;
    try { context = createClientContext(id, root, ui, preferences.store, options, environment); }
    catch (error) { surface.destroy(); preferences.release(); throw error; }
    let state: Readonly<ClientState> = Object.freeze({ phase: "idle" });
    const listeners = new Set<(state: Readonly<ClientState>) => void>();
    let destroyed = false;
    let occupied = false;
    const reportError = (error: unknown) => {
      try { context.platform.reportError?.(error); } catch { /* an embedding callback cannot interrupt cleanup */ }
    };
    const notify = (next: ClientState) => {
      if (destroyed) return;
      state = Object.freeze({ ...next });
      if (next.phase === "idle") occupied = false;
      const snapshot = state;
      for (const listener of [...listeners]) {
        if (destroyed || state !== snapshot) break;
        if (listeners.has(listener)) { try { listener(snapshot); } catch (error) { reportError(error); } }
      }
    };
    void surface.ready.catch(error => { if (!destroyed) { ui.dataset.assetError = "fonts"; reportError(error); } });
    mounted.add(container);
    let controller: ClientController;
    function cleanup() {
      context.scope.dispose(); surface.destroy(); preferences.release(); mounted.delete(container);
    }
    try {
      container.appendChild(host);
      controller = create(context, notify);
    } catch (error) { destroyed = true; cleanup(); throw error; }
    return {
      id,
      connect(connection) {
        if (destroyed) throw Error("Client has been destroyed");
        if (occupied) return false;
        occupied = true;
        notify({ phase: "connecting" });
        if (destroyed || !occupied) return false;
        try {
          const started = controller.connect(connection);
          if (!started && occupied && !destroyed && state.phase !== "closing") { occupied = false; notify({ phase: "error", text: "Could not start the session." }); }
          return started;
        } catch (error) {
          occupied = false; reportError(error);
          notify({ phase: "error", text: "Could not start the session." }); return false;
        }
      },
      cancel() { if (!destroyed && state.phase !== "closing") { controller.cancel(); occupied = false; notify({ phase: "idle" }); } },
      disconnect() {
        if (destroyed || !occupied || state.phase === "closing") return;
        notify({phase:"closing"});
        if (!destroyed) controller.disconnect();
      },
      destroy() {
        if (destroyed) return;
        // Fence re-entrancy and late callbacks before calling any user/component cleanup.
        destroyed = true;
        try { controller.destroy(); } catch (error) { reportError(error); }
        finally { cleanup(); }
        state = Object.freeze({ phase: "destroyed" });
        for (const listener of [...listeners]) { try { listener(state); } catch (error) { reportError(error); } }
        listeners.clear();
      },
      subscribe(listener) {
        if (!destroyed) listeners.add(listener);
        try { listener(state); } catch (error) { reportError(error); }
        return () => { listeners.delete(listener); };
      },
      diagnostics: () => {
        if (destroyed) return {id, phase: "destroyed"};
        const debug = controller.diagnostics?.() ?? {};
        return {...Object.fromEntries(Object.getOwnPropertyNames(debug).map(key => [key, debug[key]])), id, phase: state.phase};
      },
    };
  };
}
