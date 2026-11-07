/**
 * **This window's identity is not this Mac's.**
 *
 * The app's own client window is a subordinate device: `app://client/` can run no passkey ceremony
 * (§2, profile P-A), so it generates keys and the Mac certifies them with §10.3's `root → A → B`.
 * `adoptFromShell` runs only when the window has NO config, and §10.1 forbids an incoming chain
 * replacing one it already trusts — so once the Mac's root CHANGES underneath it, the window keeps
 * the old one and there is no route back.
 *
 * Measured 2026-09-17: a Mac added by code (capability `2`) and then upgraded through §12.1 held the
 * root bound to the deployed Worker while its own client window still held one bound to rp_id
 * `127.0.0.1`, from an enrollment against the vite dev origin. Every connect ran a full Noise
 * handshake and died at `verifyBundle` — reported as `session:peer-chain`, which names NEITHER root
 * and is indistinguishable from a chain that is simply bad. The two root records differ in their
 * FIRST field:
 *
 *     host   : rdev-e2e/root/v1 \x00\x2e rdev-control-plane.ali-fareed-…
 *     window : rdev-e2e/root/v1 \x00\x09 127.0.0.1
 *
 * **The comparison is on §10.1's readable CODE**, which is what a person is shown and what they
 * would check against another device. 80 bits is a comparison no accident survives, and nothing is
 * decided by it: it only chooses whether to ASK. The authority is still `verifyBundle`, on the chain
 * that arrives after a Replace.
 */

/** Null on either side means NOTHING TO COMPARE — never "they match". */
export type IdentityMismatch =
  | { kind: "none" }
  | { kind: "mismatch"; window: string; mac: string };

/**
 * A code is compared case-insensitively and without its separators: it is Crockford base32 shown in
 * groups of four, and two surfaces that grouped or cased it differently would read as two identities
 * while naming one. An empty or absent code on EITHER side is "nothing to compare" — the shell
 * answers "" when the host has no identity to name, and a window with no trust record has none yet, and
 * neither is evidence of a mismatch.
 */
function normalize(code: string | null | undefined): string {
  return (code ?? "").replace(/[\s-]/g, "").toUpperCase();
}

export function identityMismatch(windowCode: string | null | undefined,
                                 macCode: string | null | undefined): IdentityMismatch {
  const a = normalize(windowCode);
  const b = normalize(macCode);
  if (!a || !b || a === b) return { kind: "none" };
  return { kind: "mismatch", window: windowCode!.trim(), mac: macCode!.trim() };
}

export interface MismatchView {
  title: string;
  body: string;
  windowLabel: string;
  macLabel: string;
  confirm: string;
  cancel: string;
  /** What the session reports when the person declines. Shown by the app's dashboard too. */
  declined: string;
}

/**
 * **It says what each answer COSTS.** Replace discards this window's trust record and nothing else —
 * the keys survive, because a change of identity is not a change of device (`resetTrust`), it revokes
 * nothing, and the Mac re-certifies the same keys on the spot. Cancel is the one that needs saying
 * out loud: under the old identity this window cannot reach this Mac at all, now or later, so a
 * person who reads Cancel as "not now" would be wrong about the "later".
 */
export function mismatchView(m: Extract<IdentityMismatch, { kind: "mismatch" }>): MismatchView {
  return {
    title: "This window is signed in to a different identity",
    body: "This Mac's encryption identity is not the one this window stored — its identity changed "
        + "after this window was set up. Replacing it discards only what this window remembers; its "
        + "keys are kept, nothing is revoked, and this Mac signs them again straight away.",
    windowLabel: "This window",
    macLabel: "This Mac",
    confirm: "Replace",
    cancel: "Cancel",
    declined: `this window is signed in to ${m.window} and this Mac now uses ${m.mac}`,
  };
}
