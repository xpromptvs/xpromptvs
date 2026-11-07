import {openClientDialog,closeClientDialog} from "./instance/overlays";
import { mismatchView, type IdentityMismatch } from "./identity-mismatch";

/**
 * Paint the mismatch confirmation and carry the answer back.
 *
 * Same shape as `web/src/shared/sign-out-dialog.ts`, and for the same reason: the words are DATA, so
 * the one thing a test cannot see (the markup) holds nothing a person reads.
 *
 * **`showModal()` puts it in the TOP LAYER**, which is why it needs no `z-index` — `#windows` sits
 * above both bars on an inline z-index no stylesheet can beat, and a plain overlay would lose to it.
 *
 * **CANCEL DOES NOTHING AT ALL.** A confirmation whose dismissal performs the act is not one, so
 * both paths close and only Replace calls back. Dismissing with Escape is a Cancel: `close` fires
 * for it too, and resolving there is what keeps a caller from awaiting a promise that never settles.
 */
export function askIdentityMismatch(m: Extract<IdentityMismatch, { kind: "mismatch" }>,
                                    root: ParentNode = document): Promise<"replace" | "cancel"> {
  const dialog = root.querySelector<HTMLDialogElement>("#identity-mismatch");
  // No dialog is a Cancel, never a silent Replace: a window whose document lacks the element must
  // not swap an identity because it could not ask.
  if (!dialog) return Promise.resolve("cancel");

  const view = mismatchView(m);
  const set = (id: string, text: string) => {
    const el = dialog.querySelector(id);
    if (el) el.textContent = text;
  };
  set("#identity-mismatch-title", view.title);
  set("#identity-mismatch-body", view.body);
  set("#identity-mismatch-window-label", view.windowLabel);
  set("#identity-mismatch-mac-label", view.macLabel);
  set("#identity-mismatch-window", m.window);
  set("#identity-mismatch-mac", m.mac);

  const confirm = dialog.querySelector<HTMLButtonElement>("[data-identity-mismatch-confirm]");
  const cancel = dialog.querySelector<HTMLButtonElement>("[data-identity-mismatch-cancel]");
  if (confirm) confirm.textContent = view.confirm;
  if (cancel) cancel.textContent = view.cancel;

  return new Promise(resolve => {
    // ONE settle for three routes: Replace, Cancel, and Esc — which `showModal()` gives a dialog for
    // free and which must mean Cancel, not a promise that never resolves behind a closed dialog.
    let settled = false;
    const finish = (answer: "replace" | "cancel") => {
      if (settled) return;
      settled = true;
      closeDialog(dialog);
      resolve(answer);
    };
    // Idempotent assignment, not `addEventListener`: `#identity-mismatch` is BODY-LEVEL and outlives
    // any one session (session-dom.ts), so a plain listener here would stack one per call across
    // sessions — a stale one from an earlier call still firing `finish` on a promise long since settled.
    dialog.onclose = () => finish("cancel");
    if (confirm) confirm.onclick = () => finish("replace");
    if (cancel) cancel.onclick = () => finish("cancel");
    openDialog(dialog);
  });
}

/**
 * `showModal` where it exists, the `open` attribute where it does not — the same pair `e2e-setup.ts`
 * carries, for the same measured reason: **jsdom 25 implements neither `showModal` nor `close`**, so
 * a unit test can only ever observe the attribute. The CAPABILITY is checked, never the environment.
 */
function openDialog(dialog: HTMLDialogElement): void {
  openClientDialog(dialog);
}

function closeDialog(dialog: HTMLDialogElement): void {
  closeClientDialog(dialog);
}
