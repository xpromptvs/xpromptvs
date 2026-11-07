import {openClientDialog,closeClientDialog} from "./instance/overlays";
import {contextFor} from "./instance/context";
import { mountE2ESetup } from "../shared/e2e-setup";
import type { CredentialLookup } from "../lib/credential-lookup";
import { canSignalUnknownCredential } from "./webauthn-ceremony";
import type { ClientE2EIdentity } from "./e2e-identity";
import { credentialLookupOutcome } from "../lib/credential-lookup";
import { identityCode } from "@rdev/protocol";
import { controlPlaneOrigin } from "../lib/signaling-base";

/**
 * **Run §10.1's identity panel against a real identity.**
 *
 * ONE implementation, TWO callers: the dashboard, where a person signs in with a passkey before any
 * session exists, and `main.ts`, where a session has started and this browser turns out to hold
 * nothing. They differ only in what happens afterwards — `onDone` — and a second copy of the four
 * steps below is how two entry points come to enrol differently.
 *
 * The DECISION about what a person reads is `e2eSetupView`; this is the part that touches keys.
 */
export function mountIdentitySetup(opts: {
  root: HTMLElement;
  signal?: AbortSignal;
  identity: ClientE2EIdentity;
  /** What to do once the person closes a successful panel. */
  onDone: () => void;
  /** Injected for tests; production asks the Control Plane. */
  lookup?: (credentialId: Uint8Array) => Promise<CredentialLookup>;
}): void {
  const hex = (u: Uint8Array): string =>
    [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
  // **The identity is a CODE; the §10.2 DEVICE id is not.** A device handle is a different thing —
  // nobody holds two screens up to compare one — and rendering it in the identity's format would
  // invite exactly that mistake.
  const identity = (u: Uint8Array): string => identityCode(u);
  // Every failure carries either a specific reason or its own kind; the panel turns known ones into
  // sentences and shows the rest as they are, rather than inventing an explanation for a state it
  // has not been taught.
  const why = (failure: { kind: string } & { failure?: unknown }): string =>
    failure.failure !== undefined ? String(failure.failure) : failure.kind;

  // **`controlPlaneOrigin`, NOT the ceremony origin.** `/credential` is a route on the Worker;
  // §10.1's policy is about where a ceremony may RUN. The two are the same string in a browser and
  // differ inside the app whenever `RDEV_E2E_ORIGIN` is set, and asking the wrong one for a Worker
  // route produces a 404 that names neither.
  const context=contextFor(opts.root);
  const lookup = opts.lookup
    ?? ((credentialId: Uint8Array) => credentialLookupOutcome(context?.options.remote?.signalingEndpoint.replace(/^ws/, "http") ?? controlPlaneOrigin(), credentialId, context ? (context.options.remote?.fetch ?? globalThis.fetch.bind(globalThis)) : undefined));

  // The credential a discovery just failed to resolve, held only long enough for the person to
  // answer the confirmation about it.
  let strandedCredential: Uint8Array | null = null;
  let stranded = false;

  mountE2ESetup(opts.root, {
    enroll: async (source, onStep) => {
      // **The route carries §10.1's obligation, so this is the only place that decides.** Discovery
      // is the one that adopts something this browser did not make, and it is the one that asks.
      strandedCredential = null;
      stranded = false;
      const result = source === "discover"
        ? await (async () => {
            // **ONE CALL AND ONE PROMPT.** This was `discover()` then `enroll({route:"adopt"})`,
            // two ceremonies back to back, because the grant's challenge named a root the first
            // ceremony had to find. §10.4's commitment removed the root from the signed bytes.
            const found = await opts.identity.signIn(lookup);
            // Remembered for the offer, and ONLY when the Worker gave a definite answer — merging
            // the two calls put four different failures behind this one, and three must stay
            // silent. It is cleared on every attempt so a later sign-in can never delete an earlier
            // one's credential.
            stranded = found.stranded;
            strandedCredential = stranded ? found.credentialId ?? null : null;
            return found;
          })()
        : await opts.identity.enroll({ route: source === "resume" ? "resume" : "create" },
                                      () => onStep?.("authorising"));
      // `stranded` has to survive out to the panel — it is what decides whether the failure screen
      // offers deletion at all — and it is set only on the discover route.
      if (!result.ok) return { ok: false, reason: why(result.failure), stranded };
      return {
        ok: true,
        deviceId: result.status.kind === "ready" ? hex(result.status.deviceId) : "",
        rootId: result.status.kind === "ready" ? identity(result.status.rootId) : "",
      };
    },
    // §10.1 route 1's retained material, and the second half of the question: a browser that is
    // already `ready` is offered no setup at all, so the entry is only ever consulted in its
    // absence — which is what confines a stale one to the sign-out case.
    pending: async () => {
      const status = await opts.identity.status();
      if (status.kind === "ready") return { resume: false, discard: false };
      const retained = await opts.identity.hasPendingRoot();
      // **Deleting needs a capability finishing does not.** Offering a button the browser cannot
      // carry out would promise a person their passkey is gone when it is still there.
      return { resume: retained, discard: retained && canSignalUnknownCredential() };
    },
    // **TWO OPERATIONS, NOT ONE WITH A FLAG.** The retained-descriptor one knows the passkey is
    // unused; this one knows only that the Worker had no record, and refuses the credential this
    // browser's own identity rests on because that is the single thing it CAN check.
    discard: (stranded) => stranded
      ? (strandedCredential
          ? opts.identity.discardCredential(strandedCredential)
          : Promise.resolve({ ok: false as const, reason: "no-pending" }))
      : opts.identity.discardPendingRoot(),
    done: opts.onDone,
  }, {signal:opts.signal,open: root => openClientDialog(root as HTMLDialogElement), close: root => closeClientDialog(root as HTMLDialogElement)});
}
