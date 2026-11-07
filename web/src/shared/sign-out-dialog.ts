import type { Surface } from "./surface";

/**
 * **The sign-out confirmation, and the copy that makes it one.**
 *
 * ONE dialog, TWO ways in: the header's profile alert, and — in a browser — Settings' own Sign out
 * button. They were about to be two confirmations saying the same thing in two places, which is the
 * shape everything else in `web/src/shared/` exists to avoid.
 *
 * **IT SAYS WHAT SIGNING OUT DOES NOT DO.** Deleting a device's keys ends its use of the grant it
 * holds; it does not revoke that grant, which is a root-signed act needing the passkey (§10.5), and
 * it does not remove anything a directory lists. A person who reads this as "remove this device from
 * my identity" would be wrong about both, and about a copy of the storage taken beforehand.
 * `docs/e2e.md` requires the interface to say so.
 *
 * It also says the way back, because there is one on both surfaces: sign in again with the same
 * passkey — in a browser, or on the Mac itself since 2026-10-06.
 */

export interface SignOutConfirmView {
  title: string;
  body: string;
  confirm: string;
  cancel: string;
}

const CONFIRM: Record<Surface, SignOutConfirmView> = {
  browser: {
    title: "Sign out of this browser?",
    body: "This browser’s saved sign-in is removed. Your other devices stay signed in. "
        + "Your passkey is untouched — sign in with it again to come back. "
        + "It does not revoke the access this browser already had; anything holding a copy of its "
        + "keys could still have access.",
    confirm: "Sign out",
    cancel: "Cancel",
  },
  mac: {
    title: "Sign out of this Mac?",
    body: "This Mac’s saved sign-in is removed. Your other devices stay signed in. Nothing can "
        + "connect to it until you sign in again with your passkey. "
        + "It does not revoke the access this Mac already had; anything holding a copy of its "
        + "keys could still have access.",
    confirm: "Sign out",
    cancel: "Cancel",
  },
  // The app's own client window: a SUBORDINATE device its Mac certifies (§10.3). Only the window's
  // keys go, and the Mac certifies fresh ones the next time the window connects — no passkey.
  "app-client": {
    title: "Sign out of this window?",
    body: "This window’s saved sign-in is removed until the next "
        + "time it connects to this Mac, which signs it back in on its own. "
        + "It does not revoke the access this window already had; anything holding a copy of its "
        + "keys could still have access.",
    confirm: "Sign out",
    cancel: "Cancel",
  },
};

export function signOutConfirmView (surface: Surface): SignOutConfirmView { return CONFIRM[surface]; }

/**
 * Paint it and carry the answer back. Returns `ask`, which opens it.
 *
 * **CANCEL LEAVES EVERYTHING ALONE.** A destructive confirmation whose dismissal does the thing
 * anyway is not a confirmation; both paths close the dialog and only one of them calls back.
 */
export function mountSignOutDialog (opts: {
  root: ParentNode;
  surface: Surface;
  onConfirm: () => void;
}): () => void {
  const dialog = opts.root.querySelector<HTMLDialogElement>("#sign-out-dialog");
  if (!dialog) return () => {};
  const view = signOutConfirmView(opts.surface);

  dialog.querySelector("#sign-out-title")!.textContent = view.title;
  dialog.querySelector("#sign-out-body")!.textContent = view.body;
  const confirm = dialog.querySelector<HTMLButtonElement>("[data-sign-out-confirm]")!;
  const cancel = dialog.querySelector<HTMLButtonElement>("[data-sign-out-cancel]")!;
  confirm.textContent = view.confirm;
  cancel.textContent = view.cancel;
  cancel.onclick = () => dialog.close();
  confirm.onclick = () => { dialog.close(); opts.onConfirm(); };

  return () => { if (!dialog.open) dialog.showModal(); };
}
