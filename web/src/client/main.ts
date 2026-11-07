import { pageTransport } from "./page-transport";
import { windowResizeSettle } from "./resize-settle";
// Block native touch selection/callouts without stopping our own long-press menus.
for (const type of ["selectstart", "contextmenu"]) {
  document.addEventListener(type, event => {
    if (matchMedia("(any-pointer: coarse)").matches) event.preventDefault();
  });
}
import { installNativeWindowGrip } from "./native-window-grip";
// THE SESSION'S STYLESHEET FIRST, then the files that build on it — the ONE order, on the dev server and in every
// build. It was a `<link>` in index.html: the dev server put it ahead of these, and a build with more than one input
// (the landing and demo pages) emitted it as its own file linked AFTER them, so its equal-specificity rules won there
// — the phone's tabs 44 px and centred, their tops clipped (2026-10-06). docs/client-web.md, "One stylesheet order".
import "./style.css";
import '../shared/working-tab-title.css';
import "@xterm/xterm/css/xterm.css";
import "./terminal-scrollbar.css";
import "./native-chrome.css";
import "./keyboard-drawer.css";
import "./window-settings.css";
import "./terminal-settings.css";
import "./window-chrome.css";
import { installWindowChrome } from "./window-chrome";
installWindowChrome();
import "./command-palette.css";
import "./agents/agents.css";
import { installNativeChromeMetrics } from "../shared/native-chrome";
import { startTheme, onThemeChange } from "../shared/theme";
import { followNativeSmoothScroll } from "../shared/smooth-scroll-pref";
import { watchLayoutMode, type LayoutMode } from "./layout-mode";
import { installGlassesNav, readHomeNavState, syncGlassesFocusOrder } from "./glasses-nav";
import { homeNavOrder, navOrder } from "./spatial-nav";
import { shellstormMotion } from "./shellstorm-motion";
import { mountWelcome } from "./welcome";

import { mountStandaloneClient } from "./instance/standalone";
import { installKeyboardProbe } from "./keyboard-probe";
import { blockPageZoom, releaseStrandedScroll } from "./viewport-fit";
import { socketTransport } from "./socket-connection";
import { BridgeMessageSocket, type ShellSocketApi } from "../lib/bridge-socket";
import { resumeId } from "../lib/resume-id";

/// PAGE SETUP ONLY. Every session — the browser dashboard's, URL mode's, the app client window's — is
/// a `createSession` call run by ONE controller in this document (`session-lifecycle.ts`,
/// docs/superpowers/specs/2026-09-27-session-without-iframe-design.md). This module finishes evaluating.

/// The page's own options (layout, render, probe, …) as the page LOADED. Every session gets the
/// address bar's query AS IT IS AT ITS CONNECT (`pageParams` below), with its pairing set.
const params = new URLSearchParams(location.search);
installNativeChromeMetrics(document.documentElement);
/**
 * **`#adopt=` IS NOT `#pair=`, and the difference is which way the grant flows.** Both carry the
 * same §9.1 seed. `#pair=` means "a Mac is offering me access", and the browser joins its session
 * with `?code=&token=` beside it. `#adopt=` means "a Mac is asking to join my identity", so this
 * browser answers as the ISSUER and never starts a session at all: the dashboard opens on Add device,
 * started (`shared/add-device.ts`).
 */
const adoptCarrier = new URLSearchParams(location.hash.slice(1)).get("adopt");
const inApp = (window as Window & { __rdevShell?: unknown }).__rdevShell !== undefined;
/// THE APP'S LOCAL WINDOW ("This Mac", `?local=1`, docs/desktop-app.md): a window-less session over the
/// app's bridge socket to its OWN host — no pairing, no relay, no dashboard. Only inside the app, whose
/// shell carries the socket.
const shell = (window as Window & { __rdevShell?: ShellSocketApi & { closeWindow?: () => void } }).__rdevShell;
const localMode = shell !== undefined && params.get("local") === "1";
/// URL MODE: `?code=&token=` in the address bar (a shared link, `app-latency`, the smokes). The session
/// starts at once, with no dashboard; its Disconnect lands on the dashboard with the query stripped.
const urlMode = !!params.get("code") && !!params.get("token");
/// URL mode's return home is owed once, by the session the address bar started.
let returnHomeOnClose = urlMode;

startTheme();   // writes <html data-theme> before anything renders, so the first paint is already themed
// Inside the app, smooth scrolling is the APP's one value, shared with the dashboard and every other
// window; in a browser this does nothing (smooth-scroll-pref.ts). For the life of the page.
followNativeSmoothScroll();
// A Home Screen web app turned back to portrait is left scrolled by the status bar's height, drawn at 0
// and hit-tested at 68 (`viewport-fit.ts`). For the life of the page — the dashboard is hit by it too —
// and BEFORE the session controller, so on that event it runs ahead of every session's `ViewportFit`.
releaseStrandedScroll();
// INSTRUMENT (`?kbprobe=1`): when the soft keyboard moves the visual viewport, read off a real phone (keyboard-probe.ts).
if (params.get("kbprobe") === "1") installKeyboardProbe();
// No page zoom on a touch device — a pinch or a double tap scaled the whole client (`viewport-fit.ts`).
blockPageZoom();

// Keep the page tint synchronized when the shared theme is reapplied.
onThemeChange(() => shellstormMotion()?.retint?.());

/// The session's markup, taken OUT of the document before anything can bind to it and mounted fresh
/// for each connection (`session-dom.ts`).


let layoutMode: LayoutMode = "floating";
let uninstallGlassesNav: (() => void) | null = null;

/**
 * **CREATED BEFORE THE LAYOUT WATCHER AND THE GLASSES NAV, AND IT MUST STAY THERE.** It installs the
 * window-CAPTURE listener that finishes the session slide on the first pointer, key or wheel, and
 * listeners on one target in one phase run in REGISTRATION ORDER: registered after `installGlassesNav`
 * (or a key strip's window-capture handlers) a D-pad key or a tap would be handled against a surface
 * still mid-transform. AGENTS.md: capture-phase handling MUST settle the motion first.
 */
const standalone = mountStandaloneClient(document.getElementById("session")!, {
  transport: code => pageTransport(code) ?? (import.meta.env.DEV ? (window as Window & {__rdevDesignTransport?: typeof pageTransport}).__rdevDesignTransport?.(code) : undefined),
  // READ AT EACH CONNECT, never this module's `params`: URL mode strips its query when its session
  // ends, and a dashboard session afterwards carries none of that page's parameters. Nothing else
  // writes the query, so on the dashboard this is simply the page's own options.
  welcome: document.getElementById("welcome"),
  // URL MODE ONLY: the dashboard is mounted BEFORE the slide, so it is what slides into view…
  onDisconnect: () => { if (returnHomeOnClose) showDashboard(); else if (localMode) shell?.closeWindow?.(); },
  // …and the query goes after it — the one place this page writes its own address.
  onClosed: () => {
    if (!returnHomeOnClose) return;
    returnHomeOnClose = false;
    history.replaceState(null, "", location.pathname + (location.hash === "#debug" ? "#debug" : ""));
  },
  // A FOLLOWED MAC (`host-follow.ts`): an address naming the room it left names the one it shares in now, so a reload
  // reaches it. Only where the address names a room at all — the dashboard never writes its URL.
  onMoved: (room) => {
    const query = new URLSearchParams(location.search);
    if (!query.get("code")) return;
    query.set("code", room.code);
    query.set("token", room.token);
    history.replaceState(null, "", `${location.pathname}?${query}${location.hash}`);
  },
  // A page back from the bfcache whose session could not be rebuilt: the dashboard, SAYING why.
  // A pending attempt's busy button goes back first (`cancel` is a no-op once a session was revealed).
  // In "This Mac" there is no dashboard to land on: the window is the session, so it closes, as Disconnect does.
  onRestartFailed: (reason) => {
    if (localMode) { shell?.closeWindow?.(); return; }
    shellstormMotion()?.cancel?.();
    landOnDashboard(reason);
  },
});

const controller = standalone.controller;
if(inApp)window.__rdevWindowResize = active => standalone.context.resizeSettle.setActive(active);

// Tabbed shell: default to the Sim tab so the source picker is front-and-center on first load. MUST be
// set before watchLayoutMode below — writing data-layout="tabbed" while data-tab is unset makes both the
// terminal and the full-bleed sim render at once (neither per-tab CSS hide rule matches).
document.documentElement.dataset.tab ??= "sim";
watchLayoutMode(params.get("layout"), (mode) => {
  layoutMode = mode;
  standalone.context.presentation.setLayout(mode);
  document.documentElement.dataset.layout = mode;
  // Install on the TRANSITION, not once at startup: watchLayoutMode also fires on resize and
  // orientation change, so a desktop browser resized to 600x600 behaves exactly as the glasses do —
  // which is how this is developed and how the gate drives it.
  uninstallGlassesNav?.();
  uninstallGlassesNav = mode === "glasses" ? installGlassesNav(glassesOrder, () => {
    const welcome=document.getElementById("welcome");
    return controller.current && (!welcome || welcome.classList.contains("hidden")) ? standalone.context.root : document;
  }) : null;
  syncGlassesFocusOrder(mode);
});

/// The D-pad order for what is on screen: the DASHBOARD's controls (`homeNavOrder`) while no session
/// exists or the welcome overlay is up — a PENDING session leaves the dashboard live, because its busy
/// Connect is how a wearer cancels — and the session's own (`navOrder`) once it is revealed.
function glassesOrder(): string[] {
  const welcome = document.getElementById("welcome");
  const current = controller.current;
  if (!current || (welcome !== null && !welcome.classList.contains("hidden"))) return homeNavOrder(readHomeNavState());
  return navOrder(current.navState());
}

document.addEventListener("shellstorm:connection-state", event => {
  const shell = (window as Window & {__rdevShell?: {connectionState?: (state: string, text?: string) => void}}).__rdevShell;
  const detail = (event as CustomEvent<{state: string; text?: string}>).detail;
  const state = detail.state;
  const motion = shellstormMotion();
  // **THE TEXT GOES WITH THE STATE.** `motion.js` paints this same sentence as the session window's
  // phase; the app's dashboard rejects its pending connect with it (`connect-error.ts`). Sending the
  // state alone is what made every failure read "Could not connect. Check the session window for
  // details." on the one surface the person was actually looking at.
  if (state === "connected" && motion) motion.whenReady(() => shell?.connectionState?.(state, detail.text));
  else shell?.connectionState?.(state, detail.text);
});

/// The dashboard, wired to the ONE controller: the browser's home page, the app's client window, and
/// URL mode once its session has ended. `error` is shown on its error line at once.
function showDashboard(error?: string, adopt?: string): void {
  mountWelcome({
    error,
    adopt,
    // The RETURN is load-bearing: `false` (refused, or the session could not be built) is what ends
    // the busy Connect and keeps the reason on the dashboard's error line (`welcome.ts`).
    navigate: (search) => controller.connect(search),
    onCancel: () => controller.cancel(),
    busy: () => controller.busy(),
  });
  syncGlassesFocusOrder(layoutMode);   // the dashboard's brand link exists only now
}

/// A session that failed with nothing left to show — URL mode's own, or a bfcache restart — lands on
/// the dashboard with its reason, never on an empty page. URL mode's query goes with it.
function landOnDashboard(reason: string): void {
  if (returnHomeOnClose) {
    returnHomeOnClose = false;
    history.replaceState(null, "", location.pathname + (location.hash === "#debug" ? "#debug" : ""));
  }
  showDashboard(reason);
}

if (localMode) {
  // A session that could not be built has already SAID why (`connection-state` error), which the app's
  // dashboard shows on its error line; the window has nothing else to show.
  controller.connectTransport(socketTransport({ clientId: resumeId(), sameMac: true, nativeSimulators: true, open: () => new BridgeMessageSocket(shell!) }));
} else if (urlMode) {
  // The seed, if any, rides the fragment (§9.1) and stays in memory; `commitPairing` strips it once spent.
  // A session that could not be BUILT (the controller released it and logged why) has no Disconnect
  // to land on the dashboard with, so it lands there now — never on an empty page.
  // The reason is caught as it is said: it is dispatched before any dashboard exists to show it.
  let reason: string | undefined;
  const noteReason = (e: Event): void => {
    const detail = (e as CustomEvent<{ state: string; text?: string }>).detail;
    if (detail?.state === "error") reason = detail.text;
  };
  document.addEventListener("shellstorm:connection-state", noteReason);
  let started = false;
  try { started = controller.connect(location.search + location.hash); }
  finally { document.removeEventListener("shellstorm:connection-state", noteReason); }
  if (!started) landOnDashboard(reason ?? "Could not start the session.");
} else if (adoptCarrier && !inApp) {
  // **THE HOME PAGE IS WHERE A SCANNED CODE LANDS**, because an adoption URL carries no `code` or
  // `token` — there is no session to join. Its Add device dialog opens on the code, started.
  showDashboard(undefined, adoptCarrier);
} else {
  showDashboard();
}
// **A FRAGMENT ARRIVING LATER IS A NAVIGATION THIS PAGE CANNOT SEE.** Pasting an adoption URL into a
// tab that is already open changes only the hash, which reloads nothing. A reload rather than a second
// mount: one code path opens that dialog on a code, and it is the one above.
if (!inApp) {
  addEventListener("hashchange", () => {
    if (new URLSearchParams(location.hash.slice(1)).get("adopt")) location.reload();
  });
}
