import type {Delivery} from '../paste-upload';
import type { ClientPrefs } from "../../shared/client-prefs";
import type { WindowManagerOptions, WindowManager, WindowView } from "../window-manager";
import type { SimStateWire } from "../source-picker";
import type { PasteUIDeps } from "../paste-ui";
import type {NativeScrollBatch} from './scroll';

/** Native identities belong to one logical connection and one source presentation lifetime. */
export interface SourceWindowKey {
  readonly owner: number;
  readonly generation: number;
  readonly source: string;
  readonly incarnation: number;
}
export function sameSourceWindowKey(a: SourceWindowKey | undefined, b: SourceWindowKey): boolean {
  return !!a && a.owner === b.owner && a.generation === b.generation && a.source === b.source && a.incarnation === b.incarnation;
}
export function validSourceWindowKey(key: SourceWindowKey): boolean {
  return [key.owner, key.generation, key.incarnation].every(n => Number.isSafeInteger(n) && n > 0)
    && typeof key.source === 'string' && key.source.length > 0 && new TextEncoder().encode(key.source).length <= 256;
}

/** References cross the proven related-view WindowProxy directly; stream is never serialized/cloned. */
export interface SourceWindowSnapshot {
  key: SourceWindowKey;
  revision: number;
  view: WindowView;
  stream?: MediaStream;
  driving: boolean;
  nativeKey: boolean;
  minimized: boolean;
  prefs: ClientPrefs;
  theme: "dark" | "light";
  smooth: boolean;
  locallyMuted: boolean;
  inputState?: {state:"inactive"|"waiting"|"ready"|"unavailable";reason?:string;scrollGestures?:readonly string[]};
  size?: { w: number; h: number };
  pixelSize?: { w: number; h: number };
  live?: boolean;
  simState?: SimStateWire;
  cursor?: { url: string | null; x: number; y: number; overlay?: { url: string; w: number; h: number } };
  recovery?: number | null;
  playoutDelay?: number | null;
  curtain?: boolean | null;
}
export type SourceWindowAction =
  | { type: "settings" | "fit" | "releaseInput" | "resendDerived" | "pointerMode" | "resetView" | "closeSettings" | "suspendWorkspaces" | "attachPacer" | "failPacer" | "releasePacer" | "resetPacerStats" }
  | { type: "menu"; x: number; y: number }
  | { type: "viewMode"; value: "input" | "zoom" }
  | { type: "pacerMargin"; value: number | "auto" }
  | { type: "resizeHold"; value: boolean };
export interface SourceWindowConnection {
  current(): boolean;
  options: Omit<WindowManagerOptions, "inputChannel" | "prefs" | "onWindowMenu" | "onWindowDrop">;
  sendInput(data: string | ArrayBuffer | ArrayBufferView): void;
  paste?: Pick<PasteUIDeps, "uploader"> & {subscribeProgress?(listener:(sent:number,total:number,delivery:Delivery)=>void):()=>void};
  smoothChanged?(enabled: boolean): void;
  presentationChanged?(): void;
  reportError?(error: unknown): void;
}
export interface SourceWindowController {
  connect(connection: SourceWindowConnection): boolean;
  update(snapshot: SourceWindowSnapshot): void;
  action(action: SourceWindowAction): boolean;
  video(): HTMLVideoElement | undefined;
  autoDebug(): ReturnType<WindowManager["autoDebug"]>;
  viewDebug(): ReturnType<WindowManager["viewDebug"]>;
  pacerStats(): ReturnType<WindowManager["pacerStats"]>;
  releaseInput(): void;
  dispose(): void;
}
export interface NativeSourceDocumentBridge {
  key: SourceWindowKey;
  nativeScrollEnabled?: boolean;
  ready?(): Promise<unknown>;
  onResizeHold?(callback: (held: boolean) => void): () => void;
  onScroll?(callback:(batch:NativeScrollBatch)=>void):()=>void;
  pasteboardFiles?(): Promise<unknown>;
  preparePaste?(paths: string[]): Promise<unknown>;
  discardPaste?(urls: string[]): Promise<unknown>;
  cancelPaste?(): Promise<unknown>;
}
