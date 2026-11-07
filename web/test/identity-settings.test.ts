import { describe, expect, test } from "vitest";
import {
  identitySettingsView, type IdentitySettingsState,
} from "../src/client/identity-settings";

// What Settings says about the identity this browser holds, and the way out. Signing out of a
// passkey identity means something genuinely different from signing out of an account, and the
// copy is the whole product of this surface — which is why it has a module and a test.
const ROOT = "a".repeat(64);

describe("identitySettingsView", () => {
  test("a browser with no identity shows nothing here", () => {
    // The device list is where a browser with nothing is offered one. A second empty panel saying
    // the same thing in other words is how two surfaces come to disagree.
    expect(identitySettingsView({ kind: "none" }).hidden).toBe(true);
  });

  // §10.1 asks a person to compare an identity against a device they already trust, and an
  // abbreviation is not something anyone can check.
  test("the identity is shown IN FULL and never shortened", () => {
    const v = identitySettingsView({ kind: "held", rootId: ROOT });
    expect(v.hidden).toBe(false);
    expect(v.identity).toBe(ROOT);
    expect(v.identity.length).toBe(64);
    expect(v.action).toBe("Sign out");
    expect(v.heading).toBe("Your devices");
    expect(v.body).toBe("Signed in on this browser.");
    expect(v.body).not.toMatch(/identity|keys/i);
  });

  test("while signing out there is nothing to press", () => {
    const v = identitySettingsView({ kind: "signing-out" });
    expect(v.busy).toBe(true);
    expect(v.action).toBeNull();
    // The old value is not left on screen claiming to be current.
    expect(v.identity).toBe("");
  });

  test("every state renders something a person can read", () => {
    const states: IdentitySettingsState[] = [
      { kind: "none" }, { kind: "held", rootId: ROOT }, { kind: "signing-out" },
    ];
    for (const state of states) {
      const v = identitySettingsView(state);
      expect(typeof v.body, state.kind).toBe("string");
      expect(typeof v.heading, state.kind).toBe("string");
    }
  });
});
