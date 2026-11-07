import type { NativeSourceWindowAPI } from "../native-source/api";
import type { LocalPasteApi } from "../paste-local";
/** Capabilities are bound by the enclosing application, never discovered from window by a client. */
export interface ClientPlatform {
  native?: Partial<NativeSourceWindowAPI> & {
    activateSimulator?(source: string): void;
    simulatorTheme?(theme: string): void;
    openMacs?(): void;
    sharing?(): Promise<unknown>;
    onSharing?(cb: (on: boolean) => void): () => void;
    issueGrant?(keys: string): Promise<string>;
    identity?(): Promise<string>;
    writeClipboard?(text: string): Promise<boolean>;
  };
  localPaste?: LocalPasteApi | null;
  bell?(count: number): void;
  requestFullscreen?(element: HTMLElement): Promise<void>;
  exitFullscreen?(): void;
  onFullscreenLeft?(callback:()=>void):()=>void;
  close?(): void;
  reportError?(error: unknown): void;
}
