import { afterEach, beforeAll, describe, expect, it, test } from "vitest";
import fixture from "../../protocol/fixtures/e2e-session.json";
import {
  ADD_DEVICE_DIALOG, addDeviceCarrier, addDeviceReason, addDeviceView, mountAddDeviceDialog,
  type AddDevice, type AddDeviceState,
} from "../src/shared/add-device";
import ackFixture from "../../protocol/fixtures/adoption-ack.json";
import { adoptionAck, runAdoption, type AdoptDeps, type AdoptState } from "../src/client/adopt";
import type { ClientE2EIdentity } from "../src/client/e2e-identity";

/**
 * **ADD DEVICE BY CODE** (2026-10-07, asked for — `web/src/shared/add-device.ts`). The wording IS most of the
 * feature: the confirm screen is where §10.1's naming happens — the one moment a person is told which identity
 * a Mac is about to join — and where §12.2's required sentence has to survive a tidy-up.
 */
describe("addDeviceView", () => {
  test("the form asks for the code the new Mac's Add by code shows", () => {
    const view = addDeviceView({ kind: "form" });
    expect(view.field).toBe(true);
    expect(view.body).toMatch(/Add by code/);
    expect(view.actions.map((a) => a.id)).toEqual(["add", "close"]);
    expect(addDeviceView({ kind: "form", error: "no" }).error).toBe("no");
  });

  test("asks for a sign-in when this device holds no identity", () => {
    const view = addDeviceView({ kind: "no-identity" });
    expect(view.heading).toBe("Sign in first");
    expect(view.actions.map((a) => a.id)).toEqual(["sign-in", "close"]);
  });

  test("names the identity as a readable, selectable code, before the passkey is asked", () => {
    const view = addDeviceView({ kind: "confirm", identityCode: "C1P9-HM5S-6D93-FPDC" });
    expect(view.identity).toBe("C1P9-HM5S-6D93-FPDC");
    expect(view.body).toContain("share its screen");
    expect(view.actions.map((a) => a.id)).toEqual(["confirm", "close"]);
  });

  /** What capability 2 costs, said before it is granted rather than discovered afterwards. */
  test("the confirm screen says what the Mac will NOT be able to do", () => {
    const body = addDeviceView({ kind: "confirm", identityCode: "X" }).body;
    expect(body).toMatch(/not be able to add other devices/i);
    expect(body).toMatch(/connect out/i);
  });

  test("a failure is not called an error, and offers the same code again", () => {
    const view = addDeviceView({ kind: "failed", reason: "cancelled" });
    expect(view.heading).not.toMatch(/error/i);
    expect(view.actions.map((a) => a.id)).toEqual(["retry", "close"]);
  });

  // §12.2's REQUIRED WORDING, asserted verbatim.
  test("a rejected publication is reported in §12.2's own words", () => {
    expect(addDeviceView({ kind: "added", publication: "rejected" }).body)
      .toBe("Publication rejected; listing not confirmed. Action required.");
  });

  test("an unconfirmed publication is not reported as a problem", () => {
    const body = addDeviceView({ kind: "added", publication: "unconfirmed" }).body;
    expect(body).not.toMatch(/rejected|action required/i);
    expect(body).toContain("share its screen");
  });

  test("while a run is under way the passkey's step offers nothing to press", () => {
    expect(addDeviceView({ kind: "issuing" }).actions).toEqual([]);
    expect(addDeviceView({ kind: "waiting" }).busy).toBe(true);
  });

  // 2026-10-07: "added" was said as the chain LEFT, and a chain lost on the way read as a success.
  test("after the passkey it waits for the Mac's word, and says so", () => {
    const view = addDeviceView({ kind: "finishing" });
    expect(view.body).toMatch(/Mac to confirm/);
    expect(view.heading).not.toMatch(/added/i);
  });

  test("every state yields a heading and a body", () => {
    const states: AddDeviceState[] = [{ kind: "form" }, { kind: "no-identity" }, { kind: "waiting" },
      { kind: "confirm", identityCode: "X" }, { kind: "issuing" }, { kind: "finishing" }, { kind: "added", publication: "confirmed" },
      { kind: "failed", reason: "x" }];
    for (const s of states) {
      const v = addDeviceView(s);
      expect(v.heading.length, s.kind).toBeGreaterThan(0);
      expect(v.body.length, s.kind).toBeGreaterThan(0);
    }
  });
});

describe("addDeviceReason", () => {
  test("the cases a person can act on are said as what to do", () => {
    expect(addDeviceReason("gate/noise")).toMatch(/did not match/);
    expect(addDeviceReason("noise")).toMatch(/did not match/);
    // A SHARE code typed here: its host waits for a guest to speak, so nothing answers — and it goes in Connect.
    expect(addDeviceReason("no-answer")).toMatch(/Connect with a code/);
    expect(addDeviceReason("not-a-code")).toMatch(/not a code/);
    expect(addDeviceReason("cancelled")).toMatch(/passkey/);
    expect(addDeviceReason("weird")).toContain("weird");
    // The Mac never confirmed: what to do on IT, since it may still be waiting.
    expect(addDeviceReason("unconfirmed")).toMatch(/did not confirm/);
    expect(addDeviceReason("unconfirmed")).toMatch(/Stop/);
    expect(addDeviceReason("mac-refused/root-not-adopted")).toContain("root-not-adopted");
  });
});

// `protocol/fixtures/adoption-ack.json` — the Swift side (`RdevCore.AdoptionAck`) holds to the same file.
describe("adoptionAck", () => {
  const bytes = (t: string) => new TextEncoder().encode(t);
  test("every case parses as the fixture says", () => {
    for (const c of ackFixture.cases) {
      expect(adoptionAck(bytes(c.json)), c.json)
        .toEqual(c.kind === "adopted" ? { kind: "adopted" } : { kind: "refused", reason: c.reason });
    }
  });
  test("what is not one is nothing", () => {
    for (const n of ackFixture.not) expect(adoptionAck(bytes(n)), n).toBeNull();
  });
});

describe("addDeviceCarrier", () => {
  const carrier = "AbCdEfGhIjKlMnOpQrStU-";
  test("a bare code, trimmed", () => { expect(addDeviceCarrier(`  ${carrier}\n`)).toBe(carrier); });
  test("the link a Mac's QR encodes, pasted whole", () => {
    expect(addDeviceCarrier(`https://app.xpromptvs.ai/#adopt=${carrier}`)).toBe(carrier);
  });
  test("a GUEST link is Connect's, not this", () => {
    expect(addDeviceCarrier(`https://app.xpromptvs.ai/#pair=${carrier}`)).toBeNull();
  });
  test("anything else is nothing", () => {
    for (const raw of ["", "short", `${carrier}x`, "https://app.xpromptvs.ai/?code=a&token=b"]) {
      expect(addDeviceCarrier(raw), raw).toBeNull();
    }
  });
});

// ------------------------------------------------------------------ the dialog, in the DOM

describe("mountAddDeviceDialog", () => {
  beforeAll(() => {
    // jsdom implements neither: the attribute and the `close` event are all a unit test sees.
    const proto = HTMLDialogElement.prototype as unknown as { showModal: () => void; close: () => void };
    proto.showModal = function (this: HTMLDialogElement) { this.setAttribute("open", ""); };
    proto.close = function (this: HTMLDialogElement) {
      if (!this.hasAttribute("open")) return;
      this.removeAttribute("open");
      this.dispatchEvent(new Event("close"));
    };
  });
  afterEach(() => { document.body.replaceChildren(); });

  const carrier = "AbCdEfGhIjKlMnOpQrStU-";

  function rig() {
    const root = document.createElement("div");
    root.innerHTML = ADD_DEVICE_DIALOG;
    document.body.append(root);
    const runs: { carrier: string; report: (s: AddDeviceState) => void; answers: boolean[]; cancelled: number }[] = [];
    const addDevice: AddDevice = (c, onState) => {
      const run = { carrier: c, report: onState, answers: [] as boolean[], cancelled: 0 };
      runs.push(run);
      return { confirm: (add) => { run.answers.push(add); }, cancel: () => { run.cancelled++; } };
    };
    const closed: boolean[] = [];
    let signedIn = 0;
    const dialog = mountAddDeviceDialog({ root, addDevice, signIn: () => { signedIn++; }, onClosed: (a) => closed.push(a) });
    const $ = (id: string) => root.querySelector<HTMLElement>(`#${id}`)!;
    const press = (id: string) => $(`add-device-${id}`).click();
    return { root, runs, closed, dialog, $, press, signedIn: () => signedIn };
  }

  it("enters a code, waits, NAMES the identity, and only the person's yes reaches the run", () => {
    const r = rig();
    r.dialog.open();
    expect(r.$("add-device-dialog").hasAttribute("open")).toBe(true);
    expect(r.$("add-device-field").hidden).toBe(false);
    (r.$("add-device-code") as HTMLInputElement).value = `https://app.xpromptvs.ai/#adopt=${carrier}`;
    r.press("add");
    expect(r.runs.map((x) => x.carrier)).toEqual([carrier]);
    expect(r.$("add-device-title").textContent).toBe("Waiting for the new Mac");
    expect(r.$("add-device-field").hidden).toBe(true);

    r.runs[0]!.report({ kind: "confirm", identityCode: "C1P9-HM5S-6D93-FPDC" });
    expect(r.$("add-device-identity").textContent).toBe("C1P9-HM5S-6D93-FPDC");
    expect(r.$("add-device-identity").hidden).toBe(false);
    expect(r.runs[0]!.answers).toEqual([]);
    r.press("confirm");
    expect(r.runs[0]!.answers).toEqual([true]);

    r.runs[0]!.report({ kind: "issuing" });
    r.runs[0]!.report({ kind: "added", publication: "confirmed" });
    r.press("done");
    expect(r.$("add-device-dialog").hasAttribute("open")).toBe(false);
    expect(r.closed).toEqual([true]);
  });

  it("refuses what is not a code, starting nothing", () => {
    const r = rig();
    r.dialog.open();
    (r.$("add-device-code") as HTMLInputElement).value = "not a code";
    r.press("add");
    expect(r.runs).toEqual([]);
    expect(r.$("add-device-error").hidden).toBe(false);
  });

  it("closing it cancels the run, and a late report from that run paints nothing", () => {
    const r = rig();
    r.dialog.open(carrier, { start: true });
    expect(r.runs.length).toBe(1);
    r.press("close");
    expect(r.runs[0]!.cancelled).toBe(1);
    expect(r.closed).toEqual([false]);
    r.dialog.open();
    r.runs[0]!.report({ kind: "confirm", identityCode: "LATE" });
    expect(r.$("add-device-title").textContent).toBe("Add a Mac");
  });

  it("Try again keeps the code; no identity leads to sign-in", () => {
    const r = rig();
    r.dialog.open(carrier, { start: true });
    r.runs[0]!.report({ kind: "failed", reason: "gate/noise" });
    expect(r.$("add-device-body").textContent).toMatch(/did not match/);
    r.press("retry");
    expect((r.$("add-device-code") as HTMLInputElement).value).toBe(carrier);
    r.press("add");
    r.runs[1]!.report({ kind: "no-identity" });
    r.press("sign-in");
    expect(r.signedIn()).toBe(1);
    expect(r.$("add-device-dialog").hasAttribute("open")).toBe(false);
  });

  it("every control carries a nav id (the glasses' D-pad reaches nothing else)", () => {
    const r = rig();
    r.dialog.open();
    for (const el of r.root.querySelectorAll<HTMLElement>("#add-device-dialog button:not([hidden]), #add-device-dialog input")) {
      expect(el.dataset.navId, el.id).toMatch(/^add-device:/);
    }
    expect(r.root.querySelector("[data-nav-id='add-device:close']")).not.toBeNull();
  });
});

// ------------------------------------------------------------------ the browser's adoption driver

describe("runAdoption", () => {
  const hex = (s: string) => Uint8Array.from(s.match(/../g)!.map((b) => parseInt(b, 16)));
  const carrier = "AbCdEfGhIjKlMnOpQrStU-";

  function deps(over: Partial<AdoptDeps> & { held?: boolean } = {}) {
    const states: AdoptState[] = [];
    const identity = {
      load: async () => over.held === false
        ? { kind: "none" }
        : { record: { root: hex(fixture.root), bundle: new Uint8Array([1]) } },
      hostGateConfig: async () => ({ roomCode: "room" }),
    } as unknown as ClientE2EIdentity;
    let closed = 0;
    const d: AdoptDeps = {
      identity, origin: "https://app.example",
      connect: () => ({ send: () => {}, close: () => { closed++; } }),
      state: (s) => states.push(s),
      confirm: async () => true,
      ...over,
    };
    return { d, states, closed: () => closed };
  }

  test("what is not a code is said as that", async () => {
    const { d, states } = deps();
    expect(await runAdoption("nope", d)).toEqual({ kind: "failed", reason: "not-a-code" });
    expect(states).toEqual([{ kind: "failed", reason: "not-a-code" }]);
  });

  test("a device with no identity is asked to sign in", async () => {
    const { d } = deps({ held: false });
    expect(await runAdoption(carrier, d)).toEqual({ kind: "no-identity" });
  });

  test("a room where no Mac speaks ends, rather than waiting forever", async () => {
    const { d, states, closed } = deps({ answerMs: 20 });
    expect(await runAdoption(carrier, d)).toEqual({ kind: "failed", reason: "no-answer" });
    expect(states.map((s) => s.kind)).toEqual(["waiting", "failed"]);
    expect(closed()).toBe(1);
  });

  test("a room that closes before the Mac speaks is a lost connection", async () => {
    let closed: (() => void) | undefined;
    const { d } = deps({
      answerMs: 10_000,
      connect: (_u, _t, h) => { closed = h.onClosed; return { send: () => {}, close: () => {} }; },
    });
    const done = runAdoption(carrier, d);
    await new Promise((r) => setTimeout(r, 20));
    closed?.();
    expect(await done).toEqual({ kind: "failed", reason: "disconnected" });
  });

  test("an abort ends it and reports nothing after", async () => {
    const abort = new AbortController();
    const { d, states } = deps({ signal: abort.signal, answerMs: 10_000 });
    const done = runAdoption(carrier, d);
    await new Promise((r) => setTimeout(r, 20));
    abort.abort();
    expect(await done).toEqual({ kind: "failed", reason: "cancelled" });
    expect(states.map((s) => s.kind)).toEqual(["waiting"]);
  });
});
