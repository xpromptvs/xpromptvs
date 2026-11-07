import { describe, expect, test } from "vitest";
import { signOutConfirmView } from "../src/shared/sign-out-dialog";

// **ONE CONFIRMATION, TWO WAYS IN**: the header's profile alert, and — in a browser — Settings' own
// Sign out button. It was very nearly two dialogs saying the same thing in two places.
describe("signOutConfirmView", () => {
  // **THE SENTENCE THAT MATTERS IS THE ONE ABOUT WHAT IT DOES NOT DO.** Deleting a device's keys
  // ends its use of the grant; §10.5's revocation is a root-signed act needing the passkey, and
  // nothing here removes what a directory lists. A person who read "sign out" as "remove this
  // device from my identity" would be wrong about both. `docs/e2e.md` requires it to be said.
  test("EVERY SURFACE SAYS SIGNING OUT DOES NOT REVOKE", () => {
    for (const surface of ["browser", "mac", "app-client"] as const) {
      const v = signOutConfirmView(surface);
      expect(v.body, surface).toMatch(/does not revoke/i);
      expect(v.body, surface).toMatch(/copy of its keys/i);
    }
    for (const surface of ["browser", "mac"] as const) {
      const v = signOutConfirmView(surface);
      // There IS a way back and it is not obvious, so it is said rather than left to be discovered.
      // It differs — a browser signs in again, a Mac is set up again — but both name the passkey,
      // because neither can come back without it.
      expect(v.body, surface).toMatch(/passkey/i);
    }
  });

  test("each is about the device it is on, and names its own way back", () => {
    const browser = signOutConfirmView("browser");
    const mac = signOutConfirmView("mac");
    expect(browser.body).toMatch(/this browser/i);
    expect(browser.body).toMatch(/sign in with it again/i);
    expect(mac.body).toMatch(/this Mac/i);
    expect(mac.body).toMatch(/sign in again with your passkey/i);
    expect(mac.body).not.toBe(browser.body);
  });

  // **THE APP'S OWN CLIENT WINDOW IS NEITHER.** Its sign-out deletes only the WINDOW's keys, and the
  // Mac certifies it again (§10.3) the next time it connects — no passkey, no set-up. Saying "this
  // Mac's keys are deleted … until it is set up again" there was false, and alarming.
  test("the app's client window names the WINDOW, and its automatic way back", () => {
    const w = signOutConfirmView("app-client");
    expect(w.body).toMatch(/this window/i);
    expect(w.body).toMatch(/next time it connects/i);
    expect(w.body).not.toMatch(/this Mac's keys/i);
    expect(w.body).not.toMatch(/set up again/i);
    expect(w.body).not.toMatch(/passkey/i);
  });

  // Refusing has to be as easy as accepting — the same rule §10.1's confirmation carries. And it
  // asks: a destructive dialog whose title is a statement has already decided.
  test("both answers exist, the destructive one is named, and it ASKS", () => {
    for (const surface of ["browser", "mac", "app-client"] as const) {
      const v = signOutConfirmView(surface);
      expect(v.confirm, surface).toBe("Sign out");
      expect(v.cancel, surface).toBe("Cancel");
      expect(v.title, surface).toMatch(/\?$/);
      expect(v.title, surface).not.toMatch(/identity/i);
    }
  });
});
