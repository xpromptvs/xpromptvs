/**
 * What the app says about this Mac's encryption identity — as DATA, not DOM.
 *
 * A separate module for the reason `publish-status.ts` is one: the renderer is otherwise untestable
 * (no bundler, no test target), and this is a seam where that costs something real. §10.1 requires
 * the interface to NAME the identity a device is adopting before it commits, and "the line a person
 * actually reads" is the only place that requirement lives.
 */

/** Mirrors `E2EStatusCode` in `host/RdevAppHost/Sources/RdevAppHost/E2EHost.swift`. */
export const E2E_STATUS = {
  unavailable: 0,
  unenrolled: 1,
  enrolling: 2,
  // 3 was §12.1's polled confirmation — gone with the browser-aided ceremony (2026-10-06).
  interrupted: 4,
  ready: 5,
  blocked: 6,
  /// §12.2: ready and serving, and the publication is not confirmed. TWO codes rather than one,
  /// because the required wording and the retry policy differ.
  readyListingNotConfirmed: 7,
  readyPublicationRejected: 8,
} as const;

export interface E2ERowView {
  /**
   * **A WORKING STATE SHOWS NOTHING HERE.** The row sits at the top of the devices page, and "end-to-end
   * encryption is on for this Mac" is not news — it is always on, so a person reads it once and
   * then reads past it, which is exactly what a security row must not become. The standing state
   * lives in Settings (`e2eSettings`), where the Device ID it carries is the useful part; this row
   * is for what a person must DO, or what will not fix itself.
   */
  hidden: boolean;
  text: string;
  /**
   * An identity to show, IN FULL, or "" — never shortened: an abbreviation is not something a person
   * can check. No state carries one since the browser-aided §12.1 went (2026-10-06): the identity is
   * stated by the sign-in panel's success screen and the header's profile alert, and the §10.2 device
   * id is Settings' (`e2eSettings`).
   */
  identity: string;
  /** The primary button's label, or null when there is nothing for a person to do. */
  action: string | null;
  /**
   * `sign-in` opens the sign-in panel (`web/src/shared/e2e-setup.ts`) — the same one the browser's
   * dashboard shows — where the Mac runs the passkey ceremony itself (2026-10-06).
   */
  kind: "none" | "sign-in";
  /**
   * **THE OTHER WAY ONTO THIS MAC, when there is one.**
   *
   * `action` signs in with a passkey THIS MAC can reach — its own Touch ID, iCloud Keychain, or a
   * phone through the platform's prompt — and ends with capability 7. This one shows §9.1's code for
   * somebody to scan with a device that already holds the passkey, and ends with capability 2 —
   * share only. Both are offered because which is possible depends on where the passkey is, and this
   * Mac cannot know that.
   *
   * Null whenever there is no second route: an enrolled Mac has an identity already, and adopting it
   * again would be asking a second root to certify it — which §10.1 forbids outright.
   */
  secondary: E2ERowAction | null;
  /**
   * The adoption QR as a `data:image/…` URL, or "" when there is none.
   *
   * **ONLY a `data:image/` URL is ever carried.** The renderer puts this straight into an
   * `<img src>`, so anything else — `javascript:`, a remote URL, `data:text/html` — is a
   * script-injection surface or a beacon that phones home the moment the row paints. Filtered HERE
   * rather than at the renderer, because this is the layer with tests.
   */
  qrDataUrl: string;
  tone: "ok" | "warn" | "info";
}

export interface E2ERowAction {
  label: string;
  kind: "adopt" | "adopt-cancel";
}

export interface E2EInput {
  status: number;
  detail: string;
  /**
   * §10.1's identity as a person READS it, or "" when this Mac belongs to none.
   *
   * **OPTIONAL, and absent means signed out.** It arrives from its own host function
   * (`E2EHost.identityCode`) rather than from `detail`, which means the §10.2 device id under the
   * ready statuses — two formats that exist so a person cannot mistake one for the other. Optional
   * because an older `main` does not send it, and a header button is not worth a crash.
   */
  identity?: string;
  /**
   * §9.1's window, while one is open. **Optional, and absent means no window** — an older `main`
   * does not send it, and a row is not worth a crash.
   */
  adopt?: { phase: "waiting" | "handshaking" | "failed"; carrier?: string; reason?: string;
            qrDataUrl?: string };
  /**
   * §10.3's capability on this Mac's own leaf grant, from `rdev_host_e2e_capabilities`.
   *
   * **ABSENT AND `0` BOTH MEAN UNKNOWN**, and neither is a restriction: an older `main` sends none,
   * and a Mac whose library will not load reports 0. A caller that read either as "restricted" would
   * disable a working button for a reason that is not true.
   */
  capabilities?: number;
}

/** §10.3's bits, by name, so a reader is not left decoding a mask. */
const CAP_CONNECT = 1;
const CAP_ENROLL = 4;

/**
 * **A SHARE-ONLY MAC — capability 2 — and what it genuinely cannot do.**
 *
 * `E2ESubordinateGrant` refuses a signer without `enroll`, so such a Mac can issue no guest pairing
 * code and no grant for its own client window at `app://client/`. Those are the two affordances that
 * must be absent or explained; everything else about it works exactly as any other Mac.
 */
export function isShareOnly(state: { capabilities?: number }): boolean {
  const caps = state.capabilities ?? 0;
  return caps !== 0 && (caps & CAP_ENROLL) === 0 && (caps & CAP_CONNECT) === 0;
}

export interface OpenClientView {
  enabled: boolean;
  /** Why not, or "" when there is nothing to explain. Never a bare "unavailable". */
  reason: string;
}

/**
 * **Whether this Mac can open its own client window, and why not.**
 *
 * Pure, because jsdom cannot see a disabled button's tooltip and a person can. The renderer at
 * `app://client/` runs no passkey ceremony (§2, profile P-A), so it asks the app to certify keys it
 * generated — and a Mac without `enroll` cannot. Pressing it anyway surfaces as "this Mac refused to
 * certify its own window", which names neither the cause nor the fix.
 */
export function openClientView(state: { capabilities?: number }): OpenClientView {
  if (!isShareOnly(state)) return { enabled: true, reason: "" };
  return {
    enabled: false,
    reason: "This Mac shares its screen only. Set it up with your passkey to connect out from it.",
  };
}

/** The refusals that have a plain-language form. Anything else is shown as the code it is. */
const REASONS: Record<string, string> = {
  "origin-insecure": "its address is not secure, so no passkey can belong to it",
  "origin-unsupported-path": "its address has a path, which setup does not support",
  "origin-malformed": "its address cannot be read",
  "no-storage": "there is nowhere on this Mac to store it",
  library: "the host library could not be loaded",
  // The ways the Mac's own passkey ceremony ends badly (`E2EPasskeyFailure.reason`), which
  // `unenrolled` reports below; a dismissed prompt is a decision and is never stored. Unknown codes
  // fall through and are shown AS the code, which still beats silence.
  "not-associated": "Apple has not yet confirmed that Xpromptvs may use passkeys for this site",
  lookup: "the directory could not be reached to look the passkey up",
  "not-found": "no identity is registered for that passkey yet",
  chain: "what came back could not be verified",
  storage: "this Mac could not store it",
  "already-enrolling": "setup is already running",
  "not-applicable": "this Mac is not waiting to be set up",
  // Adding by code: its window expired before a device with the passkey answered.
  expired: "the code expired before it was used",
  // §9.2's four-attempt budget, and the rest of `PairingWindowOpener.Failure`. `conflict` is a
  // denial of service by the specification's own words, so it does not read as this Mac's fault.
  conflict: "the control plane would not give this Mac a code",
  unreachable: "the control plane could not be reached",
  refused: "the control plane refused to open a code",
  "already-enrolled": "this Mac already has an identity",
  disconnected: "the connection dropped before it finished",
  cancelled: "it was cancelled",
  // The code went into CONNECT on the other device, which starts a guest pairing — both ends spoke first
  // (`AdoptByCode`'s `entered-in-connect`, 2026-10-07: what the Mac mini's row said as `gate/noise`).
  "entered-in-connect": "the code was entered in Connect. On the other device choose Add device, beside My Devices, and enter it there",
  "gate/noise": "the code did not match",
  // The other device stopped answering mid-handshake (`AdoptByCode.stallSeconds`): its last message never came.
  stalled: "the other device stopped answering. Show a new code and try again",
};

/** Offered whenever this Mac could still be adopted. */
const ADOPT: E2ERowAction = { label: "Add by code", kind: "adopt" };

/** The browser dashboard's own words for the same panel (`device-list.ts`): one vocabulary. */
const SIGN_IN = "Sign in with a passkey";

/**
 * **The unenrolled row, which is the only one with two routes onto this Mac.**
 *
 * A window in flight takes the row over, because while one is open the CARRIER is the row's whole
 * job: a person has to read it off this screen, since that display IS §9.1's out-of-band channel.
 */
function unenrolledRow(state: E2EInput): E2ERowView {
  const adopt = state.adopt;
  if (adopt?.phase === "waiting") {
    return {
      hidden: false,
      // WHERE the code goes, said with it: Connect starts a guest pairing, and the Mac refused that (2026-10-07).
      text: `On a device signed in with your passkey, choose Add device and enter this code, or scan it: ${adopt.carrier ?? ""}`,
      identity: "", action: null,
      // **NOT "Try again" and not "Set up".** While a code is up there is exactly one thing a person
      // can decide, and it is whether to stop showing it.
      secondary: { label: "Cancel", kind: "adopt-cancel" },
      // **ONLY `data:image/`.** This goes straight into an `<img src>` in the renderer; a
      // `javascript:` URL is an injection and a remote one is a beacon that fires on paint.
      qrDataUrl: (adopt.qrDataUrl ?? "").startsWith("data:image/") ? adopt.qrDataUrl! : "",
      kind: "none", tone: "info",
    };
  }
  if (adopt?.phase === "handshaking") {
    // **STOP, not Cancel** (2026-10-07: with no button, a lost last message left this up for good). It stops
    // WAITING here; it cannot undo what the other device may already have signed, and says no more than it does.
    return { hidden: false, text: "Adding this Mac… Confirm on the other device.", identity: "",
             action: null, secondary: { label: "Stop", kind: "adopt-cancel" }, qrDataUrl: "", kind: "none", tone: "info" };
  }
  if (adopt?.phase === "failed") {
    // A route that failed to start must SAY SO, or the row goes back to exactly how it looked and
    // reads as a button that does nothing.
    return { hidden: false, text: `Adding by code did not finish — ${reason(adopt.reason ?? "")}.`,
             identity: "", action: SIGN_IN, secondary: ADOPT, qrDataUrl: "",
             kind: "sign-in", tone: "warn" };
  }
  return state.detail
    ? { hidden: false, text: `Setting up did not finish — ${reason(state.detail)}.`,
        identity: "", action: SIGN_IN, secondary: ADOPT, qrDataUrl: "", kind: "sign-in", tone: "warn" }
    : { hidden: false, text: "This Mac has no encryption identity yet.", identity: "",
        action: SIGN_IN, secondary: ADOPT, qrDataUrl: "", kind: "sign-in", tone: "warn" };
}

export function e2eRow(state: E2EInput): E2ERowView {
  switch (state.status) {
    case E2E_STATUS.ready:
      return { hidden: true, text: "", identity: "",
               action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "ok" };

    // §12.2: "An interface that says 'not listed' asserts an absence no endpoint has established."
    // Both of these are ON and serving — publication is best-effort and never a precondition for
    // access — so neither reads as broken, and neither claims the record is missing.
    //
    // **They part company on whether they FIX THEMSELVES**, which §12.2 is explicit about and which
    // is the whole reason there are two codes: `unconfirmed` retries on the next beat and needs
    // nothing from a person, so it is as silent here as `ready`. `rejected` will not, and says so.
    case E2E_STATUS.readyListingNotConfirmed:
      return { hidden: true, text: "", identity: "",
               action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "info" };

    // The REQUIRED WORDING, quoted: §12.2 gives it exactly, because a rejection "describes the
    // latest attempt, not whether an earlier one committed". It leads with the publication and not
    // with "encryption is on", because the publication is the news; the standing state is Settings'.
    case E2E_STATUS.readyPublicationRejected:
      return { hidden: false,
               text: "Publication rejected; listing not confirmed. Action required.",
               identity: "", action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "warn" };
    // **AND WHY THE LAST ATTEMPT ENDED, when there was one.** `detail` carries it here ("why the last
    // ceremony ended, or empty") — without it a ceremony that failed put the row back exactly as it
    // was, which reads as the button doing nothing at all.
    case E2E_STATUS.unenrolled:
      return unenrolledRow(state);
    case E2E_STATUS.enrolling:
      return { hidden: false, text: "Follow the passkey prompt.", identity: "",
               action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "info" };
    case E2E_STATUS.interrupted:
      return { hidden: false, text: "An earlier setup was interrupted. It cannot be resumed by this version.",
               identity: "", action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "warn" };
    case E2E_STATUS.blocked:
      return { hidden: false, text: `This Mac's stored identity cannot be read (${state.detail || "unknown"}).`,
               identity: "", action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "warn" };
    case E2E_STATUS.unavailable:
      return { hidden: false, text: `End-to-end encryption is unavailable — ${reason(state.detail)}.`,
               identity: "", action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "warn" };
    default:
      // A status this build does not know must NOT read as working. The ABI is versioned by nothing
      // — a newer library with a seventh state would otherwise render as silence, which is the one
      // thing a security state may never do.
      return { hidden: false, text: `End-to-end encryption state is unknown (${state.status}).`, identity: "",
               action: null, secondary: null, qrDataUrl: "", kind: "none", tone: "warn" };
  }
}

function reason(detail: string): string {
  if (!detail) return "this Mac cannot set it up";
  return REASONS[detail] ?? detail;
}

// --------------------------------------------------------------- Settings → End-to-End Encryption

export interface E2ESettingsView {
  /** What the section says. Never empty: a security surface that can render as silence is the one
   *  thing §14's spirit forbids, and here there is always something true to say. */
  body: string;
  /**
   * **THE §10.2 DEVICE ID, in hex and IN FULL, or "" when this Mac has none yet.** It is NOT an
   * identity and it is never rendered as one: `E2EIdentity.code` is what a person holds up against
   * another device, and a §10.2 device id stays hex (`docs/e2e.md`). It is read only from the three
   * READY statuses — under every other one `detail` carries something else.
   */
  deviceId: string;
  /**
   * **§10.3's upgrade, offered only to a device that can take it.**
   *
   * "A code-enrolled B requesting passkey authorization receives a new DIRECT grant… its new direct
   * chain does not depend on A." A share-only Mac becomes a full one by signing in with ITS
   * passkey, and this is the only surface that offers it: the ROW stays silent, because a share-only
   * Mac is working as intended and `hidden` is for what a person must DO.
   */
  action: { label: string; kind: "sign-in" } | null;
  tone: "ok" | "warn" | "info";
}

/** Signing in, named as the upgrade it is here rather than as first-time setup. */
const UPGRADE = { label: "Set up with a passkey", kind: "sign-in" } as const;

/** Keys-at-rest, in the browser client's own words (`identity-settings.ts`): one vocabulary. */
const KEYS = "Its keys are stored on this Mac only.";

/**
 * What Settings adds for a share-only Mac, or "" for every other one.
 *
 * It states both halves — what it does and what it will not do — because the second is the part a
 * person discovers otherwise by pressing something that fails.
 */
function shareOnlyNote(state: E2EInput): string {
  if (!isShareOnly(state)) return "";
  return `${KEYS} This Mac can share its screen. It cannot add other devices or connect out to `
       + "your other Macs — set it up with your passkey to do that.";
}

/**
 * **What Settings says about this Mac's encryption**, under the heading "End-to-End Encryption".
 *
 * This is where the STANDING state lives, because it is standing: encryption is always on, so the
 * devices page says nothing about it (`E2ERowView.hidden`) and what is left worth showing is the
 * Device ID. Every state a person must act on is still the row's; this section describes them too,
 * in the row's own words, so that a person who opens Settings during a ceremony is not told the
 * section is empty.
 */
export function e2eSettings(state: E2EInput): E2ESettingsView {
  const row = e2eRow(state);
  switch (state.status) {
    case E2E_STATUS.ready:
      // **A share-only Mac is working exactly as intended**, so this is what it is FOR rather than a
      // fault: it was added by code, and what a scanned code grants is a screen and nothing else.
      return { body: shareOnlyNote(state) || KEYS, deviceId: state.detail,
               action: isShareOnly(state) ? UPGRADE : null, tone: "ok" };
    // §12.2 again: ON and serving, and the listing is a separate, best-effort thing. Saying so here
    // costs nothing and is the only place a person can see it at all now that the row is silent.
    case E2E_STATUS.readyListingNotConfirmed:
      return { body: `${KEYS} Listing not confirmed.`, deviceId: state.detail,
               action: isShareOnly(state) ? UPGRADE : null, tone: "info" };
    case E2E_STATUS.readyPublicationRejected:
      return { body: `${KEYS} ${row.text}`, deviceId: state.detail,
               action: isShareOnly(state) ? UPGRADE : null, tone: "warn" };
    default:
      // **NO DEVICE ID.** Either there is none, or `detail` is carrying something that is not one.
      return { body: row.text, deviceId: "", action: null, tone: row.tone };
  }
}
