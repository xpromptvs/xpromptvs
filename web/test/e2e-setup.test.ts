import { describe, expect, test } from "vitest";
import { afterFailure, dismissal, e2eSetupView, mountE2ESetup, type SetupFlow, type SetupState }
  from "../src/shared/e2e-setup";

// §10.1: "the interface MUST name the identity being adopted before the device commits to it." That
// requirement lives in a line of text, which is why it has a module of its own.
const ROOT = "a".repeat(64);
// Distinct from ROOT on purpose: the success screen must name the IDENTITY, not the device — and
// a real CODE, so a view accidentally rendering hex fails rather than merely differing.
const IDENTITY = "C1P9-HM5S-6D93-FPDC";

const EVERY_STATE: SetupState[] = [
  { kind: "choosing", pending: { resume: false, discard: false } },
  { kind: "choosing", pending: { resume: true, discard: true } },
  { kind: "working", step: "creating" },
  { kind: "working", step: "discovering" },
  { kind: "working", step: "resuming" },
  { kind: "working", step: "resuming" },
  { kind: "working", step: "discarding" },
  { kind: "authorise" },
  { kind: "discard-confirm" },
  { kind: "failed", reason: "not-confirmed", stranded: false },
  { kind: "failed", reason: "not-found", stranded: true },
  { kind: "stranded-confirm" },
  { kind: "ready", deviceId: ROOT, rootId: IDENTITY },
];

describe("choosing", () => {
  // Both routes, always. A person whose authenticator holds nothing must still be able to start,
  // and one whose passkey lives on another device must not be cornered into making a second
  // identity because the first route was not offered.
  test("offers an existing passkey AND a new one", () => {
    const v = e2eSetupView({ kind: "choosing", pending: { resume: false, discard: false } });
    expect(v.actions.map((a) => a.id)).toEqual(["discover", "create", "dismiss"]);
    expect(v.actions.map((a) => a.label))
      .toEqual(["Use a passkey", "Create a passkey", "Not now"]);
    expect(v.busy).toBe(false);
  });

  // **AN OFFER, NOT A DEFICIENCY.** It used to open with "This browser needs an encryption
  // identity" — a shortfall announced in words most people have no use for. It proposes a login
  // now, and `info` rather than `warn` is part of that: nothing is wrong.
  test("it proposes signing in rather than reporting a lack", () => {
    const v = e2eSetupView({ kind: "choosing", pending: { resume: false, discard: false } });
    expect(v.title).toMatch(/sign in/i);
    expect(v.title).not.toMatch(/needs|required|missing/i);
    expect(v.tone).toBe("info");
  });

  // What a passkey BUYS, not what it is. The mechanism is not the point, and both routes have to
  // be distinguishable from the body alone.
  test("the body says what it is for, and tells the two routes apart", () => {
    const body = e2eSetupView({ kind: "choosing", pending: { resume: false, discard: false } }).body;
    expect(body).toMatch(/encrypted end to end/i);
    expect(body).toMatch(/already have/i);
    expect(body).toMatch(/create one/i);
  });

  // The panel used to open by fetching an account listing. Nothing is loaded now — the identities
  // come from the authenticator — and the copy must not go on implying an account exists.
  test("says nothing about an account", () => {
    for (const state of EVERY_STATE) {
      expect(e2eSetupView(state).body, state.kind).not.toMatch(/account/i);
      expect(e2eSetupView(state).title, state.kind).not.toMatch(/account/i);
    }
  });
});

describe("in flight and afterwards", () => {
  // A panel with a live button while a passkey prompt is up invites a second ceremony.
  test("a ceremony in flight is busy and offers nothing to click", () => {
    for (const step of ["creating", "discovering", "resuming"] as const) {
      const v = e2eSetupView({ kind: "working", step });
      expect(v.busy).toBe(true);
      expect(v.actions).toHaveLength(0);
    }
  });

  // Three prompts in a row described identically are three prompts a person cannot tell apart —
  // and they must not read identically — three ceremonies described the same way are three a
  // person cannot tell apart.
  test("each prompt says which one it is", () => {
    const bodies = (["creating", "discovering", "resuming"] as const)
      .map((step) => e2eSetupView({ kind: "working", step }).body);
    expect(new Set(bodies).size).toBe(3);
  });

  test("a known failure is explained, an unknown one is shown as it is", () => {
    expect(e2eSetupView({ kind: "failed", reason: "not-confirmed", stranded: false }).body).toMatch(/nothing was added/i);
    expect(e2eSetupView({ kind: "failed", reason: "something-new", stranded: false }).body).toMatch(/something-new/);
    expect(e2eSetupView({ kind: "failed", reason: "not-confirmed", stranded: false }).actions.map((a) => a.id))
      .toEqual(["retry"]);
  });

  // §12.2: absence from the directory is never revocation. The sentence a person reads must not
  // suggest their passkey is the thing that failed, and must name the way through.
  test("an unregistered passkey points at pairing, not at the passkey", () => {
    const body = e2eSetupView({ kind: "failed", reason: "not-found", stranded: false }).body;
    expect(body).toMatch(/no identity is registered/i);
    expect(body).toMatch(/pair/i);
  });

  // A substituted descriptor is a refusal that says the ANSWER was wrong. Reading "your passkey
  // could not be verified" would send a person to replace the one thing that is working.
  test("a substituted identity says nothing was added", () => {
    for (const reason of ["root-rpid", "credential-mismatch", "signature"]) {
      expect(e2eSetupView({ kind: "failed", reason, stranded: false }).body, reason)
        .toMatch(/nothing was added/i);
    }
  });

  test("success says where the keys live, and lets the session continue", () => {
    const v = e2eSetupView({ kind: "ready", deviceId: ROOT, rootId: IDENTITY });
    expect(v.tone).toBe("ok");
    expect(v.actions.map((a) => a.id)).toEqual(["close"]);
    expect(v.title).toMatch(/signed in/i);
    expect(v.body).toMatch(/this device only/i);
  });
});

// **WHAT ESC MUST DO.** A `<dialog>` opened with `showModal()` can be dismissed from the keyboard,
// and three of these states would be wrong to close that way — which is the cost of moving the
// panel into the shared dialog design, paid once, here.
describe("dismissal", () => {
  test("a ceremony in flight cannot be dismissed", () => {
    for (const step of ["creating", "discovering", "resuming"] as const) {
      expect(dismissal({ kind: "working", step }), step).toBe("no");
    }
  });

  // The confirmation this used to guard is gone with the question. What still must never be read as
  // consent is a DESTRUCTIVE screen, and Esc there closes rather than acts.
  test("Esc on either deletion screen destroys nothing", () => {
    expect(dismissal({ kind: "discard-confirm" })).toBe("close");
    expect(dismissal({ kind: "stranded-confirm" })).toBe("close");
  });

  test("a committed identity closes the way Continue does", () => {
    expect(dismissal({ kind: "ready", deviceId: ROOT, rootId: IDENTITY })).toBe("done");
  });

  test("nothing pending is simply closeable", () => {
    expect(dismissal({ kind: "choosing", pending: { resume: false, discard: false } })).toBe("close");
    expect(dismissal({ kind: "failed", reason: "not-confirmed", stranded: false })).toBe("close");
  });

  test("every state has a rule", () => {
    for (const state of EVERY_STATE) {
      expect(["no", "refuse", "close", "done"], state.kind).toContain(dismissal(state));
    }
  });
});

// **A DISMISSAL IS A DECISION, NOT A FAULT.** Cancelling a passkey prompt is a person saying "not
// that one" or "not now"; answering it with a failure screen and a Try again button reports an
// error they already know about and makes them press one more thing to get back where they were.
describe("afterFailure", () => {
  test("a dismissed prompt simply leaves the form up", () => {
    expect(afterFailure("dismissed", { resume: false, discard: false })).toEqual({ kind: "choosing", pending: { resume: false, discard: false } });
    // The offer to finish must survive a cancelled prompt — that is the state it exists for.
    expect(afterFailure("dismissed", { resume: true, discard: true })).toEqual({ kind: "choosing", pending: { resume: true, discard: true } });
  });

  // Everything else IS worth showing: a refusal the browser named, a chain that would not verify,
  // storage that would not write, an identity nobody confirmed.
  test("everything else is a failure a person should see", () => {
    for (const reason of ["refused/SecurityError", "not-found", "storage", "not-confirmed",
                          "root-rpid", "unsupported"]) {
      expect(afterFailure(reason, { resume: false, discard: false }), reason).toEqual({ kind: "failed", reason, stranded: false });
      expect(afterFailure(reason, { resume: true, discard: true }), reason).toEqual({ kind: "failed", reason, stranded: false });
    }
  });

  // The panel never shows the word, because `dismissed` never reaches the failure screen — so a
  // REASONS entry for it would be dead copy pretending to be reachable.
  test("the named refusals have sentences and the dismissal does not", () => {
    expect(e2eSetupView({ kind: "failed", reason: "refused/SecurityError", stranded: false }).body)
      .toMatch(/cannot use passkeys/i);
    expect(e2eSetupView({ kind: "failed", reason: "refused/NotSupportedError", stranded: false }).body)
      .toMatch(/cannot make the kind of passkey/i);
  });
});

describe("finishing what was abandoned", () => {
  // §2: a passkey created but never committed is the case this whole feature exists for, and a
  // person cannot reach it if the panel does not offer it.
  test("a resumable browser is offered a way to finish", () => {
    const ids = e2eSetupView({ kind: "choosing", pending: { resume: true, discard: true } }).actions.map((a) => a.id);
    expect(ids).toContain("resume");
    // FIRST, because someone who made a passkey here last time should not have to work out that
    // "Create a passkey" would make a second one.
    expect(ids[0]).toBe("resume");
    // And the other two are never taken away: an authenticator that no longer holds the retained
    // credential must not corner a person into the one route that cannot work.
    expect(ids).toContain("discover");
    expect(ids).toContain("create");
  });

  test("and a browser with nothing retained is not", () => {
    expect(e2eSetupView({ kind: "choosing", pending: { resume: false, discard: false } }).actions.map((a) => a.id))
      .not.toContain("resume");
  });

  // Three ceremonies described identically are three a person cannot tell apart.
  test("resuming has its own prompt", () => {
    const resuming = e2eSetupView({ kind: "working", step: "resuming" }).body;
    // Every OTHER step — comparing it against itself would pass for free.
    for (const step of ["creating", "authorising", "discovering", "discarding"] as const) {
      expect(resuming).not.toBe(e2eSetupView({ kind: "working", step }).body);
    }
  });
});

// **CREATING COSTS TWO PROMPTS, AND THE SCREEN MUST NOT DESCRIBE THEM IDENTICALLY.** It used to
// show one message across both, so the second arrived under words about the first — which reads as
// the same request repeating rather than as a second step. A registration returns no signature
// (Apple answers `fmt: "none"` however attestation is asked for), so the grant needs an assertion of
// its own; two calls are two prompts here. Both measured — `docs/open-threads.md`.
describe("creating says which prompt is which", () => {
  const creating = e2eSetupView({ kind: "working", step: "creating" }).body;
  const authorising = e2eSetupView({ kind: "working", step: "authorising" }).body;

  test("the two prompts do not read the same", () => {
    expect(authorising).not.toBe(creating);
  });

  test("the first sets the expectation, so the second is not a surprise", () => {
    expect(creating).toMatch(/1 of 2/);
    expect(authorising).toMatch(/2 of 2/);
  });

  // **NEITHER PROMPT IS A TEST AND NEITHER IS A SIGN-IN.** Refusing the second leaves the identity
  // unusable, so calling it a check would be false in the direction that matters — the same rule
  // that stops the deletion offer claiming a passkey is unused.
  test("the second prompt is not described as a test or a sign-in", () => {
    expect(authorising).not.toMatch(/\btest\b|\btry it\b|\bsign(ing)? in\b|\bverify\b|\bcheck\b/i);
  });

  test("and it says another prompt is coming, rather than letting it arrive unannounced", () => {
    expect(authorising).toMatch(/ask/i);
  });
});

// **BETWEEN THE TWO PROMPTS THE PANEL WAITS FOR A CLICK.** Safari refused a grant prompt started
// straight after the passkey's (2026-10-03: no prompt, the same error as a cancel), and prompted for
// the same assertion started from a click. So the second prompt is the Continue button's.
describe("between the two prompts", () => {
  const v = e2eSetupView({ kind: "authorise" });

  test("Continue starts the second prompt; Not now is the way out", () => {
    expect(v.actions.map((a) => a.id)).toEqual(["authorise", "dismiss"]);
    expect(v.actions.map((a) => a.label)).toEqual(["Continue", "Not now"]);
    expect(v.busy, "the buttons are live — that click is the point").toBe(false);
  });

  test("it is step 2 of 2, says another prompt is coming, and is no test or sign-in", () => {
    expect(v.body).toMatch(/2 of 2/);
    expect(v.body).toMatch(/ask/i);
    expect(v.body).not.toMatch(/\btest\b|\btry it\b|\bsign(ing)? in\b|\bverify\b|\bcheck\b/i);
  });

  test("Esc closes it — the passkey stays, for Finish setting up", () => {
    expect(dismissal({ kind: "authorise" })).toBe("close");
  });
});

describe("the success screen", () => {
  // §3: the create route stopped asking, so the identity has to be SHOWN somewhere — "your Macs
  // will show the same code" is only checkable against a code that is on screen.
  test("names the IDENTITY as a code, not the device and not a hash", () => {
    const v = e2eSetupView({ kind: "ready", deviceId: ROOT, rootId: IDENTITY });
    expect(v.identity).toBe(IDENTITY);
    // **NEVER ABBREVIATED** — §10.1 asks a person to check it against another device they trust,
    // and an abbreviation is not something you can check.
    expect(v.identity).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
  });

  test("and invites the check the confirmation used to", () => {
    const v = e2eSetupView({ kind: "ready", deviceId: ROOT, rootId: IDENTITY });
    expect(v.body).toMatch(/same code/i);
    expect(v.body).toMatch(/this device only/i);
  });
});

describe("deleting a stranded passkey", () => {
  const offered = (discard: boolean) =>
    e2eSetupView({ kind: "choosing", pending: { resume: true, discard } }).actions.map((a) => a.id);

  // The capability is the gate, because a button that cannot do what it says is worse than no
  // button: `signalUnknownCredential` is what deletes the passkey, and without it nothing would.
  test("offered only where the browser can actually delete it", () => {
    expect(offered(true)).toContain("discard");
    expect(offered(false)).not.toContain("discard");
  });

  test("and never without something retained to be certain about", () => {
    expect(e2eSetupView({ kind: "choosing", pending: { resume: false, discard: false } })
      .actions.map((a) => a.id)).not.toContain("discard");
  });

  // **THE OS SHOWS NOTHING.** Measured: the passkey is deleted silently, in 250 ms, with no prompt
  // of any kind. So this screen is the entire confirmation, and it has to carry the three things a
  // person needs: what goes, that it does not come back, and what the alternative is.
  test("the confirmation says what is destroyed, that it is permanent, and the way out", () => {
    const v = e2eSetupView({ kind: "discard-confirm" });
    expect(v.body).toMatch(/permanent/i);
    expect(v.body).toMatch(/icloud keychain|this device/i);
    expect(v.body).toMatch(/finish setting up/i);
    expect(v.tone).toBe("warn");
    expect(v.actions.map((a) => a.id)).toEqual(["discard-yes", "discard-no"]);
  });

  // It claims nothing is using the passkey. That is only honest because of what retention KNOWS —
  // created here, never committed, never registered — so the sentence states the reason.
  test("and says WHY nothing is using it, rather than asserting it is safe", () => {
    expect(e2eSetupView({ kind: "discard-confirm" }).body)
      .toMatch(/never finished|no Mac has it/i);
  });

  // Esc must not delete. Every outcome of this screen is reachable by a button instead.
  test("Esc on the confirmation destroys nothing", () => {
    expect(dismissal({ kind: "discard-confirm" })).toBe("close");
  });
});

describe("a passkey no identity could be found for", () => {
  // **THE TWO CONFIRMATIONS MUST NOT CLAIM THE SAME THING.** For a retained descriptor this browser
  // KNOWS nothing is using the passkey. Here it knows only that the Worker holds no record — and the
  // index is best-effort, and a Mac's registration may not have landed. Saying "nothing is using
  // it" here would be a sentence we cannot stand behind.
  test("it does NOT repeat the certain screen's claim", () => {
    const certain = e2eSetupView({ kind: "discard-confirm" }).body;
    const uncertain = e2eSetupView({ kind: "stranded-confirm" }).body;
    expect(certain).toMatch(/nothing is using it/i);
    expect(uncertain).not.toMatch(/nothing is using it/i);
    expect(uncertain).not.toBe(certain);
  });

  // The person supplies the certainty this code cannot, so the screen has to put THAT question to
  // them — in terms of something they know about themselves, not about our data model.
  test("it asks the one question only the person can answer", () => {
    const v = e2eSetupView({ kind: "stranded-confirm" });
    expect(v.body).toMatch(/if you have ever set up a Mac/i);
    expect(v.body).toMatch(/never be extended/i);
    expect(v.body).toMatch(/permanent/i);
    expect(v.tone).toBe("warn");
    expect(v.actions.map((a) => a.id)).toEqual(["discard-yes", "discard-no"]);
  });

  // Offered only where the Worker actually ANSWERED. A timeout has told us nothing, and inviting a
  // person to destroy a credential on the strength of one invites it on the strength of their Wi-Fi.
  test("offered on a definite absence, and not otherwise", () => {
    const withOffer = e2eSetupView({ kind: "failed", reason: "not-found", stranded: true });
    expect(withOffer.actions.map((a) => a.id)).toContain("discard");
    const without = e2eSetupView({ kind: "failed", reason: "not-found", stranded: false });
    expect(without.actions.map((a) => a.id)).not.toContain("discard");
    // Try again survives either way — the offer is an addition, never a replacement.
    expect(withOffer.actions.map((a) => a.id)).toContain("retry");
  });

  test("Esc on it destroys nothing", () => {
    expect(dismissal({ kind: "stranded-confirm" })).toBe("close");
  });
});

describe("signing in states the identity instead of asking about it", () => {
  // The two ceremonies run back to back now. Nothing in the model can interrupt them, because there
  // is no state between `working` and `ready` any more.
  test("no state offers to adopt, and none asks", () => {
    for (const state of EVERY_STATE) {
      const ids = e2eSetupView(state).actions.map((a) => a.id);
      expect(ids, state.kind).not.toContain("adopt");
      expect(ids, state.kind).not.toContain("cancel");
    }
  });

  // §10.1's Residual is about a candidate the DIRECTORY named; ours names none, so the identity is
  // stated rather than put to a vote. What the amended rule asks for in exchange is the undo — so
  // the screen has to say it. Naming an identity with no way out would be the half that matters.
  test("the success screen names the way out", () => {
    const v = e2eSetupView({ kind: "ready", deviceId: ROOT, rootId: IDENTITY });
    expect(v.body).toMatch(/sign out/i);
    expect(v.identity).toBe(IDENTITY);
  });

  // Only two states show an identity now, and neither of them is a question.
  test("an identity on screen is never a question", () => {
    for (const state of EVERY_STATE) {
      if (e2eSetupView(state).identity === null) continue;
      expect(state.kind, "only `ready` names an identity").toBe("ready");
    }
  });
});

// The same rule MOUNTED: the flow's grant must not run until Continue is pressed, and Not now must
// close the panel for good rather than have the flow's own ending reopen it.
describe("the create route, mounted", () => {
  const CODE = "C1P9-HM5S-6D93-FPDC";
  const flush = (): Promise<void> => new Promise((r) => setTimeout(r, 0));
  function mount(): { root: HTMLElement; granted: () => boolean } {
    document.body.innerHTML = '<dialog id="e2e-setup"><h2 id="e2e-setup-title"></h2>'
      + '<p id="e2e-setup-body"></p><p id="e2e-setup-identity"></p><div id="e2e-setup-actions"></div></dialog>';
    const root = document.getElementById("e2e-setup")!;
    let granted = false;
    const flow: SetupFlow = {
      enroll: async (_source, onStep) => {
        if ((await onStep?.("authorising")) === false) return { ok: false, reason: "dismissed" };
        granted = true;
        return { ok: true, deviceId: "d", rootId: CODE };
      },
      pending: async () => ({ resume: true, discard: false }),
      discard: async () => ({ ok: true }),
      done: () => {},
    };
    mountE2ESetup(root, flow);
    return { root, granted: () => granted };
  }
  const press = (root: HTMLElement, label: string): void =>
    [...root.querySelectorAll("button")].find((b) => b.textContent === label)!.click();

  test("the second prompt runs only once Continue is pressed", async () => {
    const { root, granted } = mount();
    press(root, "Create a passkey");
    await flush();
    expect(root.querySelector("#e2e-setup-body")!.textContent).toMatch(/press Continue/);
    expect(granted()).toBe(false);
    press(root, "Continue");
    await flush();
    expect(granted()).toBe(true);
    expect(root.querySelector("#e2e-setup-identity")!.textContent).toBe(CODE);
  });

  test("Not now closes the panel and nothing reopens it", async () => {
    const { root, granted } = mount();
    press(root, "Create a passkey");
    await flush();
    press(root, "Not now");
    await flush();
    await flush();
    expect(granted()).toBe(false);
    expect(root.hasAttribute("open")).toBe(false);
  });
});
