/**
 * **What Settings says about the identity this browser holds, and the way out.** As DATA, not DOM.
 *
 * A separate module for the reason `device-list.ts` and `e2e-setup.ts` are: the whole product of
 * this surface is a few sentences, and jsdom can assert a string where it cannot assert a layout.
 *
 * Signing out is the analogue of the account Log out this replaced — and it means something
 * genuinely different, which is the entire reason the copy below is as careful as it is.
 */
export type IdentitySettingsState =
  /** Nothing to show, and nothing to leave. */
  | { kind: "none" }
  /** The root this browser trusts, as §10.1's readable code. */
  | { kind: "held"; rootId: string }
  | { kind: "signing-out" };

export interface IdentitySettingsView {
  hidden: boolean;
  heading: string;
  body: string;
  /** The identity, IN FULL. §10.1 asks a person to compare it against a device they trust. */
  identity: string;
  /** The button's label, or null when there is nothing to press. */
  action: string | null;
  busy: boolean;
}

const NOTHING: IdentitySettingsView = {
  hidden: true, heading: "", body: "", identity: "", action: null, busy: false,
};

export function identitySettingsView (state: IdentitySettingsState): IdentitySettingsView {
  switch (state.kind) {
    // A browser with no identity has nothing to show here. The device list is where it is offered
    // one, and a second empty panel saying the same thing in other words is how two surfaces come
    // to disagree.
    case "none": return NOTHING;

    case "held":
      return {
        hidden: false,
        heading: "Your devices",
        // **NEVER ABBREVIATED.** §10.1 asks a person to check an identity against another device
        // they trust, and an abbreviation is not something you can check.
        body: "Signed in on this browser.",
        identity: state.rootId,
        action: "Sign out",
        busy: false,
      };

    case "signing-out":
      return { hidden: false, heading: "Your devices", body: "Signing out…",
               identity: "", action: null, busy: true };
  }
}
