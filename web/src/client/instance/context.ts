import { createSelectChooser } from "../glasses-chooser";
import { SessionScope } from "../session-scope";
import type { ClientOptions, PreferenceStore } from "./types";
import type { ClientPlatform } from "./platform";
import { createPresentation } from "./presentation";
import { randomUUID } from "../../lib/resume-id";
import { observeClientViewport } from "./viewport";
import { chooseLayoutMode } from "../layout-mode";
import { preferenceStorage, createSmoothPreference } from "./preferences";
import { ResizeSettle } from "../resize-settle";
import { createClientInput } from "./input";
import { createClientOverlays } from "./overlays";

const contexts = new WeakMap<Node, ClientContext>();
/** The element supplied by the caller identifies its owner; there is no ambient active instance. */
export function contextFor(element: Node): ClientContext | undefined { return contexts.get(element.getRootNode()); }
export function presentationRoot(element: Node): HTMLElement { return contextFor(element)?.ui ?? element.ownerDocument!.documentElement; }
export function queryRoot(element: Node): Document | ShadowRoot { return contextFor(element)?.root ?? element.ownerDocument!; }
export function activeWithin(element: Node): Element | null { const c = contextFor(element); return c ? c.activeElement() : element.ownerDocument!.activeElement; }

export interface ClientEnvironment {
  resumeId?: string;
  preferences?: PreferenceStore;
  pageHistory?: boolean;
  pairingCommitted?(): void;
}
export interface ClientContext {
  readonly environment: ClientEnvironment;
  readonly id: string;
  readonly resumeId: string;
  readonly scope: SessionScope;
  readonly root: ShadowRoot;
  readonly ui: HTMLElement;
  readonly preferences: PreferenceStore;
  onPreference(callback: (key: string) => void): () => void;
  readonly storage: ReturnType<typeof preferenceStorage>;
  readonly smooth: ReturnType<typeof createSmoothPreference>;
  readonly resizeSettle: ResizeSettle;
  readonly input: ReturnType<typeof createClientInput>;
  readonly chooser: ReturnType<typeof createSelectChooser>;
  readonly overlays: ReturnType<typeof createClientOverlays>;
  readonly platform: ClientPlatform;
  readonly options: ClientOptions;
  readonly presentation: ReturnType<typeof createPresentation>;
  readonly viewport: ReturnType<typeof observeClientViewport>;
  onResize(callback: () => void): () => void;
  get<T extends HTMLElement = HTMLElement>(id: string): T;
  activeElement(): Element | null;
}
export function createClientContext(id: string, root: ShadowRoot, ui: HTMLElement, backing: PreferenceStore, options: ClientOptions, environment: ClientEnvironment = {}): ClientContext {
  backing=environment.preferences ?? backing;
  const scope = new SessionScope(), changes = new Set<() => void>();
  // Registered first: descendants retain their owner while closing during LIFO disposal.
  scope.defer(() => contexts.delete(root));
  const preferenceListeners = new Set<(key: string) => void>();
  const preferences: PreferenceStore = {
    get: key => backing.get(key),
    set(key, value) { backing.set(key,value); for (const fn of [...preferenceListeners]) fn(key); },
    remove(key) { backing.remove(key); for (const fn of [...preferenceListeners]) fn(key); },
  };
  const presentation = createPresentation(ui, options.layout);
  const evaluate = () => {
    // An explicit layout does not depend on geometry. Avoid forcing style/layout
    // while the new surface is still being configured by its embedder.
    if (options.layout) presentation.setLayout(options.layout);
    else {
      const win = ui.ownerDocument.defaultView!;
      const r = ui.getBoundingClientRect();
      presentation.setLayout(chooseLayoutMode({width:r.width,height:r.height,
        coarsePointer: win.matchMedia?.("(pointer: coarse)").matches ?? false,
        screen: {width:win.screen.width,height:win.screen.height}}, null));
    }
    for (const changed of [...changes]) changed();
  };
  const viewport = observeClientViewport(ui, scope, evaluate);
  const context: ClientContext = {
    id, environment, resumeId: environment.resumeId ?? randomUUID(), root, ui, preferences, storage: preferenceStorage(preferences),
    smooth: createSmoothPreference(preferences), resizeSettle: new ResizeSettle(), input: createClientInput(root, scope),
    overlays: createClientOverlays(root,ui,scope),
    chooser: createSelectChooser({root,container:ui,history:environment.pageHistory === true}),
    options, scope, platform: options.platform ?? {},
    presentation, viewport,
    onPreference(callback) { preferenceListeners.add(callback); return () => { preferenceListeners.delete(callback); }; },
    onResize(callback) { changes.add(callback); return () => { changes.delete(callback); }; },
    get<T extends HTMLElement>(id: string): T {
      const element = root.getElementById(id);
      if (!element) throw Error(`Client element missing: ${id}`);
      return element as T;
    },
    activeElement() {
      let active = root.activeElement;
      while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
      return active;
    },
  };
  scope.defer(()=>context.chooser.dispose(),"chooser");
  contexts.set(root, context);
  scope.defer(() => { changes.clear(); preferenceListeners.clear(); context.smooth.dispose(); });
  evaluate();
  return context;
}
