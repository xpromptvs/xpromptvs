import { describe, expect, test } from "vitest";
import { deviceListView, deviceRow, type DeviceListState } from "../src/shared/device-list";

// The Macs in this identity, as a person reads them. The device list replaced the account panel, so
// what is asserted here is the wording as much as the data: §12.2 forbids reading absence from the
// directory as revocation, and every sentence has to survive that.
const session = (label: string, code = "AbCd1234") =>
  ({ label, code, token: "t", device_id: "d" });

describe("deviceListView", () => {
  test("a browser with no identity is offered a passkey, and told how to sign in", () => {
    const v = deviceListView({ kind: "no-identity" }, "browser");
    // **THE OAUTH REPLACEMENT'S OTHER HALF.** Removing Sign in left this state able to say only
    // "pair with a Mac", which strands anyone who already holds a passkey on another device.
    expect(v.actions).toEqual([{ id: "sign-in", label: "Sign in with a passkey" }]);
    expect(v.message).toMatch(/passkey/i);
    expect(v.message).toMatch(/Touch ID|phone/i);
    expect(v.devices).toHaveLength(0);
    expect(v.count).toBe("");
    // Nothing to refresh: there is no identity whose rooms could be asked for.
    expect(v.canRefresh).toBe(false);
  });

  // §10.1 forbids replacing a root that is already trusted, and a second passkey would change
  // nothing about a listing — so the only state that offers signing in is the one without one.
  test("NO OTHER STATE OFFERS TO SIGN IN", () => {
    const others: DeviceListState[] = [
      { kind: "loading" }, { kind: "ready", devices: [] },
      { kind: "ready", devices: [session("Mac")] }, { kind: "unreachable" },
    ];
    for (const state of others) {
      expect(deviceListView(state, "browser").actions, state.kind).toEqual([]);
    }
  });

  // "0" while loading reads as an answer, and the answer is not known yet.
  test("loading carries no count", () => {
    const v = deviceListView({ kind: "loading" }, "browser");
    expect(v.count).toBe("");
    expect(v.devices).toHaveLength(0);
  });

  test("rows carry the label and the code", () => {
    const v = deviceListView({ kind: "ready", devices: [session("Studio Mac")] }, "browser");
    expect(v.devices).toEqual([{ label: "Studio Mac", code: "AbCd1234" }]);
    expect(v.count).toBe("1");
    expect(v.message).toBe("");
  });

  // A Mac that published no name SAYS SO. "Mac" on every row of a list whose only purpose is
  // telling them apart is worse than admitting the name is missing.
  test("a Mac with no name is named as having none", () => {
    const v = deviceListView({ kind: "ready", devices: [session("   ")] }, "browser");
    expect(v.devices[0]!.label).toBe("Unnamed Mac");
  });

  // **§12.2: ABSENCE IS NEVER REVOCATION.** A Mac that is sharing perfectly well is absent from
  // this list whenever its own publication is failing, so the empty state must not say it stopped.
  test("an empty listing says NOT LISTED, never not sharing", () => {
    const v = deviceListView({ kind: "ready", devices: [] }, "browser");
    expect(v.message).toMatch(/not listed|is listed/i);
    expect(v.message).not.toMatch(/not sharing|stopped/i);
    expect(v.message).toMatch(/Sharing/i);
    expect(v.count).toBe("0");
  });

  // "The directory did not answer" and "you have no Macs" are different things to put in front of
  // a person, and the empty array that used to carry both told them nothing.
  test("an unreachable directory is distinguished from an empty one", () => {
    const v = deviceListView({ kind: "unreachable" }, "browser");
    expect(v.tone).toBe("warn");
    expect(v.message).toMatch(/could not reach/i);
    expect(v.message).toMatch(/may still be sharing/i);
    expect(v.count).toBe("");
    expect(v.canRefresh).toBe(true);
  });

  test("every state renders something a person can read", () => {
    const states: DeviceListState[] = [
      { kind: "no-identity" }, { kind: "loading" },
      { kind: "ready", devices: [] }, { kind: "ready", devices: [session("Mac")] },
      { kind: "unreachable" },
    ];
    for (const state of states) {
      const v = deviceListView(state, "browser");
      expect(typeof v.message, state.kind).toBe("string");
      expect(Array.isArray(v.actions), state.kind).toBe(true);
      expect(["info", "warn"], state.kind).toContain(v.tone);
    }
  });

  // **A MAC CANNOT SIGN IN.** `app://ui/` can run no ceremony (§2, profile P-A); a Mac is enrolled
  // by a browser through §12.1, which is the encryption row further up the same page. A passkey
  // button here would be one that cannot work, and merely naming a passkey sends someone looking
  // for a control this surface does not have.
  // **A MAC SIGNS IN TOO** since 2026-10-06 — natively, the same panel — so its empty list offers the
  // browser's action; only the sentence differs (it does not send a Mac to its own Share this Mac).
  test("a Mac with no identity is offered the passkey sign-in, as a browser is", () => {
    const v = deviceListView({ kind: "no-identity" }, "mac");
    expect(v.actions).toEqual(deviceListView({ kind: "no-identity" }, "browser").actions);
    expect(v.actions).toEqual([{ id: "sign-in", label: "Sign in with a passkey" }]);
    expect(v.message).toMatch(/passkey/i);
    expect(v.message).toMatch(/Touch ID|phone/i);
    expect(v.message).not.toMatch(/Share this Mac/);
    expect(v.canRefresh).toBe(false);
  });

  // **THE APP'S OWN CLIENT WINDOW** gets its identity from its Mac (§10.3) when it opens, so
  // an empty list there is about the WINDOW — never a claim that the Mac is unenrolled, and never
  // an offer of a passkey ceremony `app://client/` cannot run.
  test("the app's client window with no identity says the WINDOW gets one once the MAC is set up", () => {
    const v = deviceListView({ kind: "no-identity" }, "app-client");
    expect(v.actions).toEqual([]);
    expect(v.message).not.toMatch(/passkey/i);
    expect(v.message).toMatch(/this window/i);
    // Not "on its first connect" — the window adopts on OPEN, so this sentence shows only where the
    // Mac cannot certify it, and connecting would not change that.
    expect(v.message).not.toMatch(/first connect/i);
    expect(v.message).toMatch(/set up/i);
    expect(v.message).toMatch(/Settings/i);
    expect(v.message).not.toMatch(/once this one has/i);
    expect(v.canRefresh).toBe(false);
    expect(v).not.toEqual(deviceListView({ kind: "no-identity" }, "mac"));
  });

  // **THE WHOLE REASON THIS MODULE IS SHARED.** The browser dashboard and the app's own dashboard
  // read the same §12.2 directory and must say the same things about it. They were two hand-written
  // copies until 2026-09-14 and had already drifted — so this asserts the agreement itself, not a
  // pair of strings that a later edit is free to fork again. Exactly ONE state may differ, and it
  // is the one directly above.
  test("both dashboards read identically everywhere except the state a Mac cannot act on", () => {
    const shared: DeviceListState[] = [
      { kind: "loading" }, { kind: "ready", devices: [] },
      { kind: "ready", devices: [session("Studio Mac"), session("   ", "other")] },
      { kind: "unreachable" }, { kind: "unreachable", offline: true },
      { kind: "ready", devices: [session("Studio Mac")], stale: "unreachable" },
      { kind: "ready", devices: [session("Studio Mac")], stale: "offline" },
    ];
    for (const state of shared) {
      expect(deviceListView(state, "mac"), state.kind)
        .toEqual(deviceListView(state, "browser"));
      expect(deviceListView(state, "app-client"), state.kind)
        .toEqual(deviceListView(state, "browser"));
    }
    expect(deviceListView({ kind: "no-identity" }, "mac"))
      .not.toEqual(deviceListView({ kind: "no-identity" }, "browser"));
  });

  // **A WEAK NETWORK FAILS ONE LISTING IN SEVERAL.** The rows stay, clickable, with a line saying
  // they are the last ones seen — never an error that replaces the list the person was reaching for.
  test("stale rows stay on screen, with a warning that says they may be out of date", () => {
    const v = deviceListView({ kind: "ready", devices: [session("Studio Mac")], stale: "unreachable" },
                             "browser");
    expect(v.devices).toEqual([{ label: "Studio Mac", code: "AbCd1234" }]);
    expect(v.count).toBe("1");
    expect(v.tone).toBe("warn");
    expect(v.message).toMatch(/last time/i);
    expect(v.message).toMatch(/retrying/i);
    expect(v.canRefresh).toBe(true);
  });

  test("offline says OFFLINE, with rows or without", () => {
    const rows = deviceListView({ kind: "ready", devices: [session("Mac")], stale: "offline" }, "browser");
    expect(rows.message).toMatch(/offline/i);
    expect(rows.devices).toHaveLength(1);
    const none = deviceListView({ kind: "unreachable", offline: true }, "browser");
    expect(none.message).toMatch(/offline/i);
    expect(none.tone).toBe("warn");
  });

  // An earlier EMPTY answer vouches for nothing; "0 Macs, possibly out of date" is not a sentence.
  test("a stale EMPTY listing reads as the failure it is", () => {
    expect(deviceListView({ kind: "ready", devices: [], stale: "unreachable" }, "browser"))
      .toEqual(deviceListView({ kind: "unreachable" }, "browser"));
    expect(deviceListView({ kind: "ready", devices: [], stale: "offline" }, "browser"))
      .toEqual(deviceListView({ kind: "unreachable", offline: true }, "browser"));
  });
});


test('deviceRow: a listed Mac carries its code; This Mac carries none; both keep their resting word', () => {
  const listed = deviceRow({ label: 'Studio Mac', code: 'AbCd1234', state: 'Online', navId: 'device:AbCd1234', onConnect: () => {} });
  expect(listed.getAttribute('data-session-code')).toBe('AbCd1234');
  expect(listed.dataset.restingState).toBe('Online');
  expect(listed.querySelector('.ss-device-state')!.textContent).toBe('Online');
  const clicked: HTMLElement[] = [];
  const mine = deviceRow({ label: 'This Mac', code: null, state: 'Terminal', navId: 'device:this-mac', onConnect: (row) => clicked.push(row) });
  expect(mine.hasAttribute('data-session-code')).toBe(false);
  expect(mine.dataset.restingState).toBe('Terminal');
  mine.querySelector('button')!.click();
  expect(clicked).toEqual([mine]);
});
