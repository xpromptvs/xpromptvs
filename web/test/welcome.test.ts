import { describe, it, expect, vi, beforeEach } from "vitest";
import { mountWelcome } from "../src/client/welcome";
import { ClientE2EIdentity } from "../src/client/e2e-identity";

// **JUST THE HOST.** The header, the field, the error line and the rest are built by
// `shared/dashboard.ts` — the same page the native app mounts — so a fixture that hand-rolled
// them would be testing markup the product no longer has.
const MARKUP = `<div id="welcome" class="welcome-overlay hidden"></div>`;

beforeEach(() => { document.body.innerHTML = MARKUP; history.replaceState(null, "", "/"); });

// **THE APP'S CLIENT WINDOW OFFERS NO PASSKEY.** `app://client/` can run no WebAuthn ceremony, and
// the Mac certifies that window itself (§10.3) — so an empty list there must not send the person to
// a button that can only fail. A browser keeps it. Module-scoped: both `describe` blocks below mount
// a bare window with no rooms to list.
const noIdentity = { navigate: vi.fn(), listDevices: async () => ({ kind: "no-identity" as const }),
                     watchDevices: () => ({ ping: () => {} }) };

describe("mountWelcome", () => {
  it("un-hides the overlay on mount", () => {
    mountWelcome({ navigate: vi.fn() });
    expect(document.getElementById("welcome")!.classList.contains("hidden")).toBe(false);
  });

  it("navigates with code+token, and the seed in the FRAGMENT, on a valid v3 code", async () => {
    const navigate = vi.fn();
    history.replaceState(null, "", "/#pairing=AAAAAAAAAAAAAAAAAAAAAA");
    mountWelcome({ navigate });
    // The derivation is HKDF through SubtleCrypto, so the submit is async now.
    await vi.waitFor(() => expect(navigate).toHaveBeenCalled());
    expect(navigate).toHaveBeenCalledWith(
      "?code=1DB6haeo&token=0d002ad3-28b2-4e70-b483-8fae577d1756#pair=AAAAAAAAAAAAAAAAAAAAAA");
  });

  // **`URLSearchParams` DOES NOT STRIP A FRAGMENT**, so a caller that parsed
  // `?code=X&token=Y#pair=Z` whole would read the token as `Y#pair=Z` — a wrong token, which
  // presents as a wrong pairing code. Measured while wiring the seed through.
  it("the fragment does not leak into the token", async () => {
    const navigate = vi.fn();
    history.replaceState(null, "", "/#pairing=AAAAAAAAAAAAAAAAAAAAAA");
    mountWelcome({ navigate });
    await vi.waitFor(() => expect(navigate).toHaveBeenCalled());
    const search = navigate.mock.calls[0]![0] as string;
    const hash = search.indexOf("#");
    const query = new URLSearchParams(search.slice(0, hash));
    expect(query.get("token")).toBe("0d002ad3-28b2-4e70-b483-8fae577d1756");
    expect(query.get("token")).not.toContain("#");
    expect(search.slice(hash)).toBe("#pair=AAAAAAAAAAAAAAAAAAAAAA");
  });

  it("shows an error and does not navigate on invalid input", async () => {
    const navigate = vi.fn();
    history.replaceState(null, "", "/#pairing=garbage");
    mountWelcome({ navigate });
    // The submit is async now, so the ERROR is what to wait for — waiting on `navigate` would wait
    // for something that must never happen, and then assert it had not.
    await vi.waitFor(() =>
      expect(document.getElementById("home-error")!.hidden).toBe(false));
    expect(navigate).not.toHaveBeenCalled();
  });

  it("does not show manual code entry on the dashboard", () => {
    mountWelcome(noIdentity);
    expect(document.querySelector("#home-input, #home-connect, #home-scan")).toBeNull();
  });

  it("a browser with no identity is offered a passkey sign-in", async () => {
    mountWelcome(noIdentity);
    await vi.waitFor(() =>
      expect(document.querySelector('[data-device-action="sign-in"]')).not.toBeNull());
  });

  it("the app's client window (__rdevShell) is NOT, and says where its identity comes from", async () => {
    const g = globalThis as { __rdevShell?: unknown };
    g.__rdevShell = { signalingBase: "https://cp.test" };
    try {
      mountWelcome(noIdentity);
      await vi.waitFor(() =>
        expect(document.getElementById("home-device-list")!.textContent).toContain("This window has no encryption identity yet"));
      expect(document.querySelector('[data-device-action="sign-in"]')).toBeNull();
      expect(document.getElementById("home-device-list")!.textContent).not.toContain("passkey");
    } finally { delete g.__rdevShell; }
  });

  // FIX ROUND 1 (I-1, m-2): a connect the controller REFUSES (navigate answers false) ends the busy
  // state — motion restores the button — and the reason it gave stays on the dashboard's error line,
  // because the phase it painted goes with the button's return.
  it("a REFUSED connect restores the button and leaves the reason on the error line", async () => {
    const restore = vi.fn();
    (window as { ShellstormMotion?: unknown }).ShellstormMotion = { begin: () => true, restore };
    try {
      const navigate = vi.fn(() => {
        document.dispatchEvent(new CustomEvent("shellstorm:connection-state",
          { detail: { state: "error", text: "Could not start the session." } }));
        return false;
      });
      history.replaceState(null, "", "/#pairing=AAAAAAAAAAAAAAAAAAAAAA");
      mountWelcome({ ...noIdentity, navigate });
      await vi.waitFor(() => expect(navigate).toHaveBeenCalled());
      expect(restore).toHaveBeenCalledTimes(1);
      const error = document.getElementById("home-error")!;
      expect(error.hidden).toBe(false);
      expect(error.textContent).toBe("Could not start the session.");
    } finally { Reflect.deleteProperty(window, "ShellstormMotion"); }
  });

  // FIX ROUND 1 (m-1, O-3): a session that failed with no dashboard to say it on — URL mode's own,
  // or a bfcache restart — lands on a dashboard that SAYS why, rather than a silent one.
  it("mounted with an `error`, the dashboard shows it on the error line", () => {
    mountWelcome({ ...noIdentity, error: "Could not start the session." });
    const line = document.getElementById("home-error")!;
    expect(line.hidden).toBe(false);
    expect(line.textContent).toBe("Could not start the session.");
  });

  it("mounted without one, the error line stays hidden", () => {
    mountWelcome(noIdentity);
    expect(document.getElementById("home-error")!.hidden).toBe(true);
  });

  it("does nothing at all while the session controller is BUSY — no navigate", async () => {
    const navigate = vi.fn();
    history.replaceState(null, "", "/#pairing=AAAAAAAAAAAAAAAAAAAAAA");
    mountWelcome({ ...noIdentity, navigate, busy: () => true });
    await new Promise((r) => setTimeout(r, 200));      // the seed's HKDF has long settled
    expect(navigate).not.toHaveBeenCalled();
  });
});

// **THE WINDOW GETS ITS IDENTITY ON OPEN, NOT ONLY ON ITS FIRST CONNECT.** Before this, an app
// window that had never connected held no chain at all — `adoptFromShell` ran only from inside
// `openSecureSession` — so its own welcome list read "no identity" on a fully enrolled Mac until the
// person connected once (`docs/open-threads.md`). These drive `mountWelcome` itself, never
// `openSecureSession`, so "before any connect" is true by construction: nothing here ever navigates.
describe("adopting the window's identity on open", () => {
  const withShell = (issueGrant: (keys: string) => Promise<string>) => {
    const g = globalThis as { __rdevShell?: unknown };
    g.__rdevShell = { signalingBase: "https://cp.test", issueGrant };
    return () => { delete g.__rdevShell; };
  };

  it("a working shell adopts an identity on open, and the list stops describing an unenrolled window",
    async () => {
    const issueGrant = vi.fn(async (_keys: string) => "granted-bundle");
    const restoreShell = withShell(issueGrant);
    try {
      const adoptFromShell = vi.fn(async (issue: (keys: string) => Promise<string>) => {
        await issue("keys");
        return { ok: true,
                 status: { kind: "ready", deviceId: new Uint8Array(1), rootId: new Uint8Array(1) } };
      });
      const identity = {
        load: async () => ({ kind: "unenrolled" }),
        status: async () => ({ kind: "unenrolled" }),
        adoptFromShell,
      } as unknown as ClientE2EIdentity;

      // Ready only once the adoption has actually run — so a SECOND `listDevices` reading `ready`
      // is proof the mount re-asked after the shell answered, not a lucky first answer.
      const listDevices = vi.fn(async () => adoptFromShell.mock.calls.length > 0
        ? { kind: "ready" as const, devices: [] }
        : { kind: "no-identity" as const });
      const watchDevices = () => ({ ping: () => {} });

      mountWelcome({ navigate: vi.fn(), identity, listDevices, watchDevices });

      await vi.waitFor(() => expect(adoptFromShell).toHaveBeenCalledTimes(1));
      // `shellGrantIssuer()` hands back `issueGrant.bind(shell)`, not the same function object, so
      // what proves it is THIS shell's issuer is that calling it reaches the vi.fn underneath.
      expect(typeof adoptFromShell.mock.calls[0]![0]).toBe("function");
      expect(issueGrant).toHaveBeenCalledTimes(1);

      await vi.waitFor(() => expect(listDevices.mock.calls.length).toBeGreaterThanOrEqual(2));
      await vi.waitFor(() => expect(document.getElementById("home-device-list")!.textContent)
        .not.toContain("no encryption identity"));
    } finally { restoreShell(); }
  });

  it("while the adoption is in flight the list says LOOKING, never 'no identity'", async () => {
    // An enrolled Mac takes a round trip to certify the window. Before `adoption` held the list, the
    // dashboard's first listing answered `no-identity` meanwhile and flashed the sentence that tells
    // a person this window has no identity — on a Mac that was about to give it one.
    const restoreShell = withShell(vi.fn(async () => "granted-bundle"));
    try {
      let finish!: () => void;
      const gate = new Promise<void>((resolve) => { finish = resolve; });
      let adopted = false;
      const identity = {
        load: async () => ({ kind: "unenrolled" }),
        status: async () => ({ kind: "unenrolled" }),
        adoptFromShell: vi.fn(async () => {
          await gate; adopted = true;
          return { ok: true,
                   status: { kind: "ready", deviceId: new Uint8Array(1), rootId: new Uint8Array(1) } };
        }),
      } as unknown as ClientE2EIdentity;
      const listDevices = vi.fn(async () => adopted
        ? { kind: "ready" as const, devices: [] }
        : { kind: "no-identity" as const });
      mountWelcome({ navigate: vi.fn(), identity, listDevices, watchDevices: () => ({ ping: () => {} }) });

      const list = () => document.getElementById("home-device-list")!.textContent ?? "";
      for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
      expect(list()).not.toContain("no encryption identity");
      expect(list()).toContain("Looking");

      finish();
      await vi.waitFor(() => expect(list()).not.toContain("Looking"));
      expect(list()).not.toContain("no encryption identity");
    } finally { restoreShell(); }
  });

  it("a refusing shell leaves no identity, and throws nothing", async () => {
    const issueGrant = vi.fn(async () => "-not-enrolled");
    const restoreShell = withShell(issueGrant);
    try {
      const adoptFromShell = vi.fn(async (issue: (keys: string) => Promise<string>) => {
        const answer = await issue("keys");
        return { ok: false, failure: { kind: "shell", reason: answer } };
      });
      const identity = {
        load: async () => ({ kind: "unenrolled" }),
        status: async () => ({ kind: "unenrolled" }),
        adoptFromShell,
      } as unknown as ClientE2EIdentity;
      const listDevices = vi.fn(async () => ({ kind: "no-identity" as const }));
      const watchDevices = vi.fn(() => ({ ping: () => {} }));

      mountWelcome({ navigate: vi.fn(), identity, listDevices, watchDevices });

      await vi.waitFor(() => expect(adoptFromShell).toHaveBeenCalledTimes(1));
      // A settle beat for anything that might (wrongly) run after the refusal.
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(document.getElementById("home-device-list")!.textContent)
        .toContain("This window has no encryption identity yet");
      // The refusal did not restart the stream — only the initial mount opened it.
      expect(watchDevices).toHaveBeenCalledTimes(1);
    } finally { restoreShell(); }
  });

  it("with no __rdevShell, no adoption is attempted", async () => {
    const spy = vi.spyOn(ClientE2EIdentity.prototype, "adoptFromShell");
    try {
      mountWelcome(noIdentity);
      await vi.waitFor(() =>
        expect(document.getElementById("home-device-list")!.textContent).not.toBe(""));
      expect(spy).not.toHaveBeenCalled();
    } finally { spy.mockRestore(); }
  });

  it("with an identity already held, startup runs no adoption", async () => {
    const issueGrant = vi.fn(async () => "unexpected-call");
    const restoreShell = withShell(issueGrant);
    try {
      const adoptFromShell = vi.fn();
      const identity = {
        load: async () => ({ kind: "unenrolled" }),
        status: async () => ({ kind: "ready", deviceId: new Uint8Array(1), rootId: new Uint8Array(1) }),
        adoptFromShell,
      } as unknown as ClientE2EIdentity;

      mountWelcome({ ...noIdentity, identity });
      await vi.waitFor(() =>
        expect(document.getElementById("home-device-list")!.textContent).not.toBe(""));
      // A settle beat: the pre-check itself is async, so give it a turn before asserting the negative.
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(adoptFromShell).not.toHaveBeenCalled();
      expect(issueGrant).not.toHaveBeenCalled();
    } finally { restoreShell(); }
  });
});
