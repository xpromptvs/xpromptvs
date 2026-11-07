/**
 * What a device with no identity yet is offered — a browser, or since 2026-10-06 the Mac itself, which
 * runs the passkey ceremony natively (`docs/e2e.md`, "The Mac's own passkey ceremony") — as DATA, not
 * DOM. ONE panel for both dashboards (`web/src/shared/`): only the device the sentences name differs
 * (`SetupDevice`), and the ceremony behind it (`SetupFlow`).
 *
 * A separate module for the reason `publish-status.ts` and `desktop/src/renderer/e2e-row.ts` are:
 * §10.1's requirement lives in a line of text, and a line of text is otherwise untestable here. The
 * requirement is that the interface **NAME the identity being adopted before the device commits to
 * it** — so an identity is shown as §10.1's readable code (`identityCode`) rather than as a hash,
 * and no state offers a way to adopt one, because no browser route asks any more.
 *
 * **THE PANEL NO LONGER ASKS WHETHER YOU ARE SIGNED IN.** It used to open by fetching an account
 * listing and offering the roots it named; identities now come from the authenticator itself, by
 * §10.1's discoverable credential, so there is nothing to load and no account to have. That removed
 * the `loading` state and the candidate rows with it.
 * `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
 */

export type SetupAction =
  "discover" | "create" | "resume" | "authorise" | "discard" | "discard-yes" | "discard-no"
  | "dismiss" | "retry" | "close";

/** Which prompt the person is looking at. Three ceremonies feel identical if described identically. */
export type SetupStep = "creating" | "authorising" | "discovering" | "resuming" | "discarding";

/** Which device the panel's sentences are about: a browser signing itself in, or the Mac. */
export type SetupDevice = "browser" | "mac";

/** The words that name the device and whose prompt it is — everything else is shared. */
const DEVICE: Record<SetupDevice, { self: string; Self: string; prompt: string; others: string }> = {
  browser: { self: "this browser", Self: "This browser", prompt: "your browser's prompt",
             others: "your Macs recognise this browser" },
  mac: { self: "this Mac", Self: "This Mac", prompt: "the passkey prompt",
         others: "your other devices recognise this Mac" },
};

export interface SetupView {
  title: string;
  body: string;
  /**
   * The identity on screen, in full. Two states show one and they mean different things: §10.1's
   * confirmation shows it because a person must NAME an identity before adopting it, and the
   * success screen shows it because the create route no longer asks — "your Macs will show the same
   * code" is not checkable against a code nobody printed. Null everywhere else.
   *
   * **NEVER ABBREVIATED.** §10.1 asks a person to check this against another device they trust, and
   * an abbreviation is not something you can check — which is why it is §10.1's readable CODE
   * (`identityCode`) rather than a hash: sixty-four hexadecimal characters is a thing people glance
   * at, and nineteen in four groups is a thing they compare.
   */
  identity: string | null;
  actions: Array<{ id: SetupAction; label: string }>;
  tone: "info" | "warn" | "ok";
  /** Something is in flight; a renderer disables its controls. */
  busy: boolean;
}

/** What this browser can do with a descriptor it retained and never committed. */
export interface PendingOffers {
  /** There is one. */
  resume: boolean;
  /** There is one AND this browser can delete the passkey (the Signal API is not everywhere). */
  discard: boolean;
}

const NOTHING_PENDING: PendingOffers = { resume: false, discard: false };

export type SetupState =
  /**
   * `pending` is what can be done with §10.1 route 1's retained creation material — a passkey this
   * browser made and never committed. `resume` is whether there is one; `discard` adds whether this
   * browser can actually delete it, which needs the Signal API and is not everywhere.
   *
   * Both are offered ALONGSIDE the other routes and never instead of them: an authenticator that no
   * longer holds that credential must not corner a person into the one route that cannot work.
   */
  | { kind: "choosing"; pending: PendingOffers }
  /**
   * **The whole confirmation for a permanent deletion**, because the platform provides none —
   * measured 2026-09-14: `signalUnknownCredential` removes an Apple passkey in 250 ms with no
   * prompt at all.
   */
  | { kind: "discard-confirm" }
  /** A ceremony is in flight — a passkey prompt is up, or a grant is being written. */
  | { kind: "working"; step: SetupStep }
  /**
   * **Between the create route's two prompts, waiting for the person.** The passkey exists and is
   * retained; the grant's prompt starts from the Continue click, because Safari refused one started
   * straight after the first (no prompt at all, the same `NotAllowedError` as a cancel — 2026-10-03)
   * while the same assertion started from a click prompted.
   */
  | { kind: "authorise" }
  | { kind: "failed"; reason: string; stranded: boolean }
  /**
   * **The UNCERTAIN deletion**, and a different screen from `discard-confirm` because it knows
   * strictly less. That one can say nothing is using the passkey; this one can only say the Worker
   * has no record, and must hand the person the question they alone can answer.
   */
  | { kind: "stranded-confirm" }
  | { kind: "ready"; deviceId: string; rootId: string };

const NOTHING: Array<{ id: SetupAction; label: string }> = [];

/// **CREATING IS TWO PROMPTS, AND THE SCREEN HAS TO SAY SO.** It was one message across both, so the
/// second prompt arrived under words describing the first — which does not read as two steps, it
/// reads as the same request being made twice.
///
/// The two are genuinely different things, and saying which is which is the whole fix: the passkey
/// IS the identity, and this browser is a device that identity has to authorise. Neither prompt is a
/// test and neither is a sign-in — if the second is refused the identity is unusable, so calling it
/// a check would be false in the direction that matters.
///
/// Why two at all: a WebAuthn registration returns no signature (measured — Apple answers `fmt:
/// "none"` however attestation is requested), so the grant needs an assertion of its own, and two
/// calls are two prompts here (measured). `docs/open-threads.md`.
function working (step: SetupStep, device: SetupDevice): string {
  const d = DEVICE[device];
  switch (step) {
    case "creating": return `Step 1 of 2. Follow ${d.prompt} to create a passkey.`;
    case "authorising":
      return `Step 2 of 2. Your passkey is ready. Now let it authorise ${d.self} — `
           + (device === "browser" ? "your browser will ask once more." : "you will be asked once more.");
    case "discovering": return "Choose the passkey you use on your other devices.";
    case "resuming": return `Follow ${d.prompt} to use the passkey you made here.`;
    case "discarding": return "Deleting that passkey…";
  }
}

export function e2eSetupView (state: SetupState, device: SetupDevice = "browser"): SetupView {
  const d = DEVICE[device];
  switch (state.kind) {
    // **AN OFFER, NOT A DEFICIENCY.** This screen used to open with "This browser needs an
    // encryption identity", which announces a shortfall in words most people have no use for and
    // then asks them to fix it. What is actually on offer is a login, so it says so — and it says
    // what a passkey BUYS here rather than what it is, because the mechanism is not the point and
    // "identity" only means something once the two buttons have given it one.
    case "discard-confirm":
      return {
        title: "Delete that passkey?",
        // **IT STATES THE REASON RATHER THAN ASSERTING SAFETY.** "Nothing is using it" is only true
        // because of what retention knows — this browser made it, no Mac was ever given it, and no
        // identity was ever created from it — so the sentence says that instead of asking for
        // trust. And it names the alternative, because most people who reach this screen by
        // accident wanted the other button.
        body: "The passkey you made here was never finished, so nothing is using it — no Mac has "
            + "it, and no identity was ever created from it. Deleting it removes it from this "
            + "device and from iCloud Keychain, permanently. If you would rather use it, choose "
            + "Finish setting up instead.",
        identity: null,
        actions: [{ id: "discard-yes", label: "Delete it" },
                  { id: "discard-no", label: "Keep it" }],
        // The one `warn` that is earned: this is destructive and does not come back.
        tone: "warn", busy: false,
      };

    case "choosing":
      return {
        title: "Sign in with a passkey",
        body: `Your passkey is how ${d.others}, and what keeps the connection `
            + "encrypted end to end. Use one you already have to reach the Macs that share it, or "
            + "create one to link a new group of devices.",
        identity: null,
        // **BOTH are offered, always.** A person whose authenticator holds nothing must still be
        // able to start, and one whose passkey is on another device must not be cornered into
        // making a second identity because the first route was not offered.
        actions: [
          // **FIRST WHEN IT APPLIES.** Someone who made a passkey here last time and never finished
          // should not have to work out that "Create a passkey" would make them a second one.
          ...(state.pending.resume
            ? [{ id: "resume" as const, label: "Finish setting up" }]
            : []),
          // Beside the offer to finish, never instead of it — and only where the browser can
          // actually carry it out.
          ...(state.pending.discard
            ? [{ id: "discard" as const, label: "Delete that passkey" }]
            : []),
          { id: "discover", label: "Use a passkey" },
          { id: "create", label: "Create a passkey" },
          // **A WAY OUT.** As a full-screen overlay this had none and needed none — nothing else
          // was on screen. As a dialog over the dashboard it is something a person can open by
          // mistake, and Esc is not a control a phone has.
          { id: "dismiss", label: "Not now" },
        ],
        // `info`, not `warn`: nothing is wrong. An offer styled as a warning is what made the old
        // wording read as a fault to be repaired.
        tone: "info", busy: false,
      };

    case "working":
      return {
        title: "Setting up encryption",
        body: working(state.step, device),
        identity: null, actions: NOTHING, tone: "info", busy: true,
      };

    case "authorise":
      return {
        title: "Setting up encryption",
        body: `Step 2 of 2. Your passkey is ready. Now let it authorise ${d.self} — press `
            + (device === "browser" ? "Continue, and your browser will ask once more."
                                    : "Continue, and you will be asked once more."),
        identity: null,
        // "Not now" keeps the passkey: the form offers Finish setting up next time.
        actions: [{ id: "authorise", label: "Continue" }, { id: "dismiss", label: "Not now" }],
        tone: "info", busy: false,
      };

    case "stranded-confirm":
      return {
        title: "Delete that passkey?",
        // **IT MUST NOT BORROW `discard-confirm`'s SENTENCE.** That screen can say nothing is using
        // the passkey because a retained descriptor proves it. This one knows only that the Worker
        // holds no record — and the index is best-effort, and the Mac's retry is once per process.
        // So it says what it knows, then hands over the
        // question it cannot answer, phrased as something the person knows about themselves.
        body: "We could not find an identity for it. That usually means a setup was never "
            + "finished — but it can also mean a Mac has this identity and never reached the "
            + "directory. If you have ever set up a Mac with this passkey, deleting it means that "
            + "Mac's identity can never be extended to another device again. You can check when "
            + "the passkey was made in System Settings → Passwords. Deleting removes it from this "
            + "device and from iCloud Keychain, permanently.",
        identity: null,
        actions: [{ id: "discard-yes", label: "Delete it" },
                  { id: "discard-no", label: "Keep it" }],
        tone: "warn", busy: false,
      };

    case "failed":
      return {
        title: "Could not sign in",
        body: reason(state.reason, device),
        identity: null,
        // An ADDITION, never a replacement: Try again is the likelier want, and a person who came
        // here by accident must not find deletion as their only way forward.
        actions: [
          { id: "retry", label: "Try again" },
          ...(state.stranded ? [{ id: "discard" as const, label: "Delete that passkey" }] : []),
        ],
        tone: "warn", busy: false,
      };

    // **WHERE THE CREATE ROUTE'S IDENTITY GOES.** That route no longer puts the identity to a vote
    // (§10.1's MUST is the Residual under route 2, about DIRECTORY steering, which creation has
    // none of) — so this states it instead, with the same sentence the confirmation used, because
    // the check it invites is the same one.
    case "ready":
      return {
        title: "You're signed in",
        body: "Your Macs show the same code when they use this passkey. If that is not the "
            + "code yours show, sign out in Settings and try another passkey. "
            + `${d.Self}'s keys are stored on this device only.`,
        identity: state.rootId,
        actions: [{ id: "close", label: "Continue" }],
        tone: "ok", busy: false,
      };
  }
}

/**
 * **What Esc must do, per state.** A `<dialog>` opened with `showModal()` can be dismissed from the
 * keyboard, and three of these states would be wrong to close that way.
 *
 * - `no` — a ceremony is in flight. Closing would leave the browser's own prompt up and a promise
 *   nobody will ever resolve.
 * - `done` — the identity is committed; closing is what the Continue button does.
 * - `close` — nothing is pending.
 */
export type Dismissal = "no" | "close" | "done";

export function dismissal (state: SetupState): Dismissal {
  switch (state.kind) {
    case "working": return "no";
    // **ESC MUST NOT DELETE.** Closing the panel destroys nothing, and every outcome of that screen
    // is reachable by a button instead.
    case "discard-confirm": case "stranded-confirm": return "close";
    // Closing is "not now": the passkey stays retained and the form offers to finish it.
    case "authorise": return "close";
    case "ready": return "done";
    case "choosing": case "failed": return "close";
  }
}

/**
 * **Where the panel goes after an attempt that did not finish.**
 *
 * A DISMISSAL IS A DECISION, NOT A FAULT. Cancelling a passkey prompt is the person saying "not
 * that one" or "not now", and answering it with a failure screen and a Try again button reports an
 * error they already know about and makes them press one more thing to get back to where they were.
 * So the form simply stays — which is what every platform does with its own prompts, and what was
 * asked for.
 *
 * Everything else is a fault worth showing: a named refusal, a chain that would not verify, storage
 * that would not write, an identity nobody confirmed.
 */
export function afterFailure (reason: string, pending: PendingOffers,
                              stranded = false): SetupState {
  // `pending` is carried through rather than reset: a cancelled prompt is exactly the state the
  // offer to finish exists for, and dropping it there would hide the route on the one screen where
  // a person has just demonstrated they need it.
  return reason === "dismissed"
    ? { kind: "choosing", pending }
    : { kind: "failed", reason, stranded };
}

const REASONS: Record<string, string> = {
  // **NOT `dismissed` — that one never reaches this map** (`afterFailure` returns to the form).
  // These are the refusals a browser NAMES, which means something is genuinely wrong.
  "refused/SecurityError": "This page's address cannot use passkeys.",
  "refused/NotSupportedError": "This device cannot make the kind of passkey Xpromptvs needs.",
  "refused/InvalidStateError": "This device already has a passkey for this identity.",
  unsupported: "This browser has no passkey support.",
  "not-confirmed": "Nothing was added.",
  // Reachable only as a race — the offer to finish is drawn FROM the retained entry, so seeing this
  // means it went away between the panel painting and the button being pressed.
  "no-pending": "That setup is no longer here. Use a passkey or create one.",
  // **A refusal, not a verdict on the passkey.** §12.2: absence from the directory is never
  // revocation — nothing is registered under this credential, which a Mac joining the identity
  // fixes, and a pairing code sidesteps entirely.
  "not-found": "No identity is registered for that passkey yet. Pair with your Mac instead, "
             + "or make a new identity here.",
  // What `verifyDiscoveredRoot` says when the descriptor that came back is for another relying
  // party. Worth its own sentence: it means the answer was wrong, not that the passkey was.
  "root-rpid": "The identity that came back belongs to a different site. Nothing was added.",
  "credential-mismatch": "The identity that came back is not the one that passkey belongs to. "
                       + "Nothing was added.",
  signature: "The identity that came back could not be verified. Nothing was added.",
  // The Mac's own ceremony (`E2EPasskeyFailure.reason`, `E2EHost`'s codes).
  "not-associated": "Apple has not yet confirmed that Xpromptvs may use passkeys for this site. "
                  + "Try again in a few minutes.",
  lookup: "Could not reach the directory to look that passkey up. Try again.",
  chain: "What came back could not be verified. Nothing was added.",
  "already-enrolling": "A passkey prompt is already open.",
  "not-applicable": "This Mac already has an identity.",
  "no-storage": "This Mac has nowhere to store an identity.",
};

function reason (raw: string, device: SetupDevice): string {
  if (raw === "storage") return `${DEVICE[device].Self} could not store the result.`;
  return REASONS[raw] ?? `It ended with: ${raw}.`;
}

// ------------------------------------------------------------------ the panel

/**
 * Mount the setup panel and run the flow.
 *
 * The DECISION is `e2eSetupView` above; this paints it and carries the answers back. It is the same
 * split `command-palette.ts` uses, and for the same reason: everything worth arguing about is in the
 * pure half, and the DOM half is glue that a jsdom test could only assert against itself.
 */
export interface SetupFlow {
  /**
   * Run a ceremony. `discover` asks the authenticator which roots it holds (§10.1) and joins the one
   * the person picks; `create` makes a new identity. `confirm` is §10.1's obligation and is called
   * only when a root is actually being adopted.
   */
  enroll(source: "discover" | "create" | "resume",
         /** `authorising` is answered with whether the person pressed Continue (`authorise`). */
         onStep?: (step: SetupStep) => void | Promise<boolean>):
    Promise<
      | { ok: true; deviceId: string; rootId: string }
      /** `stranded`: the Worker gave a DEFINITE "no record" — see `SetupState.failed`. */
      | { ok: false; reason: string; stranded?: boolean }
    >;
  /**
   * What can be done with retained creation material (§10.1 route 1)? Asynchronous because it is a
   * storage read, which is why the form paints without the offers and gains them a moment later.
   */
  pending(): Promise<PendingOffers>;
  /**
   * Delete a passkey. **Permanent and unconfirmed by the platform**, so the panel asks first —
   * `discard-confirm` or `stranded-confirm` is that question, and this runs only after it is
   * answered. `stranded` says WHICH: the retained descriptor, or the credential a discovery just
   * failed to resolve. They are different operations with different guarantees behind them.
   */
  discard(stranded: boolean): Promise<{ ok: true } | { ok: false; reason: string }>;
  /** The session can start now. */
  done(): void;
  /** Whose sentences: a browser's (the default) or the Mac's. */
  device?: SetupDevice;
}

/**
 * `showModal` where it exists, the `open` attribute where it does not.
 *
 * **jsdom 25 implements neither `showModal` nor `close`** (measured), so a unit test can only ever
 * observe the attribute. The capability is checked rather than the environment, which is the same
 * rule `webauthn-ceremony.ts`'s `available()` follows: a check that throws is worse than one that
 * answers.
 */
function openDialog (root: HTMLElement): void {
  const dialog = root as HTMLDialogElement;
  if (typeof dialog.showModal === "function") { if (!dialog.open) dialog.showModal(); }
  else root.setAttribute("open", "");
}

function closeDialog (root: HTMLElement): void {
  const dialog = root as HTMLDialogElement;
  if (typeof dialog.close === "function") dialog.close();
  else root.removeAttribute("open");
}

const setupOwners = new WeakMap<HTMLElement, object>();
export function mountE2ESetup (root: HTMLElement, flow: SetupFlow, dialogs: {open(root:HTMLElement):void;close(root:HTMLElement):void;signal?:AbortSignal} = {open: openDialog, close: closeDialog}): void {
  const owner={};setupOwners.set(root,owner);
  const live=()=>!dialogs.signal?.aborted && setupOwners.get(root)===owner;
  const title = root.querySelector<HTMLElement>("#e2e-setup-title")!;
  const body = root.querySelector<HTMLElement>("#e2e-setup-body")!;
  const identity = root.querySelector<HTMLElement>("#e2e-setup-identity")!;
  const actions = root.querySelector<HTMLElement>("#e2e-setup-actions")!;

  // The state on screen, so `cancel` can consult `dismissal` rather than guess.
  let current: SetupState = { kind: "choosing", pending: NOTHING_PENDING };

  // **Read asynchronously, so the panel never waits to paint.** A dialog that blanked on every open
  // for the sake of a button most people never need would be a worse trade than showing the offer
  // a moment late.
  let pending: PendingOffers = NOTHING_PENDING;

  // Which confirmation is in flight. Latched when `discard` is pressed rather than read from
  // `current`, because by the time the answer comes back the panel is showing `working`.
  let strandedFlow = false;

  // The create route waiting between its prompts (`authorise`): answered by Continue (go), or by
  // Not now / Esc (stop — the panel closes and the passkey stays retained).
  let gate: ((go: boolean) => void) | null = null;
  const answer = (go: boolean): void => { const g = gate; gate = null; g?.(go); };

  dialogs.signal?.addEventListener("abort",()=>{answer(false);dialogs.close(root);},{once:true});
  const render = (state: SetupState): void => {
    if(!live())return;
    current = state;
    const view = e2eSetupView(state, flow.device ?? "browser");
    dialogs.open(root);
    root.dataset.tone = view.tone;
    title.textContent = view.title;
    body.textContent = view.body;

    identity.hidden = view.identity === null;
    identity.textContent = view.identity ?? "";

    actions.replaceChildren();
    for (const action of view.actions) {
      const button = document.createElement("button");
      button.textContent = action.label;
      // A modal on the dashboard: the glasses D-pad reaches only `[data-nav-id]` (docs/glasses.md).
      button.dataset.navId = `e2e-setup:${action.id}`;
      button.disabled = view.busy;
      button.addEventListener("click", () => { void act(action.id); });
      actions.appendChild(button);
    }
  };

  const act = async (id: SetupAction): Promise<void> => {
    if(!live())return;
    switch (id) {
      case "discover": await begin("discover"); return;
      case "create": await begin("create"); return;
      case "resume": await begin("resume"); return;
      // Synchronously, inside the click: the grant's prompt must start from it.
      case "authorise": answer(true); return;
      // Two steps on purpose. The platform deletes silently, so the only thing between a misplaced
      // click and a permanently gone passkey is this screen.
      // One action, two sources: the choosing screen (a retained descriptor — certain) and the
      // failure screen (a credential the Worker did not know — uncertain). The state it came FROM
      // is what picks the confirmation, so the two can never show each other's copy.
      case "discard":
        strandedFlow = current.kind === "failed";
        render(strandedFlow ? { kind: "stranded-confirm" } : { kind: "discard-confirm" });
        return;
      case "discard-no":
        render(strandedFlow ? { kind: "failed", reason: "not-found", stranded: true }
                            : { kind: "choosing", pending });
        return;
      case "discard-yes": await discard(); return;
      // **The panel goes busy the moment the answer is given.** A confirmation is followed by a
      // second passkey prompt, and leaving "Add this browser" live underneath it invites a person to
      // press it again — which is a second ceremony against a flow that already has one in hand.
      case "retry": render({ kind: "choosing", pending }); return;
      case "dismiss": dialogs.close(root); answer(false); return;
      case "close": dialogs.close(root); flow.done(); return;
    }
  };

  // Esc, which `showModal()` gives this dialog for free and three of its states would be wrong to
  // honour. `dismissal` is the rule; this only carries it out.
  //
  // Idempotent assignment, not `addEventListener`: `#e2e-setup` is BODY-LEVEL and outlives any one
  // session (session-dom.ts) — `mountE2ESetup` runs again every time a session needs sign-in, and a
  // plain listener here would stack one per call, each one a stale closure over its own `current`.
  root.oncancel = (event) => {
    switch (dismissal(current)) {
      case "no": event.preventDefault(); return;
      // Prevented AND answered: the flow continues to `failed`, so the panel stays open saying
      // nothing was added rather than vanishing mid-enrollment.
      case "done": flow.done(); return;
      case "close": answer(false); return;
    }
  };

  const begin = async (source: "discover" | "create" | "resume"): Promise<void> => {
    const step: SetupStep =
      source === "discover" ? "discovering" : source === "resume" ? "resuming" : "creating";
    render({ kind: "working", step });
    // **The create route changes its message BETWEEN its two prompts.** One message across both is
    // what made the second read as the first repeating; the flow says when the passkey exists and
    // the screen moves on. Ignored by every other route, which has one prompt and one message.
    const onStep = (next: SetupStep): void | Promise<boolean> => {
      if(!live())return Promise.resolve(false);
      if (next !== "authorising") { render({ kind: "working", step: next }); return; }
      render({ kind: "authorise" });
      return new Promise<boolean>((resolve) => {
        gate = (go) => { if (go) render({ kind: "working", step: "authorising" }); resolve(go); };
      });
    };
    // **ONE CEREMONY, AND NOTHING INTERRUPTS IT.** Discovery and the grant used to be two prompts,
    // because the grant's challenge was `H(grant)` and a grant names its root — which this browser
    // learns only from the first. §10.4's commitment removed the root from the signed bytes, so the
    // assertion that finds the credential is the one the grant is made of. The `enrolling` step went
    // with the prompt it described.
    const result = await flow.enroll(source, onStep);
    if(!live())return;
    if (result.ok) { render({ kind: "ready", deviceId: result.deviceId, rootId: result.rootId }); return; }
    // Re-read: a create that stopped after its passkey (or a resume) changed what there is to finish.
    pending = await flow.pending().catch(() => pending);
    const next = afterFailure(result.reason, pending, result.stranded ?? false);
    // Not now / Esc between the prompts closed the panel; reopening it here would undo that.
    if (result.reason === "dismissed" && !root.hasAttribute("open")) { current = next; return; }
    render(next);
  };

  const discard = async (): Promise<void> => {
    const stranded = strandedFlow;
    render({ kind: "working", step: "discarding" });
    const result = await flow.discard(stranded);
    if(!live())return;
    if (!result.ok) { render({ kind: "failed", reason: result.reason, stranded: false }); return; }
    // Nothing is left to finish OR to delete, so the form comes back without either offer — showing
    // them again would invite a second deletion of something already gone.
    pending = NOTHING_PENDING;
    render({ kind: "choosing", pending });
  };

  render({ kind: "choosing", pending });
  void flow.pending().then((offers) => {
    if(!live())return;
    pending = offers;
    // **BOTH GUARDS ARE LOAD-BEARING, and the second was found by `dashboard-signin-check`.**
    // Re-rendering over a live ceremony would throw away the state the flow is waiting on — and
    // `render` OPENS the dialog unconditionally, so re-rendering after a dismissal re-opened a
    // panel the person had just closed, seconds later and by itself. Showing the offer a visit late
    // is a far smaller cost than a dialog that will not stay shut.
    if (current.kind === "choosing" && root.hasAttribute("open")) {
      render({ kind: "choosing", pending });
    }
  }).catch(() => {});
}
