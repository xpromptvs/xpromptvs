import { describe, expect, test } from "vitest";
import { profileDialogView } from "../src/shared/profile-dialog";
import { signOutConfirmView } from "../src/shared/sign-out-dialog";

// The header's profile control, on both dashboards. There is no account behind it — passkey-only
// identity deleted sign-in, names and emails — so "who you are" is §10.1's root as the code a
// person reads, and the whole surface is that code plus the one thing you can do about it.
const CODE = "C1P9-HM5S-6D93-FPDC";

describe("profileDialogView", () => {
  // **A PROFILE CONTROL ON A SURFACE THAT BELONGS TO NOBODY invites a search for an account that
  // was deliberately removed.** Signing in lives in the device list's empty state, and that is the
  // only place that offers it.
  test("there is no button when there is no identity", () => {
    for (const surface of ["browser", "mac", "app-client"] as const) {
      const v = profileDialogView({ kind: "signed-out" }, surface);
      expect(v.hidden, surface).toBe(true);
      // Nothing left over for a renderer to paint from a stale view.
      expect(v.identity, surface).toBe("");
      expect(v.actions, surface).toEqual([]);
    }
  });

  // §10.1 asks a person to compare this against another device they trust, and an abbreviation is
  // not something you can check.
  test("THE IDENTITY IS CARRIED IN FULL, and it names the button too", () => {
    const v = profileDialogView({ kind: "signed-in", identity: CODE }, "browser");
    expect(v.hidden).toBe(false);
    expect(v.identity).toBe(CODE);
    // The glyph alone names nothing, so the accessible name carries the code.
    expect(v.label).toContain(CODE);
  });

  // **BOTH SURFACES CAN SIGN OUT**, since `rdev_host_e2e_forget` (2026-09-14). A Mac was offered
  // only `Close` before that, on the grounds that no C ABI call could delete the host's keys —
  // which was a GAP, not a principle.
  //
  // **"Sign out", the word Settings already used.** This said "Log out" for an afternoon; one
  // action with two names in one product is the drift everything else here exists to prevent.
  test("both surfaces offer the same way out, and it is named what Settings names it", () => {
    for (const surface of ["browser", "mac", "app-client"] as const) {
      expect(profileDialogView({ kind: "signed-in", identity: CODE }, surface).actions, surface)
        .toEqual([{ id: "sign-out", label: "Sign out", danger: true },
                  { id: "close", label: "Cancel", danger: false }]);
    }
    // The label a person reads is the same one the confirmation in Settings presses.
    expect(profileDialogView({ kind: "signed-in", identity: CODE }, "browser").actions[0]!.label)
      .toBe(signOutConfirmView("browser").confirm);
  });

  // **THIS ALERT IS NOT THE CONFIRMATION.** It was for an afternoon — it carried the warning and
  // its Sign out acted. Signing out deletes keys, so it gets the separate alert every other
  // destructive thing here gets (`sign-out-dialog.ts`), which is also where Settings' own button
  // leads. What survives here is that exactly one action is the destructive one and Cancel exists.
  test("exactly one action is destructive, and a way out sits beside it", () => {
    for (const surface of ["browser", "mac", "app-client"] as const) {
      const v = profileDialogView({ kind: "signed-in", identity: CODE }, surface);
      const danger = v.actions.filter((a) => a.danger);
      expect(danger, surface).toHaveLength(1);
      expect(danger[0]!.id, surface).toBe("sign-out");
      expect(v.actions.some((a) => a.id === "close"), surface).toBe(true);
    }
  });

  // The same property `deviceListView` holds: the two dashboards are one implementation, and every
  // difference between them is a named one rather than a string that drifted.
  test("the two surfaces differ in the noun, and in nothing else", () => {
    const browser = profileDialogView({ kind: "signed-in", identity: CODE }, "browser");
    const mac = profileDialogView({ kind: "signed-in", identity: CODE }, "mac");
    expect(mac.identity).toBe(browser.identity);
    expect(mac.label).toBe(browser.label);
    expect(mac.heading).toBe(browser.heading);
    expect(mac.actions).toEqual(browser.actions);
    expect(mac.body).toMatch(/Mac/);
    expect(browser.body).toMatch(/browser/);
    // The app's client window: the same view, with its own noun — the identity its MAC belongs to.
    const win = profileDialogView({ kind: "signed-in", identity: CODE }, "app-client");
    expect({ ...win, body: "" }).toEqual({ ...browser, body: "" });
    expect(win.body).toMatch(/window/);
    expect(win.body).not.toBe(mac.body);
  });
});
