import { installNativeChromeMetrics } from "./native-chrome";
import type { Surface } from "./surface";
import { mountHomeChrome } from "./home-chrome";
import { mountProfileDialog, type ProfileState } from "./profile-dialog";
import { mountSignOutDialog } from "./sign-out-dialog";
import { deviceRow, renderDeviceList, type DeviceListState, type DeviceRowInput } from "./device-list";
import { startDevicePolling, type DevicePollEnv } from "./device-poll";
import { ADD_DEVICE_DIALOG, mountAddDeviceDialog, type AddDevice } from "./add-device";

/**
 * **THE DASHBOARD — one implementation, two surfaces.**
 *
 * The browser client's home page (`#welcome` in `web/index.html`) and the native app's own
 * (`app://ui/`) are the same page: the same header, the same "Your workspace, anywhere", the same
 * quick-connect field, the same My Devices list from §12.2's directory, the same Settings page, the
 * same profile alert. They were two hand-written copies of all of it until 2026-09-14 — two HTML
 * files, two id vocabularies, two renderers — and every shared stylesheet and `motion.js` had to
 * name both. `docs/ui-design.md`.
 *
 * **The BASE is here and the differences are ADDITIONS.** What genuinely differs between a browser
 * and a Mac is never a style choice; it is something one of them cannot do:
 *
 * - where the Macs come from, and what connecting to one does — a browser navigates to
 *   `?code=&token=`, the app opens a native window (`DashboardAdapter`);
 * - what a pasted pairing code does — the browser parses it here, the app hands it to `main`;
 * - how a passkey ceremony runs — `navigator.credentials` in a browser, the platform's own API on a
 *   Mac (`signIn`; one panel, `e2e-setup.ts`), and the Mac's encryption row is an ADDITION to `lead`;
 * - who ADDS a Mac by code — a browser drives the adoption itself, the app asks its host (`addDevice`;
 *   one dialog, `add-device.ts`);
 * - the extras: Share this Mac and the encryption row on a Mac, the identity block in a browser. Each
 *   surface appends its own into the slots this returns.
 *
 * The markup is built here rather than written twice in HTML. That was the last thing left
 * duplicated after the modules were shared, and "still duplicated, deliberately" did not survive
 * contact with the second person to read it.
 */

/**
 * Static markup, no interpolation but of other CONSTANT markup (Add device's dialog) — the one place `innerHTML` is
 * used with a constant.
 *
 * **Every control a wearer can reach carries `data-nav-id` HERE, at its render site** — the glasses
 * D-pad (`homeNavOrder`, `docs/glasses.md`) addresses controls by it and cannot reach one without.
 * The brand link and Slow 10x carry none on purpose: the first duplicates Devices, the second is a
 * `#debug` instrument, and `syncGlassesFocusOrder` takes both out of the browser's focus order there.
 */
const SHELL = `
<header class="ss-header">
  <a class="ss-brand" href="#" data-home><svg class="ss-mark" viewBox="0 0 32 32" fill="none" aria-hidden="true"><path d="M25 7H13L6 14H20L13 21H7M19 25H25" stroke="currentColor" stroke-width="3" stroke-linecap="square" stroke-linejoin="bevel"/></svg><span class="ss-brand-word">Xpromptvs</span></a>
  <nav class="ss-nav" aria-label="Main navigation"><button type="button" data-home data-nav-id="home:devices" aria-current="page">Home</button><button type="button" data-settings data-nav-id="home:settings">Settings</button></nav>
  <div class="ss-header-actions"><button type="button" data-motion-slow hidden aria-pressed="false">Slow 10&times;</button><div class="ss-profile" id="profile" hidden><button id="profile-open" type="button" class="ss-profile-button" data-nav-id="profile" aria-haspopup="dialog" aria-label="Your identity"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="9" r="3.4"/><path d="M5.5 19.6a6.6 6.6 0 0 1 13 0"/></svg></button></div></div>
</header>
<div id="home-devices" class="ss-page-scroll"><div class="ss-content">
  <section id="home-local" class="ss-local-section" hidden aria-labelledby="home-local-heading">
    <div class="ss-local-intro"><h1 id="home-local-heading">This Mac</h1></div>
    <div id="home-this-mac" class="ss-device-list" hidden></div>
  </section>
  <section class="ss-intro"><h1>Your Macs</h1></section>
  <div class="ss-remote-intro"><h2>Remote access</h2></div>
  <div class="ss-remote-group">
  <section id="home-remote-signin" class="ss-remote-signin" hidden aria-labelledby="home-remote-signin-title">
    <h3 id="home-remote-signin-title">Sign in to connect and share</h3>
    <div id="home-remote-signin-slot"></div>
  </section>
  <section id="home-macs-section" class="ss-devices-section" aria-label="Connect to another Mac" hidden>
  <div class="ss-section-heading"><div class="ss-heading-label"><h2>Connect to another Mac</h2><span id="home-refresh"></span></div><div id="home-heading-actions"></div></div>
  <div id="home-macs-list-slot"><div id="home-device-list" class="ss-device-list"></div></div>
  </section>
  <p class="ss-quick-status" data-quick-status hidden></p>
  <p id="home-error" class="ss-error" role="alert" hidden></p>
  <div id="home-lead"></div>
  </div>
</div></div>
<section id="home-settings" class="ss-page-scroll" hidden aria-label="Settings"><div class="ss-content ss-settings">
  <section class="ss-preferences-group"><h2>App behavior</h2>
  <label class="ss-settings-row"><span>Smooth scrolling<small>Move smoothly through terminal history when you scroll.</small></span><input type="checkbox" data-smooth-scroll data-nav-id="home:smooth-scroll"></label>
  </section>
  <div id="home-settings-extra"></div>
</div></section>
<dialog id="profile-dialog" class="ss-dialog ss-profile-dialog" aria-labelledby="profile-dialog-heading"><h2 id="profile-dialog-heading"></h2><p id="profile-dialog-body"></p><code id="profile-dialog-identity" class="ss-profile-identity"></code><div id="profile-dialog-actions" class="ss-dialog-actions"></div></dialog>
${ADD_DEVICE_DIALOG}
<dialog id="sign-out-dialog" class="ss-dialog" aria-labelledby="sign-out-title"><h2 id="sign-out-title"></h2><p id="sign-out-body"></p><div class="ss-dialog-actions"><button type="button" class="danger" data-nav-id="sign-out:confirm" data-sign-out-confirm></button><button type="button" data-nav-id="sign-out:cancel" data-sign-out-cancel></button></div></dialog>
`;

/** What a surface's STREAM reports (`lib/directory-watch.ts` on a browser). */
export type DeviceWatchEvent<T extends DeviceRowInput = DeviceRowInput> =
  | { kind: "state"; state: DeviceListState<T> }
  | { kind: "down" }
  /** `retry` is true only for a `/watch` that never opened: the next `online` or becoming visible
   *  tries again. A REFUSAL (4401/4403/4429) is false and waits for the next page load. */
  | { kind: "stopped"; retry: boolean };

/** What only the surface can answer. Everything else is the same on both. */
export interface DashboardAdapter {
  surface: Surface;
  /** The Macs to offer, and the state to show while finding out. */
  listDevices: (force: boolean) => Promise<DeviceListState>;
  /**
   * **True when the SOURCE cannot say "looking" for itself.** A browser's directory fetch is one
   * round trip with no intermediate state, so the dashboard has to paint `loading` before awaiting
   * or the list sits on an empty — or signed-out — state for the width of a fetch. A Mac's host
   * answers `loading` itself and pushes the answer when it lands, so painting it here would make the
   * list flicker between "Looking for your Macs…" and the rows on every forced refresh.
   *
   * **Never over ROWS.** The list now polls itself (`device-poll.ts`), and a list that turned into
   * "Looking for your Macs…" every fifteen seconds would be one nobody could click on. A person who
   * presses refresh over rows sees the button say so instead.
   */
  paintsLoading?: boolean;
  /**
   * STREAM the listing. Optional: a surface without it polls (the app's host streams on its own
   * side, and pushes what it holds through `applyDevices`). Each `state` goes through exactly the path a poll
   * answer takes; `down`/`stopped` put the poll back on its normal cadence. Returns a `ping` the
   * refresh button sends while the stream is up.
   */
  watchDevices?: (onEvent: (e: DeviceWatchEvent) => void, signal: AbortSignal) => { ping: () => void };
  /** Connect to one. `row` is handed back so the connection animation can light it. */
  connect: (code: string, row: HTMLElement) => void;
  /**
   * **THIS MAC** — the app's own host, reached with no relay (docs/desktop-app.md, "The local window").
   * Only the app has it: only the app can reach its own bridge. `row` is handed back so the connection
   * animation can light it.
   */
  thisMac?: { connect: (row: HTMLElement) => void };
  /** Whatever was pasted into the quick-connect field, verbatim. Each surface parses its own way. */
  quickConnect: (raw: string, button: HTMLElement) => void;
  /**
   * Open a camera and read a QR. **Optional, because only a surface with one has anything to open**
   * — the Mac's own dashboard runs at `app://ui/` and has no reason to scan its own screen.
   */
  scan?: () => void;
  /** The identity this surface holds, for the header's profile button. */
  identity: () => Promise<ProfileState>;
  /** Delete this device's keys. Confirmed already: the alert IS the confirmation. */
  logOut: () => void;
  /**
   * Offered where a passkey ceremony can run: a browser, and the Mac's own dashboard since 2026-10-06
   * (a native ceremony). The app's client window has none — its Mac certifies it.
   */
  signIn?: () => void;
  /**
   * **ADD DEVICE BY CODE** (2026-10-07; `add-device.ts`): run one adoption of the new Mac showing `carrier`. Where
   * a passkey can sign — a browser and the Mac's own dashboard; the app's client window has none. Present, the
   * heading carries "Add device" and its dialog.
   */
  addDevice?: AddDevice;
  /** Read a code with the camera into the Add device field. Only a surface with one. */
  scanCode?: (onCode: (raw: string) => void) => void;
}

export interface Dashboard {
  /** Above the My Devices heading. The app puts Share this Mac and the encryption row here. */
  lead: HTMLElement;
  /** Beside the My Devices heading. Add device is the dashboard's own, where `addDevice` exists. */
  headingActions: HTMLElement;
  /** The top of Settings. The browser's identity block; the app's encryption block. */
  settings: HTMLElement;
  /**
   * Re-read the listing. `force` asks the source to refetch rather than answer from what it knows.
   * The list ALSO refreshes itself on a cadence (`device-poll.ts`); this is for the moments a
   * surface knows something changed. A listing the surface is PUSHED goes through `applyDevices`.
   */
  refreshDevices: (force?: boolean) => Promise<void>;
  /**
   * Paint a listing the surface was TOLD about — the app's pushed state (`rdevApp.subscribe`) —
   * through exactly the path a poll's answer takes: settled, and repainting nothing when unchanged.
   * It BUMPS THE GENERATION, so a forced poll already in flight carries older news and paints nothing.
   */
  applyDevices: (state: DeviceListState) => void;
  /**
   * Stop the current stream and start one for whatever identity the surface holds NOW — after a
   * sign-in or a sign-out. Rows from one identity must never arrive after it is gone.
   */
  restartDeviceWatch: () => void;
  /** Re-read the identity, which paints the profile button. */
  refreshIdentity: () => void;
  /** The one error line, under quick connect. Empty hides it. */
  showError: (text: string) => void;
  /** Devices or Settings. The app calls this to leave its Share view. */
  showPage: (page: "devices" | "settings") => void;
  /**
   * Ask before signing out. **The ONE confirmation**, whichever way a person arrived — the header's
   * profile alert, or Settings' own button in a browser. `adapter.logOut` runs only if they say yes.
   */
  confirmSignOut: () => void;
  /**
   * Open Add device — with `carrier` in its field, started at once when `start` (a Mac's QR, scanned with the
   * phone's camera, lands on `#adopt=`). Nothing on a surface without `addDevice`.
   */
  openAddDevice: (carrier?: string, opts?: { start?: boolean }) => void;
}

export function mountDashboard (opts: {
  /** The element the dashboard is built into. Its contents are REPLACED. */
  host: HTMLElement;
  adapter: DashboardAdapter;
  /** The browser re-mounts after every session; each mount drops the last one's listeners. */
  signal?: AbortSignal;
  /**
   * Run before either page is shown. The app is really THREE views — the two here plus Share this
   * Mac — and picking a nav item has to leave the third. A browser passes nothing.
   */
  beforeShowPage?: () => void;
  /** Timers, visibility and network events for the list's own polling. Injected by tests only. */
  pollEnv?: DevicePollEnv;
}): Dashboard {
  const { host, adapter, signal } = opts;
  const listener = signal ? { signal } : undefined;
  installNativeChromeMetrics(document.documentElement);
  host.dataset.dashboardSurface = adapter.surface;
  host.innerHTML = SHELL;                          // static, no interpolation

  const $ = <T extends HTMLElement>(id: string): T => host.querySelector<T>(`#${id}`)!;
  const error = $("home-error");

  const showError = (text: string): void => {
    error.textContent = text;
    error.hidden = text === "";
  };

  // Devices/Settings and the shared preference controls.
  const showPage = mountHomeChrome({ root: host, signal, beforeShow: opts.beforeShowPage });

  // --- the Macs in this identity ---------------------------------------------------------------
  const paint = renderDeviceList({
    root: $("home-device-list"),
    surface: adapter.surface,
    refreshRoot: $("home-refresh"),
    onConnect: (code, row) => adapter.connect(code, row),
    onRefresh: () => { void pressRefresh(); },
    // `deviceListView` offers this only where `signIn` exists — see its `no-identity` arm.
    onAction: () => adapter.signIn?.(),
  });

  // **THE APP'S OWN HOST, ABOVE THE LISTED MACS, IN EVERY LIST STATE** (docs/desktop-app.md, "The local
  // window"). Drawn ONCE, by the same row builder, and never repainted: no listing — loading, empty,
  // unreachable — hides it, and the connection animation on it survives every repaint of the list below.
  if (adapter.thisMac) {
    const thisMac = adapter.thisMac;
    const holder = $("home-this-mac");
    const row = deviceRow({ label: "Terminal", code: null, state: "Run commands on this Mac.", navId: "device:this-mac",
                            onConnect: (row) => thisMac.connect(row) });
    row.classList.add("ss-local-device");
    const button = row.querySelector<HTMLButtonElement>("button")!;
    button.textContent = "Open terminal";
    button.setAttribute("aria-label", "Open terminal on This Mac");
    row.querySelector(".ss-device-icon")!.innerHTML = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/></svg>';
    holder.append(row);
    holder.hidden = false;
    $("home-local").hidden = false;
  }

  // **A LISTING THAT OUTLIVED ITS MOUNT PAINTS NOTHING**, and a stale one never lands on top of a
  // newer one: the browser re-mounts after every session, and the app is pushed a listing.
  //
  // **AN UNCHANGED ANSWER REPAINTS NOTHING EITHER.** The app is pushed its whole state whenever ANY
  // of it changes, listing included, so an unchanged listing would otherwise rebuild the rows —
  // dropping the row a cursor is over, any focus inside the list, and the
  // connection animation `motion.js` is running on it. Same guard its permission rows carry.
  let generation = 0;
  let painted = "";
  let paintedKind: DeviceListState["kind"] | null = null;

  // **THE LAST ROWS THE DIRECTORY GAVE, kept through a failure.** On a weak network one listing in
  // several fails, and turning a list the person was reaching for into an error each time is worse
  // than keeping the rows with a line saying they may be out of date (`deviceListView`'s `stale`).
  // Forgotten the moment there is no identity: rows from one identity must never outlive it.
  let lastGood: readonly DeviceRowInput[] | null = null;
  const offline = (): boolean => typeof navigator !== "undefined" && navigator.onLine === false;
  const settle = (state: DeviceListState): DeviceListState => {
    switch (state.kind) {
      case "ready": lastGood = state.devices; return state;
      case "no-identity": lastGood = null; return state;
      case "loading": return state;
      case "unreachable":
        return lastGood
          ? { kind: "ready", devices: lastGood, stale: offline() ? "offline" : "unreachable" }
          : { kind: "unreachable", ...(offline() ? { offline: true } : {}) };
    }
  };

  const refreshDevices = async (force = false): Promise<void> => {
    const mine = ++generation;
    // **"Looking for your Macs…" IS A STATE, and something waits on it.** While the listing is out
    // the list has to say so rather than sit on stale rows. `paintsLoading` decides who says it —
    // see the adapter — and the first listing always does, whoever is asking.
    //
    // Dropping this was invisible in every unit test: `dashboard-signin-check` is what caught it,
    // because it waits for this very sentence to go away before clearing storage, and a wait that
    // is instantly true let it clear while the browser was still registering its credential.
    if ((adapter.paintsLoading && paintedKind !== "ready") || painted === "") {
      apply({ kind: "loading" });
    }
    let answer: DeviceListState;
    try {
      answer = await adapter.listDevices(force);
    } catch {
      answer = { kind: "unreachable" };
    }
    if (signal?.aborted || mine !== generation) return;
    apply(answer);
  };

  /** Paint one answer, from a poll or the stream. */
  const apply = (answer: DeviceListState): void => {
    if (answer.kind !== "loading") poller.settled(answer.kind === "unreachable");
    const state = settle(answer);
    // Adding a Mac needs a signed-in device. First run offers one clear setup action.
    if (state.kind !== "loading") {
      const add = host.querySelector<HTMLButtonElement>("#home-add-device");
      if (add) add.hidden = state.kind === "no-identity";
    }
    const hasMacs = state.kind === "ready" && state.devices.length > 0;
    $("home-macs-section").hidden = !hasMacs;
    $("home-remote-signin").hidden = hasMacs;
    const title = $("home-remote-signin-title");
    title.hidden = state.kind !== "no-identity";
    title.textContent = adapter.thisMac ? "Connect and share" : "Sign in to your Macs";
    const slot = $(hasMacs ? "home-macs-list-slot" : "home-remote-signin-slot");
    const list = $("home-device-list");
    if (list.parentElement !== slot) slot.append(list);
    const actions = $("home-heading-actions");
    const actionsSlot = hasMacs ? $("home-macs-section").querySelector<HTMLElement>(".ss-section-heading")! : $("home-remote-signin");
    if (actions.parentElement !== actionsSlot) actionsSlot.append(actions);
    const key = JSON.stringify(state);
    if (key === painted) return;
    painted = key;
    paintedKind = state.kind;
    paint(state);
  };

  /** Paint a listing the surface was TOLD about (the app's pushed state). Same path as a poll. */
  const applyDevices = (answer: DeviceListState): void => {
    if (signal?.aborted) return;
    ++generation;
    apply(answer);
  };

  const poller = startDevicePolling({ poll: () => refreshDevices(true), signal, env: opts.pollEnv });

  // --- the stream -------------------------------------------------------------------------------
  //
  // **A snapshot BUMPS THE GENERATION**, so a poll that was already in flight when it arrived lands
  // on a stale generation and paints nothing — it can only carry older news.
  let watch: { abort: AbortController; ping: () => void } | null = null;
  let retryWatch = false;
  const restartDeviceWatch = (): void => {
    watch?.abort.abort();
    watch = null;
    retryWatch = false;
    poller.setLive(false);
    if (!adapter.watchDevices || signal?.aborted) return;
    const abort = new AbortController();
    signal?.addEventListener("abort", () => abort.abort());
    const handle = adapter.watchDevices((e) => {
      if (abort.signal.aborted || signal?.aborted) return;
      if (e.kind === "state") {
        ++generation;
        poller.setLive(true);
        apply(e.state);
      } else {
        poller.setLive(false);
        if (e.kind === "stopped") retryWatch = e.retry;
      }
    }, abort.signal);
    watch = { abort, ping: handle.ping };
  };
  restartDeviceWatch();

  // **A `/watch` that never opened is tried again when the network or the page comes back** — an
  // old Worker during a deploy, or a network that has just changed. A refusal is not.
  const retryIfGaveUp = (): void => { if (retryWatch) restartDeviceWatch(); };
  addEventListener("online", retryIfGaveUp, listener);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") retryIfGaveUp();
  }, listener);

  /**
   * **THE REFRESH BUTTON SAYS IT DID SOMETHING.** An unchanged answer repaints nothing, which is
   * right for the poll and wrong for a person who just pressed a button and saw no change at all —
   * the whole reason the button was kept is that pressing it should feel like it did something. It
   * reads "refreshing…" for at least `REFRESH_FEEDBACK_MS`, and then runs the same poll the cadence
   * does, restarting the cadence from now.
   */
  const REFRESH_FEEDBACK_MS = 600;
  const pressRefresh = async (): Promise<void> => {
    const button = $("home-refresh").querySelector<HTMLButtonElement>("button");
    if (button) { button.disabled = true; button.textContent = "refreshing…"; button.setAttribute("aria-label", "Refreshing devices"); button.setAttribute("aria-busy", "true"); }
    // While the stream is up a ping makes the server re-filter AND proves the socket is alive.
    watch?.ping();
    await Promise.all([poller.now(), new Promise((r) => setTimeout(r, REFRESH_FEEDBACK_MS))]);
    // A repaint rebuilt the button; if nothing changed, this one is still on screen.
    if (button?.isConnected) { button.disabled = false; button.textContent = "refresh"; button.setAttribute("aria-label", "Refresh devices"); button.removeAttribute("aria-busy"); }
  };

  // --- Add device by code ----------------------------------------------------------------------
  //
  // **A NEW MAC'S CODE HAS ITS OWN PLACE.** It went into Connect, which starts a guest pairing, and the
  // Mac refused it (`gate/noise`, 2026-10-07). Beside the heading, because adding a Mac is about the list.
  let openAddDevice: Dashboard["openAddDevice"] = () => {};
  if (adapter.addDevice) {
    const dialog = mountAddDeviceDialog({
      root: host, addDevice: adapter.addDevice, scan: adapter.scanCode, signIn: adapter.signIn, signal,
      onClosed: (added) => { if (added) void refreshDevices(true); },
    });
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ss-text-action";
    button.id = "home-add-device";
    button.hidden = true;
    button.dataset.navId = "home:add-device";      // the glasses D-pad reaches only `[data-nav-id]`
    button.setAttribute("aria-haspopup", "dialog");
    button.textContent = "Add a Mac";
    button.addEventListener("click", () => dialog.open(), listener);
    $("home-heading-actions").append(button);
    openAddDevice = (carrier, o) => dialog.open(carrier, o);
  }

  // --- signing out, and the one confirmation in front of it --------------------------------------
  //
  // **A SEPARATE ALERT.** The profile alert used to carry the warning and act on its own button,
  // which made it a confirmation that also happened to be an identity card. Signing out deletes
  // keys; it gets the step everything else destructive here gets.
  const confirmSignOut = mountSignOutDialog({
    root: host, surface: adapter.surface, onConfirm: () => adapter.logOut(),
  });

  // --- the header's profile alert ---------------------------------------------------------------
  const paintProfile = mountProfileDialog({
    root: host, surface: adapter.surface, signal,
    onAction: () => confirmSignOut(),
  });
  const refreshIdentity = (): void => {
    void adapter.identity().then((state) => { if (!signal?.aborted) paintProfile(state); });
  };

  return {
    lead: $("home-lead"),
    headingActions: $("home-heading-actions"),
    settings: $("home-settings-extra"),
    refreshDevices, applyDevices, restartDeviceWatch, refreshIdentity, showError, showPage, confirmSignOut,
    openAddDevice: (carrier, o) => openAddDevice(carrier, o),
  };
}
