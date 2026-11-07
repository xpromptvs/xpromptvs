import { describe, expect, it } from "vitest";
import { elementHoldsFocus, isRequestedTab, pendingAfterTermList, switchReset, tabToShowAfterTermList, terminalTakesFocus, terminalTakesWindowKeys } from "../src/client/term-view-policy";

describe("terminalTakesFocus", () => {
  const base = { driver: true, mayAutofocus: true, terminalHadFocus: false };

  it("a user switch focuses the terminal", () => {
    expect(terminalTakesFocus({ ...base, reason: "user" })).toBe(true);
  });

  // Review C1: a resume / reconnect / re-snapshot commit took focus from a remote window, so the next
  // keystrokes (a password) went into the shell.
  it("a commit NEVER takes focus the terminal did not already hold", () => {
    expect(terminalTakesFocus({ ...base, reason: "commit" })).toBe(false);
    expect(terminalTakesFocus({ ...base, reason: "host" })).toBe(false);
  });

  it("a replacement keeps the focus its predecessor held", () => {
    expect(terminalTakesFocus({ ...base, reason: "commit", terminalHadFocus: true })).toBe(true);
    expect(terminalTakesFocus({ ...base, reason: "host", terminalHadFocus: true })).toBe(true);
  });

  it("never for a passive client, nor on glasses (the D-pad owns focus)", () => {
    for (const reason of ["user", "commit", "host"] as const) {
      expect(terminalTakesFocus({ ...base, reason, terminalHadFocus: true, driver: false })).toBe(false);
      expect(terminalTakesFocus({ ...base, reason, terminalHadFocus: true, mayAutofocus: false })).toBe(false);
    }
  });
});

/// On a TOUCH device, focusing the terminal raises the soft keyboard — so the terminal takes focus only
/// to HAND ON the focus it already held (the keyboard was up: it stays up for the next tab). Everything
/// else leaves the keyboard down until the user taps the terminal. Before, a tab switch always focused,
/// and switching tabs on a phone kept throwing the keyboard up.
describe("terminalTakesFocus on a soft-keyboard (touch) device", () => {
  const touch = { driver: true, mayAutofocus: true, softKeyboard: true };

  it("a user switch does NOT raise the keyboard when the terminal did not hold focus", () => {
    expect(terminalTakesFocus({ ...touch, reason: "user", terminalHadFocus: false })).toBe(false);
  });

  it("a user switch HANDS ON a raised keyboard to the new tab", () => {
    expect(terminalTakesFocus({ ...touch, reason: "user", terminalHadFocus: true })).toBe(true);
  });

  it("a tab the user opened, or becoming the driver, does not raise it either", () => {
    expect(terminalTakesFocus({ ...touch, reason: "host", terminalHadFocus: false, userOpened: true })).toBe(false);
    expect(terminalTakesFocus({ ...touch, reason: "commit", terminalHadFocus: false, userOpened: true })).toBe(false);
    expect(terminalTakesFocus({ ...touch, reason: "activate", terminalHadFocus: false, otherHoldsFocus: false, surfaceShown: true })).toBe(false);
  });

  it("a replacement still keeps the focus its predecessor held — unless something else took it", () => {
    expect(terminalTakesFocus({ ...touch, reason: "commit", terminalHadFocus: true })).toBe(true);
    expect(terminalTakesFocus({ ...touch, reason: "host", terminalHadFocus: true, otherHoldsFocus: true })).toBe(false);
  });

  it("a pointer device is unchanged: a user switch focuses", () => {
    expect(terminalTakesFocus({ ...touch, softKeyboard: false, reason: "user", terminalHadFocus: false })).toBe(true);
  });
});

describe("terminalTakesFocus on becoming the driver (a claim, or auto-promotion when another client leaves)", () => {
  const act = { reason: "activate" as const, driver: true, mayAutofocus: true, terminalHadFocus: false };

  it("focuses only when nothing else holds focus and the terminal surface is what the user sees", () => {
    expect(terminalTakesFocus({ ...act, otherHoldsFocus: false, surfaceShown: true })).toBe(true);
  });

  it("never takes focus from a remote window or any input", () => {
    expect(terminalTakesFocus({ ...act, otherHoldsFocus: true, surfaceShown: true })).toBe(false);
  });

  it("never while the window surface is what the user sees", () => {
    expect(terminalTakesFocus({ ...act, otherHoldsFocus: false, surfaceShown: false })).toBe(false);
  });

  it("never on glasses", () => {
    expect(terminalTakesFocus({ ...act, mayAutofocus: false, otherHoldsFocus: false, surfaceShown: true })).toBe(false);
  });
});

// Review N1: focus the terminal held must survive the terminal's own changes (a tab exiting, a tab
// replaced before the next one committed), and a tab this user OPENED takes focus when it lands — but
// never from a remote window or an input.
describe("terminalTakesFocus for a carried focus or a tab the user opened", () => {
  const base = { driver: true, mayAutofocus: true, terminalHadFocus: false, otherHoldsFocus: false };

  it("a tab the user opened takes focus when it lands, by either route", () => {
    expect(terminalTakesFocus({ ...base, reason: "commit", userOpened: true })).toBe(true);
    expect(terminalTakesFocus({ ...base, reason: "host", userOpened: true })).toBe(true);
  });

  it("neither a carried focus nor a user-opened tab takes it from a remote window or an input", () => {
    expect(terminalTakesFocus({ ...base, reason: "commit", userOpened: true, otherHoldsFocus: true })).toBe(false);
    expect(terminalTakesFocus({ ...base, reason: "host", terminalHadFocus: true, otherHoldsFocus: true })).toBe(false);
  });
});

// Review N2: "Move here" hides #claim and activates synchronously; Chromium still reports the hidden
// #claim-button as activeElement until the next rendering update, so the claim never focused.
describe("elementHoldsFocus", () => {
  it("nothing, the body, a detached element, a hidden one or #claim's button holds nothing", () => {
    expect(elementHoldsFocus(null)).toBe(false);
    expect(elementHoldsFocus(document.body)).toBe(false);
    expect(elementHoldsFocus(document.createElement("input"))).toBe(false);                // detached
    const claim = document.createElement("div"); claim.id = "claim";
    const btn = document.createElement("button"); btn.id = "claim-button";
    claim.append(btn); document.body.append(claim);
    expect(elementHoldsFocus(btn)).toBe(false);
    const hidden = document.createElement("input");
    document.body.append(hidden);
    (hidden as unknown as { checkVisibility: () => boolean }).checkVisibility = () => false;
    expect(elementHoldsFocus(hidden)).toBe(false);
    claim.remove(); hidden.remove();
  });

  it("a rendered input holds focus", () => {
    const input = document.createElement("input");
    document.body.append(input);
    expect(elementHoldsFocus(input)).toBe(true);
    input.remove();
  });
});

describe("pending switch", () => {
  const tl = (activeId: string | null, ids: string[]) => ({ activeId, tabs: ids.map((id) => ({ id })) });

  it("is confirmed by a term-list naming it, or dropped when its tab is gone", () => {
    expect(pendingAfterTermList("pty:2", tl("pty:2", ["pty:1", "pty:2"]))).toBeNull();
    expect(pendingAfterTermList("pty:2", tl("pty:1", ["pty:1"]))).toBeNull();
  });

  it("survives a term-list that still names the old tab — the display does not flip back", () => {
    const pending = pendingAfterTermList("pty:2", tl("pty:1", ["pty:1", "pty:2"]));
    expect(pending).toBe("pty:2");
    expect(tabToShowAfterTermList(pending, "pty:2", "pty:1")).toBeUndefined();
  });

  it("with none pending, the display follows the host's active tab", () => {
    expect(tabToShowAfterTermList(null, "pty:1", "pty:3")).toBe("pty:3");
    expect(tabToShowAfterTermList(null, "pty:3", "pty:3")).toBeUndefined();
  });

  // Review I2: a switch whose message was dropped (control not open) or ignored (this client went
  // passive) left `pending` set for good, every key named a tab the host was not on, and the host
  // dropped them all.
  it("a control reopen or a driver change clears it, and a driver re-asserts the tab it shows", () => {
    expect(switchReset("pty:2", true)).toEqual({ pending: "pty:2", reassert: "pty:2" });
    expect(switchReset("pty:2", false)).toEqual({ pending: null, reassert: null });
    expect(switchReset(null, true)).toEqual({ pending: null, reassert: null });
  });

  it("the re-asserted switch clears like any other once the host confirms it", () => {
    const { pending } = switchReset("pty:2", true);
    expect(pendingAfterTermList(pending, tl("pty:2", ["pty:1", "pty:2"]))).toBeNull();
  });
});

// N6 (2026-09-27): "focus the tab the user opened" names WHICH tab. `open-tmux` names its session, so the
// tab id is known exactly; `open-terminal` and `new-tmux` get no echo from the host, so the match is the
// next NEW tab of the requested kind that was not already known when the user asked (a tmux restore
// racing a `new-tmux` brings back tabs the client already knew).
describe("isRequestedTab", () => {
  it("an open-tmux names its tab exactly — any other tab, new or not, is not it", () => {
    const req = { id: "tmux:$5" };
    expect(isRequestedTab(req, "tmux:$5", false)).toBe(true);           // already a slot: still it
    expect(isRequestedTab(req, "tmux:$4", true)).toBe(false);
    expect(isRequestedTab(req, "pty:9", true)).toBe(false);
  });

  it("open-terminal / new-tmux: the next NEW tab of that kind, never one already known", () => {
    const tmux = { kind: "tmux" as const, known: new Set(["tmux:$2"]) };
    expect(isRequestedTab(tmux, "tmux:$3", true)).toBe(true);
    expect(isRequestedTab(tmux, "tmux:$3", false)).toBe(false);         // a slot from before the request
    expect(isRequestedTab(tmux, "tmux:$2", true)).toBe(false);          // a restore of a known session
    expect(isRequestedTab(tmux, "pty:9", true)).toBe(false);            // the other kind
    const pty = { kind: "pty" as const, known: new Set<string>() };
    expect(isRequestedTab(pty, "pty:9", true)).toBe(true);
    expect(isRequestedTab(pty, "tmux:$3", true)).toBe(false);
  });

  it("reopen-terminal (⌘⇧T): the next NEW tab of EITHER kind — a shell or a re-attached tmux session", () => {
    const any = { kind: "any" as const, known: new Set(["pty:1", "tmux:$2"]) };
    expect(isRequestedTab(any, "pty:4", true)).toBe(true);
    expect(isRequestedTab(any, "tmux:$7", true)).toBe(true);
    expect(isRequestedTab(any, "tmux:$2", true)).toBe(false);           // already known
    expect(isRequestedTab(any, "pty:4", false)).toBe(false);            // a slot from before the request
  });
});

// A WINDOW THAT HELD THE KEYS WENT and the host landed the person on a terminal tab: the terminal takes them
// as a switch hands focus on — never a passive client's, never on glasses, and on a touch only keys that were
// TYPING (the hidden input: the soft keyboard up, kept up); keys on the picture raised no keyboard and must
// not raise one now.
describe("terminalTakesWindowKeys", () => {
  const base = { driver: true, mayAutofocus: true };
  it("with a mouse or a hardware keyboard: the keys go to the terminal", () => {
    expect(terminalTakesWindowKeys({ ...base, typing: false })).toBe(true);
    expect(terminalTakesWindowKeys({ ...base, typing: true, softKeyboard: false })).toBe(true);
  });
  it("on a touch: only typing keys, so the soft keyboard stays up and never comes up uninvited", () => {
    expect(terminalTakesWindowKeys({ ...base, typing: true, softKeyboard: true })).toBe(true);
    expect(terminalTakesWindowKeys({ ...base, typing: false, softKeyboard: true })).toBe(false);
  });
  it("never for a passive client, nor on glasses", () => {
    expect(terminalTakesWindowKeys({ ...base, driver: false, typing: true })).toBe(false);
    expect(terminalTakesWindowKeys({ ...base, mayAutofocus: false, typing: true })).toBe(false);
  });
});
