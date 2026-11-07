import {supportedViewSet} from "./product-state";
import {productFeatures} from "../shared/product-features";
import { NativeSourceWindows } from "./native-source/owner";
import { SourceFocusGate } from "./native-source/focus";
import { nativeSourceWindowAPI } from "./native-source/api";
import { nativeMediaHidden } from "./native-source/visibility";
import type { ClientPlatform } from "./instance/platform";
import { createPasteDialogs } from "./paste-dialogs";
import { createReferenceReceipts } from "./av1-reference-receipts";
import { parseReferenceMessage, type ReferenceBinding } from "../shared/av1-reference-wire";
import { fontNames } from "./instance/styles";
import { openClientDialog, closeClientDialog } from "./instance/overlays";
import {createHostUpdateUI, clientRelease} from "./host-update";
/**
 * ONE BROWSER SESSION: everything a connection builds, from its connection (`transport.connect` — a
 * WebRTC peer through the relay, or one message socket; `connection.ts`) to the last listener —
 * created by `createSession`, released by `Session.dispose()`.
 *
 * **This was the body of `main.ts`**, run once per DOCUMENT: the iframe the dashboard made for every
 * connection was the unit of release. It is a closure now, so every per-connection `let` is fresh per
 * call (docs/superpowers/specs/2026-09-27-session-without-iframe-design.md). The body was MOVED, not
 * rewritten, and is deliberately NOT re-indented so `git log --follow` / `git diff --color-moved`
 * keep showing it as the code it was.
 */
import { whenOpen, type ChannelLike } from "../lib/channel";
import {newClaudeSession} from "./agents/new-session";
import { AgentsView } from "./agents/view";
import { decodeJson, encodeJson } from "../lib/codec";
import { bindVideo, frozenElementNeedsRebind, FROZEN_WINDOWS_BEFORE_REBIND } from "./video";
import { AudioPlayback, sourceIdFromAudioStream } from "./audio";
import { parseJitterBufferTargetMs } from "../lib/peer";
import type { Connection, Transport } from "./connection";
import { rtcTransport } from "./rtc-connection";
import { APPLICATION_CAPTURE_ENABLED, SessionControl, controlOpenMessages, parseControlState } from "./session-control";
import { mountTerminalSettings, rendererStatus, savedBackgroundGradient, savedTerminalFontSize, savedTerminalRenderer, saveBackgroundGradient,
         saveTerminalRenderer } from "./terminal-settings";
import { StatusBar } from "./status-bar";
import { windowResizeSettle } from "./resize-settle";
import { SNAPSHOT_SETTLE, SnapshotSettle } from "./snapshot-settle";
import { currentTheme as pageTheme, onThemeChange as onPageThemeChange } from "../shared/theme";
import { onSmoothScrollChange as onPageSmoothScrollChange, setSmoothScroll as setPageSmoothScroll, smoothScrollEnabled as pageSmoothScrollEnabled } from "../shared/smooth-scroll-pref";
import { installDebugHook } from "../lib/debug";
import type { Channels } from "../lib/peer";
import { connectionKind, iceRoundTripMs, type StatusInfo } from "../lib/ice-stats";
import { inboundVideoCodec } from "../lib/inbound-codec";
import { fecBandwidthFraction, formatDiagnostics, inboundVideoDiagnostics,
  type InboundVideoDiagnostics, formatAudioDiagnostics } from "../lib/receiver-stats";
import { presentationCadence, type PaintSample } from "../lib/presentation-cadence";
import { UnlistedStreams, staleStreams, type SyncTrigger } from "../lib/stream-prune";
import { nextPlayoutWindow, playoutRequest, playoutWindowCapable, playoutWindowStart,
         type PlayoutWindowState } from "../lib/playout-floor";
import { arrivalSpread, nextPlayoutFloor, ARRIVAL_WINDOW_MS, PLAYOUT_FLOOR_START,
         type ArrivalSample, type PlayoutFloorState } from "../lib/playout-floor";
import { makeRxBitrateMeter, startLatencyProbe, pollReceiverStats } from "../lib/probe";
import { parsePayloadTypeMap, webCodecsStringFor } from "../lib/webcodecs-caps";
import { RenderFallback } from "../lib/render-fallback";
import { buildTagFrom } from "../lib/build-tag";
import { DcDelivery } from "./dc-delivery";
import type { CompleteFrame } from "../lib/dc-feed";
import { startWebCodecsPacer } from "./webcodecs-pacer";
import { warmDecodeWorkers, takeDecodeWorker, replaceDecodeWorker } from "./decode-worker-pool";
import type { PacedRenderHandle } from "./paced-render";
import { parseAppsState, type AppsState, parseSourceList, parseViewSet, parseSourceStatus, subscribedSources, subscribedPrefs, streamedWindows, DEFAULT_SESSION_VIEW, type Source, type ViewSetMsg, type HostDisplay, type SessionViewMsg, type SimStateWire } from "./source-picker";
import { simActionOf, simMenuItems } from "./sim-menu";
import { parseSourceThumb, type ThumbEntry } from "./source-gallery";
import { WindowManager, windowViews, type WindowManagerOptions } from "./window-manager";
import { type VideoPrefs } from "./video-prefs";
import { termPaletteMessage, type XtermView } from "./xterm-view";
import { installTerminalCopy, installSelectionMirror, writeClipboard } from "./terminal-copy";
import { TouchSelection } from "./touch-selection";
import { OverlayModel, PredictionController, isGhostStale } from "./predictive-echo";
import { recognizePredictionField, type PredictionField } from "./prediction-field";
import { PredictionOverlay } from "./prediction-overlay";
import { terminalFontSize, terminalMayAutofocus, type LayoutMode } from "./layout-mode";
import { syncGlassesFocusOrder, keepTerminalCursorVisible } from "./glasses-nav";
import { screenFromHistory, pushScreen } from "./glasses-history";
import { chooserBackPending, pushScreenEntry, resetChooser } from "./glasses-chooser";
import { mountCompose } from "./glasses-compose";
import { installMobileWindowControls } from "./mobile-window-controls";
import { installTabEdge } from "./tab-edge";
import { mountKeyStrip } from "./key-strip";
import { KeyboardShift } from "./keyboard-shift";
import { HeldMods } from "./held-mods";
import { applyHeldMods, stripKeyBytes, TERMINAL_KEYS, TERMINAL_KEYS_MORE } from "./terminal-keys";
import type { TermKeyDef } from "./terminal-keys";
import { type NavState, type GlassesScreen } from "./spatial-nav";
import { WindowTabs, landedOnTerminal, windowTabViews, windowLabel, winRenameField, type Tab } from "./window-tabs";
import { TabBar } from "./tab-bar";
import { moveTab, PendingTabs, tabBarOrder, tabKind } from "./tab-order";
import { CommandPalette, paletteItemSurface, shouldCloseTab, shouldOpenPalette, shouldReopenTerminal } from "./command-palette";
import {AgentTabs,agentWorking,agentReady} from "./agents/tabs";
import {AgentSearch} from "./agents/search";
import {AgentWorkspace} from "./agents/workspace";
import { InputModality } from "./input-modality";
import { TERMINAL_TAB_LIMIT, TerminalTabs, agentTabs, agentsFinished, parseTermError, parseTermList, tabLabel, termRenameField, autoTabLabel, type TermListMsg } from "./terminal-tabs";
import { termWriter } from "./write-coalescer";
import { TermDeck, measureTerminalGrid } from "./term-deck";
import { cursorViewRow } from "./trailing-blanks";
import { PREVIEW_HANDOVER_MS, TermPreview, parseTermScreen, type Grid, type TermScreen } from "./offer-screen";
import { FileViewer } from "./file-viewer";
import { gpuState, requestGpu } from "./webgpu/device";
import { backgroundGradientEnabled, setBackgroundGradient } from "./webgpu/renderer";
import { attachTermChannel, TermStreamRouter } from "./term-stream";
import { TermOverload, parseTermStreamError } from "./term-overload";
import { LateHistoryLog, swapWouldDisturb } from "./late-history";
import { TermResync } from "./term-resync";
import { pendingAfterTermList, switchReset, tabToShowAfterTermList, type OpenRequest } from "./term-view-policy";
import { OPENING_MS, placeholderKey, predictedShellLabel, resolveOpening, withOpening, type OpeningTab } from "./opening-tab";
import { attachTouchScroll } from "./touch-scroll";
import { ScrollProbe } from "./scroll-probe";
import { parseTmuxList, parseTmuxClosed, parseTmuxError, type TmuxListMsg } from "./tmux";
import { localPasteApi } from "./paste-local";
import { TermClipboardReceiver } from "./term-clipboard";
import { execCommandCopy } from "./terminal-copy";
import { BellChrome, TabBells, hostBellTab, hostBellWindows, parseTermBell, parseWindowBell, type BellShell } from "./term-bell";
import { PasteUI, tabTakesPaste } from "./paste-ui";
import { StatusNote, attachToast, type NoteClock } from "./status-note";
import { PasteUploader, type Delivery } from "./paste-upload";
import { parsePasteReply } from "./paste-wire";
import { clientPrefsWire, loadClientPrefs, type ClientPrefs } from "../shared/client-prefs";
import type { RdevDebug } from "../lib/debug";
import { SessionScope } from "./session-scope";
import { SessionSkeleton } from "./session-skeleton";
import { releaseKeyboardOwner } from "./keys";
import type { ClientContext } from "./instance/context";

export interface SessionOptions {
  context?: ClientContext;
  /** The page's own options plus `code` and `token` — what `main.ts` used to read from `location.search`. */
  params: URLSearchParams;
  code: string;
  token: string;
  /** §9.1's psk when a seed was carried, else null. A PROMISE the handshake awaits: parsing a seed is
   *  HKDF, and it must never race the first welcome. */
  psk: Promise<Uint8Array | null>;
  /** The page's layout, read live — the layout watcher belongs to the page, not to a session. */
  layout: () => LayoutMode;
  /** The controller's generation for this session; the glasses' history entries carry it. */
  generation?: number;
  /** How this session reaches its host. Absent: WebRTC through the relay, from `code`/`token`/`psk`. */
  transport?: Transport;
}

export interface SessionHost {
  /** Every connection state the session reports, with the sentence that goes with it. */
  state(detail: { state: StatusInfo["state"]; text: string }): void;
  /** The session's own Disconnect button. */
  requestClose(): void;
  /** Explicitly rebuild this session in place after terminal overload. */
  requestReconnect?(): void;
  /** The connection followed its Mac to another room (`host-follow.ts`): a restart names that room from now on. */
  moved?(room: { code: string; token: string }): void;
}

export interface Session {
  readonly debug: RdevDebug;
  /** This session's glasses D-pad state (`navOrder`'s input). */
  navState(): NavState;
  /** Say goodbye to the control plane and the host — what `pagehide` does. */
  leave(): void;
  /** Release everything, synchronously. Idempotent. */
  dispose(): void;
  readonly disposed: boolean;
}

// The only piece of the old picker protocol the client still consumes: the host's sim-status message
// feeds the picker's permission/boot note. Narrowed inline here since sim-picker.ts (which used to own
// parseSimStatus) is gone.
type SimStatus = { udid: string; phase: "booting" | "attaching" | "streaming" | "error"; message?: string };
function parseSimStatus(msg: unknown): SimStatus | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as { t?: unknown; udid?: unknown; phase?: unknown; message?: unknown };
  if (m.t !== "sim-status" || typeof m.udid !== "string" || typeof m.phase !== "string") return null;
  if (!["booting", "attaching", "streaming", "error"].includes(m.phase)) return null;
  return { udid: m.udid, phase: m.phase as SimStatus["phase"], message: typeof m.message === "string" ? m.message : undefined };
}

export function createSession(opts: SessionOptions, host: SessionHost): Session {
  // **A SESSION THAT THROWS WHILE BEING BUILT RELEASES WHAT IT BUILT, THEN RETHROWS.** The caller
  // holds no `Session` to dispose — and the connection is established LAST, so a throwing `RTCPeerConnection`
  // (WebRTC disabled or blocked) happened with the socket open, the heartbeat running, the listeners
  // registered and <body> pinned. Under the iframe removing the frame released it all; in one
  // document nothing would. `dispose` is registered the moment the scope exists, and every step of
  // it tolerates a closure that is only partly initialized.
  let release: (() => void) | undefined;
  try {
    return buildSession(opts, host, (dispose) => { release = dispose; });
  } catch (e) {
    try { release?.(); } catch (d) { console.error("[session] releasing a session that failed to build", d); }
    throw e;
  }
}

function buildSession(opts: SessionOptions, host: SessionHost,
                      registerRelease: (dispose: () => void) => void): Session {
const currentTheme = opts.context?.presentation.theme ?? pageTheme;
const onThemeChange = opts.context ? (_fn: (theme: import("../shared/theme").Theme) => void) => () => {} : onPageThemeChange;
const smoothScrollEnabled = opts.context?.smooth.enabled ?? pageSmoothScrollEnabled;
const setSmoothScroll = opts.context?.smooth.set ?? setPageSmoothScroll;
const onSmoothScrollChange = opts.context?.smooth.subscribe ?? onPageSmoothScrollChange;
const resizeSettle = opts.context?.resizeSettle ?? windowResizeSettle;
const dom = opts.context?.root ?? document;
const ui = opts.context?.ui ?? document.documentElement;
const activeElement = () => opts.context ? opts.context.activeElement() : document.activeElement;
const params = opts.params;
const code = opts.code;
const token = opts.token;
const transport = opts.transport ?? rtcTransport({ code, token, psk: opts.psk, params });
/// The glasses screen this session last recorded (`noteGlassesScreen`). Declared first:
/// `showTerminalSurface` can run while the session is still being built.
let currentScreen: GlassesScreen | null = null;
let leaveForNavigation = () => {};
/// Everything this session registers (session-scope.ts). `dispose()` releases it all at once.
const scope = new SessionScope();
const hostUpdateUI = createHostUpdateUI({clientRelease, send: m => sendControl(m), document, container: opts.context?.ui});
scope.defer(() => hostUpdateUI.dispose(), "host-update");
/// A WINDOW-LESS session (docs/client-web.md): its transport carries no media, so it renders the
/// terminal only — no window strip, no window surface, no tiles, no view of its own to state.
const nativeSimulators = transport.presentation === "native-simulators";
const windowless = !transport.carriesMedia && !nativeSimulators;
const nativeShell = opts.context ? opts.context.platform.native : (window as Window & { __rdevShell?: ClientPlatform['native'] }).__rdevShell;
// Remote Mac sources use separate native windows; the query override is a diagnostic escape hatch.
const nativeSourceAPI = !nativeSimulators && !transport.sameMac && transport.carriesMedia && params.get('nativeSources') !== '0'
  ? nativeSourceWindowAPI(nativeShell) : undefined;
let nativeSources: NativeSourceWindows | undefined;
let sourceFocusGate: SourceFocusGate | undefined;
let nativeControlSeen = false;
let nativeMediaIsHidden: boolean | undefined;
const mediaHidden = () => nativeMediaIsHidden ?? document.hidden;
if (nativeSimulators) {
  ui.dataset.nativeSimulators = "";
  nativeShell?.simulatorTheme?.(ui.dataset.theme ?? "dark");
  scope.defer(onThemeChange(t => nativeShell?.simulatorTheme?.(t)), "theme:native-simulators");
  scope.defer(() => { delete ui.dataset.nativeSimulators; }, "native-simulators");
}
if (windowless) {
  ui.dataset.windowless = "";
  scope.defer(() => { delete ui.dataset.windowless; }, "windowless");
}
/// Set by `dispose()` BEFORE any step runs. Declared here, not beside it, because `dispose` is handed
/// out now and may run from a build that threw long before the code below it.
let released = false;
registerRelease(dispose);
scope.defer(() => resetChooser(opts.context?.root), "glasses-chooser");
scope.defer(opts.context ? () => opts.context!.input.release() : releaseKeyboardOwner, "keyboard-owner");

/// Snapshot for the D-pad order. Read fresh on every keypress, so an unsubscribe, a tab switch or a
/// palette open is reflected with no subscription machinery.
///
/// A hoisted `function` that reads `lastViewSet`/`lastSources`/`currentTab`/
/// `lastTermList`, all declared further down this closure. It is reached only through
/// `Session.navState()` — the page's D-pad order, on a keypress — so it never runs before
/// `createSession` has returned and those are initialized. Keep it that way: calling it during the
/// build would hit their temporal dead zone ("Cannot access before initialization").
function glassesNavState(): NavState {
  // TEST-ONLY, same category as `?autosub` and `__rdev.sendControl`: a harness has no host, so
  // `sessionControl` is undefined and every source list is empty — navOrder would answer ["claim"]
  // and a reachability sweep could never see an unreachable island, which is the one thing it exists
  // to catch. Reachable only by explicitly assigning it from the page; nothing in the app sets it.
  const override = (globalThis as { __rdevNavState?: () => NavState }).__rdevNavState;
  if (override) return override();
  return {
    screen: currentTab === "sim" ? "window" : "terminal",
    sources: windowTabViews(lastViewSet, lastSources, currentTab)
      .map((v) => ({ id: v.id, minimized: v.minimized })),
    terminals: lastTermList.tabs.map((t) => ({ id: String(t.id) })),
    tabOrder: barOrder(),
    paletteOpen: !(dom.getElementById("palette")?.classList.contains("hidden") ?? true),
    // Read from the DOM for the same reason as paletteEntries below: WindowManager owns the panel's
    // open state and toggles the class itself, so mirroring it here is a second source of truth that
    // can only drift. A hardcoded `false` would leave the D-pad walking the window behind an open
    // panel — reachable controls the wearer cannot see, which is the trap `paletteOpen` exists for.
    settingsOpen: dom.querySelector(".win-settings.open") !== null,
    active: sessionControl?.isActive ?? false,
    // Read from the DOM rather than mirrored in state: CommandPalette owns its own rendering and
    // re-renders in place as sources and snapshots arrive, so the DOM is the only thing that is
    // never stale. Glue may read the DOM; `navOrder` itself stays pure.
    paletteEntries: [...dom.querySelectorAll<HTMLElement>(
      "#palette-actions [data-nav-id], #palette-grid [data-nav-id]")]
      .map((el) => el.dataset.navId ?? "")
      .filter(Boolean),
    // Read from the DOM for the same reason: the visible buttons ARE the answer (the tmux one hides
    // when the host has no tmux), and an open modal is whatever `<dialog open>` holds.
    termEmpty: dom.getElementById("term-empty")?.classList.contains("hidden") ?? true ? [] :
      [...dom.querySelectorAll<HTMLElement>("#term-empty [data-nav-id]:not(.hidden)")]
        .map((el) => el.dataset.navId ?? "").filter(Boolean),
    dialog: (() => {
      const d = dom.querySelector<HTMLDialogElement>("#tmux-kill-dialog[open], #paste-lines-dialog[open], #paste-folder-dialog[open]");
      return d ? [...d.querySelectorAll<HTMLElement>("[data-nav-id]")].map((el) => el.dataset.navId ?? "").filter(Boolean) : null;
    })(),
  };
}

const $ = <T extends HTMLElement>(id: string) => dom.getElementById(id) as T;
// The session's OWN Disconnect: what it means (a frame closing, the dashboard sliding back) is the host's.
$("session-disconnect").addEventListener("click", () => host.requestClose());
// The markup is FRESH for every session (session-dom.ts), so the glasses' focus rules are re-applied to it.
syncGlassesFocusOrder(opts.layout(), dom);
const stage = $("stage");
// `sim` is the video surface SessionControl (and reconcileSimVisibility) show/hide on active/passive. It is
// now the #windows container — hiding it hides every WindowManager window (fixed-position descendants of a
// display:none ancestor ARE hidden). #sim/#screen/#surfaces are gone; WindowManager is the single renderer.
const sim = $("windows");
const claim = $("claim");

const probeOn = params.get("probe") === "1";

// TESTING RENDERERS (`?render=canvas` | `?render=webcodecs`, plus `?pace=<ms>`). Both are OPT-IN and
// the default `<video>` path is byte-for-byte unchanged.
//
//   canvas     the <video> still decodes; only PRESENTATION moves, keyed off the RTP capture
//              timestamp `requestVideoFrameCallback` hands over.
//   webcodecs  the <video> is bypassed entirely: RTCRtpScriptTransform -> VideoDecoder -> canvas.
//              Sees every frame that arrives rather than only the ones the browser chose to present,
//              at the cost of needing a secure origin and owning keyframe recovery.
//
// WHY IT EXISTS. Frame SELECTION on the plain path already measures ~99.8% correct — every source
// frame shown, in order. What is not perfect is DWELL: on a 120.5Hz panel with a 60fps source, 97.8%
// of frames occupy their correct 2 refreshes and ~2.2% occupy 1, 3 or more. `<video>` inherits that
// from arrival phase; a canvas presents when we say. This is the experiment for whether deciding it
// explicitly is visibly better.
// ---- DataChannel video delivery ----------------------------------------------------------------
//
// An alternative to the RTP receive path, selected per source: the host fragments each access unit
// into symbols with sliding-window repair and sends them on one multiplexed channel, and the frames
// come out here and go to the SAME pacer the RTP path uses.
//
// WHY IT EXISTS, measured: the DataChannel does not win because bytes arrive earlier — that was
// tested against a pinned margin and does NOT convert. It wins because they arrive more REGULARLY,
// and the pacer sizes its hold to the arrival spread, so the jitter buffer shrinks from ~21ms to ~6ms
// and glass-to-glass falls with it (26.0 -> 11.5ms p50 on Chromium).
//
// `canUseDataChannel()` is what keeps a client from asking for a path it cannot decode: `VideoDecoder`
// is [SecureContext], so Chromium exposes none on the plain-http LAN origin an iPad actually uses,
// and such a client silently keeps the RTP path.
const dcDelivery = new DcDelivery();
scope.defer(() => dcDelivery.dispose(), "dc-delivery");

/// OPT-IN (`?dc=1`). THE PRODUCT DEFAULT IS RTP INTO `<video>`, decided 2026-09-02.
///
/// The channel was the default for a day, on the strength of what it had gained for an unhealthy
/// path — retransmission, per-frame integrity, redundancy that follows measured loss, a wait that
/// grows to cover a stall. All of that still stands. What changed is the OTHER path: with the
/// playout-delay ceiling made permissive and the floor sized from measured arrival
/// (`playout-floor.ts`), plain RTP into the browser's own decoder and jitter buffer is smooth on both
/// engines over loopback and over a relay whenever the machine itself is healthy — measured at
/// 59-60fps presented, 1-4 skips a window, dropped=0. It does that with no transform hop, no worker,
/// nothing on the main thread and the browser's own recovery: fewer moving parts than this path, and
/// every one of them the browser's to keep working.
///
/// This path stays as a measurement instrument and a spike. `?dc=1` selects it — and with it the
/// WebCodecs renderer, since the channel has no other consumer — and `gate-dc-delivery.sh` keeps it
/// honest. The capability gate still applies on top of the opt-in.
///
/// STILL NOT AN ENGINE SNIFF. The gate is a capability and a measurement, never a browser name: a
/// detection rule would be wrong the day an engine changes, and it would hide the reason.
const dcRequested = params.get("dc") === "1" && dcDelivery.canUseDataChannel()
  && (params.get("render") ?? "webcodecs") === "webcodecs";

/// LOAD-BEARING — THE DataChannel PATH REQUIRES THE WEBCODECS RENDERER, and choosing them separately
/// is a blank picture. Frames arriving on the channel are handed to the WebCodecs pacer; the plain
/// `<video>` element has no way to receive them, so a client on the channel with the default renderer
/// would route its video away from RTP and into nothing, with every counter reading healthy.
///
/// So the renderer follows the transport unless asked otherwise: `<video>` by default and on RTP,
/// WebCodecs when the channel is selected. `?render=video` beside `?dc=1` turns the channel off again,
/// which is what makes that flag a complete escape hatch rather than half of one.
const renderMode = ((): "video" | "canvas" | "webcodecs" => {
  const r = params.get("render");
  if (r === "canvas" || r === "webcodecs" || r === "video") return r;
  return dcRequested ? "webcodecs" : "video";
})();
const workspaceSupported = APPLICATION_CAPTURE_ENABLED && transport.carriesMedia && !transport.sameMac && !dcRequested && renderMode === "video"
  && /(?:Chrome|Chromium)\//.test(navigator.userAgent) && !matchMedia("(any-pointer: coarse)").matches
  && typeof HTMLVideoElement.prototype.requestVideoFrameCallback === "function";
const referenceSupported = transport.carriesMedia && !transport.sameMac && !dcRequested && renderMode === "video"
  && typeof HTMLVideoElement.prototype.requestVideoFrameCallback === "function";
const referenceBindings = new Map<string, ReferenceBinding>();
const referenceTracks = new Map<string, MediaStreamTrack>();
const referenceTrackIDs = new WeakMap<MediaStreamTrack, string>();
const referenceReceipts = createReferenceReceipts({ now: () => performance.now(), send: message => {
  const binding = referenceBindings.get(message.source);
  sendControl(message.t === "av1-ref-bound" ? { ...message, trackId: binding?.trackId } : { ...message });
} });
scope.defer(() => referenceReceipts.dispose(), "reference-receipts");

/// WHICH VIDEO PATH THIS CLIENT IS ON, in the host's log rather than the device's console.
///
/// The fallback is silent by design — the session works, every counter reads healthy, and nothing
/// says the fast path was declined. That is fine until someone asks why an iPad is on RTP, and the
/// only way to answer is a Safari inspector on a phone, which is exactly the instrument this project
/// has already learned not to depend on: attaching it brings up a USB network link and ICE abandons
/// the path under test.
///
/// REPORTED EITHER WAY, WHICH THE FIRST VERSION OF THIS GOT WRONG. It spoke only when declining, so
/// silence meant "on the channel" OR "running a build without this code" and there was no way to
/// tell — and the answer turned out to be the second. An instrument whose absence is ambiguous is
/// the trap `[bridge] fec:` already documents: zeroes are printed, not omitted.
///
/// The bundle name rides along for the same reason. This project has lost a full session to a phone
/// on the deployed bundle while every local origin served the fix, so the client says which build it
/// is and the comparison against `web/dist/assets` becomes a string match instead of an argument.
function videoPathNote(): string {
  const build = buildTagFrom(import.meta.url);
  if (dcRequested) return `video path: DataChannel (webcodecs, ?dc=1) · build ${build}`;
  if (params.get("dc") === "1") {
    return `video path: RTP — DataChannel asked for and declined: ${dcDeclineReason()} · build ${build}`;
  }
  return `video path: RTP into <video> (the default; ?dc=1 opts into the channel) · build ${build}`;
}

function dcDeclineReason(): string {
  const capabilities = dcDelivery.stats().capabilities as
    { hasVideoDecoder?: boolean; isSecureContext?: boolean } | undefined;
  const render = params.get("render");
  if (render !== null && render !== "webcodecs") return `renderer pinned to ${render}`;
  if (capabilities?.isSecureContext === false) {
    // `VideoDecoder` is [SecureContext] per the WebCodecs spec, which is how a plain-http LAN origin
    // reaches this branch — the case an iPad on the LAN actually hits.
    return "insecure origin — WebCodecs needs a secure context";
  }
  if (capabilities?.hasVideoDecoder === false) return "no WebCodecs VideoDecoder in this browser";
  return "capability gate declined";
}

/// Sources the host has REFUSED the channel for, so the next subscribe stops asking.
///
/// Without this a refusal is unrecoverable rather than merely disappointing: the pacer is built for
/// the feed this client asked for, so one built for the channel installs no encoded transform, and if
/// the host is meanwhile packetising the source as RTP the pacer receives nothing at all. Its stall
/// detector then resubscribes — asking for the channel again, and rebuilding the same starved pacer.
/// Recording the refusal is what turns that loop into a single downgrade.
/// Sources whose WebCodecs path has failed for good and now render through the <video> element.
/// Consulted everywhere the fast path would otherwise be (re-)entered, so a fallback survives the
/// resubscribe that follows it.
const renderFallback = new RenderFallback();

const deliveryRefused = new Set<string>();

/// When this client last told the host which delivery it wants, per source. A source it merely
/// INHERITED — subscribed by a previous client and still inside the host's grace window — is not in
/// here, and a refusal cannot be concluded from one.
const deliveryAsserted = new Map<string, number>();

/// `<source>:<activeDelivery>` pairs already reported to the host — not bare sources. A source
/// passes through at most a few states, so this stays to a handful of lines while still showing the
/// move from unresolved to settled, which is the part that matters and the part a once-per-source
/// version silently threw away.
const deliveryReported = new Set<string>();

/// How long the host has to answer an assertion before silence counts as a refusal.
///
/// TIME, NOT A COUNT OF REPLIES — counting cannot work here. `view-set` is broadcast on every state
/// change, so several can already be in flight when the client asserts, and each of them still says
/// `rtp` because they predate the request. Treating the second one as the answer declared a refusal
/// while the host log read `delivery re-routed to dc` and the channel was carrying 4.9MB of video the
/// client had stopped listening for.
const DELIVERY_REFUSAL_GRACE_MS = 5000;

/// The delivery to ask for on `subscribe`. A request the host refuses costs nothing — the track is
/// negotiated either way — so this asks whenever the client could decode it AND the host has not
/// already said no for this source.
function requestedDelivery(source?: string): "dc" | "rtp" {
  if (!dcRequested) return "rtp";
  return source !== undefined && deliveryRefused.has(source) ? "rtp" : "dc";
}

// Frames go to the SAME pacer the RTP path feeds, which is the point: the two transports differ in
// nothing downstream of here, so a comparison between them means something.
dcDelivery.onFrames((source: string, frame: CompleteFrame) => {
  webcodecsPacers.get(source)?.pushEncoded?.(frame.data, frame.rtp, frame.key, frame.payloadType);
});
// The channel died. Re-subscribing over RTP is the whole fallback: the track never went away, so the
// host only has to re-route it — no renegotiation, no new SSRC, no keyframe storm.
// A LOST FRAME ON THIS PATH NEEDS AN IDR, and the host is the only thing that can supply one. Its
// own debounce (one per source per 500ms) is what keeps a burst of these from becoming a keyframe
// storm, so asking on every gap is safe.
dcDelivery.onMainLate(() => takeMainThreadLateMs());
dcDelivery.onTransport(() => lastTransport);
dcDelivery.onKeyframeNeeded((source: string) => {
  console.warn(`[dc] gap in ${source} — asking for a keyframe`);
  sendControl({ t: "request-keyframe", source });
});
dcDelivery.onFallback((reason: string) => {
  console.warn(`[dc] falling back to RTP: ${reason}`);
  for (const source of streamedWindows(lastViewSet)) sendControl({ t: "subscribe", source, delivery: "rtp" });
});
// A margin is UNCONDITIONAL added latency, so the default is one frame at 60fps and no more. 0 means
// "present as soon as it arrives", which is closest to today's behaviour and is the control arm.
// AUTO BY DEFAULT. A fixed hold is only right for the jitter it was chosen against: 16ms covered
// loopback (~8ms of jitter) and measured 99.8% correct dwell, and did nothing on a real link whose
// jitter exceeds it — there the pacer holds nothing useful and degenerates into "show whatever is
// newest", which is the unpaced behaviour it exists to replace. `Auto` sizes the hold to the jitter
// actually present, which is the smallest one that keeps the schedule intact.
// `?cadence=0` disables the cadence lock, so it can be A/B'd against the free-running pacer on a real
// link. Without it the two arms are indistinguishable and any comparison is run-to-run noise — which
// is exactly what a first attempt at this measurement produced.
const cadenceLock = params.get("cadence") !== "0";

// `?refbar=1` draws a locally-animated bar with the same 3s sweep as the host's motion overlay. It
// shares NOTHING with the video path, so if both judder together the cause is the browser, the
// display or the machine — and no amount of pacing work would help. See reference-bar.ts.
if (params.get("refbar") === "1") {
  void import("./reference-bar").then(scope.guard((m) => scope.defer(m.installReferenceBar(opts.context?.ui), "refbar")));
}
const paceMarginMs: number | "auto" = (() => {
  const raw = params.get("pace");
  if (raw === null || raw === "auto") return "auto";
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 && n <= 500 ? n : "auto";
})();
// `?jbuf=<ms>` overrides the receiver jitter-buffer target. rdev ships 0 — which Chrome ignores and
// clamps to ~16-18ms, so the setting has never been in force on the browser rdev is developed
// against, while a real iPad honours it at 1.0ms against 4-19ms of jitter. This is the knob for
// testing whether that is why such a receiver requests a keyframe a second.
const jitterBufferTargetMs = parseJitterBufferTargetMs(params.get("jbuf"));
// TEST-ONLY hook: `?autosub=<sourceId>` subscribes exactly that source once this client is active — e.g.
// `?autosub=win:12345`. NOT a production feature: interactive clients start EMPTY and pick their own
// sources from the gallery; this exists so a Playwright harness can bring up a KNOWN source without
// driving the picker. The value is used verbatim (no source-list lookup), so it is immune to
// list-arrival timing. Absent → no auto-subscribe at all.
const autoSub = params.get("autosub");

/// How this session reaches its host (`connection.ts`). Assigned LAST — where the first peer used to be
/// built — so it is undefined while the session is being built: read it through `?.` everywhere.
let connection: Connection | undefined;
let channels: Partial<Channels> = {};
let rxMeter = makeRxBitrateMeter();   // incoming video bitrate; reset per pc (rebuild) so a byte-counter reset doesn't spike
// The debug hook reads the connection through a getter so window.__rdev always reflects the CURRENT pc after a rebuild.
const dbg = installDebugHook({ role: "client", pc: { get connectionState() { return connection?.connectionState ?? "new"; } }, getChannels: () => channels,
                               publish: false });   // the page publishes a getter (session-lifecycle.ts)
// Reads the LIVE `connection` binding rather than capturing one, so it keeps working across a rebuild.
dbg.rxStats = () => connection?.media ? connection.media.getStats().then(inboundVideoDiagnostics) : Promise.resolve([]);
// The receiver's own inbound-AUDIO counters. A FUNCTION for the reason `rxStats` is one — it costs
// nothing until asked — and available ALWAYS rather than behind a flag, because an instrument you
// have to opt into is not there when you need it.
//
// `energy` IS THE FIELD THAT MATTERS: every other counter is satisfied by a perfectly delivered
// stream of zeroes, and totalAudioEnergy is computed from the DECODED samples.
dbg.audioStats = () => {
  const media = connection?.media;
  if (!media) return Promise.resolve({ packets: null as number | null, energy: 0, samples: 0, concealed: 0 });
  return media.getStats().then((report) => {
    let packets: number | null = null, energy = 0, samples = 0, concealed = 0;
    report.forEach((raw) => {
      const s = raw as Record<string, unknown> & { type?: string; kind?: string };
      if (s.type !== "inbound-rtp" || s.kind !== "audio") return;
      packets = (packets ?? 0) + (typeof s.packetsReceived === "number" ? s.packetsReceived : 0);
      if (typeof s.totalAudioEnergy === "number") energy += s.totalAudioEnergy;
      if (typeof s.totalSamplesReceived === "number") samples += s.totalSamplesReceived;
      if (typeof s.concealedSamples === "number") concealed += s.concealedSamples;
    });
    return { packets, energy, samples, concealed };
  });
};
dbg.dcDelivery = () => dcDelivery.stats();
dbg.renderFallback = () => renderFallback.entries();
(dbg as unknown as { build: string }).build = "predict-overlay-2026-10-01";   // bump on predictor changes → confirms which code a tab is running
(dbg as unknown as { rebuilds: number }).rebuilds = 0;                         // PC rebuild count (recovery observability)
let sessionControl: SessionControl | undefined;
let agentsView: AgentWorkspace | undefined;
let agentTabStrip: AgentTabs | undefined;
function renderAgentTabs():void {
  agentTabStrip?.update(lastViewSet.agents??[],agentsView?.selectedTab??null,sessionControl?.isActive??false);
}
function agentAction(op:"select-tab"|"close-tab",id:string):void {
  void agentsView?.tabAction(op,id).catch(error=>agentsView?.reportError(error));
}

leaveForNavigation = () => {
  // The strip's held modifiers first, while the channels still carry the release.
  try { windowManager?.releaseTouchMods(); } catch (e) { console.error("[session] leave: modifier release failed", e); }
  try { connection?.leave(); } catch (e) { console.error("[session] leave: the connection's goodbye failed", e); }
  try { audioPlayback.detachAll(); } catch (e) { console.error("[session] leave: audio detach failed", e); }
  try { probeStop?.(); } catch (e) { console.error("[session] leave: probe stop failed", e); }
};
// `pagehide` and a bfcache `pageshow` belong to the PAGE (session-lifecycle.ts): the goodbye is
// `Session.leave()`, and a page restored from the cache restarts its session in place.

// THE ON-SCREEN STRIP'S MODIFIERS ARE MIRRORED ON THE HOST, so they must be released wherever
// `win-keys-release` is sent. Arming one sends a bare-modifier `win-key`, which writes the host's
// `currentFlags` — and touch/hover stamp that holder onto every mouse event. Left set, a locked ⌘
// turns every later tap into a ⌘-click with nothing on screen to explain it.
//
// The same three transitions `keys.ts` uses, for the same reason: after any of them the browser
// stops delivering key events, so nothing else would ever clear the latch. The third, `pagehide`, is
// the PAGE's and reaches here as `leave()` (above), which releases them BEFORE the channels close —
// a listener of the session's own ran after the page's goodbye had already closed them.
scope.listen(window, "blur", () => windowManager?.releaseTouchMods());
scope.listen(document, "visibilitychange", () => {
  if (document.hidden && !nativeSourceAPI) windowManager?.releaseTouchMods();
});

// Tell the host when this tab is backgrounded, so it can stop sending and drop its sources to 1 fps
// rather than encoding for a page nobody is looking at.
//
// Sent IMMEDIATELY, with no client-side debounce — deliberately. On iOS the page is often suspended
// moments after this fires, so a timer here may never run, on exactly the platform where the win is
// biggest. The host holds the pause for 1000ms and cancels it if the tab comes straight back.
scope.listen(document, "visibilitychange", () => {
  // A WINDOW-LESS session has no media to pause: the host refuses its `set-visibility` (WindowlessPolicy)
  // and would only log each one. Its TERMINAL's pause below still goes.
  if (transport.carriesMedia) sendControl({ t: "set-visibility", hidden: mediaHidden() });
  // The TERMINAL's pause, sent at once for the same iOS reason: the host holds it 1 s, cancels it if
  // the page comes straight back, and re-serializes every tab on a resume after it applied. It can be
  // LOST — a phone's control channel is often dead by the time the page returns — so every control
  // (re)open states it again (`negotiateRaw`).
  sendControl({ t: document.hidden ? "terminal-pause" : "terminal-resume" });
  if (!document.hidden) termPageVisible?.();
});
// Per-source snapshots for the palette grid. ONE-SHOT: cleared on every palette open (and on its ↻), then
// refilled by the `source-thumb` replies. There is no background polling — see "Snapshot source gallery".
const thumbs = new Map<string, ThumbEntry>();
// The forced recovery percentage to RESTORE on reconnect, in basis points; null means Auto. A peer
// rebuild builds a NEW connection, and the override is per-connection host state, so without this a
// network blip silently discards a deliberate setting while every window survives it.
let intendedRecoveryBp: number | null = null;
let intendedPlayoutDelayMs: number | null = 20;
/// This DEVICE's preferences (`shared/client-prefs.ts`), read at connect and stated in every
/// `client-hello`. The settings panel changes them (`WindowManager`'s `onDevicePrefs`).
let clientPrefs: ClientPrefs = loadClientPrefs(opts.context?.storage);
/// Arrival diagnostics retain the adaptive estimator; the product uses a fixed 20/100 ms floor.
let playoutFloor: PlayoutFloorState = PLAYOUT_FLOOR_START;
/// The fixed-window decision beside the floor — see `playout-floor.ts`, "THE WINDOW". Only a
/// Chromium-family engine is ever asked for one; `?pd=window` forces it and `?pd=floor` forbids it,
/// for measurement.
const playoutWindowMode = params.get("pd");
const windowCapable = playoutWindowMode === "floor" ? false
  : playoutWindowMode === "window" ? true : playoutWindowCapable(navigator.userAgent);
/// The window this path settled on last time, per pairing code — the starting size is what decides
/// the compositor regime (`playoutWindowStart`). `?pdstart=<ms>` overrides it, for measurement.
/// localStorage is a per-viewer convenience here: absent or garbage means "start at the smallest".
const playoutWindowPriorKey = `rdev.playoutWindow.${params.get("code") ?? ""}`;
function readPlayoutWindowPrior(): number | null {
  const forced = Number(params.get("pdstart"));
  if (params.get("pdstart") !== null && Number.isFinite(forced)) return forced;
  try { const raw = (opts.context?.storage ?? localStorage).getItem(playoutWindowPriorKey); return raw === null ? null : Number(raw); }
  catch { return null; }
}
function rememberPlayoutWindow(state: PlayoutWindowState): void {
  try {
    if (state.active) (opts.context?.storage ?? localStorage).setItem(playoutWindowPriorKey, String(state.sizeMs));
    else (opts.context?.storage ?? localStorage).removeItem(playoutWindowPriorKey);
  } catch { /* storage unavailable: the next session starts at the smallest window */ }
}
let playoutWindow: PlayoutWindowState = playoutWindowStart(windowCapable, readPlayoutWindowPrior());
/// The last request actually sent, so the tick sends only on change — the host re-broadcasts
/// `view-set` to every client on each set. The starting window is sent by `controlOpenMessages`,
/// before the first subscribe, so it counts as sent.
let lastPlayoutRequest: { minMs: number; maxMs: number | null } | null =
  playoutWindow.active ? { minMs: playoutWindow.sizeMs, maxMs: playoutWindow.sizeMs } : null;
let everPassive = false;                      // has this client ever been passive? TEST-ONLY `?autosub`
                                              // never fires for one: claiming a session is not a fresh host.
/// The TEST-ONLY `?autosub` fires once per session, at most.
let autoSubDone = false;
let probeStart: (() => void) | undefined;
let probeStop: (() => void) | undefined;
let windowManager: WindowManager | undefined;
scope.defer(installMobileWindowControls($("windows"), $("statusbar"), () => windowManager?.togglePointerMode()), "mobile-window-controls");
scope.defer(() => probeStop?.(), "latency-probe");
scope.defer(() => windowManager?.clear(), "window-manager");
let terminalTabs: TerminalTabs | undefined;
let lastTermList: TermListMsg = { tabs: [], activeId: null };
// THE BELL (term-bell.ts; docs/terminal.md, "The bell"): a tab that rang while nobody was looking at it —
// a terminal's BEL, or a window whose application raised its Dock badge on the host — is marked on its tab,
// in the page's title and favicon, and — in the app — on the Dock, until it is looked at.
/// The tabs the person is LOOKING AT: the deck's shown tab on a terminal surface that is on screen (not
/// behind a phone's window surface, not under a full-screen window), and the session's focused window on a
/// windows surface that is on screen (a full-screen window is the only one then) — in a visible, focused
/// page of the driver — or none.
function bellLooking(): ReadonlySet<string> {
  const out = new Set<string>();
  if (!sessionControl?.isActive || document.visibilityState !== "visible" || !document.hasFocus()) return out;
  if(agentsView?.selectedTab){out.add(`agent:${agentsView.selectedTab}`);return out;}
  if (ui.hasAttribute("data-fullscreen")) {
    const fs = windowManager?.fullscreenSource() ?? null;
    if (fs !== null) out.add(fs);
    return out;
  }
  if (terminalSurfaceShown()) {
    const t = termDeck?.visibleId() ?? null;
    if (t !== null) out.add(t);
  }
  const focused = windowless ? null : lastViewSet.focused;
  if (focused !== null && windowsSurfaceShown()) out.add(focused);
  return out;
}
/// The window strip's half of `changed`: a no-op until the strip exists (it is built further down).
let markWindowBells: () => void = () => {};
const bellChrome = opts.context ? { show: (count: number) => opts.context!.platform.bell?.(count), restore: () => opts.context!.platform.bell?.(0) } : new BellChrome(document, (window as Window & { __rdevShell?: BellShell }).__rdevShell);
const bells = new TabBells({
  looking: bellLooking,
  changed: () => { terminalTabs?.markBells(); markWindowBells(); renderAgentTabs(); bellChrome.show(bells.count); },
});
dbg.termBells = () => bells.tabs;
// What can change what the person looks at, beyond a tab switch (`onVisibleChange`): the page coming back
// or into focus, and the surface — `data-tab`, `data-fullscreen` and `data-layout` on the root.
scope.listen(window, "focus", () => bells.look());
scope.listen(document, "visibilitychange", () => bells.look());
{
  const surface = new MutationObserver((changes) => {
    bells.look();
    if (changes.some(change => change.attributeName === "data-layout")) renderWindowTabs();
  });
  surface.observe(ui, { attributes: true, attributeFilter: ["data-tab", "data-fullscreen", "data-layout"] });
  scope.defer(() => surface.disconnect(), "bell:surface");
}
// The page's own title and favicon back, and a zero for the app, when the session ends.
scope.defer(() => bellChrome.restore(), "bell:chrome");
/// The tmux sessions open as tabs — the HOST's session state (`term-list`), whoever opened them. Read
/// by the palette's "open here" marker.
const openTmuxSessions = (): ReadonlySet<string> =>
  new Set(lastTermList.tabs.filter((t) => t.id.startsWith("tmux:")).map((t) => t.id.slice(5)));
/// The host's tmux sessions, from the last `tmux-list`; null until it has answered.
let lastTmuxList: TmuxListMsg | null = null;
// THE TERMINAL THE DRIVER JUST PICKED, SHOWN AT ONCE (opening-tab.ts): in the strip, selected, and on the deck,
// in the tick the palette closes — until the host's `term-list` names it, a refusal, or `OPENING_MS`.
let opening: OpeningTab | null = null;
let openingSeq = 0;
let openingTimer: ReturnType<typeof setTimeout> | undefined;
// ON THIS MAC, OPENING AN EXISTING TMUX SESSION IS SYNCHRONOUS (2026-10-04, asked for: "opening terminals should be
// synchronous (within a limit — tmux may hang)"; `openTerminal`). The host is in this process (`transport.sameMac`),
// so attaching a session from the palette's Open terminals list is WAITED FOR — the host's `term-list` naming the
// tab, then its first content (`TermDeck.whenContent`) — for at most `OPEN_SYNC_MS`, with the palette up and the
// strip, the deck and the empty state as they were; then the palette closes onto the finished tab in ONE tick.
// Past the limit (tmux hanging) the tab shows as it is: the host's if it is named, else the optimistic one
// (`startOpening`). NEW terminals are NOT waited for, here or anywhere (reported the same day: a shell's start or a
// new tmux session takes time, and the palette sat over it) — and neither is ⌘⇧T, which starts a shell again.
const OPEN_SYNC_MS = 750;
interface SyncOpen {
  opening: OpeningTab;
  /// The host's tab, once its `term-list` names it — kept off the strip until it lands (`shownTermList`).
  tab: string | null;
  cancelWait(): void;
  /// Land: show the tab (or, unnamed, the placeholder) and let the palette close.
  finish(): void;
  /// Refused: show nothing (the refusal's note says why) and let the palette close.
  fail(): void;
}
let syncOpen: SyncOpen | null = null;
/// The session of the active terminal tab when it is a tmux tab.
const activeTmuxSession = (): string | null =>
  lastTermList.activeId?.startsWith("tmux:") ? lastTermList.activeId.slice(5) : null;
/// The session's TOASTS (status-note.ts): a message goes after 6 s, held while a mouse is on it; a state stays
/// while it is true; a tap takes either away, and every exit is animated.
const noteClock: NoteClock = {
  setTimer: (fn, ms) => scope.timeout(fn, ms),
  clearTimer: (t) => scope.clearTimeout(t as ReturnType<typeof setTimeout> | undefined),
  now: () => performance.now(),
};
/// `#sim-status-note`: tmux errors, a source's boot phase, a paste's progress and its outcome, the flashes.
const statusNote = new StatusNote(() => $("sim-status-note"), noteClock);
/// `#term-stream-note`: the terminal stream's standing "not updating" — ITS OWN toast, which a message must
/// neither overwrite nor be cleared by.
let termOutputBlocked = false;
const streamNote = new StatusNote(() => $("term-stream-note"), noteClock);
attachToast($("sim-status-note"), statusNote, scope.signal);
attachToast($("term-stream-note"), {
  hold: (on) => streamNote.hold(on), dismiss: () => { if (!termOutputBlocked) streamNote.dismiss(); },
}, scope.signal);
/// The notes last written by a source's boot phase and by the terminal's give-up, so their clears never
/// take away a note written since.
let simPhaseMark = 0;
let termStuckMark = 0;
/// A message in a toast: it goes after 6 s, unless something else wrote there since.
function flashStatusNote(text: string): void {
  statusNote.flash(text);
}
function tmuxErrorText(reason: string): string {
  switch (reason) {
    case "unavailable": return "tmux is not installed on the Mac";
    case "session-gone": return "That tmux session no longer exists";
    case "too-many-tabs": return `Close a tab first — ${TERMINAL_TAB_LIMIT} is the limit`;
    case "snapshot-failed": return "Could not read that tmux session — its tab was closed";
    case "rename-failed": return "tmux could not rename that session — is the name taken?";
    default: return `tmux: ${reason}`;
  }
}
/// The driver with NO terminal tabs sees the ways to get one. Nothing opens a shell implicitly since
/// 2026-09-25, so this is a real state; a passive client sees the claim overlay instead.
/// On becoming the driver: learn what tmux can offer. The tmux TABS need nothing — they are the host's
/// session state and survive a change of driver (docs/terminal.md).
function learnTmux(): void {
  sendControl({ t: "list-tmux" });
}
/// Killing ends every program in the session, so it is confirmed — in a modal, which sits in the top
/// layer and needs no z-index. Closing the tab instead keeps the session, and the dialog says so.
/// `session`: the palette's is the shown tab's; a tmux TAB's menu ("Terminate Tmux Session", 2026-10-04) names its
/// own, which need not be on screen — so the dialog names the session it ends.
function openKillTmuxDialog(session: string | null = activeTmuxSession()): void {
  if (!session) return;
  const d = $<HTMLDialogElement>("tmux-kill-dialog");
  const name = lastTmuxList?.sessions.find((x) => x.id === session)?.name
    ?? lastTermList.tabs.find((t) => t.id === `tmux:${session}`)?.title ?? session;
  d.querySelector("h2")!.textContent = `Kill tmux session “${name}”?`;
  $("tmux-kill-confirm").onclick = () => { closeClientDialog(d); sendControl({ t: "kill-tmux", session }); };
  $("tmux-kill-cancel").onclick = () => closeClientDialog(d);
  openClientDialog(d);
}
/// The open paste question's ANSWER (`askPasteQuestion`) — which closes its dialog as it answers — null with none
/// up. The answer, never the bare `resolve`: a question replaced by the OTHER paste dialog's was answered and left
/// on screen, its buttons dead, until 2026-10-02 (the folder question's final review).
const { confirm: askPasteQuestion, chooseFolder: askFolderChoice } = createPasteDialogs({ get: $, scope });
/// A driver with NO subscribed source lands on the terminal surface. On the tabbed layout the window
/// surface is otherwise the default, and with nothing on it the screen is blank — and since shells are
/// no longer created at connect, there is not even a terminal tab to tap. The terminal surface is
/// where `#term-empty` offers the way in. A source subscribed later still takes focus as it always has.
/// Whether the terminal surface is what the user is looking at: always off the pinned layouts (the
/// floating windows sit over it), and on them only while `data-tab` is the terminal. The pinned
/// layouts are ENUMERATED, as everywhere else.
function terminalSurfaceShown(): boolean {
  if (agentsView?.visible) return false;
  const layout = ui.dataset.layout;
  const pinned = layout === "tabbed" || layout === "glasses";
  return !pinned || ui.dataset.tab === "terminal";
}
/// The windows surface is on screen: always on the floating layout, on a pinned one when it is the tab shown.
function windowsSurfaceShown(): boolean {
  const layout = ui.dataset.layout;
  const pinned = layout === "tabbed" || layout === "glasses";
  return !pinned || ui.dataset.tab === "sim";
}
function landOnTerminalIfNothingElse(): void {
  if (streamedWindows(lastViewSet).length === 0 && currentTab !== "terminal") showTerminalSurface();
}
/// The host's first `term-list` has arrived. Until it has, the page has not heard what the session holds, and the
/// empty state — which says it holds nothing — waits for it: the host says this client drives a moment before the
/// list, and in between "A fresh workspace" flashed on every connect. Until it has, the terminal area stays plain.
let termListed = false;
/// **THE SESSION LOADS UNDER A SKELETON** (session-skeleton.ts) — in its tab bar, until the host's first list.
const skeleton = new SessionSkeleton($("tab-skeleton"));
function renderTermEmpty(): void {
  $("term-empty").classList.toggle("hidden", !(termListed && sessionControl?.isActive && shownTermList().tabs.length === 0 && !opening));
}
/// **THE TAB BAR BEFORE ANY CHANNEL OPENS** (2026-10-05, asked for; docs/sources-and-focus.md, "The offer carries the
/// tab bar"): the host's first offer carries the messages a control open starts with — whether this client drives,
/// the `term-list`, the session's windows and their listed names — and the BAR is drawn from them while WebRTC still
/// connects. The strips only, and INERT (nothing they send has a channel yet): no window, no terminal instance, no
/// surface, no bell, no empty state. Each strip goes back to the host's own copy when that lands on `control` — the
/// terminal half at the first `term-list`, the window half at the first `view-set`; the names stay a fallback under
/// the host's own listing.
let early: { termList: TermListMsg; viewSet: ViewSetMsg | null; sources: Source[] } | null = null;
function onEarlyState(messages: unknown[]): void {
  if (scope.disposed || termListed) return;   // the host's own list is here: nothing to stand in for
  let active = false, termList: TermListMsg | null = null, viewSet: ViewSetMsg | null = null, sources: Source[] = [];
  let screen: TermScreen | null = null;
  for (const m of messages) {
    if (typeof m !== "object" || m === null) continue;
    const cs = parseControlState(m);
    if (cs) { active = cs.active; continue; }
    termList = parseTermList(m) ?? termList;
    viewSet = parseViewSet(m) ?? viewSet;
    sources = parseSourceList(m)?.sources ?? sources;
    screen = parseTermScreen(m) ?? screen;
  }
  if (!termList) return;
  // A window-less session takes no window from a view set (its `view-set` arm says why); none comes over an offer.
  early = { termList, viewSet: windowless || everReceivedViewSet ? null : viewSet, sources };
  dbg.earlyState = early;
  skeleton.listed();
  // Whether this client drives is the offer's word until `control` says (a passive client is drawn no terminal tab).
  terminalTabs?.setActive(active);
  terminalTabs?.update(stripList(termList.activeId));
  renderWindowTabs();
  markEarlyTabs();
  // The active tab's screen, at exactly the grid this page said (the host resized to it); a passive client is drawn
  // no terminal, and a screen at another grid would be a layout the terminal will not show.
  if (active && screen && screen.id === termList.activeId && joinGrid
      && screen.cols === joinGrid.cols && screen.rows === joinGrid.rows) {
    $("xterm").classList.remove("hidden");          // as the channels' build will, a moment later
    termPreview.show(screen, { fontSize: joinFontSize(), theme: currentTheme() });
    dbg.termPreview = () => termPreview.tab;
    armPreviewHandover();
  }
}
/// The lists the BAR draws: the host's own, or the offer's until it has landed (`onEarlyState`).
function barTermList(): TermListMsg { return !termListed && early ? early.termList : lastTermList; }
function barViewSet(): ViewSetMsg { return !everReceivedViewSet && early?.viewSet ? early.viewSet : lastViewSet; }
/// A window tab's name: the host's listing, else the offer's names for the session's windows.
function barSources(): Source[] { return early && early.sources.length > 0 ? [...lastSources, ...early.sources] : lastSources; }
/// A strip drawn from the offer is INERT: a tap, a hold or a drag there would act on a session with no channel.
function markEarlyTabs(): void {
  $("term-tabs").inert = !termListed && early !== null;
  $("win-tabs").inert = !everReceivedViewSet && early?.viewSet != null;
}
/// **THE GRID THIS PAGE SAYS AS IT JOINS** (offer-screen.ts; `client-confirm`'s app_hello): the terminal area's, as the
/// deck's first `fit` will report it, measured when that message is written — and remembered, so the offer's screen
/// is painted only when it is at exactly this grid. Nothing from a window-less page (no offer) or when the area
/// cannot be measured.
let joinGrid: Grid | null = null;
function measureJoinGrid(): Grid | null {
  joinGrid = null;
  if (!windowless) {
    // `#xterm` is `hidden` until the channels are built (`buildChannelUi`): shown for the measurement alone, in this
    // task — nothing paints between.
    const area = $("xterm"), wasHidden = area.classList.contains("hidden");
    const previousTab = ui.dataset.tab;
    // Before the host's view arrives, mobile starts on the source surface. Its hidden terminal
    // would measure null and omit the pre-resize from the handshake. Expose it only for this
    // synchronous measurement; no frame paints, and an established host view stays authoritative.
    if (!everReceivedViewSet) ui.dataset.tab = "terminal";
    area.classList.remove("hidden");
    try {
      joinGrid = measureTerminalGrid(area, {
        fontSize: joinFontSize(), theme: currentTheme(),
        fontFamily: `"${opts.context ? fontNames.mono : "JetBrains Mono"}"`,
      });
    } finally {
      if (wasHidden) area.classList.add("hidden");
      if (previousTab === undefined) delete ui.dataset.tab;
      else ui.dataset.tab = previousTab;
    }
  }
  dbg.joinGrid = joinGrid;
  return joinGrid;
}
function joinFontSize(): number { return savedTerminalFontSize(terminalFontSize(opts.layout()), opts.context?.storage); }
// The grid is measured in the terminal's font or not at all (`measureTerminalGrid`): ask for it now, so it has loaded
// by the time the handshake writes `client-confirm`.
if (!windowless) void document.fonts?.load(`${joinFontSize()}px "${opts.context ? fontNames.mono : "JetBrains Mono"}"`).catch(() => {});
/// **THE OFFER'S SCREEN, painted** (offer-screen.ts): the active tab's, under its slot, until that tab's own content
/// fades in over it (`whenContent`, in the deck's branch), the host names another active tab, another tab is shown,
/// or this client goes passive.
const termPreview = new TermPreview($("xterm"));
scope.defer(() => termPreview.remove(), "term-preview");
let cancelPreviewHandover: (() => void) | null = null;
/// The offer's screen hands over to its tab's own content, which fades in over it — armed when there are both a
/// screen and a deck, whichever comes second (the workbench's channels open before its offer's state lands).
function armPreviewHandover(): void {
  cancelPreviewHandover?.();
  cancelPreviewHandover = null;
  const tab = termPreview.tab;
  if (tab === null || !termDeck) return;
  cancelPreviewHandover = termDeck.whenContent(tab, () => { if (termPreview.tab === tab) termPreview.remove(PREVIEW_HANDOVER_MS); });
}
scope.defer(() => cancelPreviewHandover?.(), "term-preview-handover");
let lastApps: AppsState | null = null;
let lastSources: Source[] = [];
/// What the host last said it can capture. null until it says — a client that assumed "ok"
/// would render a grid of tiles that stream nothing.
let lastDisplay: HostDisplay | null = null;
let lastViewSet: ViewSetMsg = { subs: [], focused: null, recoveryOverrideBp: null, activeRecovery: null, playoutDelayMinMs: null,
                                windows: [], view: { ...DEFAULT_SESSION_VIEW }, tabOrder: [], version: 0 };
let currentTab: Tab = "sim";   // mirrors ui.dataset.tab (set "sim" by default above)
// `session-dom.ts` mounts every session on the window surface; a window-less one has none.
if (windowless || nativeSimulators || nativeSourceAPI) { ui.dataset.tab = "terminal"; currentTab = "terminal"; }
/// THE VIEW, as the host's session state last said it (`view-set.view`), or null before the first
/// view-set. The page follows a CHANGE of it — never a value — so an echo of this client's own switch,
/// or any view-set that leaves the view alone, never flips the page under the user.
let stateView: SessionViewMsg | null = null;
/// Set while the page is APPLYING the state, so the surface and full-screen functions do not send it
/// straight back.
let applyingState = false;
/// A full screen the state asked for whose window does not exist yet — a restore lands in the state
/// before the host has re-established the window's stream, and its window. Applied once it does.
let pendingFullscreen: string | null = null;

/// Tell the host what THIS client changed about the view — the session's, so another device opens on
/// it. Only a driver's change counts (the host refuses a passive one). NEVER while applying the state,
/// and NEVER once `dispose()` has begun: its UI-first teardown leaves full screen on a channel that is
/// still open, and that must not erase the remembered full screen on every Disconnect.
///
/// AND NEVER BEFORE THE PAGE HAS THE STATE'S VIEW (`stateView`). Activation can land ahead of the first
/// `view-set`, when the page still holds its empty default — so `landOnTerminalIfNothingElse` saw "no
/// windows" and told the host "terminal", overwriting a remembered windows surface and full screen on
/// every new device (`e2e/session-state-check.mjs`, restore). A page that does not know the session has
/// nothing to say about it; the local move stands, and the first `view-set` applies the state's view.
function sendView(patch: { surface?: "terminal" | "windows"; fullscreen?: string | null }): void {
  if (applyingState || released || stateView === null || !(sessionControl?.isActive ?? false)) return;
  sendControl({ t: "set-view", ...patch });
}
/// The surface moved from `before` to `after`: tell the host.
function noteSurface(before: Tab, after: Tab): void {
  if (before !== after) sendView({ surface: after === "terminal" ? "terminal" : "windows" });
}

/// Follow the host's view. `force` (becoming the driver) applies the state's value whatever this page
/// did while passive; otherwise only a CHANGE of the state is followed, and only where the page differs.
function followStateView(view: SessionViewMsg, force = false): void {
  const prev = stateView;
  stateView = view;
  applyingState = true;
  try {
    const surfaceChanged = force || prev === null || prev.surface !== view.surface;
    const localSurface = agentsView?.visible ? "agents" : currentTab === "terminal" ? "terminal" : "windows";
    if(view.surface==="agents" && lastViewSet.selectedAgent)agentsView?.showSession(lastViewSet.selectedAgent);
    if (surfaceChanged && localSurface !== view.surface) {
      if (view.surface === "terminal") showTerminalSurface();
      else if(view.surface==="windows") { showWindowSurface(); renderWindowTabs(); }
    }
    const fsChanged = force || (prev === null ? view.fullscreen !== null : prev.fullscreen !== view.fullscreen);
    if (fsChanged) pendingFullscreen = view.fullscreen;
    if (fsChanged && view.fullscreen === null && windowManager?.fullscreenSource() !== null) windowManager?.setFullscreen(null);
    applyPendingFullscreen();
  } finally {
    applyingState = false;
  }
}
/// A remembered full screen, applied once its window exists — the mode only, never the browser's.
function applyPendingFullscreen(): void {
  const source = pendingFullscreen;
  if (source === null || !windowManager?.hasWindow(source)) return;
  pendingFullscreen = null;
  if (windowManager.fullscreenSource() !== source) {
    const was = applyingState;
    applyingState = true;
    try { windowManager.setFullscreen(source, { browser: false }); } finally { applyingState = was; }
  }
}
let everReceivedViewSet = false;   // has a view-set EVER arrived? gates the no-subscription-model fallback below
let sourceLiveness = new Map<string, boolean>();   // per-window liveness from source-status; absence ⇒ live
/// A simulator's state from the same pushes, for its window's not-live words ("Shut down", "Booting…").
let sourceSimStates = new Map<string, SimStateWire>();
const streamsBySource = new Map<string, MediaStream>();   // sourceID (MSID) -> its incoming MediaStream
/// Streams whose source no view-set had listed when they arrived — kept from a prune until one does (`stream-prune.ts`).
const unlistedStreams = new UnlistedStreams();
let lastVideoPrefs: VideoPrefs = { fps: 30, scale: 1.0, bitrateBps: 2_000_000 };
let xtermView: XtermView | undefined;   // the VISIBLE tab's instance (termDeck's), undefined with none
let termDeck: TermDeck | undefined;
scope.defer(() => termDeck?.dispose(), "term-deck");
/// What the last gesture was (input-modality.ts): a touch means focusing the terminal raises the soft
/// keyboard. CAPTURE, so it is recorded before any handler that decides focus runs; passive, it cancels
/// nothing. Before any input, the device's guess — `(any-pointer: coarse)`, as every touch gate is.
const inputModality = new InputModality(typeof matchMedia === "function" && matchMedia("(any-pointer: coarse)").matches);
scope.listen(window, "pointerdown", (e) => { if (!opts.context || opts.context.input.owns(e)) inputModality.pointer(e.pointerType); }, { capture: true, passive: true });
scope.listen(window, "keydown", (e) => { if (!opts.context || opts.context.input.owns(e)) inputModality.key(); }, { capture: true, passive: true });
/// A switch the host has not confirmed yet: a `term-list` that still names the old tab must not flip
/// the display back.
let pendingSwitch: string | null = null;

/// A tab switch is CLIENT-SIDE: the other instance is shown at once and no bytes move on the terminal
/// channel. The host is still told (on `control`), because keystrokes must keep matching its active tab.
/// A control (re)open, becoming the driver, going passive: a pending switch may have been dropped
/// (control not open) or ignored (this client was passive), and would otherwise outlive it for good —
/// every key naming a tab the host is not on, every key dropped. Void it; a driver re-asserts the tab
/// it shows (term-view-policy.ts, `switchReset`).
function resetPendingSwitch(): void {
  if (!termDeck) return;
  const r = switchReset(termDeck.visibleId(), sessionControl?.isActive ?? false);
  pendingSwitch = r.pending;
  if (r.reassert !== null) sendControl({ t: "switch-terminal", id: r.reassert });
}
/// A request for a NEW tab whose id the host will not echo (`open-terminal`, `new-tmux`): the next new tab
/// of that kind the client does not already know — listed or on the deck.
function newTabRequest(kind: "pty" | "tmux" | "any"): OpenRequest {
  const known = new Set<string>([...lastTermList.tabs.map((t) => t.id), ...(termDeck?.ids() ?? [])]);
  return { kind, known };
}
function switchTerminal(id: string): void {
  if (termDeck) {
    pendingSwitch = id;
    termDeck.show(id, "user");
    terminalTabs?.update(stripList(id));
  }
  sendControl({ t: "switch-terminal", id });
}

/// The host's list as the page shows it: without a tab a local open is still waiting for (`syncOpen`).
function shownTermList(): TermListMsg {
  const list = barTermList();
  const hide = syncOpen?.tab;
  return hide ? { ...list, tabs: list.tabs.filter((t) => t.id !== hide) } : list;
}
/// The strip's list: the host's, with the opening tab while the host has not listed it.
function stripList(activeId: string | null): TermListMsg { return withOpening(shownTermList(), opening, activeId); }
/// Open an EXISTING tmux session as a tab (`send` asks for it): on This Mac, WAITED FOR and shown in one step (see
/// `syncOpen`), resolving when it has landed — the palette closes then; anywhere else at once, optimistically.
function openTerminal(o: OpeningTab, send: () => void): Promise<void> | void {
  if (!transport.sameMac || !termDeck) { startOpening(o, send); return; }
  syncOpen?.finish();                                  // one at a time: an earlier one lands as it is
  return new Promise<void>((resolve) => {
    let done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = (): boolean => {
      if (done) return false;
      done = true;
      s.cancelWait();
      scope.clearTimeout(timer);
      if (syncOpen === s) syncOpen = null;
      return true;
    };
    const s: SyncOpen = {
      opening: o, tab: null, cancelWait: () => {},
      finish: () => {
        if (!settle()) return;
        if (s.tab !== null) {
          // The host made it its active tab; the page shows it now — strip, deck and empty state in this tick.
          pendingSwitch = null;
          termDeck?.show(s.tab, "user");
          terminalTabs?.update(stripList(s.tab));
          renderTermEmpty();
        } else {
          startOpening(o, () => {});                   // asked already: the placeholder until the host names it
        }
        resolve();
      },
      fail: () => { if (settle()) { terminalTabs?.update(stripList(termDeck?.visibleId() ?? lastTermList.activeId)); renderTermEmpty(); resolve(); } },
    };
    syncOpen = s;
    timer = scope.timeout(() => s.finish(), OPEN_SYNC_MS);
    termDeck!.expectOpenedTab(o.req);                  // it takes focus when it lands
    send();
  });
}
function startOpening(o: OpeningTab, send: () => void): void {
  termDeck?.expectOpenedTab(o.req);                        // it takes focus when it lands
  opening = o;
  scope.clearTimeout(openingTimer);
  openingTimer = scope.timeout(() => cancelOpening(), OPENING_MS);
  pendingSwitch = null;
  termDeck?.show(o.key, "user");                           // nothing to draw yet: the area waits for it
  terminalTabs?.update(stripList(o.key));
  renderTermEmpty();
  send();
}
/// A new shell or tmux session: its id is the host's to give, so the tab shows under a placeholder, at once —
/// on This Mac too: starting one takes time, and nothing waits on it.
function openNewTerminal(kind: "pty" | "tmux"): void {
  if (nativeSimulators) showTerminalSurface();
  startOpening({ key: placeholderKey(++openingSeq), label: kind === "pty" ? predictedShellLabel(lastTermList) : "New session",
                 req: newTabRequest(kind) },
               () => sendControl(kind === "pty" ? { t: "open-terminal" } : { t: "new-tmux" }));
}
/// The opening tab is not coming (refused, or never listed): it leaves the strip, and the deck shows the host's
/// active tab again if it was showing that one.
function cancelOpening(): void {
  if (!opening) return;
  const key = opening.key;
  opening = null;
  scope.clearTimeout(openingTimer);
  if (termDeck?.visibleId() === key) termDeck.show(lastTermList.activeId);
  terminalTabs?.update(stripList(termDeck?.visibleId() ?? lastTermList.activeId));
  renderTermEmpty();
}
let clearPendingGhosts: (() => void) | undefined;   // set by the xterm branch; clears ghosts on active→passive

// On connect (active client), subscribe the TEST-ONLY `?autosub=<sourceId>` source — once, and only
// into a session with NO windows: the host's state is authoritative, so a host that remembers a window
// restores that instead. Interactive clients never reach this.
function maybeAutoSubscribe(): void {
  if (!autoSub || autoSubDone) return;   // test-only (?autosub=<sourceId>)
  if (everPassive || !(sessionControl?.isActive ?? false) || !everReceivedViewSet) return;
  if (lastViewSet.windows.length > 0 || subscribedSources(lastViewSet).length > 0) return;
  autoSubDone = true;
  sendControl({ t: "subscribe", source: autoSub, delivery: requestedDelivery(autoSub) });
}

// The #windows container is visible ONLY when this client is the driver AND the (authoritative) session has
// an open window. This is the single source of truth — SessionControl un-hides #windows whenever the client
// is active, and the host still delivers video frames to whoever is the active consumer, so without this an
// active client that claimed an intentionally-hidden session would show the resurrected stream.
//
// Call after a change to ANY of its three inputs: active-status, the view set, AND `streamsBySource`. That
// last one used to have no trigger, which is a bug the `!everReceivedViewSet && streams > 0` arm made
// reachable: on the TestPattern path there is no view-set, so that arm is the only way to show — and the
// track routinely lands a millisecond AFTER the activation reconcile (measured: activate at 1282ms with
// streams=0, track at 1284ms), leaving #windows hidden forever with video decoding behind it. syncVideo()
// now calls this, which is what closes it.
function reconcileSimVisibility(): void {
  const show = (sessionControl?.isActive ?? false) &&
    (streamedWindows(lastViewSet).length > 0 || (!everReceivedViewSet && streamsBySource.size > 0));
  sim.classList.toggle("hidden", !show);
}

// THE single video renderer: reconcile the floating windows to the current view-set/sources (WindowManager
// creates/removes each subscribed source's window, binds its stream, and moves id="screen" onto the focused
// window's <video>), then (re)point the latency probe at that focused <video>, then drop streams whose source
// is no longer subscribed.
/// Close (`unsubscribe`) or park (`minimize-window`) a window, saying `land` when the person was AT it
/// (`WindowManager.personAt`) — so the host lands them on the bar's previous tab, a terminal tab too
/// (`SessionState.landing`). Absent, the host keeps the window rule alone: the terminal stays on the tab
/// being typed into.
function leaveWindow(t: "unsubscribe" | "minimize-window", source: string): void {
  const land = nativeSimulators ? lastViewSet.focused === source && stateView?.surface === "windows" : windowManager?.personAt(source, currentTab === "sim") ?? false;
  sendControl({ t, source, ...(land ? { land: true } : {}) });
}

/// `keysTo`: where the keys of a window that goes holding them are handed instead of the next window
/// (`WindowManager.sync`) — the terminal, when the host landed the person there.
function syncVideo(trigger: SyncTrigger, keysTo?: (typing: boolean) => void): void {
  if (nativeSimulators) return;
  nativeSources?.setSessionState(lastViewSet,lastSources,nativeControlSeen && (sessionControl?.isActive ?? false),currentTheme(),smoothScrollEnabled());
  let views = windowViews(lastViewSet, lastSources);
  // Headless fallback: the TestPattern host (Swift "test" path / dev harness) delivers ONE video track but
  // NEVER a view-set (no SimManager ⇒ nothing calls sendViewSet). Synthesize a focused window for the sole
  // incoming stream so #screen exists for host-/browser-smoke. Guarded on !everReceivedViewSet so a real-sim
  // session (which always sends view-sets, incl. empty on hide) can't resurrect a hidden stream.
  if (views.length === 0 && !everReceivedViewSet && streamsBySource.size > 0) {
    const id = streamsBySource.keys().next().value as string;
    views = [{ source: id, name: id, focused: true, fps: lastVideoPrefs.fps, scale: lastVideoPrefs.scale, bitrateBps: lastVideoPrefs.bitrateBps }];
  }
  windowManager?.sync(views, streamsBySource, keysTo);
  watchAllPresentations();
  attachProbeTo(windowManager?.focusedVideo());
  // Prune streams whose source is no longer subscribed (WindowManager already removed their windows).
  //
  // ONLY ON THE EVIDENCE OF THE VIEW-SET THAT TRIGGERED THIS SYNC — see `stream-prune.ts`. This used
  // to prune against `lastViewSet` whenever it ran, and on a relayed path the sync a track arrival
  // triggers runs while `lastViewSet` still predates the subscribe (the offer outran the view-set),
  // so it forgot the stream it had just registered and the window stayed black with every counter
  // healthy. The headless "test" stream, which never sees a view-set, is kept alive by the same rule.
  // A view-set LISTING a stream's source makes it known; a stream no view-set has listed yet is never pruned by one
  // that may predate its subscribe (`UnlistedStreams` — 2026-10-08, black windows on a pick while previews loaded).
  if (trigger.kind === "view-set") unlistedStreams.listed(trigger.subscribed);
  const unlisted = unlistedStreams.protectedIds();
  for (const id of staleStreams(trigger, [...streamsBySource.keys()], unlisted)) {
    streamsBySource.delete(id); referenceTracks.delete(id); referenceBindings.delete(id); referenceReceipts.reset(id);
  }
  // AUDIO IS PRUNED ON THE SAME RULE, and here rather than at the unsubscribe call site for the
  // reason the video prune is here: this is the one function that owns what a live source is.
  // An element left behind would keep playing a track the host has stopped sending on.
  for (const id of staleStreams(trigger, [...audioPlayback.sources], unlisted)) audioPlayback.detach(id);
  // `streamsBySource` is an INPUT to the visibility rule, and this is the one function that owns changes to
  // it — so the reconcile belongs here rather than at any single call site (onTrack was not enough).
  reconcileSimVisibility();
}

// Latency probe (probe=1 only), bound to the FOCUSED window's <video> and rebound when focus moves to a
// different window (a new <video> element). probeStart/probeStop stay the module-level hooks that
// SessionControl (activate/deactivate) and rebuildPc drive; preserves window.__rdev.latency/receiverStats.
let probedEl: HTMLVideoElement | undefined;
let probeSamples = 0, probeSum = 0;
const probeRing: Array<{ g2gMs: number; pipelineMs: number; wireMs?: number; renderMs?: number; decodeMs?: number }> = [];
let probeStatsInterval: ReturnType<typeof setInterval> | undefined;
function attachProbeTo(el: HTMLVideoElement | undefined): void {
  if (!probeOn) return;
  if (el === probedEl) return;                 // same focused video → nothing to rebind
  probeStop?.();                               // tear down the probe on the previous element (if any)
  probeStart = undefined; probeStop = undefined;
  probedEl = el;
  if (!el) return;
  probeSamples = 0; probeSum = 0;              // fresh element → restart the g2g average
  let stopProbeFn: (() => void) | undefined;
  probeStart = () => {
    if (stopProbeFn) return;
    stopProbeFn = startLatencyProbe(el, ({ g2gMs, pipelineMs, wireMs, renderMs, decodeMs }) => {
      probeSamples++; probeSum += g2gMs;
      dbg.latency = { g2gMs: Math.round(probeSum / probeSamples), samples: probeSamples };
      // Raw ring for profiling. `dbg.latency.g2gMs` is a CUMULATIVE mean, which is the wrong shape
      // for optimisation work: it is dominated by the startup transient and hides the distribution,
      // so a change that improves steady state barely moves it. Keep the last 600 samples (~10s at
      // 60fps) so a profiler can take a steady-state window and percentiles.
      probeRing.push({ g2gMs, pipelineMs, wireMs, renderMs, decodeMs });
      if (probeRing.length > 600) probeRing.shift();
      dbg.latencySamples = probeRing;
    });
    probeStatsInterval = scope.interval(async () => {
      const media = connection?.media;
      if (!media) return;                        // read per tick, as `pc` was: nothing to poll without media
      const stats = await pollReceiverStats(media);
      if (!scope.disposed) dbg.receiverStats = stats;
    }, 1000);
  };
  probeStop = () => { stopProbeFn?.(); stopProbeFn = undefined; scope.clearInterval(probeStatsInterval); probeStatsInterval = undefined; };
  if (sessionControl?.isActive) probeStart();
}

// Set once the palette exists (inside buildChannelUi); lets the source-list handler refresh an open palette.
let refreshPaletteItems: (() => void) | undefined;

// THE BAR'S ARRANGEMENT (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md): the host
// keeps one order for every terminal tab and window (`view-set.tabOrder`) and their names; a drop and
// a rename show at once (`PendingTabs`) until its echo. Both strips are `display: contents`, so each tab
// is a flex item of the scroller and takes its place from `style.order`.
const pendingTabs = new PendingTabs();
let pendingTabsTimer: ReturnType<typeof setTimeout> | undefined;
/// The bar as the host's state draws it.
function hostBarOrder(): string[] {
  const terminals = barTermList().tabs.map((t) => t.id);
  // The opening tab, where the host will place it: after the last terminal tab.
  if (opening && !terminals.includes(opening.key)) terminals.push(opening.key);
  const vs = barViewSet();
  return tabBarOrder(terminals, vs.windows.map((w) => w.source), vs.tabOrder, (vs.agents??[]).map(a=>`agent:${a.id}`));
}
/// The bar to draw: the host's, under whatever this driver just did.
function barOrder(): string[] { return pendingTabs.barOrder(hostBarOrder(), performance.now()); }
/// Each tab's place in the bar. Not while a tab is renamed or dragged — the drag measured the tabs
/// where they stood; `settled` comes back here.
function applyTabOrder(): void {
  if (tabBar.busy) return;
  const order = barOrder();
  const at = new Map(order.map((k, i) => [k, i + 1]));
  for (const el of $("tabbar-scroll").querySelectorAll<HTMLElement>(".rl-tab[data-tab-key]")) {
    el.style.order = String(at.get(el.dataset.tabKey!) ?? order.length + 1);
  }
  revealSelectedTab();
}
/// **THE TAB ON SCREEN IS SCROLLED TO WHEN A MACHINE OPENS, AND WHEN THIS PAGE TAKES CONTROL BACK** (2026-10-06,
/// asked for: "When opening a machine, or taking back control, make sure the focused tab is scrolled to"): a crowded
/// bar came up at its start with the selected tab off to its right. Armed when the session is built and whenever this
/// page becomes the driver (its terminal tabs come back then); every redraw of the bar — and a change of surface,
/// which moves the selection with none — then scrolls to the selected tab (`TabBar.revealSelected`) in the next
/// frame, after whatever else that task changed, until it has shown one in the host's own lists (not the offer's).
/// The person's hand on the bar ends it first: it never scrolls the bar back from under them.
let revealTab = true;
let revealFrame: number | undefined;
function revealSelectedTab(): void {
  if (!revealTab || revealFrame !== undefined) return;
  revealFrame = scope.raf(() => {
    revealFrame = undefined;
    if (revealTab && tabBar.revealSelected() && termListed && (windowless || everReceivedViewSet)) revealTab = false;
  });
}
for (const type of ["pointerdown", "wheel"] as const) scope.listen($("tabbar-scroll"), type, () => { revealTab = false; }, { passive: true });
/// A pending move or name the host never echoes (it refused) gives up after `PendingTabs.HOLD_MS`; draw
/// the host's state again then.
function armPendingTabsExpiry(): void {
  scope.clearTimeout(pendingTabsTimer);
  const at = pendingTabs.nextExpiry(performance.now());
  if (at === null) return;
  pendingTabsTimer = scope.timeout(() => {
    pendingTabsTimer = undefined;
    terminalTabs?.refresh();
    renderWindowTabs();
    renderAgentTabs();
    applyTabOrder();
    armPendingTabsExpiry();
  }, Math.max(0, at - performance.now()) + 1);
}
/// The label the HOST gives `key` now — what a pending rename holds against.
function hostTabLabel(key: string): string | null {
  if(tabKind(key)==="agent"){const a=lastViewSet.agents?.find(a=>`agent:${a.id}`===key);return a?(a.name||a.title):null;}
  if (tabKind(key) === "terminal") {
    const t = lastTermList.tabs.find((x) => x.id === key);
    return t ? tabLabel(t) : null;
  }
  const w = lastViewSet.windows.find((x) => x.source === key);
  return w ? windowLabel(w, lastSources) : null;
}
scope.defer(installTabEdge($("tabbar-scroll")), "tabbar:edge");
const tabBar = new TabBar($("tabbar-scroll"), {
  // The DRIVER arranges the bar; the host refuses anyone else's, and a passive client's menu would
  // offer what it cannot do.
  enabled: () => sessionControl?.isActive ?? false,
  renameField: (key) => {
    const now = performance.now();
    if(tabKind(key)==="agent"){
      const a=lastViewSet.agents?.find(a=>`agent:${a.id}`===key);if(!a)return null;
      return {value:pendingTabs.label(key,a.name||a.title,now),placeholder:a.title,named:!!a.name,clearable:true};
    }
    if (tabKind(key) === "terminal") {
      const t = lastTermList.tabs.find((x) => x.id === key);
      if (!t) return null;
      const f = termRenameField(t);
      return { ...f, value: pendingTabs.label(key, f.value, now) };
    }
    const w = lastViewSet.windows.find((x) => x.source === key);
    if (!w) return null;
    const f = winRenameField(w, lastSources);
    return { ...f, value: pendingTabs.label(key, f.value, now) };
  },
  rename: (key, name) => {
    const host = hostTabLabel(key);
    if (host === null) return;
    sendControl({ t: "rename-tab", tab: key, name });
    // What the tab will be called: the name, or — cleared — what it is called when nobody named it.
    const t = lastTermList.tabs.find((x) => x.id === key);
    const w = lastViewSet.windows.find((x) => x.source === key);
    const shown = name !== "" ? name
      : t ? autoTabLabel(t) : w ? windowLabel({ ...w, name: undefined }, lastSources) : host;
    pendingTabs.renamed(key, shown, host, performance.now());
    armPendingTabsExpiry();
    // The field is gone (the bar is no longer busy): draw the new label now, not at the echo.
    terminalTabs?.refresh();
    renderWindowTabs();
    renderAgentTabs();
  },
  // Exactly the tab's own ×, or a window's titlebar ×: a terminal closes (a tmux tab DETACHES), a
  // window leaves the session.
  close: (key) => {
    if(tabKind(key)==="agent")agentAction("close-tab",key.slice(6));
    else if (tabKind(key) === "terminal") sendControl({ t: "close-terminal", id: key });
    else leaveWindow("unsubscribe", key);
  },
  // PASTE FROM A TAB'S MENU (paste-ui.ts, `pickForTab`): on a phone a window's titlebar is all controls —
  // its title is hidden — so the hold that opens a window's paste menu has almost nowhere to land; every tab's
  // menu carries the same items, a terminal tab's reaching a tab that is not on screen too. Not a MINIMIZED
  // window's, nor any window in a window-less session: the host would refuse the delivery (`tabTakesPaste`).
  // A TMUX tab's menu also ends its session (asked for, 2026-10-04) — confirmed. No
  // ellipsis: a command that only asks for confirmation takes none.
  extraItems: (key) => [
    ...(key.startsWith("tmux:") ? [{ action: "kill-tmux", label: "Terminate Tmux Session" }] : []),
    ...(key.startsWith("sim:") ? simMenuItems(sourceSimStates.get(key) ?? lastSources.find((s) => s.id === key)?.simState) : []),
    ...(tabTakesPaste(key, { windowless, windows: lastViewSet.windows }) ? pasteUI.menuItems() : []),
  ],
  onExtra: (key, action) => {
    if (action === "kill-tmux") { openKillTmuxDialog(key.slice("tmux:".length)); return; }
    const sim = simActionOf(action);
    if (sim && key.startsWith("sim:")) { sendControl({ t: "sim-action", source: key, action: sim }); return; }
    pasteUI.pickForTab(key, action);
  },
  move: (key, before) => {
    const next = moveTab(barOrder(), key, before);
    if (!next) return;
    sendControl({ t: "move-tab", tab: key, before });
    pendingTabs.moved(next, performance.now());
    armPendingTabsExpiry();
  },
  // ALWAYS a full redraw: a list may have arrived meanwhile, and a pending label may have expired while
  // the bar was held — neither would show otherwise.
  settled: () => { terminalTabs?.refresh(); windowTabs.refresh(); renderAgentTabs(); applyTabOrder(); },
}, scope.signal);
/// A tab being renamed that the host no longer has: drop its field, or the strip stays held for good.
function dropVanishedRename(): void {
  const key = tabBar.editingKey;
  if (key !== null && hostTabLabel(key) === null) tabBar.cancelRename();
}

// The window half of the tab bar: one tab per window of the host's session (`view-set.windows`),
// minimized ones dimmed in place. Re-rendered on every view-set/source-list update below and on every tab click.
const windowTabs = new WindowTabs(
  { root: ui, strip: $("win-tabs") },
  {
    onFocusSource: (id, minimized) => {
      if (nativeSimulators) { nativeShell?.activateSimulator?.(id); return; }
      if (nativeSources) { ui.dataset.tab = "terminal"; nativeSources.activate(id); return; }
      showWindowSurface();
      // A parked tab is still the session's: bring it back (the host un-minimizes AND focuses it).
      sendControl(minimized ? { t: "restore-window", source: id } : { t: "focus-source", source: id });
      renderWindowTabs();
    },
    hold: () => tabBar.busy,
    label: (key, label) => pendingTabs.label(key, label, performance.now()),
    rendered: applyTabOrder,
    bell: (key) => bells.has(key),
  },
);
markWindowBells = () => windowTabs.markBells();
function renderWindowTabs(): void {
  windowTabs.update(windowTabViews(barViewSet(), barSources(), nativeSources?.activeKey() ? "sim" : currentTab, opts.layout()).filter(w => !nativeSimulators || w.id.startsWith("sim:")));
}
renderWindowTabs();

// The terminal half: built with the SESSION, as the window half is, so the offer's state can draw it before any
// channel opens (`onEarlyState`). Nothing it sends has a channel until then — and its strip is inert.
terminalTabs = new TerminalTabs($("term-tabs"), {
  onSwitch: (id) => switchTerminal(id),
  onActivate: (id) => {
    if (sessionControl?.isActive && document.visibilityState === "visible") bells.acknowledge(id);
  },
  // × on a tmux tab DETACHES: the tab leaves the session, the tmux session keeps running.
  onClose: (id) => sendControl({ t: "close-terminal", id }),
  onShowTerminal: () => showTerminalSurface(),
  surfaceShown: terminalSurfaceShown,
  hold: () => tabBar.busy,
  label: (key, label) => pendingTabs.label(key, label, performance.now()),
  rendered: applyTabOrder,
  bell: (key) => bells.has(key),
});
terminalTabs.update(lastTermList);
const terminalSelection = new MutationObserver(() => { terminalTabs?.refreshSelection(); revealSelectedTab(); });
terminalSelection.observe(ui, { attributes: true, attributeFilter: ["data-tab", "data-layout"] });
scope.defer(() => terminalSelection.disconnect(), "terminal-tab-selection");

// The terminal surface became visible: fit xterm to #stage (double rAF so the display/layout change has
// applied first). Under the tabbed layout the terminal is display:none on the Sim tab, so FitAddon can't
// measure it until now — without this the grid stays at xterm's default 24 rows, leaving a band of --bg
// below it. Does NOT auto-focus (so the keyboard doesn't ambush the user); a tap on the terminal opens it.
///
/// It SETS `data-tab` itself. It used to leave that to its callers, and only a tab tap and the glasses
/// back gesture did — so on the tabbed layout a terminal opened from the palette, and the empty state
/// at connect, stayed display:none behind the window surface: a blank screen on a phone.
function showTerminalSurface(): void {
  const wasAgent=agentsView?.visible;
  agentsView?.hide();
  sourceFocusGate?.activate(null);
  const before = currentTab;
  // The terminal is what shows now, so no window can be the whole screen (and full screen hides it).
  windowManager?.setFullscreen(null);
  ui.dataset.tab = "terminal";
  currentTab = "terminal";
  noteGlassesScreen("terminal");
  scope.raf(() => scope.raf(() => { if (sessionControl?.isActive) termDeck?.fit(); }));
  renderWindowTabs();
  if (wasAgent || (nativeSimulators && stateView?.surface === "windows")) sendView({ surface: "terminal" });
  else noteSurface(before, "terminal");
}

/// The window surface becomes what the user sees — `showTerminalSurface`'s counterpart, and like it
/// it SETS `data-tab` itself: a window tab tap did, a palette pick of a window did not, so on a phone
/// showing the terminal the picked window opened behind it (command-palette.ts, `paletteItemSurface`).
/// Leaving the terminal blurs its input, so the soft keyboard dismisses. The caller re-renders the
/// window tabs once it has recorded the focus it asked for.
function showWindowSurface(): void {
  const wasAgent=agentsView?.visible;
  agentsView?.hide();
  if (nativeSimulators || nativeSourceAPI) { sendView({ surface: "windows" }); return; }
  const before = currentTab;
  ui.dataset.tab = "sim";
  currentTab = "sim";
  noteGlassesScreen("window");
  (activeElement() as HTMLElement | null)?.blur();
  if(wasAgent)sendView({surface:"windows"});else noteSurface(before, "sim");
}

/// Record a glasses screen change as a browser history entry, so the temple back gesture — which is
/// literally `history.back()` — can undo it. Inert on every other layout.
function noteGlassesScreen(screen: GlassesScreen): void {
  if (opts.context && !opts.context.environment.pageHistory) { currentScreen = screen; return; }
  if (opts.layout() !== "glasses") return;
  // Through the chooser: an open sheet's entry is REPLACED, and a closing one's back() is waited for.
  if (pushScreen(screen, currentScreen)) (opts.context?.chooser.pushScreenEntry ?? pushScreenEntry)({ rdevScreen: screen, rdevSession: opts.generation ?? 0 });
  currentScreen = screen;
}

// The glasses back gesture arrives as an ordinary popstate. Restore the screen the entry names rather
// than letting the browser walk out of the session. `screenFromHistory` returns null for a foreign
// entry, so this never adopts one somebody else pushed.
scope.listen(window, "popstate", (e) => {
  if (opts.context && !opts.context.environment.pageHistory) return;
  if (opts.layout() !== "glasses") return;
  // A closed chooser's own back() landing: it restores nothing (a screen change may be waiting on it).
  if ((opts.context?.chooser.chooserBackPending ?? chooserBackPending)()) return;
  const screen = screenFromHistory(e.state, opts.generation ?? 0);
  if (!screen) return;
  currentScreen = screen;                       // set first: the helpers below must not re-push it
  if (screen === "terminal") {
    ui.dataset.tab = "terminal";
    showTerminalSurface();
  } else {
    const before = currentTab;
    ui.dataset.tab = "sim";
    currentTab = "sim";
    renderWindowTabs();
    noteSurface(before, "sim");
  }
});

// <body> is pinned to the visual viewport by the CONTROLLER, from mount to unmount (session-lifecycle.ts),
// so the pin outlives the engine through the Disconnect slide: at rest the terminal fills the screen,
// and with the soft keyboard up the body shrinks → #stage shrinks → the ResizeObserver above reflows
// xterm to fit above the keyboard.

// The global "hide the whole stream" toggle (#sim-toggle) is gone — the mobile tab strip (switch to
// Terminal) plus per-window close (WindowManager.onClose, which takes the window out of the session)
// cover its role; see mobile-tabs.ts / window-manager.ts.
const statusBar = new StatusBar({ dot: $("status-dot"), cells: $("status-cells") });

// The last connection state we were TOLD about. The footer re-renders from this plus live stats, so the
// 1s stats tick can never overwrite a "reconnecting…" state with a stale "connected".
let connState: StatusInfo["state"] = "connecting";
let connText = "connecting…";

function setStatus(state: StatusInfo["state"], text: string): void {
  if (scope.disposed) return;
  connState = state; connText = text;
  host.state({ state, text });
  renderStatus(undefined);
}

/// The most recent stats report, so a redraw triggered by something OTHER than a stats tick — the
/// recovery stack arrives on view-set — can keep the ping and rate cells instead of blanking them
/// for a frame. view-set fires on every pref, focus and subscribe change, so that flicker would be
/// frequent and visible.
let lastStatsReport: RTCStatsReport | undefined;
/// This Mac's window: the app is sharing (the block after `renderStatus`).
let remoteAccess = false;
/// The selected ICE pair's round trip (ms) from the last stats tick — the LINK predictive echo's gate
/// reads (PredictionController). Never set on a transport without media (a socket): no network, null.
let networkRttMs: number | null = null;
// The previous inbound-video sample, so the footer's FEC share is a WINDOW and not a session
// average. Both counters run for the life of the connection, so their raw ratio would report a burst
// from a minute ago as the current state — the mistake the `[rx]` jitter buffer made.
let previousFecSample: InboundVideoDiagnostics | undefined;

function renderStatus(report: RTCStatsReport | undefined): void {
  if (report) lastStatsReport = report;
  let fecFraction: number | null = null;
  if (report) {
    const current = inboundVideoDiagnostics(report)[0];
    if (current) {
      fecFraction = fecBandwidthFraction(current, previousFecSample);
      previousFecSample = current;
    }
  }
  // Kept for the `[dc-rx]` line, which has no other way to learn it: this function already asks
  // `getStats` on a timer for the status bar, so reading it a second time would buy nothing.
  if (report) lastTransport = connectionKind(report) ?? null;
  if (report) networkRttMs = iceRoundTripMs(report);
  statusBar.render({
    state: connState, stateText: connText,
    transport: report ? connectionKind(report) : null,
    rttMs: report ? iceRoundTripMs(report) : null,
    rxMbps: report ? rxMeter(report) : 0,
    // From the last view-set rather than from stats: the host decides the recovery stack from the
    // ANSWER, and no receiver-side statistic reports it.
    activeRecovery: !transport.carriesMedia ? null : (lastViewSet.activeRecovery ?? null),
    fecFraction,
    remoteAccess,
  });
}
// THIS MAC's window says when the app is SHARING (asked for, 2026-10-04): "remote access enabled" in the status
// bar. The app knows it, never the page — asked once (`__rdevShell.sharing`) and told on every change after
// (`onSharing`, the app's state publisher). Only This Mac's window (`transport.sameMac`); elsewhere the shell has no
// such call and the cell never shows. (`remoteAccess` is declared beside `lastStatsReport`, ahead of every
// `renderStatus`.)
{
  const shell = opts.context ? opts.context.platform.native : (window as Window & {
    __rdevShell?: { sharing?(): Promise<unknown>; onSharing?(cb: (on: boolean) => void): () => void };
  }).__rdevShell;
  if (transport.sameMac && shell?.sharing && shell.onSharing) {
    const set = (on: boolean) => { if (on !== remoteAccess) { remoteAccess = on; renderStatus(lastStatsReport); } };
    scope.defer(shell.onSharing(scope.guard((on) => set(on === true))), "sharing");
    void shell.sharing().then((on) => { if (!scope.disposed) set(on === true); }, () => {});
  }
}
renderStatus(undefined);   // populate the footer before the first connection event


// Send the active client's terminal size to the host (debounced), reflowing the real PTY.
let resizeTimer: ReturnType<typeof setTimeout> | undefined;
/// The grid the deck's last fit measured (its `onFit`), whether or not it was sent — a passive page sends none.
let fittedGrid: Grid | null = null;
/// **A CLAIM SAYS ITS GRID** (docs/terminal.md, "A claim says its grid"): measured as the claim is sent, as a HOLD —
/// nothing resized, the deck waiting for the host's snapshots at it — and carried in `claim-control`, so the host
/// resizes every tab to it BEFORE the new driver's wire snapshots them. Without it the first snapshots came at the
/// previous driver's grid, committed reflowed to this page's for a frame or more, then the right ones (2026-10-06,
/// "a one-frame blink of something that looks like the other device's size"). Null when the area cannot be measured
/// (a phone's terminal behind its window surface): the claim then says none, as before.
const claimGrid = (): Grid | null => {
  fittedGrid = null;
  termDeck?.fit({ hold: true });
  return fittedGrid;
};
const sendResize = (hold: boolean) => {
  const t = channels.control;
  if (!t || t.readyState !== "open" || !sessionControl?.isActive) return;
  termDeck?.fit({ hold });   // the deck fits + emits {t:"resize"} via onFit
};
// EVERY grid change `#stage`'s size brings HOLDS for the host's snapshot (`TermDeck.fit`): one layout, the
// host's, not xterm.js's reflow and then the host's ~30 ms later, wrapped differently — a soft keyboard
// opening or closing, a rotation, and an EDGE DRAG (2026-10-03: it previewed until then, so every pause of a
// drag showed both layouts; this debounce already kept it from following the drag frame by frame).
// A controlled window resize (expand/restore, `resize-settle.ts`) fits ONCE, when its hold is released
// (two frames after its end) — not at this debounce's 100 ms after its last step, which left the old grid
// on screen that long (measured 2026-10-02).
const resizeOwner = {};
scope.defer(() => resizeSettle.cancel(resizeOwner));
// A SOFT KEYBOARD SHIFTS THE TERMINAL; IT NEVER RESIZES IT (keyboard-shift.ts): while the keyboard alone covers the
// bottom, `#xterm` keeps its box and moves up by the keyboard's band (never the cursor's row off the top) — nothing is
// fitted, followed or sent.
const keyStripTermEl = $("key-strip-term");
const keyboardShift = new KeyboardShift({
  win: window,
  stage,
  xterm: $("xterm"),
  // The layouts `ViewportFit` pins to the visual viewport (session-lifecycle.ts), the glasses aside.
  enabled: () => typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches
    && ui.dataset.layout !== "glasses",
  visibleBottom: () => {
    const strip = keyStripTermEl.getBoundingClientRect();
    return strip.height > 0 ? strip.top : stage.getBoundingClientRect().bottom;
  },
  visibleTop: () => stage.getBoundingClientRect().top,
  cursorTop: () => {
    const v = termDeck?.visibleView();
    const screen = v?.term.element?.querySelector(".xterm-screen");
    if (!v || !screen) return null;
    const b = v.term.buffer.active;
    // Scrolled back: the cursor is not on screen to keep — but an agent's view at its content's end rests INTO the
    // scrollback, the cursor drawn that many rows lower (trailing-blanks.ts).
    const row = cursorViewRow({ cursorY: b.cursorY, baseY: b.baseY, viewportY: b.viewportY, hidden: v.hiddenRows() });
    if (row === null) return null;
    const r = screen.getBoundingClientRect();
    return r.height > 0 ? r.top + row * (r.height / v.rows()) : null;
  },
});
scope.defer(() => keyboardShift.dispose());
const scheduleResize = () => {
  if (keyboardShift.onStageResize()) return;
  // The picture moves to where the host will put it in THIS frame (`TermDeck.follow`); the fit below reports.
  if (channels.control?.readyState === "open" && sessionControl?.isActive) termDeck?.follow();
  scope.clearTimeout(resizeTimer);
  if (resizeSettle.defer(resizeOwner, "resize", () => sendResize(true))) return;
  resizeTimer = scope.timeout(() => sendResize(true), 100);
};
scope.observe(new ResizeObserver(scheduleResize)).observe(stage);

// ---- Connection build (re-runnable on rebuild) -----------------------------------------------------
//
// The CONNECTION owns the transport and rebuilds it after a loss — `rtc-connection.ts` its pc + peer
// (rebuildPc → buildPeer), `socket-connection.ts` a fresh socket per reconnect — and every build hands
// this file FRESH channels through `onChannels` (the `sink.channels` it is given below). The channel
// wiring here is factored so it can run AGAIN on each. Three rules make a rebuild safe:
//   - Every send routes through the `channels` holder, re-pointed by each onChannels.
//   - The one-time DOM construction (claim button, sim menu, prefs selects, xterm mount, touch handlers)
//     runs behind the `onChannelsBuilt` guard, so a rebuild never double-binds a DOM listener.
//   - Per-channel listeners (the central control dispatch + the terminal bindings) are (re)attached on
//     EVERY onChannels — each rebuild hands us fresh channel objects, so re-adding can't double-bind a live one.

/// The ICE path the session is currently on, as last observed. NULL UNTIL KNOWN — a browser that has
/// not resolved a candidate pair has said nothing, and reporting "p2p" for it would invent an answer.
let lastTransport: string | null = null;

// All data-channel sends route through the mutable `channels` holder so a rebuild re-points them in one
// place (a channel captured by a previous build is dead once the pc is rebuilt).
const sendControl = (obj: unknown) => {
  if (termOutputBlocked && (obj as { t?: string } | null)?.t === "term-mode") return;
  const c = channels.control; if (c && c.readyState === "open") c.send(encodeJson(obj) as Uint8Array<ArrayBuffer>);
};
if (productFeatures.graphicalAgents) {
agentsView = new AgentWorkspace({root:$("agents-surface"),
  send: obj => obj.op === "upload" ? sendBulk(obj) : sendControl(obj),
  onOpen: () => { ui.dataset.agentView="true"; sourceFocusGate?.activate(null); (activeElement() as HTMLElement|null)?.blur(); terminalTabs?.refreshSelection(); renderAgentTabs(); bells.look(); },
  onHide: () => { delete ui.dataset.agentView; terminalTabs?.refreshSelection(); renderAgentTabs(); },
  onSession: id=>{void agentsView?.openSession(id).catch(error=>console.error("[agents] open",error));},
  onCloseTab: id=>agentAction("close-tab",id),
  hostSelectedTab:()=>lastViewSet.view.surface==="agents"?lastViewSet.selectedAgent??null:null,
});
agentTabStrip=new AgentTabs($("agent-tabs"),{select:id=>agentAction("select-tab",id),close:id=>agentAction("close-tab",id),
  label:(key,label)=>pendingTabs.label(key,label,performance.now()),hold:()=>tabBar.busy,rendered:applyTabOrder,bell:key=>bells.has(key)});
for (const id of ["term-tabs","win-tabs"]) $(id).addEventListener("click",()=>{
  if(agentsView?.visible){agentsView.hide();sendView({surface:id==="term-tabs"?"terminal":"windows"});}
},{capture:true});
scope.defer(()=>agentsView?.dispose(),"agents view");
}
/// The paste/drop protocol and the image viewer (docs/superpowers/specs/2026-10-12-terminal-lane-design.md, "Decisions"
/// 2): their megabytes ride `bulk`, never `control`, which is small messages on the lane.
const sendBulk = (obj: unknown) => {
  const c = channels.bulk; if (c && c.readyState === "open") c.send(encodeJson(obj) as Uint8Array<ArrayBuffer>);
};
// TEST-ONLY hook: a harness has no way to click a control it needs to drive from a script.
dbg.sendControl = sendControl;
/// AN IMAGE PATH IN THE TERMINAL OPENS HERE (term-paths.ts, file-viewer.ts): a tapped path asks the host for the file;
/// the image shows in a modal, a path that names none in a note.
const fileViewer = new FileViewer({
  send: (msg) => sendBulk(msg),
  showNote: (text) => statusNote.show(text), clearNote: (mark) => statusNote.clear(mark), flashNote: flashStatusNote,
  root: $("stage"),
  timers: { set: (fn, ms) => scope.timeout(fn, ms), clear: (t) => scope.clearTimeout(t as ReturnType<typeof scope.timeout>) },
});
scope.defer(() => fileViewer.dispose(), "file-viewer");
const sendInput = (obj: unknown): boolean => { const c = channels.input; if (!c || c.readyState !== "open") return false; c.send(encodeJson(obj) as Uint8Array<ArrayBuffer>); return true; };

// PASTE AND DROP (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md): the uploader carries a
// delivery's bytes on `bulk`, paced; `PasteUI` is what a person meets — the menus, the question, the notes.
const sourcePasteProgress = new Set<(sent:number,total:number,d:Delivery)=>void>();
const pasteUploader = new PasteUploader({
  channel: () => channels.bulk ?? null,
  send: sendBulk,
  onProgress: (sent, total, d) => {pasteUI.progress(sent,total,d);for(const listener of sourcePasteProgress)listener(sent,total,d);},
});
/// The "Sending…" note last written, so clearing it never clears a note written since.
let pasteProgressMark = 0;
/// A finger's selection in the terminal (touch-selection.ts) — made with the terminal, below.
let touchSelection: TouchSelection | null = null;
const pasteUI = new PasteUI({
  owner: opts.context?.ui,
  signal: scope.signal,
  // The DRIVER pastes — the tab bar's rule: the host refuses anyone else's.
  enabled: () => !termOutputBlocked && (sessionControl?.isActive ?? false),
  visibleTab: () => termDeck?.visibleId() ?? lastTermList.activeId,
  terminal: () => {
    const v = xtermView;
    return v ? { paste: (t) => v.term.paste(t), bracketed: () => v.term.modes.bracketedPasteMode } : null;
  },
  uploader: pasteUploader,
  note: flashStatusNote,
  // A failure is a message like any other since 2026-10-02 (asked): 6 s, held while a mouse is on it.
  fail: flashStatusNote,
  progress: (text) => {
    if (text !== null) pasteProgressMark = statusNote.show(text);
    else statusNote.clear(pasteProgressMark);
  },
  confirm: askPasteQuestion,
  // What Finder copied, as the app sees it (a browser is never told a path), and whether the host is this Mac.
  local: opts.context ? opts.context.platform.localPaste : localPasteApi((window as Window & { __rdevShell?: Parameters<typeof localPasteApi>[0] }).__rdevShell),
  sameMac: transport.sameMac,
  chooseFolder: askFolderChoice,
  hostTabs: () => ({ ids: lastTermList.tabs.map((t) => t.id), active: lastTermList.activeId }),
  // Exactly what a tap on a terminal tab does (terminal-tabs.ts): the terminal surface, and a switch when the
  // tab is not the one shown.
  showTab: (key) => {
    showTerminalSurface();
    if ((termDeck?.visibleId() ?? lastTermList.activeId) !== key) switchTerminal(key);
  },
  selection: () => touchSelection,
  copy: (text) => writeClipboard(text, (r) => { if (!r.ok) console.warn("[copy] clipboard write failed", r); }),
});
// TEST-ONLY, like `sendControl`: one delivery through the session's OWN uploader — the transport `PasteUI` hands
// every menu pick, picked file and drop to — resolving to the host's answer (`{ok, how}` or `{ok:false, reason}`).
// `e2e/paste-live-check.mjs` drives the real host with it: a desktop page has no finger to hold for the menu, a
// script cannot put files on a real drop, and the live check needs a delivery naming a tab that is NOT on screen.
dbg.paste = (d) => pasteUploader.deliver(d as Delivery);

// EVERY terminal keystroke NAMES the tab it is meant for, and the host refuses it when that is not the
// active tab (`TerminalManager.write(_:toTerminal:)`).
//
// `switch-terminal` travels on `control` while keystrokes travel on `input`: two independent streams — of one
// lane, or two SCTP channels on the baseline — ordered only against themselves. The host therefore has no
// arrival order to reason from, and used to write whatever arrived into whatever was active — so the keys
// typed around a tab switch landed in a shell the user was not looking at. A dropped keystroke is retyped; a
// password in the wrong shell is not recoverable.
//
// The claim is the tab the user SEES — the deck's visible tab, which a switch changes before the
// host's `term-list` confirms it (before the deck is mounted, the host's last announced `activeId`). With no terminal yet there is nothing to address and nothing is
// sent. Returns whether the keystroke went out — the xterm path needs that so it never predicts bytes
// it did not send.
// When the person last typed, and into which tab: a late history's rebuild waits for a pause (`rebuildWithHistory`).
let lastKey: { term: string; at: number } | null = null;
const sendKeyTo = (term: string | null, data: string): boolean => {
  if (term === null || termOutputBlocked) return false;
  if (!sendInput({ t: "key", data, term })) return false;
  lastKey = { term, at: performance.now() };
  return true;
};
const sendKey = (data: string): boolean => sendKeyTo(termDeck?.visibleId() ?? lastTermList.activeId, data);
dbg.sendKey = sendKey;
// A holder-backed stand-in for the input channel: attachPointer binds DOM listeners ONCE, but
// their sends must follow the live channel across a rebuild, so we hand them this proxy instead of a channel.
const inputProxy = { send(d: Uint8Array<ArrayBuffer>) { const c = channels.input; if (c && c.readyState === "open") c.send(d); } } as unknown as ChannelLike;

// Glasses terminal entry. Bound once here rather than inside the terminal mount, because the compose
// bar is plain markup that exists on every layout — it is CSS that reveals it — and `sendInput`
// already follows the live channel across a rebuild. Sends the same `{t:"key",data}` xterm's own
// onData sends, so the host sees no new message type.
mountCompose(
  {
    input: $("glasses-compose") as HTMLInputElement,
    chips: $("glasses-chips"),
    appCursor: () => xtermView?.appCursor() ?? false,
  },
  (data) => { sendKey(data); },
);

// The terminal's on-screen key strip. Mounted unconditionally and revealed by CSS — the same shape
// as the glasses compose bar, so no layout callback has to remember to build it, and `sendInput`
// already follows the live channel across a rebuild.
//
// Its modifiers are CLIENT-SIDE ONLY: nothing reaches the host until a key produces bytes, so unlike
// the window strip this one cannot leave a modifier stuck on the Mac.
const termMods = new HeldMods();
const termStrip = mountKeyStrip($("key-strip-term"), {
  row: TERMINAL_KEYS, more: TERMINAL_KEYS_MORE,
  drawer: {
    active: () => currentTab === "terminal",
    systemKeyboard: () => xtermView?.focus(),
    text: value => { sendKey(applyHeldMods(value, termMods.mask())); },
  },
  modState: (m) => termMods.state(m),
  onPress: (def) => {
    // The strip's own modifiers as xterm.js encodes the chord (terminal-keys.ts, `stripKeyBytes`).
    const bytes = stripKeyBytes(def as TermKeyDef, xtermView?.appCursor() ?? false, termMods.mask());
    if (!bytes) return;
    sendKey(bytes);
  },
  // Nothing goes on the wire: a terminal modifier only changes how the NEXT bytes are encoded, which
  // is why this strip can never leave a modifier stuck on the Mac.
  onModChange: (mod, down) => { if (down) termMods.down(mod); else termMods.up(mod); },
});
scope.defer(() => termStrip.destroy(), "term-strip");

let onChannelsBuilt = false;                                   // guards the one-time DOM construction
let bindTermChannel: ((ch: Channels) => void) | undefined;     // (re)binds the terminal listeners per channel
/// Drops the deck's tabs the host no longer lists — INSIDE the xterm branch's op chain, since it
/// disposes instances (term-deck.ts). Set by that branch.
let retainTermTabs: ((ids: Set<string>) => void) | undefined;
/// The page became visible: a terminal that stopped asking for a fresh wire (term-resync.ts) starts
/// over. Set by the terminal branch.
let termPageVisible: (() => void) | undefined;
let termStreamError: ((message: unknown) => boolean) | undefined;
/// This page became the driver / went passive (term-resync.ts, "a wire that never starts is asked for again"): a
/// driver's wire start is owed — a claim's rebind sends one, and one lost left every tab frozen behind "connected".
let termDriver: ((driving: boolean) => void) | undefined;
let clipboardEpoch: () => bigint | null = () => null;
const clipboardOffer = document.createElement('div');
clipboardOffer.className = 'toast'; clipboardOffer.hidden = true; clipboardOffer.setAttribute('role','status');
const clipboardCopy = document.createElement('button'); clipboardCopy.className = 'term-stream-reconnect';clipboardCopy.textContent = 'Copy';
clipboardOffer.append(document.createTextNode('Text copied in tmux. '),clipboardCopy);$('toasts').append(clipboardOffer);
const terminalClipboard = new TermClipboardReceiver({
  current: (term,epoch) => !released && sessionControl?.isActive === true && clipboardEpoch() === epoch &&
    lastTermList?.activeId === term && termDeck?.visibleId() === term,
  write: async text => {
    if(nativeShell?.writeClipboard){if(await nativeShell.writeClipboard(text))return;throw Error('Clipboard write refused');}
    if(navigator.clipboard?.writeText){await navigator.clipboard.writeText(text);return;}
    if(!execCommandCopy(text,document))throw Error('Clipboard permission requires a gesture');
  },
  offer: available => {clipboardOffer.hidden = !available;},
});
clipboardCopy.addEventListener('click',()=>{void terminalClipboard.retry();});
scope.defer(()=>{terminalClipboard.reset();clipboardOffer.remove();},'terminal-clipboard');
(dbg as unknown as {hostClipboard:()=>unknown}).hostClipboard=()=>terminalClipboard.stats;

// Central control-channel dispatch — reused across rebuilds; reads the module-level controllers/state.
function onControlMessage(e: MessageEvent): void {
  let msg: { t?: string; ts?: number; injectedAtEpochMs?: number };
  try { msg = decodeJson(new Uint8Array(e.data as ArrayBuffer) as Uint8Array<ArrayBuffer>); }
  catch { return; }
  if (sourceFocusGate?.receive(msg)) return;
  if (agentsView?.receive(msg)) return;
  if (termStreamError?.(msg)) return;
  const reference = parseReferenceMessage(msg);
  if (reference) {
    if (reference.t === "av1-ref-bind" && referenceSupported && reference.trackId) {
      referenceBindings.set(reference.source, reference);
      while (referenceBindings.size > 256) referenceBindings.delete(referenceBindings.keys().next().value!);
      watchAllPresentations(); tryReferenceBinding(reference.source);
    } else if (reference.t === "av1-ref-frame") referenceReceipts.notice(reference);
    else if (reference.t === "av1-ref-reset") { referenceBindings.delete(reference.source); referenceReceipts.reset(reference.source); }
    return;
  }
  if (hostUpdateUI.receive(msg)) return;
  if (fileViewer.handle(msg)) return;
  const cs = parseControlState(msg);
  if (cs) {
    hostUpdateUI.controlReady();
    if (!cs.active) { everPassive = true; referenceReceipts.resetAll(); referenceBindings.clear(); }
    for (const id of ["palette-open", "tab-add"]) ($(id) as HTMLButtonElement).disabled = !cs.active;
    nativeControlSeen = true;
    sessionControl?.apply(cs); sourceFocusGate?.setDriving(cs.active);
    agentsView?.setActive(cs.active);
    renderAgentTabs();
    if(cs.active&&lastViewSet.view.surface==="agents"&&lastViewSet.selectedAgent)agentsView?.showSession(lastViewSet.selectedAgent);
    if(!cs.active)terminalClipboard.reset();
    if (nativeSources) syncVideo({ kind: "other" });
    reconcileSimVisibility();
    // EVERY "passive", not only a change to it: a page whose claim was overridden at once may have seen that claim's
    // wire start without ever being told it drove — and a later claim's wire must not be taken as already started.
    if (!cs.active) termDriver?.(false);
    return;
  }
  const tl = parseTermList(msg);
  if (tl) {
    // An agent's turn ended in a tab nobody is looking at: marked as an unseen bell is (term-bell.ts — the dot, the
    // title, the favicon, the Dock). A tab being looked at is no news (`ring`).
    const finished = agentsFinished(lastTermList, tl);
    lastTermList = tl;
    // An agent's tab has no trailing blank lines (trailing-blanks.ts) — read from every list, as the shimmer is.
    termDeck?.setAgentTabs(agentTabs(tl));
    dbg.termList = tl;
    if (!termListed) {
      termListed = true;
      skeleton.listed();
      // The offer's tabs stood in until now. Whether this client drives is `control`'s word from here: the offer may
      // have called it the driver and control moved on the way, and `SessionControl` fires nothing for a first
      // "passive".
      if (early) terminalTabs?.setActive(sessionControl?.isActive ?? false);
      markEarlyTabs();
    }
    // The offer's screen was the active tab's; a list naming another (or none) is a terminal it will not show — and a
    // passive client shows none (its first word from `control` may be "passive", which fires no transition).
    if (termPreview.tab !== null && (termPreview.tab !== tl.activeId || !sessionControl?.isActive)) termPreview.remove();
    // The tab shown ahead of the host's list IS the one it now names: the strip keeps its element, the deck
    // moves to its id if it was still showing it.
    const named = opening ? resolveOpening(opening, tl) : null;
    if (opening && named !== null) {
      const was = opening.key;
      if (named !== was) terminalTabs?.rekey(was, named);
      opening = null;
      scope.clearTimeout(openingTimer);
      if (termDeck?.visibleId() === was && named !== was) termDeck.show(named, "user");
    }
    // A local open's tab, named: now its first content (at once if it has it — `finish` runs here, before the
    // strip below draws).
    if (syncOpen && syncOpen.tab === null) {
      const s = syncOpen, tab = resolveOpening(s.opening, tl);
      if (tab !== null) { s.tab = tab; s.cancelWait = termDeck?.whenContent(tab, () => s.finish()) ?? (() => {}); }
    }
    if (termDeck) {
      // The list drives the strip; it disposes only slots no snapshot reached on the current wire
      // (TermDeck.retain) — on the live wire only the wire's own `closed` does.
      retainTermTabs?.(new Set(tl.tabs.map((t) => t.id)));
      pendingSwitch = pendingAfterTermList(pendingSwitch, tl);
      // The host moved the active tab itself (a new tab, a closed neighbour): follow it — not while a tab the
      // driver picked is still on its way (the list predates it).
      const show = opening || syncOpen ? undefined : tabToShowAfterTermList(pendingSwitch, termDeck.visibleId(), tl.activeId);
      if (show !== undefined) termDeck.show(show);
    }
    terminalClipboard.refresh();
    dropVanishedRename();
    bells.retain("terminal", new Set(tl.tabs.map((t) => t.id)));
    if (finished.length > 0 && sessionControl?.isActive) for (const id of finished) bells.ring("terminal", id);
    terminalTabs?.update(stripList(termDeck?.visibleId() ?? tl.activeId));
    renderTermEmpty();
    if (sessionControl?.isActive) scope.raf(() => termDeck?.fit());
    return;
  }
  const apps = parseAppsState(msg);
  if (apps) { lastApps = apps; dbg.apps = apps; refreshPaletteItems?.(); return; }
  const sl = parseSourceList(msg);
  if (sl) {
    lastSources = sl.sources;
    syncVideo({ kind: "other" });
    lastDisplay = sl.display ?? null;
    dbg.sources = lastSources;   // Task 10 multi-source smoke: locate a picker row by source id
    // Point sizes for actual-size rendering. Sims carry none; a source without one keeps the fallback width.
    for (const s of sl.sources) if (typeof s.w === "number" && typeof s.h === "number") windowManager?.setSourceSize(s.id, s.w, s.h);
    refreshPaletteItems?.();   // no-op unless the palette is open; fills it in if the list landed late
    renderWindowTabs();   // source names may have arrived/changed (id-fallback labels resolve)
    maybeAutoSubscribe();
    return;
  }
  const parsedView = parseViewSet(msg);
  const vs = parsedView && supportedViewSet(parsedView);
  if (vs) {
    const prevViewSet = lastViewSet;
    // A WINDOW-LESS SESSION TAKES NOTHING FROM THE VIEW SET BUT THE RECORD: the windows, their full
    // screen and the surface are the windowed devices', and following them here would create windows
    // it cannot show and switch it to a surface it does not have. `stateView` stays null, so it never
    // states a view of its own (`sendView` waits for one).
    // The bar's ORDER it does take: its terminal tabs are in it.
    if (windowless) { lastViewSet = vs; dbg.viewSet = vs; everReceivedViewSet = true; markEarlyTabs(); applyTabOrder(); return; }
    lastViewSet = vs;
    agentsView?.syncTabs((vs.agents??[]).map(a=>a.id));
    bells.retain("agent",new Set((vs.agents??[]).map(a=>`agent:${a.id}`)));
    for(const a of vs.agents??[])if(agentReady(a)&&prevViewSet.agents?.some(old=>old.id===a.id&&agentWorking(old)))bells.ring("agent",`agent:${a.id}`);
    renderAgentTabs();
    if (nativeSimulators) {
      dbg.viewSet = vs; everReceivedViewSet = true; stateView = vs.view;
      markEarlyTabs(); dropVanishedRename(); renderWindowTabs();
      if (vs.view.surface === "terminal") showTerminalSurface();
      else if(vs.view.surface==="agents"&&vs.selectedAgent)agentsView?.showSession(vs.selectedAgent);
      else if(vs.view.surface==="windows")agentsView?.hide();
      maybeAutoSubscribe(); return;
    }
    dropVanishedRename();
    // BIND EVERY SUBSCRIPTION'S INDEX, INCLUDING CLEARING IT. `activeDelivery` is what the host DID,
    // so a source that asked for the channel and got RTP arrives here as `rtp` and must be UNBOUND —
    // otherwise its stale feed keeps a decoder window open and routes frames to a window that is
    // rendering from the RTP path instead.
    for (const sub of vs.subs) {
      const index = sub.activeDelivery === "dc" && sub.dcIndex !== undefined ? sub.dcIndex : null;
      dcDelivery.setSourceIndex(sub.source, index);
      // A REFUSAL IS RECORDED, NOT JUST OBSERVED. `activeDelivery` is what the host DID, so `"rtp"`
      // here against a client that asked for `"dc"` is the host declining — and the pacer for that
      // source is already built for a feed it will never receive. Remembering it stops the next
      // subscribe asking again, which is what turns a stall loop into one downgrade.
      //
      // `undefined` is NOT a refusal: absent means the host has not resolved the delivery yet.
      if (sub.activeDelivery === "rtp" && requestedDelivery(sub.source) === "dc") {
        // ASK BEFORE CONCLUDING YOU WERE REFUSED. A window the host RESTORED took this connection's
        // delivery from its `client-hello`; the assertion stays as the net for a host that answered
        // before the hello could apply. Asserting is idempotent — `addVideo` re-routes an existing track.
        const assertedAt = deliveryAsserted.get(sub.source);
        if (assertedAt === undefined) {
          deliveryAsserted.set(sub.source, performance.now());
          console.info(`[dc] asserting the channel for ${sub.source}`);
          sendControl({ t: "subscribe", source: sub.source, delivery: "dc" });
        } else if (performance.now() - assertedAt > DELIVERY_REFUSAL_GRACE_MS) {
          deliveryRefused.add(sub.source);
          console.warn(`[dc] host refused the channel for ${sub.source} — staying on RTP`);
        }
      } else if (sub.activeDelivery === "dc") {
        deliveryAsserted.set(sub.source, performance.now());   // settled; nothing more to ask for
      }
      // WHAT THIS SOURCE ACTUALLY ENDED UP ON, once per source, in the host's log.
      //
      // Three explanations for a client that wants the channel and gets RTP are indistinguishable
      // from the host side today: it never asked, it asked and was refused, or it never had the
      // chance to ask because it INHERITED the subscription. The first two show up in `[channel]`;
      // the third is invisible everywhere, and it is the one the assertion above cannot reach — that
      // fires only on an explicit `activeDelivery: "rtp"`, while an unresolved delivery is ABSENT,
      // and absent is not "rtp".
      // KEYED BY THE OUTCOME, NOT BY THE SOURCE. Reporting once per source caught the FIRST
      // `view-set`, which legitimately arrives before the host has resolved the delivery — so it
      // recorded `unresolved` and then never spoke again, turning a transient into a permanent
      // finding. Keying by the pair means the transition itself is reported: at most one line per
      // state a source actually passes through, and `unresolved` followed by nothing is then a real
      // observation rather than an artefact of when the instrument happened to look.
      const outcome = `${sub.source}:${sub.activeDelivery ?? "unresolved"}`;
      if (!deliveryReported.has(outcome)) {
        deliveryReported.add(outcome);
        sendControl({ t: "rx-stats", line: `delivery ${sub.source}: asked=${requestedDelivery(sub.source)}`
          + ` active=${sub.activeDelivery ?? "unresolved"}` });
      }
    }
    // Session-wide, so it goes to the manager rather than through the per-source view list; every
    // open titlebar reflects it at once.
    windowManager?.setRecoveryOverride(vs.recoveryOverrideBp ?? null);
    windowManager?.setPlayoutDelayMin(vs.playoutDelayMinMs ?? null);
    // HOST state, not client intent — so it is reflected FROM the host and deliberately absent from
    // controlOpenMessages. Re-asserting it on reconnect would raise a curtain the user had lowered
    // from somewhere else. `?? null` keeps absent meaning UNKNOWN, which disables the control.
    windowManager?.setCurtainUp(vs.curtainUp ?? null);
    // Re-render the footer: the recovery stack arrives on view-set, not on a stats tick, so waiting
    // would leave a degraded connection unlabelled for up to a second.
    renderStatus(lastStatsReport);
    dbg.viewSet = lastViewSet;   // Task 10 multi-source smoke: read the current focus without a DOM hook
    everReceivedViewSet = true;
    markEarlyTabs();
    // subscription may now point at an already-arrived stream (or nothing); this is also the ONE
    // sync allowed to forget streams, because this view-set is the evidence
    // WHERE THE SESSION REMEMBERS EACH WINDOW, before any window this view-set creates — `create` reads it.
    windowManager?.setStatePositions(vs.windows);
    // THE HOST LANDED THE PERSON ON A TERMINAL TAB (`SessionState.landing`): the window they were at went
    // and the tab to its left is a terminal — its `term-list` came first. The surface goes FIRST, so the
    // window's keys are handed to a terminal that is on screen (a hidden one cannot take focus) and to it
    // rather than to the next window, whose surface a phone no longer shows.
    const landed = landedOnTerminal(prevViewSet, vs);
    if (landed) followStateView(vs.view);
    syncVideo({ kind: "view-set", subscribed: subscribedSources(vs) },
              landed ? (typing) => { termDeck?.takeWindowKeys(typing); } : undefined);
    const curs = subscribedSources(vs);
    renderWindowTabs();   // the view-set is authoritative for the tab strip's entries + focus highlight
    // A window that left the session takes its bell with it; one now focused, on screen, is seen.
    bells.retain("window", new Set(vs.windows.map((w) => w.source)));
    bells.look();
    // THE VIEW, after the windows exist: a restored full screen needs its window.
    followStateView(vs.view);
    reconcileSimVisibility();   // authoritative show/hide (active AND subscribed)
    maybeAutoSubscribe();
    // Unsubscribed (nothing left in the set) → the incoming stream(s) stop; clear the rx-rate readout
    // immediately (don't wait out the poll interval showing a stale bitrate, which reads as "traffic isn't
    // zero" right after hiding).
    if (curs.length === 0) { rxMeter = makeRxBitrateMeter(); void refreshIceLabel(); }
    const prefs = subscribedPrefs(vs);
    if (prefs) { lastVideoPrefs = prefs; }
    else    // nothing subscribed → disable prefs
    return;
  }
  // Cursor passthrough: the host app's current cursor shape (sent only when it changes). The client's own
  // pointer wears it via CSS, so there is no position to apply and nothing to clear on leave.
  const cur = msg as { t?: unknown; data?: unknown; data3x?: unknown; w?: unknown; h?: unknown; hotspotX?: unknown; hotspotY?: unknown };
  if (cur && cur.t === "cursor") {
    if (typeof cur.data === "string" && typeof cur.hotspotX === "number" && typeof cur.hotspotY === "number") {
      const overlay = typeof cur.data3x === "string" && typeof cur.w === "number" && typeof cur.h === "number"
        && Number.isFinite(cur.w) && Number.isFinite(cur.h) && cur.w > 0 && cur.h > 0
        ? { url: `data:image/png;base64,${cur.data3x}`, w: cur.w, h: cur.h } : undefined;
      windowManager?.setCursor(`data:image/png;base64,${cur.data}`, cur.hotspotX, cur.hotspotY, overlay);
    }
    return;
  }
  const ss = parseSourceStatus(msg);
  if (ss) {
    // Full snapshot each message → replace the whole map. Entries for unsubscribed windows aren't pruned here,
    // but overlays only apply to windows still present, and a re-subscribe rebroadcasts a fresh snapshot.
    sourceLiveness = new Map(ss.statuses.map((s) => [s.id, s.live]));
    sourceSimStates = new Map(ss.statuses.flatMap((s) => (s.simState ? [[s.id, s.simState] as const] : [])));
    windowManager?.setSimStates(sourceSimStates);
    windowManager?.setLiveness(sourceLiveness);
    // A status entry without a size means "liveness only" — leave the remembered size alone.
    // Each size field is independent and means UNKNOWN when absent — the baseline status a client gets on
    // control-open carries PIXELS alone, the liveness monitor's pushes carry neither. Pixels first: it can
    // unblock Auto by itself, and setSourceSize recomputes off whatever is known by then.
    for (const st of ss.statuses) {
      if (typeof st.pxW === "number" && typeof st.pxH === "number") windowManager?.setSourcePixelSize(st.id, st.pxW, st.pxH);
      if (typeof st.w === "number" && typeof st.h === "number") windowManager?.setSourceSize(st.id, st.w, st.h);
    }
    return;
  }
  const th = parseSourceThumb(msg);
  if (th) {
    const entry: ThumbEntry = th.unavailable ? { unavailable: true } : { dataUrl: th.dataUrl! };
    thumbs.set(th.id, entry);
    // TEST-ONLY, for `e2e/capture-boundary.spec.ts`. Thumbnails reach a client that subscribed to
    // NOTHING, which makes them the cheapest way to see a source you were never granted — so the gate
    // has to read every one of them, and reading them off the palette's `<img>` tiles instead would
    // measure lazy loading as much as the boundary.
    dbg.thumbs = () => [...thumbs.entries()].map(([id, e]) => ({ id, dataUrl: "dataUrl" in e ? e.dataUrl : null }));
    refreshPaletteItems?.();   // no-op unless the palette is open; fills the grid in as snapshots land
    return;
  }
  const tml = parseTmuxList(msg);
  if (tml) {
    lastTmuxList = tml;
    $("term-empty-new-tmux").classList.toggle("hidden", !tml.available);
    refreshPaletteItems?.();
    return;
  }
  const tc = parseTmuxClosed(msg);
  if (tc) { flashStatusNote("tmux session ended"); return; }
  // THE HOST'S BELL: a BEL in output that reached no xterm.js here (this page hidden, its terminal paused).
  const tb = parseTermBell(msg);
  if(terminalClipboard.receive(msg))return;
  if (tb) {
    const tab = hostBellTab(tb, lastTermList, sessionControl?.isActive ?? false);
    if (tab !== null) bells.ring("terminal", tab);
    return;
  }
  const wb = parseWindowBell(msg);
  if (wb) {
    bells.ring("window", ...hostBellWindows(wb, lastViewSet.windows, sessionControl?.isActive ?? false, windowless));
    return;
  }
  const tre = parseTermError(msg);
  if (tre) {
    termDeck?.cancelOpenedPty();                               // that shell is not coming: it focuses nothing
    if (opening && "kind" in opening.req && opening.req.kind !== "tmux") cancelOpening();
    // ⌘⇧T with nothing closed does nothing, as a browser's does.
    if (tre.reason === "nothing-to-reopen") return;
    flashStatusNote(tre.reason === "too-many-tabs" ? tmuxErrorText("too-many-tabs") : `terminal: ${tre.reason}`);
    return;
  }
  const te = parseTmuxError(msg);
  if (te) {
    if (te.reason === "rename-failed") {
      // A RENAME tmux refused (a name already taken) leaves the tab and its session as they were: no
      // pending open of that session is void, and the name shown ahead of the echo goes now.
      if (te.session !== null) pendingTabs.refused(`tmux:${te.session}`);
      terminalTabs?.refresh();
      armPendingTabsExpiry();
    } else {
      termDeck?.cancelOpenedTmux(te.session);                  // that tab is not coming: it focuses nothing
      const refused = (r: OpenRequest | undefined) =>
        !!r && ("id" in r ? te.session !== null && r.id === `tmux:${te.session}` : r.kind === "tmux" && te.session === null);
      if (refused(opening?.req)) cancelOpening();
      if (refused(syncOpen?.opening.req)) syncOpen!.fail();
    }
    flashStatusNote(tmuxErrorText(te.reason));
    return;
  }
  const pr = parsePasteReply(msg);
  if (pr) { pasteUI.onReply(pr); return; }
  const status = parseSimStatus(msg);
  if (status) {
    // A phase is a STATE until the next status; an error is a message. A later status clears only the
    // phase it showed, never a note written since (a paste's failure).
    if (status.phase === "booting" || status.phase === "attaching") simPhaseMark = statusNote.show(`${status.phase}…`);
    else if (status.phase === "error") flashStatusNote(`error: ${status.message ?? "failed"}`);
    else statusNote.clear(simPhaseMark);
    return;
  }
  if (msg.t === "inputAck" && typeof msg.ts === "number" && typeof msg.injectedAtEpochMs === "number") {
    dbg.inputLatencyMs = Math.round(msg.injectedAtEpochMs - (performance.timeOrigin + msg.ts));
  }
}

function onControlOpen(): void {
  terminalClipboard.reset();
  if (sourceFocusGate) { nativeControlSeen = false; sourceFocusGate.setDriving(false); sourceFocusGate.open(); sourceFocusGate.activate(nativeSources?.activeKey() ?? null); }
  // The ordering rule lives in controlOpenMessages, where it is testable. It states the CONNECTION;
  // the session is the host's and arrives in `view-set` / `term-list`.
  if (nativeSimulators) sendControl({ t: "list-sources" });
  for (const m of controlOpenMessages({ appsPackedV1: workspaceSupported, av1ReferenceAck: referenceSupported ? 1 : undefined, windowless: !transport.carriesMedia, intendedRecoveryBp,
                                        intendedPlayoutWindowMs: (windowManager?.playoutDelayIsAuto() ?? false) && playoutWindow.active ? playoutWindow.sizeMs : null,
                                        intendedPlayoutDelayMs, delivery: requestedDelivery(),
                                        termPalette: termPaletteMessage(currentTheme()),
                                        pageHidden: mediaHidden(), prefs: clientPrefs })) {
    sendControl(m);
  }
  // THE HOST HOLDS NO DERIVED VALUE FROM A NEW CONNECTION (CONTRACT ISSUE 3): every window reports its
  // own Auto ceiling and crop again — after the hello, so they land on a driver the host has set up.
  windowManager?.resendDerived();
  // A Move here still wanted is said on the new channel — after the hello (the host reconciles a claimer on it).
  sessionControl?.reclaim();
  agentsView?.connectionReset();
}

/// The source's RTCRtpReceiver, for `?render=webcodecs` only — an encoded transform attaches to the
/// RECEIVER, which nothing else in the client needs. Keyed by MSID like `streamsBySource`; a codec
/// change hands over a fresh receiver under the same key, which is exactly what should happen.
const receiversBySource = new Map<string, RTCRtpReceiver>();

/// WebCodecs pacers, one per source, keyed by MSID. OWNED HERE RATHER THAN BY WindowManager because
/// `RTCRtpScriptTransform` must be attached before RTP starts flowing — set late it never receives at
/// all — and that is at `ontrack`, long before the window exists. WindowManager only supplies the
/// canvas once it does.
const webcodecsPacers = new Map<string, PacedRenderHandle>();
// Warmed at module init, long before any negotiation — see decode-worker-pool.ts.
if (renderMode === "webcodecs") warmDecodeWorkers();

/// Per-source audio playback. Kept beside `streamsBySource` rather than inside it, because an audio
/// stream must never reach `syncVideo` — see `onTrack`.
const audioPlayback = new AudioPlayback(opts.context?.ui);
scope.defer(() => audioPlayback.detachAll(), "audio");

// ONE UNLOCK FOR EVERYTHING, NOT ONE PER WINDOW. Browsers block audible playback until a user
// gesture; the requirement is A gesture, not a particular control, so any tap or keypress anywhere
// retries every element that is waiting. rdev has no shortage of them — claiming, a tab click, a
// tap on a window — and a per-window prompt would ask the user to satisfy the same rule N times.
//
// PASSIVE, and it never calls preventDefault: this must not alter what the gesture was actually for.
for (const evt of ["pointerdown", "keydown"] as const) {
  scope.listen(document, evt, (e) => {
    if (opts.context && !opts.context.input.owns(e)) return;
    if (!audioPlayback.blocked) return;
    void audioPlayback.retryBlocked().then(scope.guard(() => { dbg.audioBlocked = audioPlayback.blocked; }));
  }, { passive: true });
}

function onTrack(stream: MediaStream, receiver?: RTCRtpReceiver, negotiatedTrackId?: string): void {
  // ROUTED ON track.kind, WHICH IS AUTHORITATIVE; the MSID only NAMES the source.
  //
  // An audio stream must NEVER reach `streamsBySource` — `syncVideo` would try to bind it to a
  // window — and keying the decision on the id's `audio:` prefix instead would make a naming
  // convention carry a correctness property. The prefix is used only to recover the source id.
  const isAudio = receiver?.track?.kind === "audio" || stream.getAudioTracks().length > 0;
  if (isAudio) {
    const source = sourceIdFromAudioStream(stream.id);
    if (source) {
      unlistedStreams.arrived(source, lastViewSet !== null && subscribedSources(lastViewSet).includes(source));
      audioPlayback.attach(source, stream);
      dbg.audioBlocked = audioPlayback.blocked;
    }
    return;
  }
  onVideoTrack(stream, receiver, negotiatedTrackId);
}

function onVideoTrack(stream: MediaStream, receiver?: RTCRtpReceiver, negotiatedTrackId?: string): void {
  // The host sets MediaStream.id to the sourceID (its MSID); key the incoming stream by it so syncVideo can
  // bind it to the matching window. syncVideo also (re)points the latency probe at the focused window's video.
  // (A track can arrive before the data channels open — i.e. before WindowManager exists — so buildChannelUi
  // re-runs syncVideo once the manager is constructed to catch the already-arrived stream.)
  const track = receiver?.track ?? stream.getVideoTracks()[0];
  if (track) {
    referenceTracks.set(stream.id, track);
    if (negotiatedTrackId) referenceTrackIDs.set(track, negotiatedTrackId);
  }
  streamsBySource.set(stream.id, stream);
  unlistedStreams.arrived(stream.id, lastViewSet !== null && subscribedSources(lastViewSet).includes(stream.id));
  if (receiver) {
    receiversBySource.set(stream.id, receiver);
    if (renderMode === "webcodecs" && !renderFallback.has(stream.id)) startWebCodecsCapture(stream.id, receiver);
  }
  syncVideo({ kind: "track" });
}

/// THE FAST PATH HAS FAILED FOR THIS SOURCE — put it on the `<video>` element and say so.
///
/// This is the safety net the default flip needed and did not have. While WebCodecs was opt-in, a
/// dead renderer printed "reload, or drop ?render=webcodecs" and stopped, which was actionable
/// because a parameter had put you there. As the DEFAULT it is not: a browser whose WebCodecs
/// cannot decode the negotiated codec — a real possibility for AV1 on Safari — got a permanently
/// black window and advice it could not follow.
///
/// NOT SILENT, which is the constraint `webcodecs-pacer.ts` states and is right to state: a quiet
/// fallback means believing you measured WebCodecs while watching the ordinary path. It is logged,
/// sent to the host so it lands in the log beside `[rx]`, and left readable on `__rdev`.
///
/// THE HOST HAS TO BE TOLD, and that is the half easy to forget: on the DataChannel path the host is
/// routing frames to the channel and writing no RTP, so restoring the element without asking for RTP
/// back swaps a black canvas for a black video.
function fallBackToVideo(source: string, reason: string): void {
  if (!renderFallback.fallBack(source, reason)) return;
  console.error(`[render] ${source} falling back to the video element: ${reason}`);
  webcodecsPacers.get(source)?.stop();
  webcodecsPacers.delete(source);
  windowManager?.failPacer(source);
  sendControl({ t: "rx-stats", line: `render fell back to <video> for ${source}: ${reason}` });
  if (requestedDelivery(source) === "dc") {
    deliveryRefused.add(source);
    deliveryAsserted.delete(source);
    // DROP THE FEED HERE, rather than waiting for the `view-set` that confirms the re-route to do it.
    //
    // Observed in a real session: after this fallback fired, `[dc-rx]` went on printing byte-identical
    // frozen counters every five seconds for the rest of the run — emitted stuck at 777, a loss figure
    // climbing to 53.93% purely because `span - emitted` grows while the host keeps sending. It read
    // as an ongoing catastrophic link while nothing was happening at all, and the RTP path beside it
    // was losing 1.5%.
    //
    // Depending on the echo is the mistake: this client has decided, so this client clears. The
    // `view-set` handler still clears it too, and both are idempotent.
    dcDelivery.setSourceIndex(source, null);
    sendControl({ t: "subscribe", source, delivery: "rtp" });
  }
  // "connected" rather than "error": the window WORKS after this, just not on the fast path. Saying
  // error would report a broken session to someone watching a perfectly good picture.
  setStatus("connected", "Connected — this window is on the standard video path");
}

/// Attach the encoded transform for one source, replacing any pacer already bound to an older
/// receiver. A codec change (or an unsubscribe/resubscribe) removes the track and adds a fresh one,
/// so this runs again with a NEW receiver — and the old transform must be torn down or two workers
/// race over one source and the dead one holds a decoder for the life of the page.
/// Consecutive stall recoveries per source, so a recovery that cannot work stops trying. Cleared
/// whenever frames flow again (see startPacerWithWorker).
const stallRecoveries = new Map<string, number>();
const MAX_STALL_RECOVERIES = 3;
let webcodecsCaptureCount = 0;
function startWebCodecsCapture(source: string, receiver: RTCRtpReceiver): void {
  webcodecsCaptureCount++;
  console.info(`[render] webcodecs capture #${webcodecsCaptureCount} for ${source}`);
  webcodecsPacers.get(source)?.stop();
  webcodecsPacers.delete(source);
  const pooled = takeDecodeWorker();
  if (!pooled) { console.error(`[render] no warmed decode worker left for ${source}`); return; }
  replaceDecodeWorker();                 // keep the pool stocked for the next track
  // AWAIT READINESS — the pool's whole contract. `startWebCodecsPacer` installs the transform
  // immediately, and installing it on a worker that has not yet evaluated its module fails SILENTLY:
  // `onrtctransform` never fires while `receiver.transform` reads set on the correct live track. The
  // pool warms workers at page load so this normally resolves instantly; awaiting is what makes that
  // a guarantee rather than a hope.
  void pooled.ready.then(() => {
    // The session went while the worker booted: it belongs to nobody, so it is terminated here.
    if (scope.disposed) { pooled.worker.terminate(); return; }
    startPacerWithWorker(source, receiver, pooled.worker);
  });
}

function startPacerWithWorker(source: string, receiver: RTCRtpReceiver, worker: Worker): void {
  const { map, fallback } = codecMapForSource(source);
  const handle = startWebCodecsPacer(receiver, worker, {
    marginMs: paceMarginMs,
    cadenceLock,
    probe: probeOn,
    forward: params.get("fwd") !== "0",
    // SPIKE (`?carrier=1`): RTP as a packet transport. The browser's decoder is fed one stashed
    // keyframe per second rather than the real stream, so the payload is ours alone.
    carrier: params.get("carrier") === "1",
    // The transform is installed only when this source is delivered over RTP. On the DataChannel
    // path the frames arrive through `dcDelivery` instead, and installing a transform as well would
    // hand the decoder every frame twice.
    // THE REQUEST, NOT THE BINDING. `deliversSource` reads the index map, which is filled by the
    // host's `dc-map` and by `view-set` — both of which can arrive AFTER `ontrack`. Reading it here
    // made the feed a race: a pacer built a few milliseconds early installed a transform for a source
    // the host was about to deliver over the channel, or the reverse. What this client ASKED for is
    // known synchronously and cannot race, and a refusal is handled by `deliveryRefused` above.
    feed: requestedDelivery(source) === "dc" ? "datachannel" : "transform",
    codecMap: map,
    fallbackCodec: fallback,
    // The host's restored `request-keyframe`. It debounces per source AND defers rather than drops,
    // so asking often is safe; the client debounces too, to keep a burst of decode errors off the
    // control channel.
    requestKeyframe: () => sendControl({ t: "request-keyframe", source }),
    // FATAL FOR THE RENDERER, NOT FOR THE WINDOW. The decoder is gone for good — an unsupported
    // codec, or a config this browser refuses — and the ordinary path decodes the same stream.
    onFatal: (reason) => fallBackToVideo(source, reason),
    // A stall is RECOVERABLE, unlike a fatal: rebuild capture from scratch — a fresh worker, a fresh
    // transform — and let the window re-attach its canvas. The receiver is unchanged, so
    // WindowManager has to be told to rebind, or it sees the same receiver and leaves the dead
    // handle in place.
    // RECOVERY IS A RESUBSCRIBE, NOT A REBUILD.
    //
    // A new worker on the SAME receiver does not work: once an RTCRtpScriptTransform has been
    // detached, that receiver delivers nothing to a replacement — measured, `incoming` stays 0
    // through thirty rebuild attempts. Only a NEW receiver carries a working transform, and the only
    // way to get one is to have the host remove and re-add the track.
    //
    // That is a renegotiation and costs about a second of video, which is the right trade against a
    // window that is dead until the page is reloaded.
    onStall: () => {
      // BOUNDED. A recovery that cannot work must not run forever: resubscribing every four seconds
      // for the life of the page is noise that hides the real failure and churns the host's encoder.
      const n = (stallRecoveries.get(source) ?? 0) + 1;
      stallRecoveries.set(source, n);
      if (n > MAX_STALL_RECOVERIES) {
        fallBackToVideo(source, `stalled and ${MAX_STALL_RECOVERIES} recoveries did not fix it`);
        return;
      }
      // A DataChannel FEED NEEDS NO NEW TRACK, and resubscribing for one is actively harmful.
      //
      // The resubscribe above exists for ONE reason: a detached RTCRtpScriptTransform cannot be
      // replaced on the same receiver, so only a fresh track carries a working one. The DataChannel
      // path installs no transform — frames arrive on the channel, entirely independently of the
      // receiver — so the whole renegotiation buys nothing here, and it costs plenty: it is what
      // trips the bridge's offer-coalescing defect, where the second of two rapid subscribes reads
      // as a peer rebuild and the track comes back delivering nothing. Observed as three
      // resubscribes, three dead tracks, and `routed=1 sent=0` on the host.
      //
      // Rebuilding the decoder in place keeps the subscription, the track and the channel binding.
      if (requestedDelivery(source) === "dc") {
        console.warn(`[render] webcodecs stalled for ${source} — rebuilding the decoder in place (${n}/${MAX_STALL_RECOVERIES})`);
        windowManager?.releasePacer(source);
        startWebCodecsCapture(source, receiver);
        return;
      }
      console.warn(`[render] webcodecs stalled for ${source} — resubscribing for a fresh track (${n}/${MAX_STALL_RECOVERIES})`);
      webcodecsPacers.get(source)?.stop();
      webcodecsPacers.delete(source);
      windowManager?.releasePacer(source);
      // A FRESH TRACK WITHOUT TOUCHING THE SESSION (CONTRACT ISSUE 2). Unsubscribe-then-subscribe used to
      // get it, and under the host's session state that CLOSES the window — it leaves the state, losing
      // its place in the tab order, its position and its minimized flag — then opens a new one at the
      // end. `reattach-source` asks the host to remove and re-add this driver's track alone.
      sendControl({ t: "reattach-source", source });
    },
  });
  if (handle) {
    webcodecsPacers.set(source, handle);
    // A working attach clears the budget: the count exists to stop a HOPELESS loop, not to cap how
    // many times a long session may legitimately recover.
    let seen = 0;
    const clear = scope.interval(() => {
      const s = handle.stats() as { incoming?: number };
      if ((s.incoming ?? 0) > seen + 60) { stallRecoveries.delete(source); scope.clearInterval(clear); }
      seen = s.incoming ?? 0;
    }, 2000);
    scope.timeout(() => scope.clearInterval(clear), 30_000);
    // Give it a canvas immediately. On the first attach the window may not exist yet, in which case
    // `sync` picks it up; on a stall rebuild it does exist and there is no view-set coming.
    windowManager?.attachPacer(source);
  }
}

/// The negotiated payload-type -> WebCodecs codec map, read from OUR OWN local description (the
/// answer). Computed on demand rather than cached: a codec change renegotiates, and a stale map would
/// configure the decoder for the codec we used to receive.
function codecMapForSource(source: string): { map: Map<number, string>; fallback: string | null } {
  const sdp = connection?.media?.localSdp() ?? "";
  const map = parsePayloadTypeMap(sdp);
  // The fallback is only reached on an engine whose frame metadata omits `payloadType`. `view-set`'s
  // activeCodec is what the host RESOLVED, which is the same question asked a different way.
  const active = lastViewSet.subs.find((s) => s.source === source)?.activeCodec;
  const fallback = active ? webCodecsStringFor(`video/${active}`) : null;
  return { map, fallback };
}

function onChannels(chs: Channels): void {
  const { terminal, input, control, bulk } = chs;
  channels = { terminal, input, control, bulk };
  control.binaryType = "arraybuffer";
  terminal.binaryType = "arraybuffer";
  bulk.binaryType = "arraybuffer";

  if (!onChannelsBuilt) {
    onChannelsBuilt = true;
    buildChannelUi(chs);   // one-time DOM construction (first connect — behaviorally identical to before)
  } else {
    // Rebuild: re-point the claim sender at the live control channel + refresh the active-gated UI. DOM
    // listeners are NOT re-added; the sim/prefs callbacks already send through the `channels` holder.
    sessionControl?.rebind(control);
    terminalTabs?.update(stripList(termDeck?.visibleId() ?? lastTermList.activeId));
  }

  // Per-channel listeners: (re)bound on every onChannels — each rebuild has fresh channel objects, so this
  // can't double-bind a live channel. The central control dispatch + the terminal bindings both go here.
  control.addEventListener("message", onControlMessage);
  control.addEventListener("close", () => { if (channels.control === control) { nativeControlSeen = false; sourceFocusGate?.close(); } }, { signal: scope.signal });
  // At once if it is ALREADY open (`whenOpen`): the SCTP baseline's `control` opens before `bulk` completes the set,
  // and a lane's streams read open at the hand-over — an `open` listener alone would miss it and send no batch.
  whenOpen(control, onControlOpen);
  // The paste and image replies arrive on `bulk`; the control dispatch reads them by CONTENT, as before.
  bulk.addEventListener("message", onControlMessage);
  // A delivery waiting on THIS channel's answer gets none: it fails now, not at its 60 s timeout. Named,
  // because this close can land after a rebuilt channel already carries the next delivery.
  bulk.addEventListener("close", () => pasteUI.channelClosed(bulk), { signal: scope.signal });
  bindTermChannel?.(chs);
}

// One-time DOM + terminal machinery. Runs on the FIRST onChannels only; a rebuild re-uses everything built
// here and just re-points the channel refs (via the `channels` holder + sessionControl.rebind + bindTermChannel).
function buildChannelUi(chs: Channels): void {
  const { control } = chs;

  sessionControl = new SessionControl(
    control,
    { sim, claim, claimButton: $("claim-button") },
    () => { sendResize(false); windowManager?.resendDerived(); probeStart?.(); revealTab = true; terminalTabs?.setActive(true); renderTermEmpty(); learnTmux(); if (stateView) followStateView(stateView, true); landOnTerminalIfNothingElse(); maybeAutoSubscribe(); reconcileSimVisibility(); resetPendingSwitch(); termDeck?.activate(terminalSurfaceShown); termDriver?.(true); bells.look(); },   // becoming active
    // A PASSIVE client's windows are hidden (`reconcileSimVisibility`), and a full-screen one would leave a
    // screen with no bars, no window and no Exit — only the claim overlay. The chrome comes back first.
    () => { palette.close(); windowManager?.setFullscreen(null); probeStop?.(); tabBar.cancelGesture(); tabBar.cancelRename(); tabBar.closeMenu(); pasteUI.passive(); terminalTabs?.setActive(false); termPreview.remove(); syncOpen?.fail(); cancelOpening(); renderTermEmpty(); reconcileSimVisibility(); clearPendingGhosts?.(); resetPendingSwitch(); termDeck?.deactivate(); bells.clear(); },   // becoming passive
    mediaHidden,   // Aggregate media visibility; the terminal still follows its main document.
    // A window-less one states only the terminal's pause; a claim says its grid; a wanted claim expires on the scope.
    { terminalHidden: () => document.hidden, windowless: !transport.carriesMedia, claimGrid, timer: (f, ms) => { const t = scope.timeout(f, ms); return () => scope.clearTimeout(t); } },
  );

  // ⌘K palette — the ONLY source picker (it replaced the standalone snapshot gallery). Entries are data
  // (`paletteModel`); this resolves their ids. Sends route through the `channels` holder so a rebuild
  // targets the live control channel automatically.
  /// The picks the palette stays up for: an existing tmux session opening on This Mac (`openTerminal`).
  function paletteWaits(id: string): boolean {
    if(id.startsWith("agent:"))return true;
    return transport.sameMac && id.startsWith("tmux:") && !lastTermList.tabs.some((t) => t.id === id);
  }
  function runPaletteItem(id: string): void | Promise<void> {
    if(id.startsWith("agent:"))return agentsView?.openSession(id.slice(6));
    if (id.startsWith("apps-add:") || id.startsWith("apps-remove:") || id === "action:apps-restore-all") {
      if (!workspaceSupported || !sessionControl?.isActive) return;
      if (id === "action:apps-restore-all") sendControl({ t: "apps-restore-all" });
      else if (id.startsWith("apps-remove:")) sendControl({ t: "apps-remove", app: id.slice(12) });
      else if (lastApps?.availability === "available") sendControl({ t: "apps-add", app: id.slice(9) });
      return;
    }
    // The surface first, so a tab switched to below is revealed (and fitted) on a surface that shows.
    const surface = paletteItemSurface(id);
    if (surface === "terminal") showTerminalSurface();
    else if (surface === "window") showWindowSurface();
    if (id === "action:claim") { $("claim-button").click(); return; }
    // A terminal picked here shows its tab AT ONCE, in this tick (opening-tab.ts).
    if(id==="action:new-claude"){if(agentsView)newClaudeSession($("session"),cwd=>agentsView!.createClaudeSession(cwd));return;}
    if (id === "action:new-terminal") { openNewTerminal("pty"); return; }
    if (id === "action:new-tmux") { openNewTerminal("tmux"); return; }
    if (id.startsWith("tmux:")) {
      // An open session is SELECTED, never opened twice; the host would select it anyway.
      if (lastTermList.tabs.some((t) => t.id === id)) switchTerminal(id);
      else {
        const session = id.slice(5);
        const name = lastTmuxList?.sessions.find((s) => s.id === session)?.name ?? session;
        return openTerminal({ key: id, label: name, req: { id } }, () => sendControl({ t: "open-tmux", session }));
      }
      return;
    }
    if (id.startsWith("source:") || id.startsWith("launch:sim:")) {
      const launching = id.startsWith("launch:");
      const source = id.slice(7);
      const mine = lastViewSet.windows.find((w) => w.source === source);
      // In the session already: a parked window comes back, an open one takes focus. Otherwise open it.
      // A launch is always an OPEN intent: it also boots a stopped device whose tab already exists.
      if (launching) sendControl({ t: "subscribe", source, delivery: requestedDelivery(source) });
      else if (mine?.minimized) sendControl({ t: "restore-window", source });
      else if (mine) { if (!nativeSources) sendControl({ t: "focus-source", source }); }
      else sendControl({ t: "subscribe", source, delivery: requestedDelivery(source) });
      if (nativeSimulators) sendView({ surface: "windows" });
      nativeSources?.activate(source);
      renderWindowTabs();
    }
  }

  const requestSources = () => { if (windowless) return; sendControl({ t: "list-sources" }); sendControl({ t: "request-thumbs" }); if (workspaceSupported) sendControl({ t: "apps-list" }); };
  if (transport.sameMac) {
    $<HTMLInputElement>("palette-input").placeholder = "Search commands…";
    $("palette-open").setAttribute("aria-label", "Search commands or open a new terminal");
  }
  let paletteAgents: import("./agents/search").SearchSession[]=[];
  let agentSearchNotice="";
  const agentSearch=new AgentSearch(query=>agentsView?.search(query)??Promise.resolve([]),(rows,notice)=>{
    paletteAgents=rows;agentSearchNotice=notice;refreshPaletteItems?.();
  });
  scope.defer(()=>agentSearch.reset(),"agent search");
  const palette = new CommandPalette(
    {
      overlay: $("palette"), input: $<HTMLInputElement>("palette-input"),
      actions: $("palette-actions"), grid: $("palette-grid"), empty: $("palette-empty"),
      close: $<HTMLButtonElement>("palette-close"),
      notice: $("palette-notice"), noticeTitle: $("palette-notice-title"),
      noticeDetail: $("palette-notice-detail"),
      tmuxNote: $("palette-tmux-note"),
    },
    { onRun: runPaletteItem, waits: paletteWaits, onQuery:query=>{if(productFeatures.graphicalAgents&&(!windowless||nativeSimulators))agentSearch.query(query);} },
  );
  const paletteCtx = () => ({
    active: sessionControl?.isActive ?? false,
    sources: lastSources,
    apps: workspaceSupported ? lastApps : null,
    subscribed: new Set(streamedWindows(lastViewSet)),
    focused: lastViewSet.focused,
    thumbs,
    display: lastDisplay,
    tmux: lastTmuxList,
    openTmux: openTmuxSessions(),
    activeTmux: activeTmuxSession(),
    windowless, nativeSimulators,
    agents: productFeatures.graphicalAgents && (!windowless || nativeSimulators),
    agentSessions:paletteAgents,
    agentProviders:agentsView?.providers,
    agentSearchNotice,
  });
  // Snapshots are ONE-SHOT per open (as the gallery's were): clear the map, re-request list + thumbs, and
  // let each async reply refresh the open palette in place — it renders once, so without that the grid
  // would stay as it was at open.
  // Re-opening IS the refresh — for tmux sessions as for windows.
  // THE PALETTE LEAVES FULL SCREEN. ⌘K reaches it even from a full-screen window's picture (the key is
  // forwarded to the Mac AND bubbles), and every pick acts on a surface full screen hides: a window picked
  // opened hidden behind the full-screen one and took the Mac's focus from it.
  const openPalette = () => { if (!sessionControl?.isActive) return; windowManager?.setFullscreen(null); thumbs.clear(); palette.open(paletteCtx()); requestSources(); sendControl({ t: "list-tmux" }); };
  refreshPaletteItems = () => palette.refresh(paletteCtx());
  $("palette-open").addEventListener("click", openPalette);
  $("term-empty-browse").classList.toggle("hidden", windowless);
  $("term-empty-browse").addEventListener("click", openPalette);
  $("term-empty").querySelector(".term-empty-description")!.textContent = windowless
    ? "Open a terminal and make yourself at home."
    : "Open a terminal or choose a window to get started.";
  $("tab-add").addEventListener("click", openPalette);
  scope.listen(opts.context?.root ?? window, "keydown", (event) => {
    const e = event as KeyboardEvent;
    if (opts.context && !opts.context.input.owns(e)) return;
    // The terminal owns Ctrl+K (readline kill-line), so only ⌘K is unconditional — see shouldOpenPalette.
    if (shouldOpenPalette(e, activeElement()?.closest("#term-surface") != null)) {
      e.preventDefault(); e.stopPropagation();
      openPalette();
    } else if (shouldReopenTerminal(e) && !activeElement()?.closest(".source-window")) {
      // A window holding the keys forwards ⌘⇧T to its Mac (a browser there reopens ITS tab); it is ours only
      // outside one.
      e.preventDefault(); e.stopPropagation();
      reopenTerminal();
    } else if (shouldCloseTab(e) && ui.dataset.nativeClient === "true"
               && !activeElement()?.closest(".source-window") && closeShownTab()) {
      // ⌘W IN THE APP CLOSES THE TAB, NOT THE WINDOW (asked for, 2026-10-06). Prevented, WebKit hands it to no menu;
      // with no tab to close it is left alone and reaches the app's menu, whose ⌘W closes the window as before. A
      // window holding the keys forwards it to its Mac, as every key.
      e.preventDefault(); e.stopPropagation();
    }
  });
  /// ⌘W's tab: the terminal tab on screen, closed exactly as its × closes it (a tmux tab detaches; ⌘⇧T brings it
  /// back). Nothing — false — when this page does not drive, the terminal is not on screen (a phone's window
  /// surface, a full-screen window) or shows no listed tab (the empty state, a tab still opening).
  function closeShownTab(): boolean {
    if(sessionControl?.isActive&&agentsView?.selectedTab){agentAction("close-tab",agentsView.selectedTab);return true;}
    if (!sessionControl?.isActive || !terminalSurfaceShown() || ui.hasAttribute("data-fullscreen")) return false;
    const id = termDeck?.visibleId();
    if (!id || !lastTermList.tabs.some((t) => String(t.id) === id)) return false;
    sendControl({ t: "close-terminal", id });
    return true;
  }
  /// ⌘⇧T: the host brings back the tab the driver closed last (a passive client's request is dropped there),
  /// and it takes focus when it lands, on the terminal surface.
  function reopenTerminal(): void {
    if (!sessionControl?.isActive) return;
    showTerminalSurface();
    termDeck?.expectOpenedTab(newTabRequest("any"));
    sendControl({ t: "reopen-terminal" });
  }

  const windowOptions: WindowManagerOptions = {
    workspaceSupported, workspaceActive: () => sessionControl?.isActive ?? false,
    trackIdentity: track => referenceTrackIDs.get(track),
    onFocus: (source) => sendControl({ t: "focus-source", source }),
    // The window surface is the current one while a window is full screen — `showWindowSurface` without
    // its blur, which would take the keys from the picture that just took them. Both changes are the
    // SESSION's: the host remembers which window is full screen, and another device opens it so.
    onFullscreen: (source) => {
      sendView({ fullscreen: source });
      if (source === null) return;
      if (nativeSources) { renderWindowTabs(); return; }
      const before = currentTab;
      ui.dataset.tab = "sim";
      currentTab = "sim";
      renderWindowTabs();
      noteSurface(before, "sim");
    },
    // × takes the window out of the SESSION — it leaves the state on every device, parked or not.
    onClose: (source) => leaveWindow("unsubscribe", source),
    // − parks it: the host stops capturing and encoding, and the window stays in the session as a tab.
    onMinimize: (source) => leaveWindow("minimize-window", source),
    // Where the desktop layout put it is the SESSION's, so another device opens it there. Only the
    // driver's moves count — the host refuses a passive client's anyway, and this keeps it quiet.
    onMoved: (source, x, y) => { if (sessionControl?.isActive) sendControl({ t: "set-window-position", source, x, y }); },
    // PER WINDOW, ONLY WHAT THIS CLIENT DERIVED FOR IT: the Auto ceiling and the crop.
    onPrefs: (source, patch) => sendControl({ t: "set-source-prefs", source, ...patch }),
    // The DEVICE's preferences — any client may state them (a passive one's apply when it drives).
    prefs: clientPrefs,
    onDevicePrefs: (p) => { clientPrefs = p; sendControl({ t: "set-prefs", prefs: clientPrefsWire(p) }); },
    // SESSION-SCOPED, so it names no source: one forced FEC overhead for the whole connection.
    onRecovery: (bp) => { intendedRecoveryBp = bp; sendControl({ t: "set-recovery", overrideBp: bp }); },
    onPlayoutDelay: (minMs) => {
      intendedPlayoutDelayMs = minMs;
      sendControl({ t: "set-playout-delay", minMs });
    },
    onCurtain: (on) => sendControl({ t: "curtain", on }),
    // BOTH HALVES, AND THE ORDER MATTERS. The local mute silences the element on this frame; the
    // message stops the host encoding and sending. Waiting for the host's `view-set` reply to
    // silence the speaker would put a whole round trip between the tap and the silence.
    onSourceAudio: (source, enabled) => {
      audioPlayback.setMuted(source, !enabled);
      sendControl({ t: "set-source-audio", source, enabled });
      // Repaint now rather than waiting for the reply, for the same reason.
      if (lastViewSet) windowManager?.sync(windowViews(lastViewSet, lastSources), streamsBySource);
    },
    audioIsMuted: (source) => audioPlayback.isMuted(source),
    onResize: (source, w, h) => sendControl({ t: "set-source-size", source, w, h }),
    // PASTE INTO A WINDOW (paste-and-drop design §2.2, §5): the titlebar's menu, full screen's `⌨`, a drop
    // on the picture. The DRIVER pastes (the host refuses anyone else), and a window-less session has no
    // window to paste into — its policy refuses a window target outright.
    canPaste: () => (sessionControl?.isActive ?? false) && !windowless,
    onWindowMenu: (source, at) => pasteUI.openWindowMenu(source, at),
    onSimAction: (source, action) => sendControl({ t: "sim-action", source, action }),
    onWindowDrop: (source, at, dt) => pasteUI.windowDrop(source, at, dt),
    ...(renderMode === "video" ? {} : {
      pacedRender: {
        mode: renderMode,
        marginMs: paceMarginMs,
        cadenceLock,
        probe: probeOn,
        webcodecs: {
          receiverFor: (source: string) => receiversBySource.get(source),
          pacerFor: (source: string) => webcodecsPacers.get(source),
        },
      },
    }),
    inputChannel: inputProxy, nowMs: () => performance.now(),
    pc: () => connection?.media,   // a getter: pc rebuilds on reconnect, so don't capture the instance
  };
  if (nativeSourceAPI) {
    sourceFocusGate = new SourceFocusGate({
      control: sendControl,
      input: message => { const channel = channels.input; if (channel?.readyState === 'open') channel.send(encodeJson(message) as Uint8Array<ArrayBuffer>); },
      now: () => performance.now(),
      state: state => nativeSources?.setInputState(state),
    });
    scope.defer(() => sourceFocusGate?.dispose(), 'native-source-focus');
    nativeSources = new NativeSourceWindows($("windows"),windowOptions,nativeSourceAPI,{
      input: (key,data) => sourceFocusGate?.send(key,data),
      focus: key => { sourceFocusGate?.activate(key); renderWindowTabs(); },
      restore: source => sendControl({t:'restore-window',source}),
      retired: key => sourceFocusGate?.retire(key),
      paste: {uploader: pasteUploader,subscribeProgress(listener){sourcePasteProgress.add(listener);return()=>sourcePasteProgress.delete(listener);}},
      visibilityChanged: (owner,children) => { nativeMediaIsHidden = nativeMediaHidden(owner,children); if(nativeControlSeen)sendControl({t:'set-visibility',hidden:mediaHidden()}); },
      presentationChanged: () => { watchAllPresentations(); attachProbeTo(nativeSources?.focusedVideo()); applyPendingFullscreen(); },
    });
    windowManager = nativeSources;
    dbg.nativeSourceInput = () => sourceFocusGate?.debug();
    scope.defer((opts.context?.smooth.subscribe ?? onPageSmoothScrollChange)(() => syncVideo({kind:'other'})), 'native-source-smooth');
  } else windowManager = new WindowManager($("windows"), windowOptions);
  syncVideo({ kind: "other" });   // a track that arrived before the data channels opened (e.g. the headless "test" stream) now gets its window
  windowManager.setLiveness(sourceLiveness);   // apply any source-status that arrived before the manager existed
  windowManager.setSimStates(sourceSimStates);
  dbg.autoRes = () => windowManager?.autoDebug();
  dbg.playoutFloor = () => ({ ...playoutFloor, window: playoutWindow.active, arrivalSpreadMs: lastArrivalSpreadMs, samples: arrivals.length });
  // Which sources currently hold a video stream — beside `viewSet`, the discriminator between "the
  // track never arrived" and "it arrived and was let go", which look identical from the window.
  dbg.videoStreams = () => [...streamsBySource.keys()];
  // TESTING hooks for the paced renderer: read the counters, retune the margin live (so one session
  // can A/B several margins), and zero the counters between arms.
  dbg.pacer = () => windowManager?.pacerStats();
  dbg.setPace = (ms: number | "auto") => windowManager?.setPacerMargin(ms);
  dbg.resetPace = () => windowManager?.resetPacerStats();
  if (renderMode !== "video") console.info(`[render] ${renderMode}, margin ${paceMarginMs}ms`);

  // A tab this user asks for takes focus when it lands (TermDeck.expectOpenedTab).
  $("term-empty-new").addEventListener("click", () => openNewTerminal("pty"));
  $("term-empty-new-tmux").addEventListener("click", () => openNewTerminal("tmux"));
  renderTermEmpty();


  const xtermEl = $("xterm");
  xtermEl.classList.remove("hidden");

  // Typeahead predictor (Plan 3): only the ACTIVE client predicts; setActive/setAltScreen are
  // re-checked on every keystroke since sessionControl/alt-screen can flip between them.
  const model = new OverlayModel();
  let cursorHidden = false;                        // xterm's real cursor is hidden while the overlay draws its own
  const predictLagMs = Math.max(0, Number(params.get("predictlag") ?? "0")) || 0;
  const controller = new PredictionController({
    thresholdMs: 30,
    force: params.get("predict") === "on" ? "on" : params.get("predict") === "off" ? "off" : null,
    networkRttMs: () => networkRttMs,
    addedLagMs: predictLagMs,
  });
  // `linkMs` is what the gate reads — the network's round trip (+ `?predictlag`), null with no network;
  // `rttMs` is the echo's, the stale-ghost clock's scale only (PredictionController).
  const termEcho = { rttMs: 0, linkMs: null as number | null, active: false, shown: 0, confirmed: 0, rolledBack: 0,
    prediction: { pending: false, field: false, text: "", cursor: 0 } };
  dbg.termEcho = termEcho;
  const reportGate = () => {
    termEcho.active = controller.active();
    termEcho.rttMs = Math.round(controller.rttMs());
    termEcho.linkMs = controller.linkMs();
  };
  // TEST-ONLY, like `sendControl`: every row of the VISIBLE tab's buffer (scrollback + screen) as
  // text, so a check can see that a resume CONTINUED the scrollback rather than replaced or repeated it.
  dbg.termBuffer = () => {
    const b = xtermView?.term.buffer.active;
    return b ? Array.from({ length: b.length }, (_, i) => b.getLine(i)?.translateToString(true) ?? "") : [];
  };
  // TEST-ONLY: the visible tab's 256-colour BACKGROUNDS, cells counted per palette index over its whole buffer —
  // which coloured blocks it holds, whatever renderer draws them (the workbench's red/green samples).
  dbg.termBgCells = () => {
    const t = xtermView?.term, b = t?.buffer.active;
    const counts: Record<number, number> = {};
    if (!t || !b) return counts;
    const cell = b.getNullCell();
    for (let y = 0; y < b.length; y++) {
      const line = b.getLine(y);
      for (let x = 0; line && x < t.cols; x++) {
        if (line.getCell(x, cell)?.isBgPalette()) counts[cell.getBgColor()] = (counts[cell.getBgColor()] ?? 0) + 1;
      }
    }
    return counts;
  };
  // TEST-ONLY: any tab's buffer, visible or not — what a background tab has been painting all along.
  dbg.termBufferOf = (tab: string) => {
    const b = termDeck?.liveView(tab)?.term.buffer.active;
    return b ? Array.from({ length: b.length }, (_, i) => b.getLine(i)?.translateToString(true) ?? "") : [];
  };
  // TEST-ONLY, like `termBuffer`: xterm.js's own mode flags (origin, bracketed paste, ?2026, …), so a
  // check can see what an attach left the client in rather than only what it painted.
  dbg.termModes = () => ({ ...(xtermView?.term.modes ?? {}) });
  // TEST-ONLY: the visible tab's cursor, screen-relative — so a check can hold it against tmux's own
  // `cursor_x`/`cursor_y` (the glyph widths a tmux tab counts as tmux does).
  dbg.termCursor = () => {
    const b = xtermView?.term.buffer.active;
    return b ? { x: b.cursorX, y: b.cursorY } : null;
  };
  let ghostSince: number | null = null;   // when the current run of ghosts first appeared (for staleness)

  // All terminal work (ghost paints, server applies, the deck's instance swaps and disposals, async
  // clears) runs through ONE serialized async chain, so an apply that writes-then-reads xterm's
  // buffer never races the next keystroke's ghost paint or the next chunk — and the deck's swaps and
  // disposals land in wire order with the writes (term-deck.ts). Reading xterm state requires awaiting
  // its write callback, so the chain is the only safe way to interleave.
  let opChain: Promise<void> = Promise.resolve();
  // Fenced: an op queued before dispose must not touch a disposed instance after it.
  const enqueue = (task: () => Promise<void>) => { opChain = opChain.then(() => (scope.disposed ? undefined : task())).catch((e) => console.error("[predict] op failed", e)); };

  let overlay: PredictionOverlay | null = null;   // Mosh-style opaque prediction overlay, over the visible instance
  let overlayView: XtermView | undefined;          // the instance the overlay (and its cursor hiding) belongs to

  // Paint the overlay for the current model state and hide xterm's real cursor while ours shows (the
  // overlay draws its own block cursor at the prediction end). Idempotent; MUST run inside an enqueued
  // task (it writes to xterm). When nothing is predicted it clears the overlay and restores the cursor.
  const renderOverlay = async (): Promise<void> => {
    termEcho.prediction = { pending: model.active(), field: model.inField(), text: model.text(), cursor: model.cursorOffset() };
    const anchor = model.anchorAt();
    if (overlay && overlayView && model.active() && anchor) {
      if (!cursorHidden) { await overlayView.writeAsync("\x1b[?25l"); cursorHidden = true; }
      overlay.show(anchor.row, anchor.col, model.paintText(), true, model.cursorOffset(), model.pendingCells());
      if (ghostSince == null) ghostSince = performance.now();
    } else {
      overlay?.clear();
      if (cursorHidden && overlayView) await overlayView.writeAsync("\x1b[?25h");
      cursorHidden = false;
      ghostSince = null;
    }
  };

  // Mobile (tabbed) layout uses a 2x-smaller font; same value feeds the prediction overlay below so
  // the ghost text stays aligned to the grid.
  let termFontSize = savedTerminalFontSize(terminalFontSize(opts.layout()), opts.context?.storage);
  const cellHeight = (v: XtermView | undefined) =>
    (v?.term as unknown as { _core?: { _renderService?: { dimensions?: { css?: { cell?: { height?: number } } } } } } | undefined)
      ?._core?._renderService?.dimensions?.css?.cell?.height || 18;
  // Its colours come from the terminal itself — the theme and the cells it covers (prediction-overlay.ts).
  const buildOverlay = (v: XtermView) => new PredictionOverlay(v.term, {
    fontFamily: '"JetBrains Mono", Menlo, Monaco, "DejaVu Sans Mono", "Courier New", monospace',
    fontSize: termFontSize, cellHeight: Math.round(cellHeight(v)),
  });

  const foregroundKind = () => lastTermList.tabs.find(t => t.id === deck.visibleId())?.agentKind;
  const readField = (view: XtermView): PredictionField | null => {
    const b = view.term.buffer.active;
    const field = recognizePredictionField({
      kind: foregroundKind(), cols: view.cols(), cursor: { row: b.cursorY, col: b.cursorX },
      rows: Array.from({ length: view.rows() }, (_, i) => b.getLine(b.baseY + i)?.translateToString(true) ?? ""),
      dimAt: (row, col) => !!b.getLine(b.baseY + row)?.getCell(col)?.isDim(),
    });
    if (field) field.anchor.row += b.baseY;
    return field;
  };
  // A control/edit we cannot model invalidates the cursor baseline. Do not immediately anchor
  // the following key to that OLD cursor (Enter + typing ahead was another source of duplicates).
  // This quiet guard only delays NEW predictions; it never withdraws an outstanding overlay.
  let predictionResumeAt = 0, predictionNeedsOutput = false;
  let submittedComposer: PredictionField["kind"] | null = null;
  const pausePrediction = () => {
    predictionResumeAt = performance.now() + Math.max(2500, (controller.linkMs() ?? 0) * 4);
    predictionNeedsOutput = true;
    model.reset();
  };

  // Input from the VISIBLE instance, named with its tab (the deck drops hidden instances' input —
  // the host answers their queries).
  const onTermData = (tab: string, raw: string) => {
    // The strip's latched modifiers apply to CHARACTERS the soft keyboard produced, not only to
    // strip keys — that is what makes a tapped Ctrl followed by a typed "c" send ^C. Transformed
    // HERE, at the top, so the prediction block below sees the real bytes: a Ctrl-transformed
    // \x03 must land in its "Enter / arrows / ctrl → stop predicting" branch rather than being
    // predicted as a printable character.
    const data = applyHeldMods(raw, termMods.mask());
    controller.setActive(sessionControl?.isActive ?? false);

    controller.onKeystroke(performance.now());                      // record the real keystroke time now
    const sent = sendKeyTo(tab, data);                              // send immediately (routes to the live input channel)
    enqueue(async () => {
      // `!sent` means there was no terminal to address, so nothing went to the host — predicting it
      // would leave a ghost that no server echo can ever reconcile. A switch since the keystroke
      // (the overlay now belongs to another instance) predicts nothing either.
      const field = xtermView ? readField(xtermView) : null;
      // Any key typed ahead of the submit echo prevents using an empty prompt as
      // a fresh baseline: that key may already be in flight beyond the empty frame.
      submittedComposer = null;
      controller.setAltScreen((xtermView?.isAltScreen() ?? false) && !field);
      const paused = predictionNeedsOutput || performance.now() < predictionResumeAt;
      if (paused) predictionResumeAt = performance.now() + Math.max(2500, (controller.linkMs() ?? 0) * 4);
      const willPredict = controller.active() && !paused && (!foregroundKind() || !!field)
        && (!xtermView?.isAltScreen() || !!field);
      if (!sent || !willPredict || !xtermView || xtermView !== overlayView) {
        // A sent-but-unpredicted edit is still in flight. Starting a new run from its OLD
        // screen on the next key would merely shift the same duplication bug to this path.
        if (sent) pausePrediction();
        else model.reset();
        await renderOverlay(); return;
      }
      // Output-only cursor excursions may settle back into place, but an input
      // must never extend an old field anchor after a real move or resize.
      if (model.inField()) {
        const anchor = model.anchorAt();
        if (!field || !anchor || field.anchor.row !== anchor.row || field.anchor.col !== anchor.col || field.capacity !== model.fieldCapacity()) {
          pausePrediction(); await renderOverlay(); return;
        }
      }
      if (!model.active() && field) model.beginField(field.anchor, field.text, field.cursor, field.capacity, field.coverWidth);
      if (data === "\x7f") {                                    // backspace: pop an un-echoed ghost
        if (!model.backspace()) { pausePrediction(); await renderOverlay(); return; }
      } else if (data.length === 1 && data >= " " && data <= "~") {   // printable → extend the prediction
        if (!model.predictChar(data, xtermView.cursor())) { pausePrediction(); await renderOverlay(); return; }
        termEcho.shown++;
      } else {                                                  // Enter / arrows / ctrl → wait for a fresh baseline
        // A nonempty composer settling empty supplies a fresh baseline,
        // provided no earlier predicted deletion can itself produce an empty echo.
        if (data === "\r" && field?.text.length && !model.hasPendingEmpty()) submittedComposer = field.kind;
        pausePrediction(); await renderOverlay();
        return;
      }
      await renderOverlay();
    });
  };

  // The terminals' renderer: WebGPU wherever it can draw (webgpu/renderer.ts — a hardware adapter), unless
  // `?renderer=dom` or this device's saved setting (Terminal Settings → WebGPU rendering) says the DOM one.
  let terminalRenderer: "dom" | "webgpu" = params.get("renderer") === "dom" || savedTerminalRenderer(opts.context?.storage) === "dom" ? "dom" : "webgpu";
  // Ask for the shared GPU device now, ahead of the first terminal (webgpu/device.ts — null where WebGPU
  // cannot draw, and nothing asks again).
  if (terminalRenderer === "webgpu") void requestGpu();
  // EXPERIMENTAL: coloured backgrounds shaded by where they sit in the area (Terminal Settings → Gradient
  // backgrounds; the WebGPU renderer only). The renderer holds the value — the design workbench sets it too.
  if (!opts.context) setBackgroundGradient(savedBackgroundGradient());
  // Every tab drawn afresh: set once the stream router exists (below).
  let renewTerminals = () => {};
  const deck = new TermDeck({
    container: xtermEl, fontSize: termFontSize, theme: currentTheme(), smoothScroll: smoothScrollEnabled(),
    // `?scrollsync=0`: a scroll's rows wait for xterm.js's frame again (smooth-scroll.ts) — to compare.
    scrollSync: params.get("scrollsync") !== "0",
    // `?wheelresample=0`: a trackpad's wheel moves the scrollback as it lands again (wheel-resample.ts).
    wheelResample: params.get("wheelresample") !== "0",
    // The shared device is asked for as the session starts (`requestGpu` above), so a terminal mounted once
    // it is there draws with WebGPU from its first frame.
    renderer: terminalRenderer,
    // On This Mac only a NEW terminal fades in; every other tab's first content appears (asked for, 2026-10-04).
    fadeIn: transport.sameMac ? "new" : "always",
    onData: onTermData,
    // A device-query reply: its OWN message, naming the tab whose instance parsed the query — shown or
    // hidden — never a keystroke (no held modifiers, no prediction, no claim about what is on screen).
    // The host delivers it to that tab while it owes one (docs/terminal.md, "Who answers").
    onReply: (tab, data) => { if (!termOutputBlocked) sendInput({ t: "term-reply", data, term: tab }); },
    // A BEL from any tab, shown or hidden: unseen until the person looks at that tab (term-bell.ts).
    onBell: (tab) => { if (sessionControl?.isActive) bells.ring("terminal", tab); },
    // An image path printed in a tab was tapped or clicked: the host resolves it against that tab (file-viewer.ts).
    onPath: (tab, path) => { fileViewer.open(tab, path); },
    // A held resize bottom-aligns on a touch device (a phone's keyboard); a desktop's stays top-left (term-deck.ts).
    holdShift: () => typeof matchMedia === "function" && matchMedia("(any-pointer: coarse)").matches,
    onFit: (cols, rows) => { fittedGrid = { cols, rows }; if (sessionControl?.isActive) sendControl({ t: "resize", cols, rows }); },
    onVisibleChange: (view, tab) => {
      xtermView = view ?? undefined;
      // Another tab shown: the offer's screen of the one that was active is not what shows.
      if (tab !== null && termPreview.tab !== null && tab !== termPreview.tab) termPreview.remove();
      // A finger's selection was in the terminal that was shown: it goes, and its menu.
      if (touchSelection?.active) { touchSelection.clear(); pasteUI.menu.close(); }
      bells.look();
      const shown = xtermView;
      // Predictions belong to the instance they were drawn over: a switch drops them, and gives the
      // cursor the overlay hid back to THAT instance. Queued, so it runs after any write in flight.
      enqueue(async () => {
        if (scope.disposed || shown !== xtermView) return;
        model.reset();
        overlay?.clear();
        if (cursorHidden && overlayView) await overlayView.writeAsync("\x1b[?25h");
        if (scope.disposed || shown !== xtermView) return;
        cursorHidden = false;
        ghostSince = null;
        predictionResumeAt = 0; predictionNeedsOutput = false; submittedComposer = null;
        overlayView = shown;
        overlay = shown ? buildOverlay(shown) : null;
      });
      // xterm's helper textarea only exists once term.open() has run, so the glasses focus order is
      // re-applied for every instance — and the cursor kept visible on the one that is shown.
      syncGlassesFocusOrder(opts.layout(), dom);
      if (xtermView) keepTerminalCursorVisible(opts.layout(), xtermView.term.element ?? document);
    },
    // The DECK decides when the terminal takes focus (term-view-policy.ts): a user switch, or handing
    // on focus it already held — never a repaint, which would take it from a remote window. Never on
    // glasses: the D-pad owns focus there, and text reaches the PTY via the compose bar.
    focusPolicy: (userOpened) => ({
      driver: sessionControl?.isActive ?? false,
      mayAutofocus: terminalMayAutofocus(opts.layout()) && (!opts.context || opts.context.input.focused() || userOpened === true),
      // The gesture was a TOUCH: focusing the terminal would raise the soft keyboard (term-view-policy.ts,
      // input-modality.ts) — decided per gesture, so a hardware keyboard on a touch device still types.
      softKeyboard: inputModality.lastWasTouch(),
    }),
  });
  termDeck = deck;
  deck.setAgentTabs(agentTabs(lastTermList));   // a list that came before the deck
  armPreviewHandover();
  scope.defer(mountTerminalSettings($("statusbar"), {
    get: () => termFontSize,
    set: size => {
      termFontSize = size;
      enqueue(async () => {
        model.reset(); overlay?.clear();
        if (cursorHidden && overlayView) await overlayView.writeAsync("\x1b[?25h");
        cursorHidden = false;
        deck.setFontSize(size);
        overlay = overlayView ? buildOverlay(overlayView) : null;
      });
    },
  }, {
    enabled: () => terminalRenderer === "webgpu",
    status: () => rendererStatus(terminalRenderer === "webgpu", deck.visibleView()?.renderer() ?? null, gpuState()),
    set: (on) => {
      terminalRenderer = on ? "webgpu" : "dom";
      saveTerminalRenderer(terminalRenderer, opts.context?.storage);
      if (on) void requestGpu();
      deck.setRenderer(terminalRenderer);
      renewTerminals();
    },
  }, {
    enabled: opts.context ? () => savedBackgroundGradient(opts.context?.storage) : backgroundGradientEnabled,
    set: (on) => { saveBackgroundGradient(on, opts.context?.storage); if (!opts.context) setBackgroundGradient(on); },
  }, $("term-surface"), transport.sameMac), "terminal-settings");
  dbg.termSwitch = (id: string) => switchTerminal(id);
  dbg.termVisible = () => deck.visibleId();
  dbg.termTabs = () => deck.ids();
  syncGlassesFocusOrder(opts.layout(), dom);
  scope.defer(onThemeChange((t) => deck.setTheme(t)), "theme:deck");
  // The palette's toggle, the dashboard's checkbox or another page of this origin: every open tab at once.
  scope.defer(onSmoothScrollChange((on) => deck.setSmoothScroll(on)), "smooth-scroll:deck");
  // The host answers a tmux tab's unreached colour queries from this palette (docs/terminal.md).
  scope.defer(onThemeChange((t) => sendControl(termPaletteMessage(t))), "theme:palette");

  // Copy the terminal selection ourselves rather than leaving it to xterm's `copy` listener: on
  // iPadOS Safari that event never arrives (the focused helper textarea is empty, so the platform
  // has nothing to copy) and ⌘C over a visible selection did nothing while ⌘V worked. See
  // terminal-copy.ts — it does not preventDefault, so browsers whose native path works are untouched.
  // Everything reads the VISIBLE instance.
  const termCopy = { copies: 0, method: "", ok: false, chars: 0, error: "" };
  dbg.termCopy = termCopy;
  // Keep the terminal selection mirrored into xterm's helper textarea at all times, so the platform
  // has a real selection to copy whenever ⌘C is pressed — see installSelectionMirror.
  scope.defer(installSelectionMirror({
    textarea: () => xtermView?.term.textarea ?? undefined,
    getSelection: () => xtermView?.term.getSelection() ?? "",
    subscribe: (cb) => { deck.onSelectionChange(cb); return { dispose() {} }; },
  }), "selection-mirror");
  scope.defer(installTerminalCopy(xtermEl, {
    hasSelection: () => xtermView?.term.hasSelection() ?? false,
    getSelection: () => xtermView?.term.getSelection() ?? "",
    textarea: () => xtermView?.term.textarea ?? undefined,
    onResult: (r) => {
      termCopy.copies++; termCopy.method = r.method; termCopy.ok = r.ok; termCopy.chars = r.chars;
      termCopy.error = r.error ?? "";
      if (!r.ok) console.warn("[copy] clipboard write failed", r);
    },
  }), "terminal-copy");

  // One-finger scrolling on a touch screen: rows into xterm's own wheel handler, or — smooth scrolling
  // on, over the scrollback — pixel for pixel with a glide after a flick (touch-scroll.ts).
  scope.defer(attachTouchScroll(xtermEl, { view: () => xtermView ?? null, rowHeight: () => cellHeight(xtermView),
    // A FULL-SCREEN app (the alternate screen) under the keyboard: the shifted view pans first, the app scrolls after.
    pan: (dy) => (xtermView?.isAltScreen() ? keyboardShift.panBy(dy) : dy) }),
    "touch-scroll");
  // A held finger's menu (Paste, Paste Image/File…), ⌘V carrying an image, and drops (paste-ui.ts). The hold
  // is CAPTURE on this element, so it sees the gesture before touch scroll's listeners whatever the order.
  pasteUI.attachTerminal(xtermEl);
  // A hold on TEXT selects its word, a held drag or the handles extend it, and the menu leads with Copy
  // (touch-selection.ts). The handles live in `#term-surface`, beside the terminal, never in it.
  touchSelection = new TouchSelection($("term-surface"), {
    signal: scope.signal,
    term: () => xtermView?.term ?? null,
    showMenu: (anchor) => pasteUI.openSelectionMenu(anchor),
    hideMenu: () => pasteUI.menu.close(),
  });
  // INSTRUMENT (`?scrollprobe=1`): how evenly a real trackpad's wheel stream moves the scrollback — events
  // per frame and step unevenness per gesture, in an overlay (scroll-probe.ts). Absent, nothing is built.
  if (params.get("scrollprobe") === "1") {
    const probe = new ScrollProbe({ target: xtermEl, term: () => xtermView?.term ?? null,
                                    smooth: () => xtermView?.smooth?.enabled ?? false,
                                    rowStats: () => xtermView?.rowStats() ?? null,
                                    sync: () => params.get("scrollsync") !== "0",
                                    resample: () => params.get("wheelresample") !== "0" });
    scope.defer(() => probe.dispose(), "scroll probe");
  }

  // Server bytes: frames → the router (per-tab DEFLATE + UTF-8, term-stream.ts) → one WriteCoalescer
  // per tab generation → that generation's instance. The server bytes are the AUTHORITATIVE buffer and
  // are written IMMEDIATELY — hidden under the opaque prediction overlay if a run is pending, so a
  // lagged edit can replay under it without the display rewinding. Reconcile runs on a SETTLE (after
  // the echo burst quiesces), never mid-replay, so an intermediate edit-state can't confirm. Only the
  // VISIBLE instance's writes run the prediction reconcile; a hidden one is written plainly.
  const SETTLE_QUIET_MS = 40, SETTLE_MAX_MS = 180;
  let settleTimer: ReturnType<typeof setTimeout> | undefined;
  let settleFirstAt = 0;
  const reconcileTask = async () => {
    if (!xtermView) return;
    // A redraw can transiently erase the composer before restoring its old text.
    // Use the same settled-screen boundary as pending-edit reconciliation.
    if (submittedComposer) {
      const field = readField(xtermView);
      if (field?.kind === submittedComposer && field.text === "" && field.cursor === 0) {
        submittedComposer = null;
        predictionResumeAt = 0;
      }
    }
    if (!model.active()) return;
    const field = model.inField() ? readField(xtermView) : null;
    // Cursor moves and incomplete borders inside a redraw are not a field change.
    // Validate at the same settled boundary as its content, including alternate screen.
    if (model.inField()) {
      const field = readField(xtermView), anchor = model.anchorAt();
      if (!field || !anchor || field.anchor.row !== anchor.row || field.anchor.col !== anchor.col || field.capacity !== model.fieldCapacity()) {
        pausePrediction(); await renderOverlay(); return;
      }
    }
    // Empty-field placeholders are decoration, not input text. Reconcile with the normalized
    // recognized field so deleting its last character can confirm without waiting out a ghost.
    const cellAt = field ? (r: number, c: number) => r === field.anchor.row
      ? field.text[c - field.anchor.col] ?? " " : xtermView!.cellAt(r, c) : xtermView.cellAt;
    const { matched, cleared, definitive } = model.reconcile(xtermView.cursor(), xtermView.cols(), cellAt);
    if (!matched) {
      // The buffer disagrees. If it's NOT definitive, the shell is mid-replay of an edit (echoing the
      // char you just backspaced, before the backspace echo) — keep the overlay covering and wait for
      // the next echo, no matter the lag. NEVER withdraw on a timer: at high lag the correcting echo can
      // be hundreds of ms away, and withdrawing exposes the raw replay. Only a DEFINITIVE mismatch (the
      // cursor settled past the prediction end with wrong content) is a real divergence to withdraw.
      if (!definitive) return;
      model.reset();
      await renderOverlay();
      controller.onReconcile(false);
      termEcho.rolledBack++;
      reportGate();
      return;
    }
    await renderOverlay();                               // shrink to survivors, or clear + restore the cursor
    controller.onReconcile(true);
    if (cleared) { termEcho.confirmed++; ghostSince = null; }
    else ghostSince = performance.now();                 // partial confirm = link alive → restart stale clock
    reportGate();
  };
  const scheduleSettle = () => {
    if (settleTimer === undefined) settleFirstAt = performance.now();
    scope.clearTimeout(settleTimer);
    const wait = Math.max(0, Math.min(SETTLE_QUIET_MS, SETTLE_MAX_MS - (performance.now() - settleFirstAt)));
    settleTimer = scope.timeout(() => { settleTimer = undefined; enqueue(reconcileTask); }, wait);
  };
  const applyVisible = async (view: XtermView, text: string) => {
    if (view.isAltScreen() && !model.inField() && !readField(view)) {   // Only a positively recognized composer may predict in alternate screen
      if (model.active()) { model.reset(); await renderOverlay(); }
      await view.writeAsync(text);
      predictionNeedsOutput = false;
      if (submittedComposer) scheduleSettle();
      controller.onBytes(performance.now());   // consume the keystroke clock so RTT doesn't stale over the alt-screen session
      controller.onReconcile(true);
      ghostSince = null;
      reportGate();
      return;
    }
    await view.writeAsync(text);   // authoritative echo, applied immediately (hidden under the overlay)
    predictionNeedsOutput = false;
    // The echo's latency, as it ARRIVES (not at the settled reconcile below) — the stale-ghost clock's scale.
    // The gate reads the network instead (predictive-echo.ts, PredictionController).
    controller.onBytes(performance.now());
    if (submittedComposer) scheduleSettle();
    if (!model.active()) {         // no prediction pending → nothing to reconcile
      controller.onReconcile(true);
      reportGate();
      return;
    }
    scheduleSettle();              // reconcile once the echo burst quiesces
  };
  // Server bytes go through a writer per generation: a redraw that arrives as hundreds of messages,
  // or a backlog drained when a phone returns from the background, is applied as a single write (one
  // paint) instead of being played back line by line (write-coalescer.ts) — and a ?2026 frame only
  // WHOLE, or xterm.js skips every paint while frames stream in pieces (sync-frames.ts).
  dbg.termWrites = 0;   // TEST-ONLY: server writes applied — what a paint-per-message regression would show
  const writers = new Map<string, ReturnType<typeof termWriter>>();     // `${tab}#${gen}`
  // **SCROLLBACK COMES AFTER THE SCREEN** (docs/terminal.md): a generation begun by a SCREEN snapshot expects the tab's
  // full snapshot later (`history`). Until its rebuild is swapped in, the text APPLIED to that generation's instance
  // beyond its own snapshot is kept (late-history.ts) — counted at the apply, inside the op chain, so text the writer
  // still holds goes to whichever instance is current when it lands and is never kept twice.
  const LATE_HISTORY_CAP = 8 * 1024 * 1024;        // chars of live text kept for a rebuild; past it, the screen stays
  const lateHistory = new LateHistoryLog(LATE_HISTORY_CAP, (tab, gen) => {
    console.warn(`[term] ${tab}: more live text than a rebuild keeps while its history arrives; it keeps its screen`);
    deck.rebaseAbandon(tab, gen);
  });
  const writerFor = (tab: string, gen: number) => {
    const key = `${tab}#${gen}`;
    let w = writers.get(key);
    if (!w) {
      w = termWriter(enqueue, async (text: string) => {
        dbg.termWrites = (dbg.termWrites ?? 0) + 1;
        const view = deck.viewFor(tab, gen);
        if (!view) return;                        // superseded or closed since: its instance is gone
        lateHistory.applied(tab, gen, text);
        if (view === xtermView && view === overlayView) await applyVisible(view, text);
        else await view.writeAsync(text);
      }, { set: (f, ms) => scope.timeout(f, ms), clear: (t) => scope.clearTimeout(t) });
      writers.set(key, w);
    }
    return w;
  };
  const dropWriters = (tab: string, keep?: number) => {
    for (const [k, w] of [...writers]) {
      if (k.startsWith(`${tab}#`) && k !== `${tab}#${keep}`) { w.dispose(); writers.delete(k); }
    }
  };
  // Everything the router reports reaches the deck THROUGH the op chain, in wire order with the
  // writes (term-deck.ts). `?predictlag=<ms>` delays applying (test hook) — every event, `retain`
  // included, by the SAME delay, so their order survives.
  const lag = (f: () => void) => { if (predictLagMs > 0) scope.timeout(f, predictLagMs); else f(); };
  retainTermTabs = (ids) => lag(() => enqueue(async () => {
    const before = new Set(deck.ids());
    deck.retain(ids);
    for (const id of before) if (!deck.ids().includes(id)) dropWriters(id);
  }));
  dbg.termResyncs = 0;
  // A re-declaration after an undecodable stream BACKS OFF and is CAPPED (term-resync.ts): a failure
  // that repeats every time must not become a loop of full re-serializations.
  // Not "could not be decoded" any more: a wire that never started gives up here too (term-resync.ts).
  const TERM_STUCK_NOTE = "Terminal is not updating — reconnect or switch away and back";
  const termResync = new TermResync<ReturnType<typeof setTimeout> | undefined>({
    request: () => sendControl({ t: "term-mode", mode: "raw" }),
    // ITS OWN TOAST (`streamNote`), not `#sim-status-note`: that one is written by tmux errors, flashes and
    // the source status, which overwrote this standing notice (or were erased by its clear). A STATE: it
    // stays until the stream decodes again, or a tap.
    gaveUp: () => {
      console.warn("[term] the stream failed to decode on every retry; not asking again until a reconnect, a return to the page or a wire that decodes");
      termStuckMark = streamNote.show(TERM_STUCK_NOTE);
    },
    recovered: () => { if (!termOutputBlocked) streamNote.clear(termStuckMark); },
    setTimer: (f, ms) => scope.timeout(f, ms),
    clearTimer: (t) => scope.clearTimeout(t),
    now: () => performance.now(),
    // A wire is owed only to a driver, and asked for only on an open control channel: a connection mid-rebuild says
    // raw itself when its next control opens (`negotiateRaw`).
    asking: () => !termOutputBlocked && (sessionControl?.isActive ?? false) && channels.control?.readyState === "open",
  });
  termPageVisible = () => { if (!termOutputBlocked) termResync.reset(true); };
  termDriver = (driving) => { if (termOutputBlocked) return; if (driving) termResync.becameDriver(); else termResync.passive(); };
  const commitSnapshot = (tab: string, gen: number) => lag(() => enqueue(async () => { deck.commit(tab, gen); dropWriters(tab, gen); }));
  // A snapshot answering a HELD resize is committed WITH the program's redraw that follows it, written into
  // the still-hidden instance first (snapshot-settle.ts) — not one frame before it, a second layout.
  const settle = new SnapshotSettle({ ...SNAPSHOT_SETTLE, set: (f, ms) => scope.timeout(f, ms),
    clear: (t) => scope.clearTimeout(t), commit: commitSnapshot });
  scope.defer(() => settle.dispose());
  const heldSnapshots = new Set<string>();   // `${tab}#${gen}`: snapshots that answer the deck's hold
  /// The tab's full snapshot for generation `gen` arrived: rebuild — a hidden instance (`TermDeck.rebaseBegin`, its replies
  /// and bells muted: the replayed bytes were answered by the instance it replaces), the snapshot in 64 KB slices, each
  /// its own op queued only when the one before has run, so whatever arrived meanwhile — the echo on screen, other
  /// tabs — runs in between; then the live text kept since, and the swap. The swap and the last catch-up are ONE op:
  /// nothing is applied to the generation's instance between that op's read of the kept text and the swap, and
  /// whatever is applied after it lands in the rebuild (`viewFor` names it once it is in). While the swap would
  /// disturb the person at that tab (`swapWouldDisturb`), the rebuild catches up and looks again later — for at most
  /// `SWAP_PATIENCE_MS`.
  const HISTORY_SLICE = 64 * 1024;
  const REBUILD_RETRY_MS = 500;
  const rebuildWithHistory = (tab: string, gen: number, cols: number, rows: number, text: string) => {
    const giveUp = () => { deck.rebaseAbandon(tab, gen); lateHistory.end(tab, gen); };
    let replayed = "";                                    // TEST-ONLY: `dbg.termRebuildLive`
    let firstTry: number | null = null;
    const swap = () => enqueue(async () => {
      const v = deck.rebaseView(tab, gen), live = lateHistory.take(tab, gen);
      if (!v || live === null) { giveUp(); return; }
      if (live) { await v.writeAsync(live); replayed = (replayed + live).slice(-4096); }
      const now = performance.now();
      firstTry ??= now;
      if (swapWouldDisturb({
        tab, visible: deck.visibleId(), holding: deck.holding(), predicting: model.active(),
        selecting: !!touchSelection?.active || !!deck.visibleView()?.term.hasSelection(),
        lastKey, now, waitedMs: now - firstTry,
      })) { scope.timeout(swap, REBUILD_RETRY_MS); return; }
      lateHistory.end(tab, gen);
      if (!deck.rebaseCommit(tab, gen)) return;
      dbg.termRebuilds = (dbg.termRebuilds ?? 0) + 1;
      dbg.termRebuildLive = { ...dbg.termRebuildLive, [tab]: replayed };
    });
    const slice = (from: number) => enqueue(async () => {
      const v = deck.rebaseView(tab, gen);
      if (!v || !lateHistory.wants(tab, gen)) { giveUp(); return; }
      let end = Math.min(text.length, from + HISTORY_SLICE);
      if (end < text.length && /[\ud800-\udbff]/.test(text[end - 1]!)) end--;      // never between a surrogate pair
      await v.writeAsync(text.slice(from, end));
      if (end < text.length) slice(end); else swap();
    });
    enqueue(async () => {
      if (!lateHistory.wants(tab, gen) || !deck.rebaseBegin(tab, gen, cols, rows)) { giveUp(); return; }
      slice(0);
    });
  };
  const router = new TermStreamRouter({
    wireStart: () => {
      terminalClipboard.reset();
      if (termOutputBlocked) { router.resync(); return; }
      termResync.wireStarted(); heldSnapshots.clear(); lateHistory.clear(); lag(() => enqueue(async () => deck.newWire())); },
    history: (tab, gen, cols, rows, text) => lag(() => rebuildWithHistory(tab, gen, cols, rows, text)),
    snapshotStart: (tab, cols, rows, gen, historyFollows) => {
      lateHistory.drop(tab);                   // a newer generation: a rebuild of an older one has nothing to replace
      if (historyFollows) lateHistory.begin(tab, gen);
      settle.drop(tab);                        // superseded: its instance goes at `begin`
      if (deck.holdingFor(cols, rows)) heldSnapshots.add(`${tab}#${gen}`);
      lag(() => enqueue(async () => {
        deck.begin(tab, cols, rows, gen);
        syncGlassesFocusOrder(opts.layout(), dom);     // the new instance's helper textarea leaves the glasses' focus order
      }));
    },
    bytes: (tab, gen, text, fromSnapshot) => {
      if (fromSnapshot) lateHistory.snapshot(tab, gen, text.length);
      settle.bytes(tab, gen);
      lag(() => writerFor(tab, gen).push(text));
    },
    // Fires only for a snapshot that decoded WHOLE: after a give-up, that wire proves the stream works
    // again (termResync.decoded clears the stop and the notice at once).
    snapshotEnd: (tab, gen) => {
      termResync.decoded();
      if (heldSnapshots.delete(`${tab}#${gen}`)) settle.end(tab, gen);
      else commitSnapshot(tab, gen);
    },
    closed: (tab) => {
      lateHistory.drop(tab);
      settle.drop(tab);
      for (const k of [...heldSnapshots]) if (k.startsWith(`${tab}#`)) heldSnapshots.delete(k);
      lag(() => enqueue(async () => { deck.close(tab); dropWriters(tab); }));
    },
    // A stream that cannot be decoded is dropped whole: the router drops EVERY frame until the next
    // wire start, and re-declaring raw makes the host build a fresh wire — which opens with that
    // start — and snapshot every tab (ChannelHub.handleTermWire → rebindTermWire). Instances stay on
    // screen until their tab's new snapshot commits. The re-declaration waits its turn (termResync).
    failed: (_tab, _gen, err) => recoverWire(err),
  });
  clipboardEpoch = () => router.currentEpoch;
  const recoverWire = (error: unknown) => {
    if (termOutputBlocked) return;
    console.warn("[term] shared stream failed; resyncing every tab", error);
    router.resync(); lateHistory.clear();
    dbg.termResyncs = (dbg.termResyncs ?? 0) + 1;
    termResync.failed();
  };
  const overload = new TermOverload({
    stop: () => {
      termOutputBlocked = true;
      router.resync(); lateHistory.clear(); termResync.reset(false);
      clearPendingGhosts?.();
    },
    show: (message, reconnect) => {
      termStuckMark = streamNote.show(message);
      const button = document.createElement("button"); button.type = "button"; button.textContent = "Reconnect"; button.className = "term-stream-reconnect";
      scope.listen(button, "click", (event) => { event.stopPropagation(); reconnect(); });
      $("term-stream-note").append(document.createTextNode(" "), button);
    },
    reconnect: () => host.requestReconnect?.(),
  });
  termStreamError = (message) => {
    if (overload.receive(message, router.currentEpoch)) return true;
    const fault = parseTermStreamError(message);
    if (!fault) return false;
    if (fault.reason === "codec" && (router.currentEpoch === null || fault.epoch >= router.currentEpoch)) {
      recoverWire(new Error("Host terminal compression failed"));
    }
    return true;
  };
  dbg.termRx = router.stats;
  // A RENDERER CHANGE MOVES EVERY TAB OVER AT A FRESH SNAPSHOT (Terminal Settings → WebGPU rendering): a
  // terminal's renderer is chosen when its instance is mounted, and every snapshot mounts a fresh one. So
  // re-declare raw — the host builds a fresh wire and snapshots every tab, the path an undecodable stream
  // takes (no back-off: one request per change) — and each old instance stays on screen until its tab's
  // new one commits, built with the new renderer and every DOM-side module. A passive client has no
  // terminal; one whose control is down moves over at its next snapshot anyway.
  renewTerminals = () => {
    const c = channels.control;
    if (termOutputBlocked || !c || c.readyState !== "open" || !sessionControl?.isActive) return;
    router.resync();
    sendControl({ t: "term-mode", mode: "raw" });
    termResync.expectWire();
  };

  // Clear ghosts on active→passive (a passive client shows none), and clear ghosts left unconfirmed
  // too long — e.g. a no-echo password prompt (sudo / read -s) where the shell never echoes. Both go
  // through the queue so they can't race an in-flight apply. clearShown() is position-independent.
  const clearGhostsOp = () => enqueue(async () => { if (model.active()) model.reset(); await renderOverlay(); });
  clearPendingGhosts = clearGhostsOp;
  scope.interval(() => { if (isGhostStale(ghostSince, performance.now(), controller.rttMs())) clearGhostsOp(); }, 250);

  // Declare raw as soon as control is open. The host answers with a snapshot of every open tab once
  // BOTH this and the terminal channel are open — there is no replay request any more.
  //
  // And STATE THE PAGE'S VISIBILITY (final review C1): the `terminal-pause`/`-resume` sent from
  // `visibilitychange` may have gone into a control channel that was already dead — the phone case —
  // and the host voids its pause on a rebuild. A hidden page that reconnects pauses again; a visible
  // one lifts any pause still in force.
  const negotiateRaw = () => {
    if (termOutputBlocked) return;
    const c = channels.control;
    if (!c || c.readyState !== "open") return;
    c.send(encodeJson({ t: "term-mode", mode: "raw" }) as Uint8Array<ArrayBuffer>);
    c.send(encodeJson({ t: document.hidden ? "terminal-pause" : "terminal-resume" }) as Uint8Array<ArrayBuffer>);
    termResync.connectionOpened(); // a new connection starts over; the raw above is its request, its wire start owed
    resetPendingSwitch();          // a control (re)open: a switch sent while it was down never arrived
  };
  // (Re)attach the per-channel terminal listeners — first channels and every rebuild. A new
  // connection has a fresh shared zstd context, and the router drops everything until the new wire's start
  // (`attachTermChannel`); instances stay on screen until their tab's snapshot lands.
  bindTermChannel = (ch) => {
    attachTermChannel(router, ch.terminal);
    if (ch.control.readyState === "open") negotiateRaw(); else ch.control.addEventListener("open", negotiateRaw);
  };
}

// The host's two video channels. Routed by LABEL, because the connection hands over anything that is
// not one of rdev's three and a future channel must not be fed to the decoder.
function onExtraChannel(ch: RTCDataChannel): void {
  if (ch.label === "video") { dcDelivery.bindVideoChannel(ch); return; }
  if (ch.label === "video-feedback") { dcDelivery.bindFeedbackChannel(ch); return; }
  console.warn(`[dc] ignoring an unknown channel: ${ch.label}`);
}
// The answer now exists, so the payload-type map can finally be read — see updateCodecMap for why it
// cannot be read at `ontrack`.
function onNegotiated(): void {
  for (const [source, h] of webcodecsPacers) {
    const { map, fallback } = codecMapForSource(source);
    h.updateCodecMap?.(map, fallback);
  }
}
/// A REBUILD CLOSED THE OLD PEER. Its tracks are gone, so are the elements rendering them (audio has no
/// `frozenElementNeedsRebind` self-heal), the probe re-arms on the fresh peer's first track, and the host
/// zeroes held modifiers on a client's leave — a locked one carried across would be a lie on screen.
function onPeerClosed(state?: { controlRetained: boolean }): void {
  // Fast terminal/input/control channels survive a media-peer rebuild and do not emit another
  // open/control-state batch. Keep their admission/capability truth; otherwise every later source
  // is sent to AppKit as driving:false forever, although its track is receiving and decoding.
  if (!state?.controlRetained) { nativeControlSeen = false; sourceFocusGate?.close(); }
  nativeSources?.setSessionState(lastViewSet,lastSources,false,currentTheme(),smoothScrollEnabled());
  windowManager?.suspendWorkspaces();
  referenceReceipts.resetAll(); referenceBindings.clear(); referenceTracks.clear();
  for (const video of presentationChains.keys()) stopPresentation(video);
  probeStop?.(); probeStart = undefined; probeStop = undefined; probedEl = undefined;   // the fresh pc's onTrack re-arms the probe on the (persisting) focused <video>
  // The host calls releaseKeys() on client leave, which ZEROES currentFlags — so a locked modifier
  // carried across a rebuild is a lie the client would keep displaying. This is the clear condition
  // nothing else would catch: no DOM event fires, and both ends otherwise read healthy.
  windowManager?.releaseTouchMods();
  // THE OLD TRACKS ARE GONE, so the elements rendering them are too. The fresh pc's onTrack
  // re-attaches; leaving them would hold a dead track exactly as a stale <video> would, and audio
  // has no `frozenElementNeedsRebind` self-heal to notice.
  audioPlayback.detachAll();
  rxMeter = makeRxBitrateMeter();    // new peer → new byte counters; avoid a delta spike across the reset
}

// Refresh the footer from live stats: the ICE candidate-pair type (whether media is going direct (host),
// STUN-assisted (srflx), or TURN-relayed (turn)), the negotiated codec, the rtt, and the incoming bitrate.
// getStats() is async; re-check the pc is still connected after the await so we don't render a stale
// footer during a reconnect. Refreshed on connect + on a light interval (the pair can switch after an ICE
// restart). Cell selection/formatting lives in `statusCells` — this only supplies the report.
async function refreshIceLabel(): Promise<void> {
  const media = connection?.media;
  if (!media || connection?.connectionState !== "connected") return;
  let report: RTCStatsReport | undefined;
  try { report = await media.getStats(); } catch { /* stats unavailable */ }
  if (scope.disposed) return;
  if (connection?.connectionState !== "connected" || !report) return;
  dbg.codec = inboundVideoCodec(report);
  connState = "connected"; connText = "connected";
  renderStatus(report);
}

// Keep the candidate-pair label + the incoming-bitrate readout current. 1s so the rx-rate tracks changes
// (and drops promptly on hide/unsubscribe); also catches an ICE pair switch after a restart. No-op unless connected.
scope.interval(() => { void refreshIceLabel(); }, 1000);

// PUSH THE RECEIVER'S OWN COUNTERS TO THE HOST LOG, every 5 s to match the host's `[encode]` and
// `[bridge] fec:` windows so all three read on one timeline.
//
// IT RIDES THE DATA CHANNEL BECAUSE THE INSTRUMENT CANNOT TRAVEL BY CABLE. Attaching Safari's Web
// Inspector to the device under test brings up a USB network link, ICE finds it, and the media
// abandons the Wi-Fi path whose jitter is the thing being measured — so connecting the debugger
// destroys the symptom. In band is the only way to measure the path in use.
//
// Nothing is sent when no inbound video track exists, so an idle or terminal-only client is silent.
// The previous sample, so the report is a WINDOW rather than a session average. Every counter
// getStats() returns here is a running total: a session that opened badly would otherwise report its
// opening forever, which is exactly what `jbuf=843ms` meant on a stream that had long since
// recovered.
/// MAIN-THREAD RESPONSIVENESS, measured from inside the thread whose health is in question.
///
/// A page that locks up hard enough to refuse console input leaves no trace in any counter here:
/// every one of them describes the transport or the decoder, and all of those read perfectly healthy
/// while the tab is dead. This is the only number that describes the THREAD.
///
/// It works because a stall is measured AFTERWARDS. A timer that should fire every 250ms and fires
/// 3000ms late reports 2750ms of lateness on the tick that finally runs, so the stall is captured
/// even though nothing could run during it. A tab that never recovers reports nothing more — but the
/// last line before the silence shows whether lateness was already climbing, which is the difference
/// between a sudden death and a slide into one.
const MAIN_TICK_MS = 250;
let mainThreadLateMaxMs = 0;
/// Read and reset. Exported to whichever reporter is actually running: the `[rx]` line does not print
/// on the DataChannel arm at all — every inbound RTP counter is zero there because the media is on
/// the channel — so an instrument attached only to it is inert on exactly the path being debugged.
/// That is what happened to the first version of this.
function takeMainThreadLateMs(): number {
  const worst = mainThreadLateMaxMs;
  mainThreadLateMaxMs = 0;
  return worst;
}
let mainTickExpected = performance.now() + MAIN_TICK_MS;
scope.interval(() => {
  const now = performance.now();
  const late = now - mainTickExpected;
  if (late > mainThreadLateMaxMs) mainThreadLateMaxMs = late;
  mainTickExpected = now + MAIN_TICK_MS;
}, MAIN_TICK_MS);

let dcDeclineReported = false;
let previousRxStats: ReturnType<typeof inboundVideoDiagnostics> = [];
/// The focused window's element clock at the previous report, so the next one can say whether it
/// MOVED. Every getStats counter describes the decoder; this is the only thing that describes the
/// picture, and a stream can decode flawlessly while presenting a still image.
/// PRESENTED-frame counting, via `requestVideoFrameCallback` — the only browser API that reports a
/// frame having been PAINTED. `framesDecoded` is the decoder's count and `currentTime` on a
/// MediaStream is a wall clock; neither can see a frozen picture, and both said everything was fine
/// while a reporter watched one.
///
/// The callback re-arms itself and is re-attached whenever the focused element changes, so a
/// minimise/restore or a codec rebuild does not leave it counting a detached element forever.
let presentedFrames = 0;
/// Painted frames since the last report — paint time beside media time — for `presentationCadence`.
let presentedGaps: PaintSample[] = [];
/// Each presented frame's ARRIVAL beside its RTP timestamp, for the adaptive floor — a sliding window
/// of `ARRIVAL_WINDOW_MS`, pruned on push and on read, never cleared per report. See
/// `playout-floor.ts`: this is the INPUT to the jitter buffer, which the floor cannot change, and that
/// is what makes the floor loop-free.
let arrivals: ArrivalSample[] = [];
/// The spread measured at the last controller tick, for the [rx] line. Null is UNKNOWN.
let lastArrivalSpreadMs: number | null = null;
/// Five seconds of 60fps is 300; this leaves headroom for a long window without unbounded growth.
const MAX_PRESENTED_GAPS = 600;
let presentedElement: HTMLVideoElement | null = null;
let previousPresented: number | null = null;
let previousReportAt: number | null = null;
/// Consecutive stats windows in which the focused element decoded but painted nothing.
let frozenWindows = 0;
/// Cumulative self-heals this session, reported on the [rx] line so the recovery is observable.
let elementRebinds = 0;
/// Attempts before the self-heal admits it cannot fix this. Each one blacks the picture, so a loop
/// that never succeeds is strictly worse than stopping and saying so.
const MAX_ELEMENT_REBINDS = 3;
/// `framesDecoded` at the previous window, so the predicate can tell a FREEZE from an IDLE source.
let previousDecoded: number | null = null;

/// `requestVideoFrameCallback` is in newer DOM lib definitions as a REQUIRED member, so an interface
/// that redeclares it optional does not extend HTMLVideoElement. A structural alias keeps the runtime
/// feature test — Playwright WebKit and older Safari lack it — without fighting the type.
///
/// `receiveTime` and `rtpTimestamp` are the WebRTC-only members. Both engines fill them for a remote
/// track — Chromium always has, and WebKit does in `RealtimeIncomingVideoSource::metadataFromVideoFrame`
/// (the last packet's arrival, and the frame's timestamp) — unlike `mediaTime`, which Safari has
/// already been caught reporting unreliably on the same callback.
type RVFCMetadata = { mediaTime: number; receiveTime?: number; rtpTimestamp?: number };
type RVFCVideo = HTMLVideoElement & {
  requestVideoFrameCallback?: (cb: (now: number, metadata: RVFCMetadata) => void) => number };

/// Bumped on every arm, and captured by the callback chain it starts.
///
/// IDENTITY IS NOT ENOUGH TO RETIRE A CHAIN. A rebind sets `srcObject` to null and back on the SAME
/// element, so a guard comparing elements cannot tell the old chain from the new one, and whether
/// the old one is dead or merely pending is engine-dependent — killing it leaves the counter frozen,
/// keeping it double-counts. A generation answers both.
let presentationGeneration = 0;

type PresentationChain = { source: string; track: MediaStreamTrack; identity?: string; generation: number; callback?: number };
const presentationChains = new Map<HTMLVideoElement, PresentationChain>();
scope.defer(() => { for (const video of presentationChains.keys()) stopPresentation(video); }, "presentation-chains");
function stopPresentation(video: HTMLVideoElement): void {
  const chain = presentationChains.get(video); if (!chain) return;
  presentationChains.delete(video);
  if (chain.callback !== undefined) video.cancelVideoFrameCallback?.(chain.callback);
  referenceReceipts.reset(chain.source);
}
function tryReferenceBinding(source: string): void {
  const binding = referenceBindings.get(source); if (!binding?.trackId) return;
  for (const chain of presentationChains.values()) {
    if (chain.source === source && referenceTracks.get(source) === chain.track && referenceTrackIDs.get(chain.track) === binding.trackId) {
      referenceReceipts.bind(source, binding.epoch, chain.track, chain.generation); return;
    }
  }
}
function ensurePresentation(video: HTMLVideoElement): void {
  const track = (video.srcObject as MediaStream | null)?.getVideoTracks?.()[0];
  const source = video.closest<HTMLElement>(".source-window")?.dataset.source;
  const previous = presentationChains.get(video);
  const identity = track && referenceTrackIDs.get(track);
  if (previous?.track === track && previous?.source === source && previous?.identity === identity) return;
  if (previous) stopPresentation(video);
  const el = video as RVFCVideo;
  if (!track || !source || !el.requestVideoFrameCallback) return;
  const chain: PresentationChain = { source, track, identity, generation: ++presentationGeneration };
  presentationChains.set(video, chain);
  tryReferenceBinding(source);
  const tick = (now: number, metadata: RVFCMetadata) => {
    if (scope.disposed || presentationChains.get(video) !== chain) return;
    if ((video.srcObject as MediaStream | null)?.getVideoTracks?.()[0] !== track || referenceTrackIDs.get(track) !== chain.identity) { stopPresentation(video); return; }
    if (!video.ownerDocument.hidden && referenceTracks.get(source) === track) referenceReceipts.presented(source, track, chain.generation, metadata.rtpTimestamp);
    if (video === presentedElement) {
    presentedFrames++;
    // PAINT TIME BESIDE MEDIA TIME. A gap alone says nothing: rdev's timestamps carry real capture
    // time and a window source is content-driven, so a window that stops redrawing produces long
    // gaps with nothing lost and nothing late. What separates that from judder is whether the gap
    // MATCHED the media timeline — see `presentation-cadence.ts`. `now` is the callback's own
    // timestamp, so this measures paint-to-paint and includes nothing of our own scheduling.
    //
    // A browser that reports no `mediaTime` contributes no samples at all, which the cadence
    // function reports as UNKNOWN rather than as healthy.
    if (typeof metadata?.mediaTime === "number") {
      presentedGaps.push({ paintMs: now + (video.ownerDocument.defaultView?.performance.timeOrigin ?? performance.timeOrigin) - performance.timeOrigin, mediaMs: metadata.mediaTime * 1000 });
    }
    // ARRIVAL BESIDE TIMESTAMP, for the floor. Both fields or neither — a sample missing either would
    // be a deviation against nothing — and a browser reporting neither contributes no samples, which
    // the controller reads as UNKNOWN rather than as a clean path.
    if (typeof metadata?.receiveTime === "number" && typeof metadata?.rtpTimestamp === "number") {
      const receiveMs = metadata.receiveTime + (video.ownerDocument.defaultView?.performance.timeOrigin ?? performance.timeOrigin) - performance.timeOrigin;
      arrivals.push({ receiveMs, rtpTimestamp: metadata.rtpTimestamp });
      pruneArrivals(receiveMs);
    }
    // BOUNDED. This array is appended to sixty times a second for the life of the session; the
    // window only ever reads the last few hundred, so an unbounded one is a leak that grows at a
    // fixed rate forever.
    if (presentedGaps.length > MAX_PRESENTED_GAPS) presentedGaps.splice(0, presentedGaps.length - MAX_PRESENTED_GAPS);
    if (arrivals.length > MAX_PRESENTED_GAPS) arrivals.splice(0, arrivals.length - MAX_PRESENTED_GAPS);
    }
    chain.callback = el.requestVideoFrameCallback!(tick);
  };
  chain.callback = el.requestVideoFrameCallback(tick);
}
// One callback chain per video, shared by receipts and the existing focused-window
// cadence instrument. A focus change does not revoke an otherwise continuous stream.
function watchAllPresentations(): void {
  if (!referenceSupported) return;
  const videos = new Set(windowManager?.videos() ?? []);
  for (const video of presentationChains.keys()) if (!videos.has(video)) stopPresentation(video);
  for (const video of videos) ensurePresentation(video);
}
function watchPresentation(video: HTMLVideoElement | null, force = false): void {
  if (video === presentedElement && !force) { if (video) ensurePresentation(video); return; }
  if (force && video) stopPresentation(video);
  if (!referenceSupported && presentedElement && presentedElement !== video) stopPresentation(presentedElement);
  presentedElement = video;
  presentedFrames = 0; presentedGaps = []; arrivals = []; lastArrivalSpreadMs = null; previousPresented = null;
  if (video) ensurePresentation(video);
}
/// Drop arrivals older than the window, measured from `nowMs` on the `performance.now()` timeline
/// that `receiveTime` shares.
function pruneArrivals(nowMs: number): void {
  const cutoff = nowMs - ARRIVAL_WINDOW_MS;
  let stale = 0;
  while (stale < arrivals.length && arrivals[stale]!.receiveMs < cutoff) stale++;
  if (stale > 0) arrivals.splice(0, stale);
}

/// The adaptive playout floor. The ACTUATOR runs only while the select is on Auto — the moment the
/// user pins a value the controller stands down, and `playoutDelayIsAuto` is the one place that is
/// decided — but the MEASUREMENT runs regardless, so the [rx] line can say what the path demanded
/// beside what the user chose.
///
/// ONE SECOND. The spread is a measurement of something the floor cannot affect, so a raise waits for
/// nothing but the sample; the four-second window is what keeps the reading from moving by the second.
///
/// SENDS ONLY ON CHANGE. The floor is session-wide host state and every set re-broadcasts `view-set`
/// to every client, so a message per second would be pure noise on a path that has settled.
scope.interval(() => {
  if (!connection?.media || connection.connectionState !== "connected") return;
  // PRUNE BY WALL TIME BEFORE READING. The window is pruned on push, and a picture that stopped
  // presenting stops pushing — so without this a frozen or hidden picture would keep reporting the
  // spread of the last four seconds it painted, forever.
  pruneArrivals(performance.now());
  lastArrivalSpreadMs = arrivalSpread(arrivals);
  if (!windowManager?.playoutDelayIsAuto()) return;
  playoutFloor = nextPlayoutFloor(playoutFloor, lastArrivalSpreadMs);
  // THE WINDOW BESIDE THE FLOOR — started before the first frame (see `playoutWindowStart`) and
  // resized here to what the path needs.
  playoutWindow = nextPlayoutWindow(playoutWindow, lastArrivalSpreadMs, windowCapable);
  const request = playoutRequest(playoutFloor, playoutWindow);
  if (!lastPlayoutRequest || request.minMs !== lastPlayoutRequest.minMs || request.maxMs !== lastPlayoutRequest.maxMs) {
    // The very first tick sends only if there is something to ask for: a fresh session at floor 0
    // under the configured ceiling is what the host already has.
    if (lastPlayoutRequest !== null || request.minMs !== 0 || request.maxMs !== null) {
      lastPlayoutRequest = request;
      intendedPlayoutDelayMs = request.minMs;
      sendControl({ t: "set-playout-delay", minMs: request.minMs, maxMs: request.maxMs });
      rememberPlayoutWindow(playoutWindow);
    }
  }
}, 1000);

scope.interval(() => {
  const media = connection?.media; if (!media || connection?.connectionState !== "connected") return;
  void media.getStats().then((report) => {
    if (scope.disposed) return;
    const current = inboundVideoDiagnostics(report);
    // The FOCUSED window's element: the one whose picture the user is judging. A window that is
    // merely subscribed and unfocused is throttled on purpose, and reporting it would cry wolf.
    const video = dom.querySelector<HTMLVideoElement>(".source-window.focused .win-body video")
               ?? dom.querySelector<HTMLVideoElement>(".win-body video");
    watchPresentation(video);
    const wallNow = performance.now();
    const supported = !!(video as RVFCVideo | null)?.requestVideoFrameCallback;
    // The source's configured rate is what a gap is judged against — an 8fps throttled window has a
    // 125ms nominal period and is not juddering when it paints one frame every 125ms.
    const focusedFps = lastViewSet?.subs.find((sub) => sub.source === lastViewSet.focused)?.fps
      ?? lastViewSet?.subs[0]?.fps ?? null;
    const element = video === null || !supported ? null : {
      presented: previousPresented === null ? null : presentedFrames - previousPresented,
      elapsedMs: previousReportAt === null ? null : Math.round(wallNow - previousReportAt),
      readyState: video.readyState,
      paused: video.paused,
      rebinds: elementRebinds,
      cadence: focusedFps ? presentationCadence(presentedGaps, 1000 / focusedFps) : null,
      arrivalSpreadMs: lastArrivalSpreadMs,
      floor: (windowManager?.playoutDelayIsAuto() ?? true)
        ? (playoutWindow.active ? { ms: playoutWindow.sizeMs, auto: true, window: true } : { ms: playoutFloor.floorMs, auto: true })
        : { ms: intendedPlayoutDelayMs ?? 0, auto: false },
    };
    presentedGaps = [];   // per WINDOW, like every other delta on this line
    previousPresented = presentedFrames;
    previousReportAt = wallNow;

    // SELF-HEAL A FROZEN ELEMENT. An element that decodes without painting reports perfect health on
    // every other counter here, so this is the only place the condition is visible. Re-attaching
    // srcObject is the same recovery shouldRebindVideo performs for a replaced track.
    const decodedNow = current.reduce((sum, d) => sum + (d.framesDecoded ?? 0), 0);
    const decodedDelta = previousDecoded === null ? 0 : decodedNow - previousDecoded;
    previousDecoded = decodedNow;
    // `element.presented` is NULL for the first window after an arm — there is nothing to subtract
    // yet. THAT IS UNKNOWN, NOT ZERO: reading it as zero makes the window after every rebind look
    // frozen, which is the recovery being mistaken for the fault it was recovering from.
    if (video && element && element.presented !== null) {
      const track = (video.srcObject as MediaStream | null)?.getVideoTracks()[0];
      const decision = frozenElementNeedsRebind({
        presented: element.presented,
        decodedDelta,
        trackLive: track?.readyState === "live",
        paused: video.paused,
        hidden: document.hidden,
      }, frozenWindows);
      frozenWindows = decision.frozenWindows;
      if (decision.rebind && elementRebinds >= MAX_ELEMENT_REBINDS) {
        // BOUNDED. A recovery that cannot work must not run forever: each attempt tears `srcObject`
        // down and puts it back, which blacks the picture, so an endless loop is worse than the
        // fault it is chasing. Observed in the field as eight rebinds and a permanently blank video
        // with the receiver decoding every frame.
        if (elementRebinds === MAX_ELEMENT_REBINDS) {
          elementRebinds++;   // once, so this reports and then stays quiet
          console.error(`[rdev] video element still presenting nothing after ${MAX_ELEMENT_REBINDS} re-attaches — giving up`);
          setStatus("error", "Video stopped rendering and could not recover — reload the page");
          sendControl({ t: "rx-stats", line: `element re-attach GAVE UP after ${MAX_ELEMENT_REBINDS} attempts` });
        }
      } else if (decision.rebind) {
        // A FRESH MediaStream AROUND THE SAME TRACK, not the same stream object again. The element
        // sat at readyState 0 (HAVE_NOTHING) through eight re-attaches of the identical object while
        // its track stayed live and the receiver decoded 300 frames a window — WebKit reuses the
        // MediaStream object, and one it has finished with does not restart just because it was
        // assigned again. The track is what carries the media; the stream is only a wrapper.
        elementRebinds++;
        console.warn("[rdev] video element decoded but presented nothing — re-attaching");
        // REPORT IT NOW, not on the next 5s tick. The rebind fires at the END of the window that
        // detected the freeze, so a log that stops there shows the freeze and never the recovery —
        // which is exactly how two reproductions came back unreadable.
        sendControl({ t: "rx-stats", line: `element re-attached after ${FROZEN_WINDOWS_BEFORE_REBIND} frozen windows (rebind #${elementRebinds})` });
        // NULL FIRST. Assigning the same object back is a no-op in some engines, and a no-op is
        // exactly what this recovery must not be. `bindVideo` then owns the play() policy handling.
        video.srcObject = null;
        if (track) bindVideo(video, new MediaStream([track]));
        // RE-ARM THE INSTRUMENT, or the recovery can never be observed. Nulling `srcObject` ends the
        // pending frame callback, and `watchPresentation` skips an element it has already seen — so
        // without this the presented-frame counter stops for good on the FIRST rebind, the element
        // reads FROZEN forever however well it is painting, and this branch fires every two windows
        // for the life of the session. Seen in the field as `rebinds=4` and climbing, with
        // `frames=300/300 dropped=0 lost=0` throughout.
        watchPresentation(video, true);
      }
    }
    const line = formatDiagnostics(current, previousRxStats, {
      targetMs: jitterBufferTargetMs,
      // A relayed path and a LAN path produce entirely different numbers from identical code, and
      // nothing else in the host log says which one a session used.
      transport: connectionKind(report) ?? undefined,
      // ABSENT on the first tick: there is nothing to subtract yet, and claiming STALLED there would
      // fire on every session start.
      element: element === null || element.presented === null ? null : element,
    });
    // THE PACER'S OWN REPORT, which nothing else carries to the host.
    //
    // `[rx]` does not print on the DataChannel arm — every inbound RTP counter is zero there — so on
    // the path that is now the default, margin, cadence and loop smoothness were readable only from
    // a browser console. That is fine on loopback and useless on a phone, which is where the picture
    // is actually judged.
    //
    // The display half is the addition worth having: `miss` cannot say whether a frame was held
    // wrong because our callback was skipped or because the source's rate does not divide the
    // refresh, and those need opposite fixes — one is work off the main thread, the other is
    // arithmetic no client can beat.
    for (const [source, handle] of webcodecsPacers) {
      const st = handle.stats?.();
      if (!st) continue;
      const d = st.display;
      const smooth = d?.smoothPercent === null || d?.smoothPercent === undefined
        ? "?" : `${d.smoothPercent.toFixed(1)}%`;
      sendControl({ t: "rx-stats", line: `pace ${source} margin=${Math.round(st.marginMs ?? 0)}ms`
        + ` presented=${st.presented} miss=${st.cadenceMiss ?? 0} starve=${st.starve}`
        + ` src=${st.sourcePeriodMs === null || st.sourcePeriodMs === undefined ? "?" : st.sourcePeriodMs.toFixed(1) + "ms"}`
        + ` refresh=${d?.refreshMs == null ? "?" : d.refreshMs.toFixed(2) + "ms"}`
        + ` loop=${smooth} skips=${d?.skips ?? 0} lost=${d?.lostRefreshes ?? 0}`
        + ` worst=${d?.worstSteps ?? 0}x stalls=${d?.stalls ?? 0}`
        // OUR OWN CALLBACK'S COST, beside the skips it might explain. A skip with a cheap draw is the
        // compositor declining to call us; a skip with an expensive one is us.
        + ` draw=${st.draw ? `${st.draw.p50.toFixed(1)}/${st.draw.p95.toFixed(1)}/${st.draw.max.toFixed(1)}ms` : "?"}`
        // DID THE CADENCE LOCK ENGAGE. Free-running is the state the lock exists to escape: a frame
        // whose target lands near a vsync boundary flips between two of them on a millisecond of
        // noise, producing 1x/3x dwell pairs that read as continuous roughness rather than as a
        // hitch. Safari clamps performance.now() to 1ms, which is the same order as the boundary the
        // lock has to resolve, so whether it can lock at all is a real question and not a detail.
        + ` cadence=${st.cadence ?? "free"}`
        + ` dwell=${Object.entries(st.dwell ?? {}).map(([k, v]) => `${k}:${v}`).join(",") || "-"}` });
    }
    // ONCE, and on the first report rather than at startup: the control channel is open by then, so
    // it cannot be lost to a send that precedes it.
    if (!dcDeclineReported) {
      dcDeclineReported = true;
      sendControl({ t: "rx-stats", line: videoPathNote() });
    }
    previousRxStats = current;
    // Audio rides the SAME line, so the host prints one timeline rather than two that have to be
    // correlated by timestamp — the reason `[encode]`, `[rx]` and `[bridge] fec:` already share one.
    if (line) {
      sendControl({ t: "rx-stats",
                    line: `${line} ${formatAudioDiagnostics(report)} `
                        + `mainLate=${Math.round(takeMainThreadLateMs())}ms` });
    }
  }).catch(() => { /* stats unavailable */ });
}, 5000);

// Established LAST, as the first peer always was: everything it can call back into exists by now.
connection = transport.connect({
  scope, dbg, jitterBufferTargetMs, context: opts.context,
  sink: {
    channels: onChannels, status: setStatus, track: onTrack, extraChannel: onExtraChannel, earlyState: onEarlyState,
    joinGrid: measureJoinGrid,
    negotiated: onNegotiated, mediaConnected: () => { void refreshIceLabel(); }, peerClosed: onPeerClosed,
    drives: () => sessionControl?.isActive ?? false,
    moved: (room) => host.moved?.(room),
  },
});

/// The session's `<dialog>`s are BODY-LEVEL (index.html) and outlive it, so they are closed here;
/// one left open would sit over the dashboard. This file's own are `#tmux-kill-dialog`,
/// `#paste-lines-dialog` and `#paste-folder-dialog` (closing either answers its question no); the identity
/// panels (`#identity-mismatch`, `#e2e-setup`) belong to the CONNECTION, which closes them in
/// `connection.closeDialogs()` (rtc-connection.ts).
function closeSessionDialogs(): void {
  for (const id of ["tmux-kill-dialog", "paste-lines-dialog", "paste-folder-dialog"]) {
    const d = dom.getElementById(id) as HTMLDialogElement | null;
    if (d?.hasAttribute("open")) { if (typeof d.close === "function") closeClientDialog(d); else d.removeAttribute("open"); }
  }
  connection?.closeDialogs();
}

/// IMMEDIATE CANCELLATION: everything this session holds, released synchronously, in one call.
/// The UI goes FIRST — the decoders, the dialogs, then the scope: every listener, timer, frame and
/// observer, and the deferred teardowns LIFO (the windows, the terminal, the key strip) — while the
/// channels still exist, so a teardown that says something to the host (a held modifier released)
/// says it on an open channel rather than a closed one. Then the network, in the same tick: the
/// signalling leave with its close code and the peer, which the host is waiting on, then the §11
/// session. Once the scope is gone nothing the closing peer fires can report or re-arm a timer.
///
/// **EXCEPTION-SAFE, step by step**: a throw in one step must not leave the socket open (the host
/// would keep capturing for the full grace window), the peer up or the timers running, so every step
/// runs in its own try/catch, and `released` is set BEFORE any of them — a retry never re-runs a
/// step that threw. Idempotent.
function dispose(): void {
  if (released) return;
  released = true;
  const step = (label: string, fn: () => void) => {
    try { fn(); } catch (e) { console.error(`[session] dispose: ${label} failed`, e); }
  };
  // In a step of its own: from a build that threw early, `webcodecsPacers` does not exist yet.
  step("pacers", () => {
    for (const [source, handle] of webcodecsPacers) step(`pacer ${source}`, () => handle.stop());
    webcodecsPacers.clear();
  });
  step("dialogs", closeSessionDialogs);
  step("scope", () => scope.dispose());
  step("leave", leaveForNavigation);
  step("connection", () => connection?.close());
}

return {
  debug: dbg,
  navState: glassesNavState,
  leave: () => leaveForNavigation(),
  dispose,
  get disposed() { return released; },
};
}
