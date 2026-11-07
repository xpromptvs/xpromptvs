import type { Surface } from "./surface";

/**
 * **The profile button in the header, and the alert it opens.**
 *
 * One implementation, both dashboards — the browser's `#welcome` header and the app's `app://ui/`
 * header, which are the same header (`docs/ui-design.md`).
 *
 * **There is no account behind it.** Passkey-only identity deleted sign-in, names, emails and
 * avatars (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`), so "who you are" here is
 * §10.1's ROOT, shown as the code a person reads: `C1P9-HM5S-6D93-FPDC`. That is the whole content
 * of the alert, plus the one thing you can do about it.
 *
 * **The button does not exist when there is no identity.** A profile control on a surface that
 * belongs to nobody is an invitation to look for an account that was deliberately removed; the
 * device list's empty state is where signing in lives, and it is the only place that offers it.
 *
 * **A MODAL `<dialog>`, like every other alert in the client** — `#e2e-setup`, the sign-out
 * confirmation, Add a device. It replaced an anchored popover on 2026-09-14: a menu that carries a
 * destructive action is not a menu, and `showModal()` brings the top layer, the backdrop, focus
 * containment and Escape for nothing, all of which a hand-built popover has to reimplement badly.
 *
 * **IT IS NOT THE CONFIRMATION.** It was for an afternoon — it carried the warning and its Sign out
 * acted — which made it an identity card that also happened to be a confirmation. Signing out
 * deletes keys, so it gets the separate alert every other destructive thing here gets:
 * `sign-out-dialog.ts`, which is also where Settings' own button leads, so there is ONE set of words
 * about what signing out does not do rather than two.
 *
 * The DECISION is `profileDialogView`, pure and tested, for the reason `deviceListView` and
 * `e2eSettings` are: what a person reads is the whole product of this module.
 */

export type ProfileState =
  /** No identity — no button. */
  | { kind: "signed-out" }
  /** `identity` is §10.1's readable code, NEVER a device id and never abbreviated. */
  | { kind: "signed-in"; identity: string };

/** `close` is the way out that does nothing; it is handled by the renderer and never reported. */
export type ProfileAction = "sign-out" | "close";

export interface ProfileDialogAction {
  id: ProfileAction;
  label: string;
  /** Destructive, and styled as such. Exactly one action may be. */
  danger: boolean;
}

export interface ProfileDialogView {
  /** The BUTTON is absent, not disabled: there is nothing here to come back to. */
  hidden: boolean;
  /** The button's accessible name. It carries the code, because the glyph alone names nothing. */
  label: string;
  heading: string;
  body: string;
  /** IN FULL. §10.1 asks a person to compare this against another device they trust. */
  identity: string;
  actions: ProfileDialogAction[];
}

const NOTHING: ProfileDialogView = {
  hidden: true, label: "", heading: "", body: "", identity: "", actions: [],
};

export function profileDialogView (state: ProfileState, surface: Surface): ProfileDialogView {
  if (state.kind === "signed-out") return NOTHING;
  return {
    hidden: false,
    label: `Your devices, ${state.identity}`,
    heading: "Your devices",
    body: surface === "browser" ? "This browser is linked to the devices using your passkey. Their shared device group code is shown below."
      : surface === "mac" ? "This Mac is linked to the devices using your passkey. Their shared device group code is shown below."
      : "This window is linked through this Mac. Its shared device group code is shown below.",
    identity: state.identity,
    // **BOTH SURFACES CAN SIGN OUT.** A Mac could not until 2026-09-14, and this offered it `Close`
    // for that reason — but "there is no C ABI call that deletes the host's keys" was a GAP, not a
    // principle, and `rdev_host_e2e_forget` closed it.
    //
    // **"Sign out", the same words Settings uses.** This said "Log out" for an afternoon and the
    // product had two names for one action; the other surface's was the older one, so this moved.
    // The destructive action leads and Cancel closes the row. Pressing it opens the CONFIRMATION
    // (`sign-out-dialog.ts`) rather than acting — this alert is where you read who you are.
    actions: [{ id: "sign-out", label: "Sign out", danger: true },
              { id: "close", label: "Cancel", danger: false }],
  };
}

// ------------------------------------------------------------------ the DOM half

/**
 * Paint `profileDialogView` into the header, and open and close the alert. DOM glue only, in the
 * split `device-list.ts` uses.
 *
 * **`showModal()`, never `show()`** — the top layer is what puts it over a dashboard that has an
 * inline-z-index window layer of its own, and it is what the repo learned the hard way with
 * `#e2e-setup` (`docs/client-web.md`). Escape and the backdrop come with it.
 */
export function mountProfileDialog (opts: {
  /** Where the header and the dialog live. The browser scopes this to `#welcome`; the app uses the document. */
  root: ParentNode;
  surface: Surface;
  /** The browser re-mounts its overlay after every session, and each mount drops the last one's listeners. */
  signal?: AbortSignal;
  onAction: (id: Exclude<ProfileAction, "close">) => void;
}): (state: ProfileState) => void {
  const wrap = opts.root.querySelector<HTMLElement>("#profile");
  const button = opts.root.querySelector<HTMLButtonElement>("#profile-open");
  const dialog = opts.root.querySelector<HTMLDialogElement>("#profile-dialog");
  if (!wrap || !button || !dialog) return () => {};
  const listener = opts.signal ? { signal: opts.signal } : undefined;

  button.addEventListener("click", () => { if (!dialog.open) dialog.showModal(); }, listener);

  return (state: ProfileState): void => {
    const view = profileDialogView(state, opts.surface);
    wrap.hidden = view.hidden;
    // **The identity can go away underneath an open alert** — which is exactly what logging out
    // does — so closing is part of painting, not only of pressing a button.
    if (view.hidden) { if (dialog.open) dialog.close(); return; }

    button.setAttribute("aria-label", view.label);
    dialog.querySelector("#profile-dialog-heading")!.textContent = view.heading;
    dialog.querySelector("#profile-dialog-body")!.textContent = view.body;
    // textContent, never innerHTML, and never shortened: §10.1 asks a person to check this against
    // a device they already trust, and an abbreviation is not something you can check.
    dialog.querySelector("#profile-dialog-identity")!.textContent = view.identity;
    const actions = dialog.querySelector<HTMLElement>("#profile-dialog-actions")!;
    actions.replaceChildren();
    for (const action of view.actions) {
      const b = document.createElement("button");
      b.type = "button";
      if (action.danger) b.className = "danger";
      b.dataset.profileAction = action.id;
      // The glasses D-pad moves between `[data-nav-id]`, and a control without one is unreachable
      // there. Carried at the RENDER SITE, which for a button built here is here.
      b.dataset.navId = `profile:${action.id}`;
      b.textContent = action.label;
      // **CLOSED ON EVERY PATH, and only one of them acts.** A destructive alert whose dismissal
      // does the thing anyway is not a confirmation.
      b.addEventListener("click", () => {
        dialog.close();
        if (action.id !== "close") opts.onAction(action.id);
      });
      actions.appendChild(b);
    }
  };
}
