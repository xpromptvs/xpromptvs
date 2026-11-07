import {
  PublicationStatus, identityCode, parseRoot, rootId as hashRoot,
} from "@rdev/protocol";
import { E2EHostGate } from "@rdev/protocol";
import type { AddDeviceRun, AddDeviceState } from "../shared/add-device";
import { issueDirectGrant } from "../lib/e2e-grant";
import { policyFor } from "../lib/product-origin";
import { SignalingClient } from "../lib/signaling";
import { ClientE2EIdentity } from "./e2e-identity";
import { parsePairing } from "./pairing";

/**
 * **ADOPTING A MAC: this browser holds the passkey, and the Mac showed its code.**
 *
 * The reverse of guest pairing in the one way a person notices — they carry the code FROM the Mac
 * rather than to it — and the same §11.1 `pair` underneath: the Mac initiates and is issued a chain,
 * this side answers and issues one. What it issues is a DIRECT, root-signed grant at capability `2`:
 * host, and nothing else, so a scanned code grants a screen and never the ability to reach anything.
 *
 * **The psk is the authorisation, and the confirmation is the NAMING.** Only someone standing at that
 * Mac could read its screen, so nobody is being asked whether the peer is legitimate — they are being
 * told which identity this Mac is about to join, and asked to name it. §10.1's requirement is to name
 * the identity before the device commits, and that is what the confirm screen is for.
 */

/** Where an adoption is: the Add device dialog's states (`web/src/shared/add-device.ts`). */
export type AdoptState = Exclude<AddDeviceState, { kind: "form" }>;

/** How long the new Mac has to speak once this side is in its room. It speaks the moment the relay says somebody
 *  joined, so silence means no Mac shows that code — or the code is a SHARE code, whose host waits for a guest to
 *  speak (it belongs in Connect). The Mac's own issuer waits as long (`AddDeviceByCode`). */
export const ADOPT_ANSWER_MS = 15_000;

/** How long the new Mac has, once its chain is sent, to say it committed it (`adoptionAck`). It says so in
 *  milliseconds; silence means the chain never reached it. The Mac's own issuer waits as long (`AddDeviceByCode`). */
export const ADOPT_ACK_MS = 20_000;

/**
 * **THE NEW MAC'S WORD ON ITS CHAIN** (`RdevCore.AdoptionAck`; `protocol/fixtures/adoption-ack.json`): sent inside the
 * session once it has committed the chain, or refused it. This side says "added" only on `adopted` — until 2026-10-07
 * it said so as the chain left, and a chain lost on the way read as a success. Null for anything that is not one.
 */
export function adoptionAck (inner: Uint8Array): { kind: "adopted" } | { kind: "refused"; reason: string } | null {
  let m: unknown;
  try { m = JSON.parse(new TextDecoder().decode(inner)); } catch { return null; }
  if (typeof m !== "object" || m === null) return null;
  const o = m as { t?: unknown; reason?: unknown };
  if (o.t === "adopted") return { kind: "adopted" };
  if (o.t === "adopt-refused") return { kind: "refused", reason: typeof o.reason === "string" ? o.reason : "" };
  return null;
}

/** What the driver needs from the world, injected so the flow is drivable without a browser. */
export interface AdoptDeps {
  identity: ClientE2EIdentity;
  /** Opens the room socket. Separated so a test need not stand up a WebSocket. */
  connect: (url: string, token: string, handlers: {
    onE2E: (ct: string, peer?: string, mode?: string) => void;
    onError: (code: string) => void;
    /** The new Mac's room closed (the relay's `peer-left` with `role: "host"`), or the socket did. */
    onClosed?: () => void;
  }) => { send: (ct: string, peer?: string) => void; close: () => void };
  /** Each state, as it is reached. */
  state: (s: AdoptState) => void;
  /** Asks the person "Add this Mac?". Resolves with their answer. */
  confirm: () => Promise<boolean>;
  origin: string;
  /** Aborted: the dialog closed. The run stops and reports nothing more. */
  signal?: AbortSignal;
  /** `ADOPT_ANSWER_MS`, shortened by tests. */
  answerMs?: number;
  /** `ADOPT_ACK_MS`, shortened by tests. */
  ackMs?: number;
}

/**
 * Drive one adoption to a conclusion.
 *
 * **Confirmation comes BEFORE the assertion.** A confirmation collected afterwards is a
 * notification, and the one-prompt rule this product already pays for elsewhere is exactly that the
 * passkey is asked once, for something the person has already agreed to.
 */
export async function runAdoption (carrier: string, deps: AdoptDeps): Promise<AdoptState> {
  const aborted = (): boolean => deps.signal?.aborted === true;
  const show = (s: AdoptState): AdoptState => { if (!aborted()) deps.state(s); return s; };

  const pairing = await parsePairing(carrier);
  if (!pairing?.psk) return show({ kind: "failed", reason: "not-a-code" });

  const loaded = await deps.identity.load();
  if ("kind" in loaded || !loaded.record.root || !loaded.record.bundle) {
    return show({ kind: "no-identity" });
  }
  const root = loaded.record.root;
  const parsedRoot = parseRoot(root);
  if (!parsedRoot) return show({ kind: "failed", reason: "unreadable identity" });

  const config = await deps.identity.hostGateConfig(pairing.code, pairing.psk);
  if (!config) return show({ kind: "failed", reason: "unreadable identity" });
  if (aborted()) return { kind: "failed", reason: "cancelled" };

  const gate = new E2EHostGate(config);
  show({ kind: "waiting" });

  return await new Promise<AdoptState>((resolve) => {
    let settled = false;
    let heard = false;
    /** The chain is out: what decides now is the new Mac's word. */
    let chainSent = false;
    let ackTimer: ReturnType<typeof setTimeout> | undefined;
    const finish = (s: AdoptState): void => {
      if (settled) return;
      settled = true;
      clearTimeout(silence);
      clearTimeout(ackTimer);
      deps.signal?.removeEventListener("abort", onAbort);
      socket.close();
      gate.close();
      resolve(show(s));
    };
    const onAbort = (): void => finish({ kind: "failed", reason: "cancelled" });
    deps.signal?.addEventListener("abort", onAbort);
    const silence = setTimeout(() => { if (!heard) finish({ kind: "failed", reason: "no-answer" }); },
                               deps.answerMs ?? ADOPT_ANSWER_MS);

    const socket = deps.connect(`/session/${pairing.code}`, pairing.token, {
      onError: (code) => finish({ kind: "failed", reason: chainSent ? "unconfirmed" : code }),
      // After the chain and before the word, nobody knows whether the Mac committed it.
      onClosed: () => finish({ kind: "failed", reason: chainSent ? "unconfirmed" : "disconnected" }),
      onE2E: (ct, _peer, mode) => {
        heard = true;
        void (async () => {
          if (settled) return;
          const received = gate.receive(fromB64u(ct), mode);
          if (!received.ok) {
            finish({ kind: "failed", reason: describe(received.failure) });
            return;
          }
          if (received.value.kind === "reply") {
            for (const out of received.value.cts) socket.send(b64u(out));
            return;
          }
          if (received.value.kind === "signalling") {
            // Only the new Mac's word, and only once its chain is out.
            const ack = chainSent ? adoptionAck(received.value.inner) : null;
            if (ack?.kind === "adopted") finish({ kind: "added", publication: publicationWord(config.publicationStatus) });
            else if (ack?.kind === "refused") finish({ kind: "failed", reason: `mac-refused/${ack.reason}` });
            return;
          }
          if (received.value.kind !== "awaiting-issuance") return;

          const pending = gate.pendingIssuance;
          if (!pending) { finish({ kind: "failed", reason: "nothing to issue" }); return; }

          // §10.1's naming, and the act, in one step and before any signature.
          show({ kind: "confirm", identityCode: identityCode(hashRoot(root)) });
          if (!(await deps.confirm())) { finish({ kind: "failed", reason: "cancelled" }); return; }
          if (settled) return;

          show({ kind: "issuing" });
          const issued = await issueDirectGrant({
            config: { rpId: policyFor(deps.origin).rpId, rpName: "Xpromptvs" },
            origin: deps.origin,
            root,
            credentialId: parsedRoot.credentialId,
            device: pending.device,
            operationId: crypto.getRandomValues(new Uint8Array(32)),
            capabilities: 2,
            // §10.4: the far side checks both against its OWN view, which is what makes this a
            // statement about this transcript rather than a claim about one.
            binding: {
              kind: "remote",
              handshakeHash: pending.handshakeHash,
              responderDeviceId: pending.responderDeviceId,
            },
          });
          if (settled) return;
          if (!issued.ok) {
            finish({ kind: "failed", reason: describeGrant(issued.failure) });
            return;
          }
          const sent = gate.issue(issued.bundle);
          if (!sent.ok) { finish({ kind: "failed", reason: describe(sent.failure) }); return; }
          socket.send(b64u(sent.value.ct));
          // NOT "added" yet: that is the new Mac's to say (`adoptionAck`).
          chainSent = true;
          show({ kind: "finishing" });
          ackTimer = setTimeout(() => finish({ kind: "failed", reason: "unconfirmed" }), deps.ackMs ?? ADOPT_ACK_MS);
        })();
      },
    });
  });
}

/**
 * **The browser's `AddDevice`** (`web/src/shared/add-device.ts`): one adoption, steered by the dialog — its
 * "Add this Mac" answers the confirmation, closing it aborts the run.
 */
export function startAdoption (carrier: string, onState: (s: AddDeviceState) => void,
                               deps: { identity: ClientE2EIdentity; origin?: string;
                                       connect?: AdoptDeps["connect"] }): AddDeviceRun {
  const abort = new AbortController();
  let answer: ((add: boolean) => void) | null = null;
  const origin = deps.origin ?? location.origin;
  void runAdoption(carrier, {
    identity: deps.identity,
    connect: deps.connect ?? liveConnect(origin),
    origin,
    state: onState,
    confirm: () => new Promise<boolean>((resolve) => { answer = resolve; }),
    signal: abort.signal,
  });
  return {
    confirm: (add) => { answer?.(add); answer = null; },
    cancel: () => { answer?.(false); answer = null; abort.abort(); },
  };
}

const publicationWord = (p: PublicationStatus | undefined): "confirmed" | "unconfirmed" | "rejected" =>
  p === PublicationStatus.Rejected ? "rejected" : p === PublicationStatus.Confirmed ? "confirmed" : "unconfirmed";

const describe = (f: { kind: string; failure?: string }): string =>
  f.failure ? `${f.kind}/${f.failure}` : f.kind;
const describeGrant = (f: { kind: string; failure?: string }): string =>
  f.kind === "ceremony" ? "cancelled" : describe(f);

const b64u = (u: Uint8Array): string =>
  btoa(String.fromCharCode(...u)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64u = (s: string): Uint8Array => {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(t + "=".repeat((4 - t.length % 4) % 4)), (c) => c.charCodeAt(0));
};

/** Kept out of `runAdoption` so the driver never learns what a real socket is. */
export function liveConnect (origin: string): AdoptDeps["connect"] {
  return (path, token, handlers) => {
    const ws = new WebSocket(origin.replace(/^http/, "ws") + path);
    const client = new SignalingClient(ws, { role: "client", token }, {
      onE2E: handlers.onE2E,
      onError: (code) => handlers.onError(code),
      onPeerLeft: (peer) => { if (peer === "host") handlers.onClosed?.(); },
    });
    ws.addEventListener("close", () => handlers.onClosed?.());
    return {
      send: (ct) => client.sendE2E(ct),
      close: () => ws.close(),
    };
  };
}
