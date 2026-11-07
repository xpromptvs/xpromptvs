import type { Transport } from "../connection";
import type { LayoutMode } from "../layout-mode";
import type { ClientE2EIdentity } from "../e2e-identity";
import type { ClientPlatform } from "./platform";

export type ClientConnection =
  | { kind: "remote"; code: string; token: string; pairingCarrier?: string; params?: URLSearchParams }
  | { kind: "transport"; transport: Transport; params?: URLSearchParams };
export interface ClientState {
  phase: "idle" | "connecting" | "connected" | "error" | "closing" | "destroyed";
  text?: string;
}
export interface PreferenceStore {
  get(key: string): string | null;
  set(key: string, value: string): void;
  remove(key: string): void;
}
export interface ClientOptions {
  layout?: LayoutMode;
  persistence?: { namespace: string; storage: Storage };
  platform?: ClientPlatform;
  remote?: { identity: ClientE2EIdentity; signalingEndpoint: string; fetch?: typeof fetch };
}
export interface ClientHandle {
  readonly id: string;
  connect(connection: ClientConnection): boolean;
  cancel(): void;
  disconnect(): void;
  destroy(): void;
  subscribe(listener: (state: Readonly<ClientState>) => void): () => void;
  diagnostics(): Readonly<Record<string, unknown>>;
}
