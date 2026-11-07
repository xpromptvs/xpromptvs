/**
 * The signaling origin, as a WebSocket base with no trailing slash.
 *
 * In a browser this is the page's own origin — the identical expression the client has always
 * used, which is the point: the Cloudflare-served client is UNMODIFIED, not "still supported".
 *
 * The native app is the only caller that diverges. Its client window is served from `app://client/`,
 * whose origin is not an http(s) one at all, so the shell injects the control plane's origin through
 * a bridge script it installs at document start (`app/Sources/BridgeScripts.swift`). The ws
 * conversion stays HERE so there is one place that knows the rule.
 *
 * NOTE the key is `__rdevShell`, deliberately NOT `__rdev`: `lib/debug.ts` assigns `globalThis.__rdev`
 * wholesale, and the bridge script defines a NON-WRITABLE property (as Electron's
 * `contextBridge.exposeInMainWorld` did before it) — so sharing the name would make that assignment
 * throw in strict mode and take the client down at startup.
 */
export function signalingBase(): string {
  const injected = (globalThis as { __rdevShell?: { signalingBase?: string } }).__rdevShell?.signalingBase;
  const origin = injected && injected.length > 0 ? injected : location.origin;
  return origin.replace(/^http/, "ws").replace(/\/+$/, "");
}

/**
 * The http(s) origin §10.1's policy is about: the party that may run a ceremony.
 *
 * In a browser it is `location.origin`, and that is not configurable — the browser's version of the
 * rule `E2EOrigin` enforces on the Mac. Under `app://client/` there IS no such origin, and the
 * renderer cannot run a ceremony at all (§2, profile P-A); what it needs the value for is
 * VERIFYING — the chain the app issues it was signed in a ceremony at the control plane's origin,
 * and a chain checked under the wrong policy is refused for a reason that names neither.
 *
 * Same injected value as `signalingBase`, without the ws conversion: one place knows the rule.
 */
export function ceremonyOrigin(): string {
  const shell = (globalThis as {
    __rdevShell?: { e2eOrigin?: string; signalingBase?: string };
  }).__rdevShell;
  // The app's OWN value first: it knows which origin it enrolled against (`RDEV_E2E_ORIGIN`), and
  // that is not always the signalling base. Guessing disagrees exactly when it matters.
  const injected = shell?.e2eOrigin ?? shell?.signalingBase;
  const origin = injected && injected.length > 0 ? injected : location.origin;
  return origin.replace(/\/+$/, "");
}

/**
 * The Control Plane's http(s) origin — where `/directory`, `/credential` and `/pair` live.
 *
 * **NOT `ceremonyOrigin()`, and the difference is real.** That one is where a passkey CEREMONY ran,
 * which the app can override with `RDEV_E2E_ORIGIN`; this is where the Worker is. They are the same
 * string in a browser and can differ inside the app, and asking the wrong one produces a 404 that
 * names neither.
 */
export function controlPlaneOrigin(): string {
  return signalingBase().replace(/^ws/, "http");
}

/** The shell's §10.3 issuer, when this renderer is running inside the app. Null in a browser. */
export function shellGrantIssuer(): ((keys: string) => Promise<string>) | null {
  const shell = (globalThis as { __rdevShell?: { issueGrant?: (k: string) => Promise<string> } }).__rdevShell;
  return typeof shell?.issueGrant === "function" ? shell.issueGrant.bind(shell) : null;
}

/**
 * §10.1's readable code for the root the SHELL holds, or null in a browser (there is no shell) and
 * on any shell too old to answer. Null means "nothing to compare", never "they match".
 */
export function shellIdentity(): (() => Promise<string>) | null {
  const shell = (globalThis as { __rdevShell?: { e2eIdentity?: () => Promise<string> } }).__rdevShell;
  return typeof shell?.e2eIdentity === "function" ? shell.e2eIdentity.bind(shell) : null;
}
