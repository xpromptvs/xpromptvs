/// §13: what an authenticated session is actually allowed to do, and when that permission stops.
///
/// Mirror of `RdevCore.E2EAuthorization` (Swift).
///
/// §10 and §11 establish WHO a peer is. This is the layer that turns that into WHETHER — and §13 is
/// blunt about the order: "A Host grants remote access only after the §11.2 confirmation gate and
/// §12.2's revocation check". Both are parameters here rather than assumptions, so a call site that
/// has not done them cannot accidentally read as one that has.
///
/// **"Authentication cannot be performed in or after the component whose privileged side effect it
/// is supposed to guard."** That sentence is why this lives apart from the effects it guards.
import { IssuerKind, CAP_CONNECT, CAP_ENROLL, CAP_HOST } from "./e2e-identity";
import type { VerifiedChain } from "./e2e-verify";

/// The privileged effects §13 names. Deliberately COARSE: these are the three things a grant says,
/// not a catalogue of every control message. Per-message policy (who is the active controller, what
/// the lifecycle allows) stays where it already lives — §13: "Terminal control, input,
/// subscriptions, and curtain actions retain the application's active-controller and lifecycle
/// rules."
export type AuthEffect =
  /** Establish a controlled session at all — which per §10.3 includes full remote control and a
   *  shell. `connect` is NOT a read-only capability. */
  | "connect"
  /** Serve as the Host of a session. */
  | "host"
  /** Issue a pairing code, and enroll another device against it. */
  | "issue-code";

export type AuthDenial =
  /** §11.2's gate has not passed. §13: "A routing ID, open connection, account token, or
   *  certificate without possession proof is insufficient." */
  | "not-authenticated"
  /** §12.2's revocation check has not been made for this activation — "we did not ask" is a denial,
   *  not a pass. */
  | "revocation-not-checked"
  /** The chain does not carry the capability this effect requires. */
  | "missing-capability"
  /** §13: "Only a direct `enroll` grant authorizes code issuance." */
  | "not-direct-enroll"
  /** §13: "Late callbacks must never execute through a replacement session's authority." */
  | "authority-withdrawn";

export type AuthResult = { ok: true } | { ok: false; denial: AuthDenial };

/// The whole of §13's capability test, in one place so the three rules can be read together.
///
/// `gatePassed` and `revocationChecked` are separate parameters ON PURPOSE. Folding them into one
/// "ready" flag would let a caller that did one of them satisfy a check meant for both, and they are
/// made at different times by different code.
export function authorize (effect: AuthEffect, opts: {
  chain: VerifiedChain;
  gatePassed: boolean;
  revocationChecked: boolean;
}): AuthResult {
  if (!opts.gatePassed) return { ok: false, denial: "not-authenticated" };
  if (!opts.revocationChecked) return { ok: false, denial: "revocation-not-checked" };

  const caps = opts.chain.leaf.capabilities;
  switch (effect) {
    case "connect":
      return (caps & CAP_CONNECT) !== 0 ? { ok: true } : { ok: false, denial: "missing-capability" };
    case "host":
      return (caps & CAP_HOST) !== 0 ? { ok: true } : { ok: false, denial: "missing-capability" };
    case "issue-code":
      // DIRECT is the operative word, and already implied: §10.3 forbids `enroll` on any
      // device-issued grant. Stated anyway, because that implication lives in another file and a
      // future relaxation there must not silently widen this.
      return (caps & CAP_ENROLL) !== 0 && opts.chain.leaf.issuerKind === IssuerKind.Root
        ? { ok: true }
        : { ok: false, denial: "not-direct-enroll" };
  }
}

/// A stamp identifying WHICH session authorized something.
///
/// §13: "Replacing a session or receiving revocation withdraws the old session's authority. Late
/// callbacks must never execute through a replacement session's authority."
///
/// **THIS IS A KNOWN-RECURRING SHAPE IN THIS CODEBASE, not a hypothetical** — the same bug has been
/// paid for wherever a deferred effect outlived the state that authorized it.
export interface AuthStamp { epoch: number }

/// Tracks which session is current, so a deferred effect can be asked whether its own authority
/// still exists.
export class SessionAuthority {
  private epoch: number;
  private isWithdrawn = false;

  constructor (epoch = 1) { this.epoch = epoch; }

  get current (): AuthStamp { return { epoch: this.epoch }; }
  get withdrawn (): boolean { return this.isWithdrawn; }

  /// A new authenticated session supersedes the old one. The previous stamp never becomes valid
  /// again, because the epoch only moves forward.
  replace (): AuthStamp {
    this.epoch += 1;
    this.isWithdrawn = false;
    return this.current;
  }

  /// §10.5 on receiving a revocation: "terminate affected sessions, withdraw active control, release
  /// held input, and prevent further effects from those sessions." TERMINAL for the current epoch —
  /// the way back is `replace()`, which is a new session, never a resumption of this one.
  withdraw (): void { this.isWithdrawn = true; }

  permits (stamp: AuthStamp): boolean {
    return !this.isWithdrawn && stamp.epoch === this.epoch;
  }

  check (stamp: AuthStamp): AuthResult {
    return this.permits(stamp) ? { ok: true } : { ok: false, denial: "authority-withdrawn" };
  }
}
