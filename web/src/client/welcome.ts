import { shellstormMotion } from "./shellstorm-motion";
import { mountDashboard, type Dashboard, type DashboardAdapter } from "../shared/dashboard";
import type { DeviceListState } from "../shared/device-list";
import type { ProfileState } from "../shared/profile-dialog";
import { ClientE2EIdentity, shellScopedIdentity } from "./e2e-identity";
import { mountIdentitySetup } from "./identity-setup";
import { identitySettingsView, type IdentitySettingsState } from "./identity-settings";
import { listDirectorySessions, type DirectoryIdentity } from "../lib/directory-api";
import { watchDirectory } from "../lib/directory-watch";
import { controlPlaneOrigin, shellGrantIssuer } from "../lib/signaling-base";
import { parsePairing } from "./pairing";
import { startAdoption } from "./adopt";
/**
 * **STATIC — KEEP IT STATIC.** The trap that forced this is gone: the home page used to PARK module
 * init on `await new Promise(() => {})`, the entry chunk never finished evaluating, and vite's
 * `__vitePreload` helper lives IN the entry chunk — so a dynamically imported scanner imported a
 * module that never finished, and its `import()` never settled (the button did nothing, with no
 * error anywhere). `main.ts` finishes evaluating since 2026-09-27, but a lazy scanner would buy
 * nothing worth reopening that class of failure for. `jsqr` stays lazy inside `qr-decode`: that is
 * the 128 KB that matters, and its chunk imports nothing.
 */
import { mountScanner } from "./qr-scan";
import { decodePairingSeed, identityCode, type DirectorySession } from "@rdev/protocol";

/// **The browser's half of the dashboard.** The page itself — header, quick connect, My Devices,
/// Settings, the profile alert — is `shared/dashboard.ts`, which the native app mounts too. What
/// is here is what only a browser can answer: a pairing code parsed and navigated to, §12.2's
/// directory read with this browser's own key, and §10.1's passkey flows, which `app://ui/` can run
/// none of. `docs/ui-design.md`.
///
/// Mounted by `main.ts` on every page that has no session to show; a valid pairing submission hands
/// `?code=&token=#pair=` to `navigate` — the page's one session controller — and the address bar
/// never changes.
let welcomeListeners: AbortController | undefined;

export function mountWelcome(opts: {
  /**
   * Start a session: the page's one session controller (`session-lifecycle.ts`). FALSE means the
   * connect was REFUSED (the controller said why, as a `connection-state` error). REQUIRED — there is
   * no fallback that navigates, because a navigation would end any session this document holds.
   */
  navigate: (search: string) => boolean | void;
  /** Main starts the real connection in place and owns teardown when Cancel is pressed. */
  onCancel?: () => void;
  /**
   * The session controller is busy — a session exists or is sliding out. A connect then starts
   * NOTHING: without this the button's morph would begin with no session behind it.
   */
  busy?: () => boolean;
  /**
   * The Macs to offer, and the state to show while finding out. Injected so the DOM half is
   * testable without IndexedDB or a network; production uses `liveDevices` below.
   */
  listDevices?: () => Promise<DeviceListState<DirectorySession>>;
  /** Injected for tests; production builds one over this origin's own storage. */
  identity?: ClientE2EIdentity;
  /** Injected for tests; production streams with `watchDirectory` (`productionWatch` below). */
  watchDevices?: DashboardAdapter["watchDevices"];
  /**
   * A reason to show on the error line at once: a session that failed with no dashboard to say it on
   * (URL mode's own, or a bfcache restart) lands here rather than on a silent dashboard.
   */
  error?: string;
  /** A new Mac's code from an `#adopt=` link (its QR, scanned with a phone's camera): Add device opens on it,
   *  started. */
  adopt?: string;
}): void {
  welcomeListeners?.abort();
  welcomeListeners = new AbortController();
  const { signal } = welcomeListeners;
  const navigate = opts.navigate;
  // **SCOPED TO §10.1's POLICY ORIGIN, NOT `location.origin`.** Inside the app's client window that
  // is `app://client/` — no http(s) origin at all — while `shellScopedIdentity()` reads
  // `ceremonyOrigin()`, the one a shell-issued chain was actually enrolled against. In a browser the
  // two coincide, so this changes nothing there.
  const identity = () => opts.identity ?? shellScopedIdentity();
  // **THE APP'S OWN CLIENT WINDOW RUNS NO PASSKEY CEREMONY** — `app://client/` is no registrable
  // domain for WebAuthn's RP ID, and a third-party WKWebView would need Associated Domains besides.
  // It never needs one: the Mac certifies this window through §10.3 (`__rdevShell.issueGrant`), and
  // now on OPEN rather than only on the window's first connect — see the adoption below. So there it
  // is its own `Surface`, `"app-client"` — no "Sign in with a passkey", and a sign-out that says only
  // the window's keys go. `docs/desktop-app.md`.
  const inApp = (globalThis as { __rdevShell?: unknown }).__rdevShell !== undefined;

  const overlay = document.getElementById("welcome");
  if (!overlay) return;
  overlay.classList.remove("hidden");

  // **The room TOKENS never reach the DOM.** The renderer is given codes; this map is what turns one
  // back into a connect URL, and it is replaced wholesale on every listing so a stale token can
  // never outlive the row it came with.
  let tokens = new Map<string, string>();

  const connectTo = (search: string, row: HTMLElement | null = null): void => {
    if (opts.busy?.()) return;
    const motion = shellstormMotion();
    if (motion && !motion.begin({ row, button: row ? null : document.getElementById("home-connect"),
                                  onCancel: opts.onCancel })) return;
    // **A REFUSED CONNECT ENDS THE BUSY STATE.** The controller says why as a `connection-state`
    // error, which `motion.js` paints as the phase — but the button's return takes the phase with it,
    // so the reason is caught here, synchronously, and kept on the dashboard's error line.
    let reason: string | undefined;
    const noteReason = (e: Event): void => {
      const detail = (e as CustomEvent<{ state: string; text?: string }>).detail;
      if (detail?.state === "error") reason = detail.text;
    };
    document.addEventListener("shellstorm:connection-state", noteReason);
    let started: boolean | void;
    try { started = navigate(search); } finally { document.removeEventListener("shellstorm:connection-state", noteReason); }
    if (started !== false) return;
    motion?.restore?.();
    if (reason) dashboard.showError(reason);
  };

  // **The stream's rows carry tokens too**, and they reach the dashboard rather than `listDevices`,
  // so the map is replaced here — by every snapshot, exactly as by every poll answer.
  const streamTokens = (w: NonNullable<DashboardAdapter["watchDevices"]>): DashboardAdapter["watchDevices"] =>
    (onEvent, s) => w((e) => {
      if (e.kind === "state" && e.state.kind === "ready") {
        tokens = new Map((e.state.devices as readonly DirectorySession[]).map((d) => [d.code, d.token]));
      }
      onEvent(e);
    }, s);

  // **THE WINDOW GETS ITS IDENTITY ON OPEN, NOT ONLY ON ITS FIRST CONNECT.** Before this, a window
  // that had never connected held no chain — `adoptFromShell` ran only from inside `openSecureSession`
  // — so its own welcome list read "no identity" even on a Mac that was fully enrolled, until the
  // person actually connected once (`docs/open-threads.md`). The SAME path runs here, once, while
  // this overlay is up rather than gating it: `adoptFromShell` is already idempotent (a `ready`
  // renderer asks the shell for nothing) and single-flight (a connect racing it shares this one), so
  // the pre-check below is only to avoid restarting the device stream on every mount once an
  // identity is already held.
  //
  // **STARTED BEFORE THE DASHBOARD MOUNTS, AND THE LIST WAITS FOR IT** (`adoption`, awaited by
  // `listDevices` below): the dashboard's first listing would otherwise answer `no-identity` while
  // the Mac was still certifying this window, and flash "This window has no encryption identity yet"
  // on an enrolled Mac for the length of a round trip. Held, it reads "Looking for your Macs…" until
  // the adoption settles either way.
  //
  // **FAILURE HERE MUST NOT BLOCK OR BREAK THE WELCOME SCREEN.** A Mac that is not enrolled, or a
  // capability-`2` Mac that cannot issue (`E2ESubordinateGrant` refuses it), answers with a `-`
  // reason; the window is left exactly as it reads today — `NO_IDENTITY["app-client"]` — and the
  // connect-time call in `openSecureSession` remains the fallback (idempotent: with a config already
  // committed here, it is skipped there). `adoption` never rejects.
  let adoption: Promise<void> | null = null;
  // Deferred on purpose: `refresh` and `dashboard` are declared below, and this runs only after the
  // adoption's first await, by which time both exist.
  const afterAdoption = (): void => { refresh(); dashboard.restartDeviceWatch(); };
  if (inApp) {
    const shell = shellGrantIssuer();
    if (shell) {
      adoption = (async () => {
        try {
          const id = identity();
          const status = await id.status();
          if (status.kind === "ready" || signal.aborted) return;
          const adopted = await id.adoptFromShell(shell);
          // The dashboard may already have run its own stream; this is what makes it stop describing
          // a window that no longer has no identity. Mirrors `signIn`'s own `onDone`.
          if (adopted.ok && !signal.aborted) afterAdoption();
        } catch { /* the welcome stays as it reads; a connect retries */ }
      })();
    }
  }

  const dashboard: Dashboard = mountDashboard({
    host: overlay,
    signal,
    adapter: {
      surface: inApp ? "app-client" : "browser",

      // One round trip with no intermediate state, so the dashboard paints "Looking for your Macs…"
      // in front of it. The app's source reports that itself and sets this false.
      paintsLoading: true,

      // **The room tokens are taken OUT of the listing here and never handed to the renderer.**
      // Replaced wholesale by every ANSWER, so a stale token can never outlive the row it came with
      // — and KEPT through a failed listing, because the dashboard keeps showing those rows then
      // (`deviceListView`'s `stale`) and a row whose Connect did nothing would be a dead button.
      // No identity forgets them, exactly as the dashboard forgets the rows.
      listDevices: async () => {
        if (adoption) await adoption;
        const state = await (opts.listDevices ?? liveDevices)();
        if (state.kind === "ready") tokens = new Map(state.devices.map((d) => [d.code, d.token]));
        else if (state.kind === "no-identity") tokens = new Map();
        return state;
      },

      watchDevices: streamTokens(opts.watchDevices ?? productionWatch),

      connect: (code, row) => {
        const token = tokens.get(code);
        if (!token) return;
        connectTo(`?code=${encodeURIComponent(code)}&token=${encodeURIComponent(token)}`, row);
      },

      // **THE ONE PAIRING PARSER.** The native app hands raw input to this same field through a
      // fragment, rather than duplicating `parsePairing` into the shell.
      quickConnect: (raw) => { void submitPairing(raw); },

      identity: async (): Promise<ProfileState> => {
        const state = await identityOf();
        return state.kind === "held"
          ? { kind: "signed-in", identity: state.rootId }
          : { kind: "signed-out" };
      },

      logOut: () => { void signOut(); },

      // **SIGNING IN, on a page where no session exists yet.** The identity panel is the same one a
      // client mounts mid-connection (§10.1's naming, both answers, one vocabulary of reasons); only
      // what follows differs, and here it is the list this browser could not populate a moment ago.
      signIn: inApp ? undefined : () => {
        const panel = document.getElementById("e2e-setup");
        if (!panel) return;
        mountIdentitySetup({
          root: panel,
          identity: identity(),
          // BOTH surfaces. The list is what the person was looking at; Settings is where the
          // identity they just adopted has to appear, and a panel that refreshed only one would
          // leave the other describing a browser that no longer exists.
          onDone: () => { refresh(); dashboard.restartDeviceWatch(); },
        });
      },

      // **ADD DEVICE BY CODE** (`shared/add-device.ts`): this browser answers the new Mac's handshake and its
      // passkey signs the Mac's grant (`adopt.ts`). Not in the app's client window: it runs no passkey ceremony.
      addDevice: inApp ? undefined : (carrier, onState) => startAdoption(carrier, onState, { identity: identity() }),
      // A Mac's QR encodes its `#adopt=` link, a bare code only fills the field; anything else reads nothing.
      scanCode: inApp ? undefined : (onCode) => {
        mountScanner({
          origin: location.origin,
          onScanned: (s) => {
            if (s.kind === "adopt") onCode(s.carrier);
            else if (s.kind === "code") onCode(s.text);
          },
        });
      },
    },
  });

  /** Both views of the same answer, always together. */
  const refresh = (): void => {
    dashboard.refreshDevices();
    dashboard.refreshIdentity();
    void paintIdentitySettings();
  };

  // --- native pairing handoff ------------------------------------------------------------------------
  const submitPairing = async (raw: string): Promise<void> => {
    const parsed = await parsePairing(raw);
    if (!parsed) {
      const text = "This connection link is invalid. Open Sharing on the Mac you want to use and create a new link.";
      dashboard.showError(text);
      document.dispatchEvent(new CustomEvent("shellstorm:connection-state",
                                             { detail: { state: "error", text } }));
      return;
    }
    dashboard.showError("");
    // **CODE AND TOKEN IN THE QUERY, THE SEED IN THE FRAGMENT** — the shape of a connect link, which
    // is what `navigate` takes (`splitConnectSearch`). None of it reaches the address bar: the
    // controller keeps it in memory. The seed stays in the fragment half because that is the half a
    // pasted or scanned LINK carries it in, and §9.1 keeps it out of anything a server is sent.
    const carrier = seedCarrier(raw);
    connectTo(`?code=${encodeURIComponent(parsed.code)}&token=${encodeURIComponent(parsed.token)}`
              + (carrier ? `#pair=${encodeURIComponent(carrier)}` : ""));
  };

  /// The v3 carrier inside whatever was pasted, or null. Taken from the INPUT rather than rebuilt
  /// from the parse, because only the seed can reproduce the psk and the parse deliberately does not
  /// carry it back out.
  const seedCarrier = (raw: string): string | null => {
    const t = raw.trim();
    // **SHAPE, NOT A PREFIX** — `decodePairingSeed` enforces the exact length and alphabet, which is
    // the whole discriminator now that `ss3.` is gone.
    if (decodePairingSeed(t)) return t;
    const hash = t.indexOf("#");
    if (hash < 0) return null;
    const pair = new URLSearchParams(t.slice(hash + 1)).get("pair");
    return pair && decodePairingSeed(pair) ? pair : null;
  };

  // The native app hands raw input to the one existing parser, in a fragment that never reaches a server.
  const handoff = new URLSearchParams(location.hash.slice(1)).get("pairing");
  if (handoff) {
    history.replaceState(null, "", location.pathname + location.search);
    void submitPairing(handoff);
  }

  // --- the browser's own additions --------------------------------------------------------------
  //
  // Settings: the identity this browser holds, and the way out. The app's equivalent is its
  // encryption section, which says different things because a Mac is enrolled differently.
  const identitySection = document.createElement("section");
  identitySection.id = "welcome-identity";
  identitySection.className = "ss-settings-identity";
  identitySection.hidden = true;
  identitySection.innerHTML =
    '<h2 id="welcome-identity-heading"></h2><div class="ss-settings-card"><div class="ss-settings-account"><div class="ss-settings-copy"><p id="welcome-identity-body"></p>'
    + '<p class="ss-settings-help">Use the same passkey on your other devices to connect to your Macs.</p></div>'
    + '<div id="welcome-identity-actions" class="e2e-setup-actions"></div></div>'
    + '<div class="ss-settings-details" role="region" aria-label="Device connection details">'
    + '<p class="ss-settings-help">Device group code · Devices using the same passkey share this code.</p>'
    + '<code id="welcome-identity-value" class="e2e-setup-identity"></code></div></div>'
    + '<p class="ss-settings-note">Signing out removes this browser’s saved sign-in. Your other devices stay signed in.</p>';
  dashboard.settings.appendChild(identitySection);
  const privacySection = document.createElement("section");
  privacySection.className = "ss-preferences-group";
  privacySection.innerHTML = '<h2>Privacy</h2><div class="ss-settings-card"><span class="ss-settings-title">Private connections</span><p class="ss-settings-help">Your screens, sound, and terminal sessions are encrypted between your devices.</p></div>';
  dashboard.settings.appendChild(privacySection);

  const paintIdentity = (state: IdentitySettingsState): void => {
    const view = identitySettingsView(state);
    identitySection.hidden = view.hidden;
    if (view.hidden) return;
    identitySection.querySelector("#welcome-identity-heading")!.textContent = view.heading;
    identitySection.querySelector("#welcome-identity-body")!.textContent = view.body;
    const value = identitySection.querySelector<HTMLElement>("#welcome-identity-value")!;
    // textContent, never innerHTML, and never shortened: §10.1 asks a person to compare this
    // against a device they already trust.
    value.textContent = view.identity;
    value.hidden = view.identity === "";
    const actions = identitySection.querySelector<HTMLElement>("#welcome-identity-actions")!;
    actions.replaceChildren();
    if (view.action !== null) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "danger";
      button.dataset.signOut = "";
      button.dataset.navId = "home:sign-out";
      button.textContent = view.action;
      // **THE SAME CONFIRMATION the header's alert leads to.** Two entry points, one set of words
      // about what signing out does not do.
      button.addEventListener("click", () => dashboard.confirmSignOut(), { signal });
      actions.appendChild(button);
    }
  };

  const identityOf = async (): Promise<IdentitySettingsState> => {
    const loaded = await identity().load();
    if ("kind" in loaded || !loaded.record.root) return { kind: "none" };
    return { kind: "held", rootId: await rootIdCode(loaded.record.root) };
  };

  const paintIdentitySettings = async (): Promise<void> => {
    const state = await identityOf();
    if (!signal.aborted) paintIdentity(state);
  };

  const signOut = async (): Promise<void> => {
    paintIdentity({ kind: "signing-out" });
    const result = await identity().forget();
    if (signal.aborted) return;
    // The list is the surface that changes: with no identity it goes back to offering a passkey.
    tokens = new Map();
    refresh();
    // The stream belonged to the identity that just went away.
    dashboard.restartDeviceWatch();
    if (!result.ok) {
      dashboard.showError("This browser could not delete its identity. It is still signed in.");
    }
  };

  refresh();
  if (opts.error) dashboard.showError(opts.error);
  if (opts.adopt) {
    // Forgotten from the address bar first: a reload must not add the Mac a second time.
    history.replaceState(null, "", location.pathname + location.search);
    dashboard.openAddDevice(opts.adopt, { start: true });
  }
}

/// `root_id` is the hash of the descriptor, and §10.1's identity as a person reads it is
/// `identityCode` of that.
///
/// **NOT HEX.** This is the string somebody holds against another device they trust, and
/// sixty-four characters is a thing people glance at rather than compare (`docs/e2e.md`).
async function rootIdCode (root: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", root as BufferSource));
  return identityCode(digest);
}

/**
 * The live listing: this browser's own chain, asking §12.2's directory.
 *
 * **A browser with no committed chain is `no-identity`, not an error.** It has no root whose rooms
 * it could ask for, and the pairing input is the whole answer — saying "could not load your Macs"
 * there would describe a request that was never worth making.
 *
 * **EXPORTED so `scripts/gate-directory-listing.sh` drives THIS function** rather than a lookalike
 * assembled in the check. A gate that rebuilds the composition it is checking proves only that the
 * check agrees with itself.
 */
export async function liveDevices(): Promise<DeviceListState<DirectorySession>> {
  const identity = new ClientE2EIdentity();
  const directory = await directoryIdentity(identity);
  if (!directory) return { kind: "no-identity" };

  // §12.2 says a device registers the grant it holds, and this is where a browser does it. The
  // listing below would teach the directory the same root anyway — `rememberRoot` runs on any signed
  // request — so this is not what rescues discovery; it makes it deliberate, and it covers a browser
  // that enrolled mid-session and reaches the dashboard later. Guarded by the stored publication
  // status: one round trip once, nothing thereafter, and a failure costs the listing nothing.
  await identity.registerWithDirectory(controlPlaneOrigin());

  const rows = await listDirectorySessions(controlPlaneOrigin(), directory);
  return rows === null ? { kind: "unreachable" } : { kind: "ready", devices: rows };
}

/// This browser's directory credentials, or null with no committed chain. Shared by the poll and
/// the stream so the two can never ask under different identities (`ClientE2EIdentity.directoryIdentity`).
function directoryIdentity (identity = new ClientE2EIdentity()): Promise<DirectoryIdentity | null> {
  return identity.directoryIdentity();
}

/// The live stream, for the browser: `watchDirectory` under this browser's own identity. A browser
/// with none starts nothing — sign-in restarts it.
const productionWatch: NonNullable<DashboardAdapter["watchDevices"]> = (onEvent, watchSignal) => {
  let handle: { ping: () => void } | null = null;
  void (async () => {
    let id: DirectoryIdentity | null = null;
    try { id = await directoryIdentity(); } catch { id = null; }
    if (!id || watchSignal.aborted) return;
    handle = watchDirectory({
      base: controlPlaneOrigin(), identity: id, signal: watchSignal,
      onEvent: (e) => {
        if (e.kind === "sessions") {
          onEvent({ kind: "state", state: { kind: "ready", devices: e.sessions } });
        } else if (e.kind === "down") {
          onEvent({ kind: "down" });
        } else {
          onEvent({ kind: "stopped", retry: e.reason === "unavailable" });
        }
      },
    });
  })();
  return { ping: () => handle?.ping() };
};
