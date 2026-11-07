import { createClientMount } from "./instance/mount";
import { createInstanceController } from "./instance/controller";
export const mountClient = createClientMount(createInstanceController);
export type { ClientConnection, ClientHandle, ClientOptions, ClientState } from "./instance/types";

// Explicit identity construction for embedders; importing this creates no identity or storage IO.
export { ClientE2EIdentity } from "./e2e-identity";
export { IndexedDBInstallationBackend } from "../lib/installation-idb";
export type { ClientPlatform } from "./instance/platform";
export type { Transport } from "./connection";
