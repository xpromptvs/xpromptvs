/**
 * **ADD DEVICE BY CODE — one dialog, both dashboards** (2026-10-07, asked for: "We should add a dedicated Add
 * device by code workflow"; docs/pairing.md, "Add device by code").
 *
 * A new Mac's Add by code shows a code; this dialog is where a device that holds the identity ENTERS it — typed,
 * pasted (a bare code or the link its QR encodes) or scanned — confirms the identity the Mac will join, and has
 * its passkey sign the Mac's grant. Before it, the code had nowhere to go but Connect, which starts a GUEST
 * pairing: both ends spoke first and the new Mac refused the handshake as `gate/noise`.
 *
 * What differs between the surfaces is only who runs the adoption (`AddDevice`): a browser drives §11.1's
 * responder itself (`web/src/client/adopt.ts`), the Mac app asks its host (`AddDeviceHost`, the bridge's
 * `addDevice*` ops) and follows the state it pushes. Both report the same `AddDeviceState`s, and every word the
 * dialog says is `addDeviceView`'s — pure, so the wording is testable without a socket, a Mac or a passkey.
 */

/** Where one run is. The form is the dialog's own; every other state is the surface's report. */
export type AddDeviceState =
  /** The code field. `error` when the last entry was not a code. */
  | { kind: "form"; error?: string }
  /** This device holds no identity to add the Mac to. */
  | { kind: "no-identity" }
  /** In the code's room; the new Mac has not spoken yet. */
  | { kind: "waiting" }
  /** The new Mac is authenticated and owed a chain. NOTHING IS SIGNED until the person says so. */
  | { kind: "confirm"; identityCode: string }
  /** The passkey has been asked for. */
  | { kind: "issuing" }
  /** Its chain was sent; the new Mac's word that it committed it is awaited (`AdoptionAck`). */
  | { kind: "finishing" }
  /** The new Mac SAID it committed its chain. `publication` is this device's own listing (§12.2) — `rejected` has
   *  required wording. */
  | { kind: "added"; publication: "confirmed" | "unconfirmed" | "rejected" }
  | { kind: "failed"; reason: string };

/** One run, as the dialog steers it. */
export interface AddDeviceRun {
  /** The person's answer to "Add this Mac?". */
  confirm(add: boolean): void;
  /** The dialog closed: stop, and report nothing more. */
  cancel(): void;
}

/** What a surface does to add a Mac: start one run for `carrier`, reporting each state through `onState`. */
export type AddDevice = (carrier: string, onState: (state: AddDeviceState) => void) => AddDeviceRun;

/**
 * The code in what was entered: the bare carrier (§9.1's 22 base64url characters — SHAPE is the discriminator)
 * or the `#adopt=` link its QR encodes, pasted whole. Null for anything else. A `#pair=` link is a GUEST code
 * and belongs in Connect, so it is refused here as Connect refuses nothing.
 */
export function addDeviceCarrier (raw: string): string | null {
  const t = raw.trim();
  if (CARRIER.test(t)) return t;
  const hash = t.indexOf("#");
  if (hash < 0) return null;
  const adopt = new URLSearchParams(t.slice(hash + 1)).get("adopt");
  return adopt && CARRIER.test(adopt) ? adopt : null;
}
const CARRIER = /^[A-Za-z0-9_-]{22}$/;

export interface AddDeviceAction { id: "add" | "confirm" | "sign-in" | "retry" | "done" | "close"; label: string; primary?: boolean }

export interface AddDeviceView {
  heading: string;
  body: string;
  /** The code field (and Scan, where a camera exists). */
  field: boolean;
  /** The identity code, shown selectable — §10.1's naming before the device commits. */
  identity: string | null;
  error: string | null;
  actions: AddDeviceAction[];
  /** A run is under way: Escape and the backdrop cancel it. */
  busy: boolean;
}

/** Every word the dialog says. PURE. */
export function addDeviceView (state: AddDeviceState): AddDeviceView {
  const base = { field: false, identity: null, error: null, busy: false };
  switch (state.kind) {
    case "form":
      return {
        ...base,
        heading: "Add a Mac",
        body: "On the new Mac, open Xpromptvs and choose Add by code. Enter the code it shows.",
        field: true,
        error: state.error ?? null,
        actions: [{ id: "add", label: "Add", primary: true }, { id: "close", label: "Cancel" }],
      };
    case "no-identity":
      return {
        ...base,
        heading: "Sign in first",
        body: "A Mac joins the identity this device holds, and this device holds none yet. "
            + "Sign in with your passkey, then add the Mac.",
        actions: [{ id: "sign-in", label: "Sign in", primary: true }, { id: "close", label: "Cancel" }],
      };
    case "waiting":
      return {
        ...base, busy: true,
        heading: "Waiting for the new Mac",
        body: "Keep its code on screen until this finishes.",
        actions: [{ id: "close", label: "Cancel" }],
      };
    case "confirm":
      return {
        ...base, busy: true,
        heading: "Add this Mac?",
        body: "It will join this identity and will be able to share its screen. "
            + "It will not be able to add other devices, or connect out to your other Macs.",
        identity: state.identityCode,
        actions: [{ id: "confirm", label: "Add this Mac", primary: true }, { id: "close", label: "Cancel" }],
      };
    case "issuing":
      return { ...base, busy: true, heading: "Adding it now", body: "Confirm with your passkey.", actions: [] };
    case "finishing":
      return { ...base, busy: true, heading: "Adding it now", body: "Waiting for the Mac to confirm.", actions: [] };
    case "added":
      return {
        ...base,
        heading: "This Mac is added",
        body: state.publication === "rejected"
          // §12.2's REQUIRED WORDING, quoted rather than paraphrased.
          ? "Publication rejected; listing not confirmed. Action required."
          : "It can share its screen, and it appears in My Devices.",
        actions: [{ id: "done", label: "Done", primary: true }],
      };
    case "failed":
      return {
        ...base,
        heading: "That did not finish",
        body: `${addDeviceReason(state.reason)} Nothing about the Mac changed; show a new code on it to start again.`,
        actions: [{ id: "retry", label: "Try again", primary: true }, { id: "close", label: "Close" }],
      };
  }
}

/** A failure's code as a sentence. The browser's and the Mac's codes, where both can say one. */
export function addDeviceReason (reason: string): string {
  if (reason === "cancelled") return "The passkey was not confirmed.";
  if (reason === "not-a-code" || reason === "not a pairing code") return "That is not a code from a Mac's Add by code.";
  if (reason === "no-answer") {
    return "The Mac did not answer. Check that it still shows its code. "
         + "(A pairing code from Share this Mac goes in Connect with a code instead.)";
  }
  if (reason === "noise" || reason === "gate/noise") return "The code did not match the Mac's.";
  if (reason === "no-identity" || reason === "unreadable identity") return "This device holds no identity to add the Mac to.";
  if (reason === "disconnected") return "The connection to the Mac was lost.";
  // Its chain was sent and the Mac never said it had it (2026-10-07: the Mac mini's connection dropped as it was
  // sent). It may still say "Adding this Mac…" until it gives up.
  if (reason === "unconfirmed") {
    return "The Mac did not confirm it was added. If it still says Adding this Mac, press Stop there, then show a new code.";
  }
  if (reason.startsWith("mac-refused/")) return `The Mac refused what it was given (${reason.slice("mac-refused/".length)}).`;
  if (reason === "not-associated") return "This Mac cannot use your passkey yet: Apple has not confirmed its domain.";
  if (reason.startsWith("refused/")) return `The passkey refused (${reason.slice("refused/".length)}).`;
  return `Something went wrong (${reason}).`;
}

/**
 * The dialog's markup, inside the dashboard (`dashboard.ts` builds it beside the profile alert). Static, no
 * interpolation. Every control carries `data-nav-id` at its render site — the glasses D-pad reaches nothing else.
 */
export const ADD_DEVICE_DIALOG = `<dialog id="add-device-dialog" class="ss-dialog ss-add-device" aria-labelledby="add-device-title"><h2 id="add-device-title"></h2><p id="add-device-body"></p><div class="ss-quick" id="add-device-field"><input id="add-device-code" data-nav-id="add-device:code" type="text" autocomplete="off" autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="Code from the new Mac" aria-label="Code from the new Mac"><button id="add-device-scan" data-nav-id="add-device:scan" type="button" hidden aria-label="Scan the Mac's QR code" title="Scan the Mac's QR code"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3H4a1 1 0 0 0-1 1v4m13-5h4a1 1 0 0 1 1 1v4M3 16v4a1 1 0 0 0 1 1h4m8 0h4a1 1 0 0 0 1-1v-4"/><path d="M7 7h3v3H7zm7 0h3v3h-3zM7 14h3v3H7zm7 0v3h3v-3z"/></svg></button></div><p id="add-device-error" class="ss-error" role="alert" hidden></p><code id="add-device-identity" class="ss-profile-identity" hidden></code><div id="add-device-actions" class="ss-dialog-actions"></div></dialog>`;

export interface AddDeviceDialog {
  /** Open on the form — with `carrier` in the field, and started at once when `start` (a scanned `#adopt=` link). */
  open(carrier?: string, opts?: { start?: boolean }): void;
}

/**
 * Wire the dialog. `addDevice` runs one adoption; `scan` (a surface with a camera) reads a code into the field;
 * `signIn` is the no-identity state's way on; `onAdded` runs when one finishes (the list refreshes, the page
 * forgets an `#adopt=` link).
 */
export function mountAddDeviceDialog (opts: {
  root: HTMLElement;
  addDevice: AddDevice;
  scan?: (onCode: (raw: string) => void) => void;
  signIn?: () => void;
  onClosed?: (added: boolean) => void;
  signal?: AbortSignal;
}): AddDeviceDialog {
  const listener = opts.signal ? { signal: opts.signal } : undefined;
  const $ = <T extends HTMLElement>(id: string): T => opts.root.querySelector<T>(`#${id}`)!;
  const dialog = $<HTMLDialogElement>("add-device-dialog");
  const field = $("add-device-field");
  const input = $<HTMLInputElement>("add-device-code");
  const scan = $<HTMLButtonElement>("add-device-scan");
  const error = $("add-device-error");
  const identity = $("add-device-identity");
  const actions = $("add-device-actions");

  let run: AddDeviceRun | null = null;
  /** The current run's identity — its reports are painted only while it is this. */
  let current: object | null = null;
  let added = false;

  if (opts.scan && typeof navigator.mediaDevices?.getUserMedia === "function") {
    scan.hidden = false;
    scan.addEventListener("click", () => opts.scan!((raw) => { input.value = raw; start(); }), listener);
  }

  const paint = (next: AddDeviceState): void => {
    if (next.kind === "added") added = true;
    const view = addDeviceView(next);
    $("add-device-title").textContent = view.heading;
    $("add-device-body").textContent = view.body;
    field.hidden = !view.field;
    error.textContent = view.error ?? "";
    error.hidden = view.error === null;
    identity.textContent = view.identity ?? "";
    identity.hidden = view.identity === null;
    actions.replaceChildren(...view.actions.map((a) => {
      const button = document.createElement("button");
      button.type = "button";
      button.id = `add-device-${a.id}`;
      button.dataset.navId = `add-device:${a.id}`;
      button.textContent = a.label;
      if (a.primary) button.className = "primary";
      button.addEventListener("click", () => act(a.id));
      return button;
    }));
    // The person acts next: the field on the form, else the primary button — never a stale focus on a button
    // a repaint removed.
    if (dialog.open) (view.field ? input : actions.querySelector<HTMLButtonElement>(".primary") ?? actions.querySelector("button"))?.focus();
  };

  const start = (): void => {
    const carrier = addDeviceCarrier(input.value);
    if (!carrier) {
      paint({ kind: "form", error: "That is not a code from a Mac's Add by code. Check it and try again." });
      return;
    }
    stop();
    // Each run reports into the dialog only while it is the current one: a cancelled run's late report is
    // ignored. Waiting is painted FIRST, so a surface that reports synchronously overrides it.
    const token = {};
    current = token;
    paint({ kind: "waiting" });
    run = opts.addDevice(carrier, (s) => { if (current === token) paint(s); });
  };

  const stop = (): void => {
    const was = run;
    run = null;
    current = null;
    was?.cancel();
  };

  const close = (): void => {
    stop();
    if (dialog.open) dialog.close();
  };

  const act = (id: AddDeviceAction["id"]): void => {
    switch (id) {
      case "add": start(); return;
      case "confirm": run?.confirm(true); return;
      case "sign-in": close(); opts.signIn?.(); return;
      case "retry": stop(); paint({ kind: "form" }); return;
      case "done": case "close": close(); return;
    }
  };

  // Painted at once, closed: the controls exist in the markup from the start (the glasses' D-pad and its check
  // address them by `data-nav-id`).
  paint({ kind: "form" });
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); start(); } }, listener);
  // Escape, or a `close()` from anywhere: whatever is under way stops — a Mac half-added by a dialog nobody
  // sees is worse than one the person must start again.
  dialog.addEventListener("close", () => {
    stop();
    const wasAdded = added;
    added = false;
    opts.onClosed?.(wasAdded);
  }, listener);

  return {
    open (carrier?: string, o: { start?: boolean } = {}): void {
      stop();
      added = false;
      input.value = carrier ?? "";
      paint({ kind: "form" });
      if (!dialog.open) dialog.showModal();
      paint({ kind: "form" });   // focus, now that it is open
      if (carrier && o.start) start();
    },
  };
}
