import { WorkspaceRenderer } from "./workspace-renderer";
import { attachWorkspaceInput } from "./workspace-input";
import { openClientDialog, closeClientDialog } from "./instance/overlays";
import { contextFor, presentationRoot, activeWithin } from "./instance/context";
import { positionSettingsCard } from "./settings-overlay";
import { chrome } from "./window-chrome";
import { windowControlIcon } from "./window-control-icons";
import { attachSimTouch } from "./sim-touch";
import { windowResizeSettle } from "./resize-settle";
import type { ChannelLike } from "../lib/channel";
import { parseWorkspaceFormat, type WorkspaceFormat, type ViewSetMsg, type Source, type SimStateWire } from "./source-picker";
import { simOfflineText } from "./sim-menu";
import { personAtWindow, windowLabel } from "./window-tabs";
import { audioBadge } from "./audio";
import { bindVideo, shouldRebindVideo } from "./video";
import { startCanvasPacer } from "./canvas-pacer";
import type { PacedRenderHandle } from "./paced-render";
import { initFloatingWindow, aspectRatioFromDims, tabBarHeight, statusBarHeight, clampToViewport, type Rect } from "./floating-window";
import { windowAspectRatio } from "./window-aspect";
import { attachPointer, attachScroll, toNormalized, type PointerHandle, type ViewGestureKind } from "./input";
import { attachPressHold } from "./press-hold";
import type { PastePoint } from "./paste-wire";
import { containedRect } from "./pointer-map";
import { FIT_VIEW, ViewGesture, clampView, maxZoom, transformFor, videoViewRect, visibleSourceRect, zoomedRect, type View } from "./view-zoom";
import { DEFAULT_POINTER_MODE, type PointerMode } from "./pointer-mode";
import { loadClientPrefs, saveClientPrefs, type ClientPrefs } from "../shared/client-prefs";
import { Trackpad } from "./trackpad";
import { attachWindowKeys } from "./keys";
import { mountWindowKeyboard, type WindowKeyboardHandle } from "./window-text-input";
import { attachBrowserFullscreen, exitRevealed, EXIT_LINGER_MS, type BrowserFullscreen } from "./window-fullscreen";
import { encodeJson } from "../lib/codec";
import { BITRATE_STEPS_BPS, autoScale, autoScaleWorthSending, nearestStep, bitrateLabel,
         codecUnmet,
         RECOVERY_STEPS_BP, recoveryLabel, AUTO_RECOVERY } from "./video-prefs";
import { makeRxBitrateMeter } from "../lib/probe";
import {
  SETTINGS_ROWS, settingsRowLabel, mountSettingsChoice, syncSettingsChoice,
} from "./window-settings";

// A real image source avoids the browser's missing-image frame around a CSS-only fallback.
const FALLBACK_CURSOR = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="12" height="19" viewBox="0 0 12 19"><path d="M0 0l12 11.5H6.8l3 6.2-2.6 1.3-3-6.3L0 16z" fill="#fff" stroke="#000" stroke-width="1"/></svg>')}`;

export type WindowManagerOptions = ConstructorParameters<typeof WindowManager>[1];

export interface WindowView { presentation?: WorkspaceFormat; source: string; name: string; focused: boolean; fps: number; scale: number; bitrateBps: number;
                              /// What the client ASKED for, and what the answer settled on. `activeCodec` is
                              /// ABSENT until the track resolves — the UI must tell that from "resolved and equal".
                              codec?: string; activeCodec?: string;
                              /// Whether the host is SENDING this source's audio, and — when it is not,
                              /// because another window of the same app carries it — which one does.
                              /// ABSENT MEANS UNKNOWN in both cases, never "off".
                              audio?: boolean; audioOwner?: string }

/// What a window shows before the host has echoed its effective values — the host's defaults
/// (60 fps is in code; 2 Mbps is where a stream starts). Only the panel's fallbacks read these.
const ECHO_PENDING = { fps: 60, scale: 1, bitrateBps: 2_000_000 } as const;

/// One window per OPEN window of the host's session (`view-set.windows`, minimized ones excluded —
/// they are tabs only), in the session's order, each carrying the host's LIVE echo from `subs` when
/// the host is streaming it. A window the host has not re-established yet (a restore, before this
/// driver's hello) is in the state already and gets its window at once.
export function windowViews(vs: Pick<ViewSetMsg, "windows" | "subs" | "focused">, sources: Source[]): WindowView[] {
  return vs.windows.filter((w) => !w.minimized).map((w) => {
    const s = vs.subs.find((x) => x.source === w.source);
    return {
      source: w.source,
      name: windowLabel(w, sources),
      focused: w.source === vs.focused,
      fps: s?.fps ?? ECHO_PENDING.fps, scale: s?.scale ?? ECHO_PENDING.scale, bitrateBps: s?.bitrateBps ?? ECHO_PENDING.bitrateBps,
      codec: s?.codec, activeCodec: s?.activeCodec,
      audio: s?.audio, audioOwner: s?.audioOwner,
      ...(w.source.startsWith("apps:") && sources.some(x => x.id === w.source && x.kind === "application-workspace")
        && (!s?.activeCodec || s.activeCodec === "av1") && parseWorkspaceFormat(s?.presentation) ? { presentation: parseWorkspaceFormat(s?.presentation)! } : {}),
    };
  });
}

/// A source is live unless the liveness map says otherwise. CONVENTION: absence ⇒ live (sims never appear in
/// source-status; a window appears only once the host has polled it). Only an explicit `false` darkens a window.
export function sourceIsLive(source: string, liveness: Map<string, boolean>): boolean {
  return liveness.get(source) !== false;
}

/// LOAD-BEARING: this MUST track the `.win-titlebar` height in style.css. It feeds `windowElementSize` /
/// `resizeRequest` — i.e. the host resize request/confirm protocol — so a stale value lands every window
/// body short in height AND makes every resize request wrong by the same amount.
export const WIN_CHROME_PX = chrome.headerHeight;   // floating .win-titlebar height in window-chrome.css
export const WIN_BORDER_PX = 1;    // .source-window border width in style.css (per side)

/// Element size for a video body of `bodyW` x `bodyH` CSS px. The BODY is what must match the source's real
/// point size, so the titlebar is added on top rather than folded into the aspect ratio — and because the
/// stylesheet sets `box-sizing: border-box` globally, the 1px border on each side eats into the element's
/// content box and must be added too, or the body lands 2px short in BOTH axes.
export function windowElementSize(bodyW: number, bodyH: number,
                                  chrome: number = WIN_CHROME_PX, border: number = WIN_BORDER_PX):
                                  { w: number; h: number } {
  return { w: bodyW + 2 * border, h: bodyH + chrome + 2 * border };
}

/// Element size → the BODY size to request from the host (points): the exact inverse of
/// `windowElementSize`. Null when the body would be degenerate, so a mid-drag 0-height element can never
/// ask the host to collapse a real window.
///
/// `scale` is the factor the body is currently DRAWN at — 1 normally, the fit scale while fitted. The
/// dragged pixels must be divided back out, or the request is off by 1/scale. Measured before this
/// existed: a window fitted at 0.559x and dragged 60px narrower (8% of its on-screen width) asked the host
/// for 721pt against a real 1400pt window — a 48% collapse from an 8% drag. A drag must move the real
/// window by what it LOOKS like it moves it by.
export function resizeRequest(elW: number, elH: number,
                              chrome: number = WIN_CHROME_PX, border: number = WIN_BORDER_PX,
                              scale = 1): { w: number; h: number } | null {
  const k = scale > 0 ? scale : 1;
  const w = Math.round((elW - 2 * border) / k);
  const h = Math.round((elH - chrome - 2 * border) / k);
  return w > 0 && h > 0 ? { w, h } : null;
}

/// How far to shift a window's titlebar controls LEFT to keep them inside the viewport.
///
/// Windows render at their ACTUAL host size and are deliberately allowed to overflow the viewport
/// ("actual size, overflow ALLOWED — dragged, never shrunk"). The controls live at the right end of the
/// titlebar, so an oversized window puts them outside the viewport entirely, where they cannot be
/// hit-tested — measured live: a 1730px-wide window placed its ✕ at x=1720 in a 1280px viewport and
/// `elementFromPoint` returned null. Shifting by exactly the overhang parks the cluster against the
/// viewport's right edge instead, without resizing the window or changing what it renders.
export function controlOffset(elementRight: number, viewportWidth: number): number {
  return Math.max(0, elementRight - viewportWidth);
}

/// The band a FITTED window may occupy: the stage — below the tab bar, above the status bar — inset by
/// `margin` on every edge. Viewport coordinates, because `.source-window` is `position: fixed`.
export function stageBand(vw: number, vh: number, tabbarH: number, statusbarH: number, margin = 16): Rect {
  return {
    x: margin,
    y: tabbarH + margin,
    w: Math.max(0, vw - 2 * margin),
    h: Math.max(0, vh - tabbarH - statusbarH - 2 * margin),
  };
}

/// The largest scale at which a `bodyW`x`bodyH` POINT body plus its non-scaling chrome fits `avail`.
///
/// SHRINK ONLY — a window that already fits returns exactly 1. Fit is a rescue for a window too big to
/// see, not a maximize: the stream is encoded at the host's size x the resolution pref, so upscaling would
/// only produce a softer picture.
///
/// The titlebar and the borders do NOT scale, so they are subtracted from the available space BEFORE the
/// ratio is taken rather than multiplied by it — the same body-vs-element split `windowElementSize` makes.
/// Floored at 0.1: a viewport too short to hold the chrome would otherwise yield a zero-or-negative scale
/// and a degenerate box, and a 0-sized window keeps measuring 0 forever.
export function fitScale(bodyW: number, bodyH: number, availW: number, availH: number,
                         chrome: number = WIN_CHROME_PX, border: number = WIN_BORDER_PX): number {
  if (bodyW <= 0 || bodyH <= 0) return 1;
  const k = Math.min((availW - 2 * border) / bodyW, (availH - chrome - 2 * border) / bodyH);
  return Math.min(1, Math.max(0.1, k));
}

/// The scale a FITTED window is actually DRAWN at: the band-filling fit, further reduced by any scale the
/// user pinned with the grip.
///
/// LOAD-BEARING — `min`, not "the pin wins". In fit mode the drawn size is a function of the BAND and the
/// host size, never of the drag, so the grip used to shrink the real window and `applySize` would then
/// re-fit that smaller window straight back out to fill the band. Measured, host 1658x1084 in a 1000x700
/// viewport (fit 0.4889, drawn 811px): dragging the body to 600 -> host 1227pt, refit 0.6608, REDRAWN 811;
/// to 400 -> host 818pt, refit 0.9907, REDRAWN 810; to 200 -> host 409pt, refit **1.0000**, REDRAWN 409.
/// So the drag had no visible effect at all until the host window became small enough to fit unscaled, at
/// which point the window snapped to the host's size — bigger than what was dragged — and fit was silently
/// over. Pinning the scale the body was drawn at makes `host x k` land exactly on the dragged size.
///
/// The `min` is what keeps fit's contract: a pin can only ever shrink further, so a window that later
/// GROWS on the host is still shown whole rather than overflowing at a stale zoom.
export function drawnFitScale(bodyW: number, bodyH: number, availW: number, availH: number,
                              pin?: number, chrome: number = WIN_CHROME_PX, border: number = WIN_BORDER_PX): number {
  const bandFit = fitScale(bodyW, bodyH, availW, availH, chrome, border);
  return pin === undefined ? bandFit : Math.min(bandFit, pin);
}

/// Centre a box in the band — the placement used when fit is switched ON.
export function centerIn(size: { w: number; h: number }, band: Rect): { x: number; y: number } {
  return { x: band.x + (band.w - size.w) / 2, y: band.y + (band.h - size.h) / 2 };
}

/// Move a rect back inside the band WITHOUT resizing it — the placement used on every recompute AFTER the
/// toggle (host window resize, viewport resize). Centring is the entry gesture only: a window dragged aside
/// to see one behind it must stay where the user put it. A box larger than the band pins to its origin.
export function nudgeInto(rect: Rect, band: Rect): { x: number; y: number } {
  return {
    x: Math.max(band.x, Math.min(rect.x, band.x + band.w - rect.w)),
    y: Math.max(band.y, Math.min(rect.y, band.y + band.h - rect.h)),
  };
}

/// The CSS `cursor` value for a host cursor image, or `auto` (the page's own cursor) when we have none.
/// The client's pointer WEARS this shape — no cursor position ever crosses the wire, so there is no pointer
/// latency and no compositor. CSS hotspot offsets must be integers.
export function cursorCssValue(dataUrl: string | null, hotspotX: number, hotspotY: number): string {
  return dataUrl ? `url("${dataUrl}") ${Math.round(hotspotX)} ${Math.round(hotspotY)}, auto` : "auto";
}

/// Initial placement for a newly-opened window: a CASCADE, stepping down-right.
///
/// LOAD-BEARING — the vertical step must exceed the titlebar height. This used to tile left-to-right on a
/// shared row with `stepX = 300` ("≈ the default window width (280) + a gap"), which was true when every
/// window was a fixed 280px. Windows now render at their ACTUAL host size (routinely 400-1700px), so a
/// shared row overlaps the neighbour by hundreds of pixels — and because the controls live at the RIGHT
/// end of the titlebar, they are precisely what gets buried. Measured: with 4 windows subscribed,
/// `elementFromPoint` over one window's − returned a DIFFERENT window's `.win-title`, and clicking it did
/// nothing. Separating every window vertically by more than the chrome height keeps each titlebar — and so
/// each window's controls — visible and clickable no matter how wide the windows are.
///
/// Bounded so a long run of opens/closes never marches a window off-screen. Each is freely draggable after.
export function tileOffset(index: number, viewportW: number = typeof window !== "undefined" ? window.innerWidth : 1280): { x: number; y: number } {
  const stepX = 34, stepY = 44, marginX = 24, top = 72, perRun = 8, runShift = 56;
  const slot = index % perRun;
  const run = Math.floor(index / perRun) % 4;   // a 4th run wraps back to the first — bounded, not endless
  const x = marginX + run * runShift + slot * stepX;
  return { x: Math.min(x, Math.max(marginX, viewportW - 120)), y: top + slot * stepY };
}

/// The debounce on Auto recomputes. A geometry storm — dragging the browser window, a grip drag, an
/// orientation change — must produce ONE request, not one per frame: every scale change costs the host a
/// CVPixelBufferPool + VTCompressionSession recreate and a fresh IDR.
const AUTO_DEBOUNCE_MS = 1000;

/// Layouts that pin the focused window to the viewport (full-bleed + object-fit: contain), where an
/// inline width/height would fight the CSS and a control can never overflow.
///
/// LOAD-BEARING — enumerated, never written as `!== "floating"`. `data-layout` is UNSET until
/// watchLayoutMode fires its first callback, and unset must behave as floating (the default mode).
/// The inverted form makes unset mean "pinned", which silently stops every window being sized.
const PINNED_LAYOUTS: ReadonlySet<string> = new Set(["tabbed", "glasses"]);
/// Whether two crops are the same to within a quarter of a percent — far below the even-pixel grid
/// `CropRect.pixels` rounds to on the host, so anything smaller cannot change a single encoded pixel.
const CROP_EPSILON = 0.0025;
/// The whole source — the host's default, and what an unzoomed picture always yields.
function isFullCrop(c: { x: number; y: number; w: number; h: number }): boolean {
  return c.x < CROP_EPSILON && c.y < CROP_EPSILON
      && c.w > 1 - CROP_EPSILON && c.h > 1 - CROP_EPSILON;
}
function sameCrop(a: { x: number; y: number; w: number; h: number },
                  b: { x: number; y: number; w: number; h: number } | undefined): boolean {
  return b !== undefined && Math.abs(a.x - b.x) < CROP_EPSILON && Math.abs(a.y - b.y) < CROP_EPSILON
      && Math.abs(a.w - b.w) < CROP_EPSILON && Math.abs(a.h - b.h) < CROP_EPSILON;
}

const isPinnedLayout = (root: HTMLElement): boolean =>
  PINNED_LAYOUTS.has(root.dataset.layout ?? "");

function fillSelect(sel: HTMLSelectElement, values: readonly number[], label: (v: number) => string): void {
  for (const v of values) {
    const o = document.createElement("option");
    o.value = String(v); o.textContent = label(v);
    sel.append(o);
  }
}

interface Win {
  workspace?: WorkspaceRenderer;
  workspaceSuspendedTrack?: MediaStreamTrack;
  workspaceNote?: HTMLElement;
  /// The source this window renders. Carried on the record because several painters take only a
  /// `Win` and now need per-source state (`views`) — a reverse lookup through `this.wins` would work
  /// and would be a second way to answer a question the record can answer directly.
  source: string;
  zoomBtn: HTMLButtonElement;
  /// The pointer attachment's handle, so a mode toggle can cancel a gesture already in flight.
  pointer: PointerHandle;
  el: HTMLElement; video: HTMLVideoElement; title: HTMLElement; setRatio: (r: number) => void; focused: boolean;
  bitrateSel: HTMLSelectElement;
  codecInfo: HTMLElement; recoverySel: HTMLSelectElement; rate: HTMLElement;
  referenceRecovery: HTMLButtonElement;
  delaySel: HTMLButtonElement; panel: HTMLDialogElement; gear: HTMLButtonElement;
  meter: (report: RTCStatsReport) => number; offline: HTMLElement; fit: HTMLButtonElement;
  /// The titlebar's `Full screen`, and the `Exit` that replaces the whole titlebar while it is on.
  fsBtn: HTMLButtonElement; fsExit: HTMLButtonElement;
  padCursor: HTMLImageElement;
  audioBtn: HTMLButtonElement; audioTag: HTMLElement;
  /// Where this window's trackpad cursor is, normalized. Mirrors `Trackpad`'s own position so the
  /// painter can redraw on a resize without asking the machine.
  cursorPos: { x: number; y: number };
  // The video track currently bound to `video`, so a REPLACEMENT track for the same source is
  // detectable. Lives on the Win rather than keyed by source, deliberately: it describes what this
  // element is rendering, and it must not survive the element. `sync` destroys the Win on
  // unsubscribe, so minimize->restore starts with no bound track and rebinds — which is correct, and
  // is the opposite of `fitted`/`sizes`, which ARE keyed by source precisely so they do survive.
  boundTrack?: MediaStreamTrack;
  boundTrackIdentity?: string;
  /// Present only under `?render=canvas`. Owns the canvas overlay and both callback loops.
  pacer?: PacedRenderHandle;
  /// The RTCRtpReceiver the WebCodecs pacer is attached to.
  ///
  /// LOAD-BEARING, and the same lesson `shouldRebindVideo` records from the other side. A codec
  /// change — or any unsubscribe/resubscribe — makes the host REMOVE the source's track and ADD a
  /// fresh one, which hands over a NEW receiver under the same MSID. The <video> element is stable
  /// across that, which is why the canvas pacer needs no equivalent; an encoded transform is bound to
  /// the RECEIVER, so a stale one delivers nothing. Measured: `onrtctransform` never fires, the
  /// worker never speaks, and the window is simply blank with no error anywhere.
  pacerReceiver?: RTCRtpReceiver;
  /// What this window registers BEYOND its own element — the titlebar's hold listens on `window`, because
  /// a finger's moves and release land anywhere — aborted when the window goes (`sync`, `clear`). Its
  /// element's own listeners die with the element; these would outlive it, one set per window opened.
  listeners: AbortController;
}

export class WindowManager {
  private wins = new Map<string, Win>();
  private sizes = new Map<string, { w: number; h: number }>();   // source -> host point size
  private pixelSizes = new Map<string, { w: number; h: number }>();   // source -> host NATIVE PIXEL size
  // Sources in FIT mode: drawn scaled down so the whole host window is visible. CLIENT-SIDE ONLY — the
  // host window keeps its real size and nothing about this crosses the wire. Keyed by source (not by
  // element) so the mode survives minimize->restore and unsubscribe->resubscribe, exactly as `sizes` does.
  private fitted = new Set<string>();
  /// Sources whose paced renderer started and then died. Not retried — see `ensurePacer`.
  private pacerFailed = new Set<string>();
  // The drawn scale a grip drag pinned for a FITTED source. Without it the drag is invisible: applySize
  // would re-fit the now-smaller host window straight back out to fill the band (see `drawnFitScale`).
  // Keyed by source, like `fitted` and `sizes`, so it survives minimize->restore. Cleared by `toggleFit`,
  // which is the reset gesture — pressing Fit means "show me this whole window" all over again.
  private fitPin = new Map<string, number>();
  /// Each source's zoom and pan of the PICTURE (`view-zoom.ts`). Keyed by source but DELIBERATELY NOT
  /// surviving unsubscribe — the opposite of `sizes`/`fitted`, which are keyed by source precisely so
  /// they survive minimize->restore. A restored window opens fitted, like a fresh one.
  private readonly views = new Map<string, View>();
  /// "zoom" while the user is adjusting the picture rather than driving the Mac. Per source, because
  /// the zoom it manipulates is. Dropped with the view on unsubscribe.
  private readonly viewModes = new Map<string, "input" | "zoom">();
  /// The last crop sent per source, so a settle that moved nothing sends nothing. Several paths call
  /// `recomputeAuto` for reasons that never touch the picture's position — a host size push, a scale
  /// change — and each of those would otherwise re-send an identical rect.
  private readonly sentCrops = new Map<string, { x: number; y: number; w: number; h: number }>();
  // Sources whose auto-fit decision has been made. SEPARATE from `fitted` on purpose: `fitted` being false
  // is ambiguous — "never decided" vs "decided, then the user turned it off" — and without this latch the
  // next host size push (the 300ms poll fires on any host-side resize) would re-fit over the user. Keyed
  // by source so it survives minimize->restore, which destroys and recreates the element.
  private autoFitDecided = new Set<string>();
  /// THIS DEVICE's preferences (`shared/client-prefs.ts`): one frame rate, resolution, bitrate, codec
  /// and touch mode for every window. Resolution `auto` is still decided PER WINDOW — each derives its
  /// own ceiling from its box and reports it (`sendAuto`); a fixed resolution is the host's to apply.
  private devicePrefs: ClientPrefs;
  /// The last scale Auto actually SENT for a source, so an unchanged computation sends nothing.
  ///
  /// LOAD-BEARING: dropped when the source leaves the view set, while the device's mode survives it.
  /// `SimManager.subscribe` builds a fresh `SourceStream` from `defaultPrefs` for any id that is not
  /// already subscribed, so a re-subscribed source is back at the host default — a cache that survived
  /// would see "same as last time", send nothing, and strand it there. `−` minimize unsubscribes, so
  /// every restore takes this path.
  private lastSentAuto = new Map<string, number>();
  private autoObservers = new Map<string, ResizeObserver>();
  /// The on-screen keyboard, mounted on the FOCUSED window only — one strip on screen at a time even
  /// when three windows are open on a landscape iPad.
  private keyboards = new Map<string, WindowKeyboardHandle>();
  private autoTimers = new Map<string, number>();
  private dprDispose?: () => void;
  // Resize is REQUEST/CONFIRM (iPadOS-style), never optimistic: while the grip is held the frame follows the
  // pointer with the body blurred; on release we send ONE request and stay blurred until the host replies
  // with the window's real size, which we animate to. "resizing" also suppresses incoming size pushes so a
  // background poll can't yank the frame mid-drag.
  private resizeState = new Map<string, "resizing" | "pending">();
  private settleTimers = new Map<string, number>();
  private cursorCss = "auto";   // latest host cursor shape; applied to each window body
  private cursorUrl: string | null = null;              // trackpad mode: the image itself
  private cursorSize: { w: number; h: number } | null = null;
  private cursorHotspot = { x: 0, y: 0 };
  /// READ ONCE, not per event. `mode` is consulted on every pointermove, and the device set is read
  /// once, in the constructor — 60 storage reads a second for a value only this class ever changes.
  private pointerMode: PointerMode;
  private created = 0;   // for the cascade offset
  /// The positions the host's session state remembers (`view-set.windows`), by source. Read when a
  /// window is created; a CHANGE moves an open window (`setStatePositions`).
  private statePositions = new Map<string, { x: number; y: number }>();
  private lastStreams = new Map<string, MediaStream>();
  private liveness = new Map<string, boolean>();
  private simStates = new Map<string, SimStateWire>();
  private readonly rxInterval: ReturnType<typeof setInterval>;
  /// Every page-level listener this manager adds, removed in ONE `abort()` by `clear()`. They used to
  /// be anonymous, so `clear()` could not remove them — harmless while each connection had its own
  /// document, a leak per connection now that the session lives in the dashboard's.
  private readonly pageListeners = new AbortController();
  /// The source whose window is FULL SCREEN, or null (`setFullscreen`, `window-fullscreen.ts`). One at a
  /// time, like focus — there is one screen to fill.
  private fullscreen: string | null = null;
  private readonly browserFs: BrowserFullscreen;
  /// A mouse's Exit button hides after `EXIT_LINGER_MS` (see `onFullscreenPointer`).
  private exitTimer: number | undefined;

  private get context() { return contextFor(this.container); }
  private get ui() { return presentationRoot(this.container); }
  private get viewportWidth() { return this.context?.viewport.size().width ?? window.innerWidth; }
  private get viewportHeight() { return this.context?.viewport.size().height ?? window.innerHeight; }

  constructor(
    private readonly container: HTMLElement,
    private readonly opts: {
      workspaceSupported?: boolean;
      workspaceActive?(): boolean;
      trackIdentity?: (track: MediaStreamTrack) => string | undefined;
      onFocus(source: string): void;
      onClose(source: string): void;
      /// The `−` button: the caller unsubscribes the source (freeing the host's capture + encode) and
      /// parks it so its tab stays in the bar, ready to restore.
      onMinimize(source: string): void;
      /// A window's DERIVED values — what this client measured for THAT window: the Auto resolution
      /// ceiling (only while the device's resolution is Auto) and the crop. The caller sends
      /// `set-source-prefs`. The device's own preferences go to `onDevicePrefs`.
      onPrefs(source: string, patch: Partial<{ scale: number;
                                              crop: { x: number; y: number; w: number; h: number } }>): void;
      /// This DEVICE's preferences changed from a window's panel (fps, resolution, bitrate, codec, touch
      /// mode) — already applied to every window and saved. The caller sends `set-prefs`.
      onDevicePrefs?(prefs: ClientPrefs): void;
      /// The device set to start from; `loadClientPrefs()` when absent.
      prefs?: ClientPrefs;
      /// SESSION-WIDE despite living in a window titlebar: one forced FEC overhead for the whole
      /// connection, so it names no source. `null` is adaptive control.
      onRecovery(bp: number | null): void;
      /// The playout-delay FLOOR in milliseconds; null is Auto. Session-wide, like onRecovery.
      onPlayoutDelay(minMs: number | null): void;
      /// Raise or lower the HOST's physical screen curtain. Broader than session-wide: it changes the
      /// Mac itself and outlives this connection, which is why its row is labelled "(this Mac)".
      onCurtain?(on: boolean): void;
      /// Mute or unmute ONE source for this client. The caller silences the element itself
      /// immediately and sends `set-source-audio` — the local mute is what makes it instant, the
      /// message is what makes it cheap.
      onSourceAudio?(source: string, enabled: boolean): void;
      /// Whether THIS client has muted the source locally. Read rather than mirrored, so the
      /// button and the playback element cannot disagree about what is muted.
      audioIsMuted?(source: string): boolean;
      /// The user dragged the grip: ask the host to resize the REAL window (points). Best-effort — the
      /// host's next source-status push is authoritative and overrides whatever we drew locally.
      onResize?(source: string, w: number, h: number): void;
      /// A window was dragged to a new place on the desktop layout — once, at the end of the drag. The
      /// caller sends `set-window-position`: where a window sits is the SESSION's, so another device
      /// opens it there too.
      onMoved?(source: string, x: number, y: number): void;
      /// A window went full screen (its source) or came out of it (null). The session makes the WINDOW
      /// surface the current one (`data-tab`), which the tabbed layout reads: a `data-tab` left on the
      /// terminal — a terminal tab tapped on the floating layout, then the iPad turned upright — would
      /// hide the full-screen window along with everything else.
      onFullscreen?(source: string | null): void;
      /// PASTE AND DROP (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md): whether this client
      /// may paste into a window at all — it drives, and it has windows. Read at each gesture; absent
      /// means never, and then every gesture below is left to whatever it did before.
      canPaste?(): boolean;
      /// The window's paste menu, at `at` (client px): a held finger or a right-click on its TITLEBAR,
      /// or in full screen a held `⌨` (§2.2). The menu's items target THIS window.
      onWindowMenu?(source: string, at: { x: number; y: number }): void;
      onSimAction?(source: string, action: "home" | "keyboard"): void;
      /// Something DROPPED on the window's picture (§2.5, §5): `at` is the point on the PICTURE, each
      /// coordinate 0…1, normalized exactly as a touch is — letterbox and zoom included — and clamped
      /// to it. `dt` is the drop's own transfer, read by the caller (files, else text).
      onWindowDrop?(source: string, at: PastePoint, dt: DataTransfer | null): void;
      /// TESTING ONLY (`?render=canvas` | `?render=webcodecs`). Absent means the ordinary <video>
      /// path, untouched — which stays the default.
      ///
      ///   canvas     the <video> still decodes; only PRESENTATION moves to a canvas rdev paces.
      ///   webcodecs  the <video> is bypassed: RTCRtpScriptTransform -> VideoDecoder -> canvas, so
      ///              rdev owns decode as well. Needs the source's RTCRtpReceiver and the negotiated
      ///              payload-type map, neither of which WindowManager can reach on its own.
      pacedRender?: {
        mode: "canvas" | "webcodecs";
        marginMs: number | "auto";
        cadenceLock: boolean;
        /// `?probe=1`. Only the canvas path needs it here — the WebCodecs pacer is built in main.ts
        /// and gets it directly.
        probe?: boolean;
        webcodecs?: {
          receiverFor(source: string): RTCRtpReceiver | undefined;
          /// The handle main.ts already created for this source at `ontrack`. WindowManager does not
          /// construct WebCodecs pacers: the transform must be attached before RTP flows, which is
          /// long before a window exists.
          pacerFor(source: string): PacedRenderHandle | undefined;
        };
      };
      inputChannel: ChannelLike;
      nowMs(): number;
      pc(): Pick<RTCPeerConnection, "getReceivers"> | null | undefined;   // getter: the pc rebuilds on reconnect, so don't capture the instance
    },
  ) {
    this.devicePrefs = opts.prefs ?? loadClientPrefs(this.context?.storage);
    this.pointerMode = this.devicePrefs.pointerMode ?? DEFAULT_POINTER_MODE;
    const { signal } = this.pageListeners;
    this.rxInterval = setInterval(() => this.tickRxBitrate(), 1000);
    if (this.context) {
      const off = this.context.onResize(this.onViewportResize);
      signal.addEventListener("abort", off, {once: true});
    } else window.addEventListener("resize", this.onViewportResize, { signal });
    this.watchDpr();
    // DESKTOP DISMISSAL, and only that: the panel's own close button is what serves every layout.
    // Esc and click-outside are conveniences a pointer-and-keyboard user expects, not the mechanism.
    document.addEventListener("pointerdown", (e) => {
      if (this.context && !e.composedPath().includes(this.context.root)) return;
      if ((e.composedPath()[0] as Element).closest?.(".win-settings-choice-menu")) return;
      this.closeAllSettings();
    }, { signal });
    document.addEventListener("keydown", (e) => { if (this.context && !e.composedPath().includes(this.context.root)) return; if (e.key === "Escape") this.closeAllSettings(); }, { signal });
    const settingsLayout = new MutationObserver(() => this.closeAllSettings());
    settingsLayout.observe(this.ui, { attributes: true, attributeFilter: ["data-layout"] });
    signal.addEventListener("abort", () => settingsLayout.disconnect(), { once: true });
    this.browserFs = attachBrowserFullscreen({ element: this.container, onLeft: () => this.setFullscreen(null), signal });
    // CAPTURE, so a handler under the picture that stops the event cannot hide the way out from a mouse.
    document.addEventListener("pointermove", this.onFullscreenPointer, { signal, capture: true });
  }

  /// devicePixelRatio changes — the browser window dragged to a display with a different backing scale,
  /// or zoomed — do NOT resize the body, so the ResizeObserver cannot see them, yet they change how many
  /// device pixels the same box paints. `matchMedia` on the CURRENT dpr fires once when it stops
  /// matching, so re-arm against the new value each time.
  private watchDpr(): void {
    if (typeof window.matchMedia !== "function") return;
    const mq = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
    const onChange = (): void => {
      this.dprDispose?.();
      for (const source of this.wins.keys()) this.recomputeAuto(source);
      this.watchDpr();
    };
    mq.addEventListener("change", onChange);
    this.dprDispose = () => { mq.removeEventListener("change", onChange); this.dprDispose = undefined; };
  }

  /// Recompute a source's Auto scale and, if it changed, ask the host for it.
  ///
  /// Debounced, EXCEPT for a source's first computation — which fires immediately so the stream starts at
  /// the right resolution instead of sitting at the host's default until the debounce elapses. "First" is
  /// "nothing sent yet", so a computation that bailed out (no native size yet) leaves the next one prompt.
  private recomputeAuto(source: string): void {
    // THE CROP RIDES THE SETTLE, NOT THE GESTURE. This method is called from exactly the moments the
    // picture has finished moving — the view gesture's `up` branch, `resetView`, the body's
    // ResizeObserver and each host size push — which is the behaviour that makes the checkerboard
    // acceptable: one crop change per settle, not one per frame.
    //
    // NOT from `refreshView`, which is the obvious-looking home and is wrong: it fires on EVERY
    // gesture frame, so the crop would stream up the control channel throughout a pinch.
    //
    // Undebounced, unlike the Auto scale below: a crop change costs the host no encoder recreate and
    // no keyframe, so there is nothing to protect against.
    this.sendCrop(source);
    const immediate = !this.lastSentAuto.has(source);
    this.clearAutoTimer(source);
    if (immediate) { this.sendAuto(source); return; }
    this.autoTimers.set(source, window.setTimeout(() => {
      this.autoTimers.delete(source);
      this.sendAuto(source);
    }, AUTO_DEBOUNCE_MS));
  }

  private clearAutoTimer(source: string): void {
    const t = this.autoTimers.get(source);
    if (t !== undefined) { window.clearTimeout(t); this.autoTimers.delete(source); }
  }

  /// Compute and send. Every bail-out here leaves `lastSentAuto` untouched, so the host keeps whatever it
  /// was last asked for rather than being driven by a momentarily-unknowable measurement.
  private sendAuto(source: string): void {
    if (source.startsWith("apps:")) return;
    if ((this.context?.resizeSettle ?? windowResizeSettle).defer(this, `auto:${source}`, () => this.sendAuto(source))) return;
    if (this.modeOf(source) !== "auto") return;
    // The user owns the frame while the grip is held, and the observer fires continuously through a drag
    // — the same guard `setSourceSize` and `onViewportResize` already apply.
    if (this.resizeState.get(source) === "resizing") return;
    const m = this.autoMeasure(source);
    if (!m || m.scale === null) return;
    // A DEADBAND, NOT AN EQUALITY CHECK. See `autoScaleWorthSending`: every send recreates the
    // encoder and emits an IDR, and exact equality on a float ratio let a sub-pixel layout shift buy
    // one. `lastSentAuto` still holds the value SENT, never the value computed, so a run of
    // below-threshold measurements is compared against the last thing the host was actually told —
    // otherwise the deadband would ratchet, drifting arbitrarily far in small steps.
    if (!autoScaleWorthSending(this.lastSentAuto.get(source), m.scale, m.px.w)) return;
    this.lastSentAuto.set(source, m.scale);
    this.opts.onPrefs(source, { scale: m.scale });
  }

  /// The measurement behind one Auto decision, or null when a required input is missing. Split out of
  /// `sendAuto` so `autoDebug` reports exactly what the decision saw.
  private autoMeasure(source: string):
    { pt: { w: number; h: number }; px: { w: number; h: number }; box: { w: number; h: number };
      dpr: number; scale: number | null } | null {
    const win = this.wins.get(source);
    const pt = this.sizes.get(source), px = this.pixelSizes.get(source);
    if (!win || !pt || !px) return null;   // native size unknown: a simulator, or before the first capture push
    const body = win.el.querySelector(".win-body") as HTMLElement | null;
    if (!body) return null;
    const r = body.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    // THE EFFECTIVE DRAWN BOX. A zoomed picture is painted at z times the body, so it needs z times
    // the pixels — otherwise zoom is a magnifying glass over an upscale. `autoScale` is unchanged: it
    // already clamps at native and quantises to the 16px grid, so native parity as the zoom ceiling
    // and native as the resolution ceiling are reached together.
    const z = this.viewOf(source).z;
    const box = { w: r.width * z, h: r.height * z };
    return {
      pt, px, box, dpr,
      scale: autoScale({ w: pt.w, h: pt.h, pxW: px.w, pxH: px.h, boxW: box.w, boxH: box.h, dpr }),
    };
  }

  /// Observability for `e2e/auto-scale-check.mjs` — the ResizeObserver, the debounce and the measurement
  /// are all invisible to jsdom, so the gate reads the real numbers from here.
  autoDebug(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const source of this.wins.keys()) {
      out[source] = { mode: this.modeOf(source), lastSent: this.lastSentAuto.get(source),
                      ...(this.autoMeasure(source) ?? {}) };
    }
    return out;
  }

  /// Remember a source's point size and apply it to its window (if any). Called from `source-list` and from
  /// every `source-status` that carries a size. A message WITHOUT a size never clears what we know.
  /// Apply the host's current cursor shape to every window body. A CSS cursor only takes effect while the
  /// pointer is over that element, so the hovered window wins naturally and leaving needs no handling.
  /// The host's current cursor shape. Kept as PARTS, not only as the composed CSS value: direct mode
  /// wears it via CSS, and trackpad mode has to POSITION it, which a CSS string cannot express.
  setCursor(dataUrl: string | null, hotspotX: number, hotspotY: number, overlay?: { url: string; w: number; h: number }): void {
    this.cursorUrl = overlay?.url ?? dataUrl;
    this.cursorSize = overlay ? { w: overlay.w, h: overlay.h } : null;
    this.cursorHotspot = { x: hotspotX, y: hotspotY };
    this.cursorCss = cursorCssValue(dataUrl, hotspotX, hotspotY);
    for (const win of this.wins.values()) { this.applyCursor(win.el); this.paintTrackpadCursor(win); }
  }

  /// Put the trackpad cursor where the machine says it is, inside the PICTURE — the same content
  /// rect the touches map through, so what you click is where it is drawn.
  private paintTrackpadCursor(win: Win, x?: number, y?: number): void {
    const el = win.padCursor;
    el.style.width = this.cursorSize ? `${this.cursorSize.w}px` : "";
    el.style.height = this.cursorSize ? `${this.cursorSize.h}px` : "";
    el.src = this.cursorUrl ?? FALLBACK_CURSOR;
    if (x !== undefined) win.cursorPos = { x, y: y ?? win.cursorPos.y };
    const body = win.el.querySelector<HTMLElement>(".win-body");
    if (!body) return;
    const box = { w: body.clientWidth, h: body.clientHeight };
    // Against the ZOOMED picture, or the virtual cursor drifts off whatever it is pointing at the
    // moment the picture is zoomed — it reports a position inside the picture, not inside the body.
    const c = zoomedRect(containedRect(box, this.pictureSize(win)),
                         this.viewOf(win.source), box);
    el.style.left = `${c.x + c.w * win.cursorPos.x - this.cursorHotspot.x}px`;
    el.style.top = `${c.y + c.h * win.cursorPos.y - this.cursorHotspot.y}px`;
  }

  private applyCursor(el: HTMLElement): void {
    const body = el.querySelector(".win-body") as HTMLElement | null;
    // TRACKPAD MODE HIDES THE CSS CURSOR, and it has to be decided HERE rather than in the
    // stylesheet: this write is INLINE, so it beats any rule the stylesheet could carry, and a
    // `cursor: none` rule there is silently overridden by whatever shape the host last sent.
    if (body) body.style.cursor = el.dataset.source?.startsWith("sim:") ? "default"
      : this.pointerMode === "trackpad" ? "none" : this.cursorCss;
  }

  /// Remember a source's NATIVE PIXEL size (`points x the host display's backing scale`).
  ///
  /// SEPARATE from `setSourceSize` because the two arrive independently and each means UNKNOWN when
  /// absent, never "cleared": `source-list` carries points for every listed window, the liveness monitor's
  /// pushes carry neither, and the baseline `source-status` a client gets when it joins an ALREADY-
  /// CAPTURING source carries pixels ALONE. That last case is why this exists — folding it into
  /// `setSourceSize` meant a reconnecting client, whose baseline has no point size, dropped the pixel size
  /// on the floor, `autoScale` kept returning null, and Auto silently never sent anything.
  setSourcePixelSize(source: string, pxW: number, pxH: number): void {
    if (source.startsWith("apps:")) { pxW = 1280; pxH = 800; }
    this.pixelSizes.set(source, { w: pxW, h: pxH });
    this.recomputeAuto(source);   // this may be exactly the input Auto was missing
  }

  setSourceSize(source: string, w: number, h: number): void {
    if (source.startsWith("apps:")) { w = 1280; h = 800; }
    const had = this.sizes.get(source);
    this.sizes.set(source, { w, h });
    // The first real point size, or a genuine host-side resize, is when the window's aspect should be
    // (re)derived — not when the ENCODER's resolution changed, which is what used to drive it.
    if (!had || had.w !== w || had.h !== h) this.reapplyRatio(source);
    const win = this.wins.get(source);
    if (!win) return;
    this.maybeAutoFit(source);   // first size for this source? decide whether it opens fitted
    const state = this.resizeState.get(source);
    if (state === "resizing") return;   // the user owns the frame until they let go
    if (state === "pending") this.settle(source, win.el);
    else this.applySize(win.el, source);
    // The box may not have changed at all — the first push carrying pxW/pxH often repeats the same point
    // size — so the ResizeObserver cannot be relied on to notice. Decide explicitly.
    this.recomputeAuto(source);
  }

  /// The host's reply to our resize landed: animate to the size the window REALLY became (identical,
  /// clamped, or refused — all the same code path) and unblur.
  private settle(source: string, el: HTMLElement): void {
    this.clearSettleTimer(source);
    this.resizeState.delete(source);
    el.classList.add("settling");
    this.applySize(el, source);
    el.classList.remove("resizing");
    this.afterGeometryTransition(el, "settling");
  }

  private clearSettleTimer(source: string): void {
    const t = this.settleTimers.get(source);
    if (t !== undefined) { window.clearTimeout(t); this.settleTimers.delete(source); }
  }

  /// Toggle a source's fit-to-screen mode: draw the whole host window scaled down instead of at actual
  /// size. Desktop only — the button is hidden in the tabbed layout, and `applySize` returns early there
  /// regardless. Purely local: the host window is never resized and nothing is sent.
  toggleFit(source: string): void {
    const win = this.wins.get(source);
    if (!win) return;
    const on = !this.fitted.has(source);
    if (on) this.fitted.add(source); else this.fitted.delete(source);
    // Pressing Fit is an explicit "show me this whole window", so it discards whatever zoom a previous
    // grip drag pinned — in BOTH directions, so turning it off and on again is a full reset.
    this.fitPin.delete(source);
    win.fit.setAttribute("aria-pressed", String(on));
    // Fit both moves AND resizes, so it needs its own transition class: `.settling` animates left but not
    // top. Removed afterwards so a subsequent drag is never transitioned.
    win.el.classList.add("fitting");
    this.afterGeometryTransition(win.el, "fitting");
    this.applySize(win.el, source, on ? "center" : "keep");
  }

  private modeOf(_source: string): "auto" | number {
    return this.devicePrefs.scale;
  }

  /// The device set as it stands.
  devicePrefsNow(): ClientPrefs { return { ...this.devicePrefs }; }

  /// A panel changed a DEVICE preference: apply it to every window, save it, and tell the caller.
  changeDevicePrefs(patch: Partial<ClientPrefs>): void {
    const prev = this.devicePrefs;
    const next: ClientPrefs = { ...prev, ...patch };
    this.devicePrefs = next;
    saveClientPrefs(next, this.context?.storage);
    if (next.pointerMode !== undefined && next.pointerMode !== this.pointerMode) {
      this.pointerMode = next.pointerMode;
      for (const w of this.wins.values()) {
        w.el.dataset.pointerMode = w.source.startsWith("sim:") ? "direct" : next.pointerMode;
        this.applyCursor(w.el);          // direct wears the host's shape; trackpad wears none
        this.paintTrackpadCursor(w);
      }
    }
    for (const w of this.wins.values()) this.paintDevicePrefs(w, undefined);
    // RE-ENTERING AUTO re-reports every window's ceiling, even one that lands where it was: the host
    // was applying a fixed resolution meanwhile and holds no ceiling from this client.
    if (next.scale === "auto" && prev.scale !== "auto") {
      for (const source of this.wins.keys()) { this.lastSentAuto.delete(source); this.recomputeAuto(source); }
    }
    this.opts.onDevicePrefs?.({ ...next });
  }

  /// Show the device set in a window's panel. `echo` is the host's effective values for that window,
  /// shown only where the device has not chosen (fps, bitrate).
  private paintDevicePrefs(w: Win, echo: { fps: number; bitrateBps: number; activeCodec?: string } | undefined): void {
    const p = this.devicePrefs;
    w.referenceRecovery.setAttribute("aria-checked", String(p.av1ReferenceRecovery === true));
    const bitrate = p.bitrateBps ?? echo?.bitrateBps;
    if (bitrate !== undefined) { const v = String(nearestStep(BITRATE_STEPS_BPS, bitrate)); if (w.bitrateSel.value !== v) w.bitrateSel.value = v; syncSettingsChoice(w.bitrateSel); }
  }

  /// A new connection, or this client just became the driver: the host holds no DERIVED value from this
  /// client for any window (CONTRACT ISSUE 3 — it drops a driver's Auto ceilings and crops with it), so
  /// every window reports its own again. The crop still says nothing while unzoomed (`sendCrop`).
  resendDerived(): void {
    for (const source of this.wins.keys()) {
      this.lastSentAuto.delete(source);
      this.sentCrops.delete(source);
      this.clearAutoTimer(source);
      this.recomputeAuto(source);
    }
  }

  /// Forget a source's Auto tracking state (see `lastSentAuto`).
  /// `keepKeyboard`: the window holds the keys, and its keyboard goes only after `sync` has handed them on.
  private disposeAuto(source: string, keepKeyboard = false): void {
    this.autoObservers.get(source)?.disconnect();
    this.autoObservers.delete(source);
    this.clearAutoTimer(source);
    this.lastSentAuto.delete(source);
    if (!keepKeyboard) this.disposeKeyboard(source);
  }

  /// Mount or unmount the touch keyboard as focus moves.
  ///
  /// Gated on `(any-pointer: coarse)` rather than the layout, matching the stylesheet — a landscape
  /// iPad resolves to `floating` and has no hardware keys either. Glasses are excluded EXPLICITLY:
  /// the D-pad is the keyboard there, and one pinch into a projected window would hand the wearer's
  /// only input device to the remote Mac irrecoverably (the same rule `attachWindowKeys` follows).
  private syncKeyboard(source: string, win: Win): void {
    const want = win.focused
      && typeof matchMedia === "function" && matchMedia("(any-pointer: coarse)").matches
      && this.ui.dataset.layout !== "glasses";
    const have = this.keyboards.get(source);
    if (want && !have) {
      this.keyboards.set(source, mountWindowKeyboard(win.el, {
        send: (msg) => this.opts.inputChannel.send(encodeJson(msg) as Uint8Array<ArrayBuffer>),
        isActive: () => win.focused,
        // FULL SCREEN HAS NO TITLEBAR, so its paste menu is a held `⌨` (§2.2).
        isFullscreen: () => this.fullscreen === source,
        canPaste: () => this.opts.canPaste?.() ?? false,
        onKeyboardHold: (at) => this.opts.onWindowMenu?.(source, at),
        sendText: source.startsWith("sim:")
          ? (text) => this.opts.inputChannel.send(encodeJson({ t: "sim-text", text }) as Uint8Array<ArrayBuffer>)
          : undefined,
      }));
    } else if (!want && have) {
      this.disposeKeyboard(source);
    }
  }

  /// Unmount a window's keyboard, CLEARING ITS MODIFIERS FIRST — on the wire as well as in the UI.
  ///
  /// A locked ⌘ left behind would keep the host's `currentFlags` set, and every later click on any
  /// window would arrive as a ⌘-click with nothing on screen to explain it.
  private disposeKeyboard(source: string): void {
    const kb = this.keyboards.get(source);
    if (!kb) return;
    kb.clearMods();
    kb.destroy();
    this.keyboards.delete(source);
  }

  /// Drop every on-screen modifier, on the wire as well as in the UI.
  ///
  /// The strip's modifiers are MIRRORED ON THE HOST — arming one sends a bare-modifier `win-key`
  /// that writes `currentFlags` — so they must be released wherever `win-keys-release` is sent, or
  /// the client shows a lock the host has dropped (or the host holds one the client no longer shows).
  /** A peer rebuild keeps ordinary window records, but no workspace mask may survive its track. */
  suspendWorkspaces(): void {
    for (const win of this.wins.values()) if (win.source.startsWith("apps:")) {
      win.pointer.cancelGesture(); win.workspace?.stop(); win.workspaceSuspendedTrack = win.boundTrack;
    }
  }

  /** Native blur/handoff abandons deferred gestures as well as held keyboard state. */
  releaseInput(): void {
    for (const win of this.wins.values()) {
      try { win.pointer.cancelGesture(); } catch (error) { console.warn("[wm] releaseInput", error); }
    }
    this.releaseTouchMods();
    try { this.opts.inputChannel.send(encodeJson({t:"win-keys-release"}) as Uint8Array<ArrayBuffer>); } catch { /* closing channel */ }
  }

  releaseTouchMods(): void {
    for (const kb of this.keyboards.values()) kb.clearMods();
  }

  /// The band a fitted window may occupy, in viewport coordinates.
  private band(): Rect {
    return stageBand(this.viewportWidth, this.viewportHeight, tabBarHeight(this.container), statusBarHeight(this.container));
  }

  /// The whole viewport. Windows paint above both bars, so this — not the band — is where a window may
  /// legitimately sit once the user has placed it.
  private viewportRect(): Rect {
    return { x: 0, y: 0, w: this.viewportWidth, h: this.viewportHeight };
  }

  /// Remove a geometry transition class once it has run, and RE-PIN. LOAD-BEARING: `pinControls` inside
  /// `applySize` measured the PRE-transition box — a transition keeps `getBoundingClientRect` reporting
  /// the old geometry for its whole duration — and nothing else re-measures, so a stale translateX would
  /// just sit there. Measured on `.fitting` before this existed: the control cluster left translated
  /// -426px over the title of a window that fit perfectly. `.settling` had the identical latent defect.
  ///
  /// Tracked, so `clear()` cancels it: left running it re-pinned a removed window, and in a loaded test
  /// run fired after the environment was gone (an unhandled error that failed the suite).
  private afterGeometryTransition(el: HTMLElement, cls: string): void {
    const t = window.setTimeout(() => {
      this.geometryTimers.delete(t);
      el.classList.remove(cls);
      this.pinControls(el);
    }, 260);
    this.geometryTimers.add(t);
  }
  private readonly geometryTimers = new Set<number>();

  /// Decide ONCE per source, the first time its size is known: a window too big for the band opens fitted.
  /// Runs from both `create` and `setSourceSize`, because the size can arrive either side of the window —
  /// `source-list` often carries it before you subscribe, `source-status` sometimes only after capture
  /// starts. Whichever happens second decides; the latch makes it idempotent.
  private maybeAutoFit(source: string): void {
    if (this.autoFitDecided.has(source)) return;
    const s = this.sizes.get(source);
    if (!s) return;                                   // size unknown — decide when it arrives
    this.autoFitDecided.add(source);
    const band = this.band();
    if (fitScale(s.w, s.h, band.w, band.h) >= 1) return;
    this.fitted.add(source);
    // Live window: update the button. During `create` this is undefined (the Win is registered last) and
    // the ?. no-ops — the button reads `this.fitted` when it is built, which happens after this runs.
    this.wins.get(source)?.fit.setAttribute("aria-pressed", "true");
  }

  /// The factor this source's body is currently DRAWN at: 1 unless fitted. Read at drag-end to convert
  /// dragged pixels back into host points. Safe to compute then: `resizeState === "resizing"` suppresses
  /// size pushes for the whole drag, so `sizes` still holds the size the window was displayed at.
  private drawScale(source: string): number {
    const s = this.sizes.get(source);
    if (!s || !(s.w > 0)) return 1;
    // ON A PINNED LAYOUT THE BAND-FIT PATH BELOW IS WRONG, so this branch comes first and the pixel
    // scroll deltas it feeds are converted from client pixels into host points properly: the drawn
    // scale there is simply the picture's width over the host's width.
    //
    // THE EARLY RETURN IS THE WHOLE PROTECTION, and it has to be — `maybeAutoFit` is NOT gated on
    // layout, so a source larger than the band lands in `fitted` on the tabbed layout exactly as it
    // does on the floating one. (An earlier version of this comment claimed `fitted` is never set on
    // a pinned layout. It is not true, and nothing ever depended on it being true.)
    //
    // The floating path is untouched on purpose: `drawScale` also feeds the grip-drag resize, whose
    // correctness rests on `sizes` still holding the pre-drag size, and a pinned layout has no grip
    // (`.win-resize { display: none }`) so this branch only ever feeds scroll.
    //
    // A FULL-SCREEN WINDOW IS PINNED TOO, on every layout: CSS fills the screen with its body and
    // `object-fit: contain` scales the picture into it — up as well as down — so the floating path's
    // "1 unless fitted" is as wrong there as on a phone: a flick over a picture drawn at 1.8x would
    // move the Mac's content 1.8 times as far as the finger.
    if (isPinnedLayout(this.ui) || this.fullscreen === source) {
      const win = this.wins.get(source);
      const body = win?.el.querySelector<HTMLElement>(".win-body");
      if (!win || !body) return 1;
      const box = { w: body.clientWidth, h: body.clientHeight };
      // ZOOM IS A PROPERTY OF THE PICTURE'S RECT, so the zoomed width is all this branch needs to
      // keep being right: a flick over a picture drawn at 2x must move the content by what it LOOKS
      // like it moves it by, exactly as it must over a fitted desktop window.
      const c = zoomedRect(containedRect(box, this.pictureSize(win)),
                           this.viewOf(source), box);
      return c.w > 0 ? c.w / s.w : 1;
    }
    if (!this.fitted.has(source)) return 1;
    const band = this.band();
    return drawnFitScale(s.w, s.h, band.w, band.h, this.fitPin.get(source));
  }

  /** Shares the exact pointer/wheel mapping with native phase delivery into a source document. */
  scrollGeometry(source:string):{left:number;top:number;width:number;height:number;scale:number}|undefined {
    const win=this.wins.get(source),body=win?.el.querySelector<HTMLElement>('.win-body');
    if(!win||!body||this.viewModeOf(source)==='zoom')return;
    return {...videoViewRect(body.getBoundingClientRect(),this.pictureSize(win),this.viewOf(source)),scale:this.drawScale(source)};
  }

  private viewOf(source: string): View { return this.views.get(source) ?? FIT_VIEW; }

  /// Tell the host what this source's viewer can actually see, if it has changed. Everything outside
  /// the rect is filled with a checkerboard at encode time, so the bitrate goes where it is being
  /// looked at. The frame's geometry does not change, so there is nothing to synchronise and nothing
  /// in the render path to update.
  private sendCrop(source: string): void {
    if (source.startsWith("apps:")) return;
    if ((this.context?.resizeSettle ?? windowResizeSettle).defer(this, `crop:${source}`, () => this.sendCrop(source))) return;
    const win = this.wins.get(source);
    const body = win?.el.querySelector<HTMLElement>(".win-body");
    if (!win || !body) return;
    const box = { w: body.clientWidth, h: body.clientHeight };
    const fit = containedRect(box, this.pictureSize(win));
    const crop = visibleSourceRect(fit, this.viewOf(source), box);
    const sent = this.sentCrops.get(source);
    if (sameCrop(crop, sent)) return;
    // A FULL CROP IS THE HOST'S DEFAULT, so saying it before anything else has been said is pure
    // noise — one message per source, on every size push, for every client that will never zoom.
    // The feature is inert unzoomed on the wire as well as in the picture. `sent` being present is
    // what distinguishes "never cropped" from "cropped, now back to full", and the second of those
    // MUST be sent or the host keeps masking a window nobody is zoomed into any more.
    if (sent === undefined && isFullCrop(crop)) return;
    this.sentCrops.set(source, crop);
    this.opts.onPrefs(source, { crop });
  }

  /// Store a view and draw it. The Auto request is NOT recomputed here: a gesture calls this on every
  /// frame, and `recomputeAuto` belongs at the settle (see `onViewGesture`), or the debounce is
  /// re-armed sixty times a second for nothing.
  private applyView(source: string, next: View): void {
    this.views.set(source, next);
    this.refreshView(source);
  }

  /// Re-clamp the stored view against the CURRENT box, picture and native size, and write the
  /// transform. Called whenever any of those three can have changed: a gesture, the body's
  /// ResizeObserver, and the video's metadata.
  private refreshView(source: string): void {
    const win = this.wins.get(source);
    const body = win?.el.querySelector<HTMLElement>(".win-body");
    if (!win || !body) return;
    // ZOOM IS A PINNED-LAYOUT FEATURE, so leaving the layout RESETS rather than merely hiding. A
    // rotation to landscape resolves to `floating`, where `applySize` owns the geometry and a stale
    // transform would fight it — and the `Zoom` button is hidden there, so a mode left on would be an
    // input state the user has no control to turn off.
    //
    // NO NEW HOOK IS NEEDED: a layout flip resizes the body, and the ResizeObserver already calls
    // this. `isPinnedLayout(this.ui)` is enumerated, so an UNSET layout behaves as floating — the fail-safe
    // direction, since unset is every layout until `watchLayoutMode` fires its first callback.
    if (!isPinnedLayout(this.ui) && (this.viewOf(source).z !== 1 || this.viewModeOf(source) === "zoom")) {
      this.views.set(source, FIT_VIEW);
      this.setViewMode(source, "input");
    }
    const box = { w: body.clientWidth, h: body.clientHeight };
    const fit = containedRect(box, this.pictureSize(win));
    const view = clampView(this.viewOf(source), box, fit,
                           maxZoom(fit.w, this.pixelSizes.get(source)?.w ?? 0, window.devicePixelRatio || 1));
    this.views.set(source, view);
    const t = transformFor(fit, zoomedRect(fit, view, box));
    // NO TRANSFORM PROPERTY AT ALL AT THE FIT VIEW. The floating and glasses layouts never leave it,
    // so their painting stays byte-identical rather than gaining an identity transform that would
    // promote the element to its own compositor layer.
    const css = view.z === 1 ? "" : `translate(${t.tx}px, ${t.ty}px) scale(${t.z})`;
    win.video.style.transform = css;
    // The paced canvas sits exactly where the <video> does under `?render=canvas` and carries the
    // same `object-fit: contain`; leaving it behind would slide the picture out from under itself.
    const paced = body.querySelector<HTMLElement>("canvas.win-paced, canvas.workspace-picture");
    if (paced) paced.style.transform = css;
    win.el.dataset.zoomed = String(view.z > 1);
  }

  private viewModeOf(source: string): "input" | "zoom" {
    return this.viewModes.get(source) ?? "input";
  }

  /// Enter or leave zoom mode. Public so a gate can drive it without synthesizing a click.
  setViewMode(source: string, mode: "input" | "zoom"): void {
    const win = this.wins.get(source);
    if (!win) return;
    // CANCEL BEFORE THE SWITCH, ALWAYS. A finger on the glass has a real press behind it in input
    // mode and a half-finished pan behind it in zoom mode; either one surviving the switch is a
    // gesture continuing under rules that no longer apply.
    win.pointer.cancelGesture();
    this.viewModes.set(source, mode);
    win.zoomBtn.setAttribute("aria-pressed", String(mode === "zoom"));
    win.el.dataset.viewMode = mode;
  }

  /// Back to contain-fit. Public: the `Fit` button calls it on a pinned layout.
  resetView(source: string): void {
    this.applyView(source, FIT_VIEW);
    this.recomputeAuto(source);
  }

  /// The host's remembered desktop positions. A window opened later is placed from these; an open
  /// window moves ONLY when its remembered position CHANGES — never for a state change that left it
  /// alone, or a drag in progress would be yanked back under the finger by any unrelated echo.
  /// Ignored on the pinned layouts, where CSS owns the frame.
  setStatePositions(windows: ReadonlyArray<{ source: string; x?: number; y?: number }>): void {
    const next = new Map<string, { x: number; y: number }>();
    for (const w of windows) if (w.x !== undefined && w.y !== undefined) next.set(w.source, { x: w.x, y: w.y });
    for (const [source, pos] of next) {
      const prev = this.statePositions.get(source);
      if (prev && prev.x === pos.x && prev.y === pos.y) continue;
      const win = this.wins.get(source);
      if (win && !isPinnedLayout(this.ui)) this.placeAt(win.el, pos);
    }
    this.statePositions = next;
  }

  /// Put a window at a remembered position, clamped onto THIS screen — the one it was dragged on may
  /// have been bigger.
  private placeAt(el: HTMLElement, pos: { x: number; y: number }): void {
    const r = el.getBoundingClientRect();
    const c = clampToViewport({ x: pos.x, y: pos.y, w: r.width || 280, h: r.height || 200 },
                              this.viewportWidth, this.viewportHeight, 24);
    el.style.left = `${c.x}px`; el.style.top = `${c.y}px`;
    this.pinControls(el);
  }

  /// Put `source`'s window FULL SCREEN, or take the full-screen window out (null). One at a time.
  /// Public: the titlebar's `Full screen`, the `Exit` button, the browser leaving its own full screen
  /// and the session going passive all come here, and a gate drives it directly.
  ///
  /// THE MODE IS CSS (`data-fullscreen` on the root, `.fullscreen` on the window), so nothing here
  /// writes geometry: the window's inline desktop size is left alone underneath the override, and
  /// comes back as it was. The body's box changes, and the ResizeObserver already on it re-measures
  /// Auto resolution and the crop — one mechanism, as for every other change of box.
  ///
  /// `browser: false` APPLIES THE MODE ONLY — the page's own full screen, with no request for the
  /// browser's (in the Mac app, the window's). The session uses it to restore a full screen the host's
  /// state remembers: a browser grants its full screen only inside a click, and in the app the request
  /// would put the macOS window into full screen with nobody asking.
  setFullscreen(source: string | null, opts: { browser?: boolean } = {}): void {
    const next = source !== null && this.wins.has(source) ? source : null;
    if (next === this.fullscreen) return;
    const prev = this.fullscreen !== null ? this.wins.get(this.fullscreen) : undefined;
    this.clearExitTimer();
    if (prev) {
      prev.el.classList.remove("fullscreen");
      delete prev.el.dataset.exitShown;
      prev.fsBtn.setAttribute("aria-pressed", "false");
    }
    this.fullscreen = next;
    const root = this.ui;
    if (next === null) {
      delete root.dataset.fullscreen;
      this.browserFs.exit();
      // EVERY window's titlebar controls, re-pinned: the full-screen one's were last pinned against a
      // window the size of the screen, and the others were `display: none` — a resize meanwhile (the
      // browser's own full screen coming or going) pinned them against a 0x0 box and dropped the shift
      // that keeps an oversized window's `×` on screen. RE-PIN ONLY, never `applySize`: that re-derives
      // the frame from the host size, and a window whose height `setRatio` last wrote came back 1.1 px
      // shorter than it went in (measured by the gate).
      for (const w of this.wins.values()) this.pinControls(w.el);
      this.opts.onFullscreen?.(null);
      return;
    }
    const w = this.wins.get(next)!;
    this.closeAllSettings();
    // ZOOM MODE HAS NO BUTTON IN FULL SCREEN — the titlebar carrying it is gone — so a window left in
    // it would take every tap as a pan, with no way back. The VIEW survives, as it does every mode switch.
    this.setViewMode(next, "input");
    w.el.classList.add("fullscreen");
    w.fsBtn.setAttribute("aria-pressed", "true");
    root.dataset.fullscreen = "window";
    this.opts.onFullscreen?.(next);
    if (opts.browser !== false) this.browserFs.enter();
    // Shown on the way in, so a mouse user learns where it lives before it hides (`onFullscreenPointer`).
    w.el.dataset.exitShown = "true";
    this.lingerExit(w);
    // The button that asked has gone with the titlebar, and a focused element that disappears leaves
    // focus on <body>, where no key reaches the Mac — Esc included. The picture takes it, as a tap would.
    w.el.querySelector<HTMLElement>(".win-body")?.focus({ preventScroll: true });
  }

  /// The source whose window is full screen, or null.
  fullscreenSource(): string | null { return this.fullscreen; }
  /// Whether `source` has a window right now.
  hasWindow(source: string): boolean { return this.wins.has(source); }

  /// Whether the person is AT `source` as they close or park it (`personAtWindow`) — what the intent says as
  /// `land`. `windowsSurface`: the session shows the windows surface, which only a pinned layout reads.
  personAt(source: string, windowsSurface: boolean): boolean {
    const w = this.wins.get(source);
    if (!w) return false;
    return personAtWindow({ pinned: isPinnedLayout(this.ui), windowsSurface, focused: w.focused,
                            holdsKeys: w.el.contains(activeWithin(this.container)) });
  }

  /// A MOUSE brings the Exit button back at the top edge, where a menu bar would be, and it leaves
  /// `EXIT_LINGER_MS` after the mouse does. A finger never hides it (`style.css` keeps it on a coarse
  /// pointer): there is no hover to bring it back with, and no Esc key.
  private readonly onFullscreenPointer = (e: PointerEvent): void => {
    if (this.fullscreen === null || e.pointerType !== "mouse") return;
    const w = this.wins.get(this.fullscreen);
    if (!w) return;
    if (exitRevealed(e.clientY - (this.context?.viewport.rect().top ?? 0))) {
      this.clearExitTimer();
      w.el.dataset.exitShown = "true";
    } else if (w.el.dataset.exitShown && this.exitTimer === undefined) {
      this.lingerExit(w);
    }
  };

  private lingerExit(w: Win): void {
    this.clearExitTimer();
    this.exitTimer = window.setTimeout(() => {
      this.exitTimer = undefined;
      delete w.el.dataset.exitShown;
    }, EXIT_LINGER_MS);
  }

  private clearExitTimer(): void {
    if (this.exitTimer !== undefined) { window.clearTimeout(this.exitTimer); this.exitTimer = undefined; }
  }

  /// Observability for `e2e/mobile-touch-map-check.mjs` — jsdom has no layout engine and the gate
  /// needs the numbers the transform was actually drawn from. The `autoDebug` precedent.
  viewDebug(): Record<string, View> {
    const out: Record<string, View> = {};
    for (const [source, v] of this.views) out[source] = { ...v };
    return out;
  }

  /// Write the actual size onto a window element — or, in fit mode, the shrunk-to-fit size. This is the
  /// ONLY method that writes a window's width/height. Skipped on mobile, where CSS pins the focused window
  /// to the viewport (full-bleed + object-fit: contain) and an inline width/height would fight it.
  ///
  /// `place` is the fit-mode placement rule: "center" on the toggle itself, "keep" on every later
  /// recompute (host window resize, viewport resize), which only nudges the window back in bounds.
  private applySize(el: HTMLElement, source: string, place: "keep" | "center" = "keep"): void {
    if (isPinnedLayout(this.ui)) return;
    const s = this.sizes.get(source);
    if (!s) return;
    if (!this.fitted.has(source)) {
      const size = windowElementSize(s.w, s.h);
      el.style.width = `${size.w}px`;
      el.style.height = `${size.h}px`;
      this.pinControls(el);
      return;
    }
    const band = this.band();
    const k = drawnFitScale(s.w, s.h, band.w, band.h, this.fitPin.get(source));
    const size = windowElementSize(s.w * k, s.h * k);
    // Read the CURRENT position from the inline styles we own, never getBoundingClientRect: an
    // un-laid-out element measures 0x0 there (the same trap documented on setRatio in floating-window.ts).
    const here = { x: parseFloat(el.style.left) || 0, y: parseFloat(el.style.top) || 0, w: size.w, h: size.h };
    // "center" uses the BAND (a tidy, unobstructive spot for an explicit "show me this whole window").
    // "keep" nudges against the full VIEWPORT instead, so a window deliberately parked over a bar is not
    // yanked back on the next re-fit. Strictly more permissive: the band is always contained in the
    // viewport, so this can never move a window the band would have left alone.
    const pos = place === "center" ? centerIn(size, band) : nudgeInto(here, this.viewportRect());
    el.style.width = `${size.w}px`;
    el.style.height = `${size.h}px`;
    el.style.left = `${pos.x}px`;
    el.style.top = `${pos.y}px`;
    this.pinControls(el);
  }

  /// Keep a window's titlebar controls inside the viewport (see `controlOffset`). Called after ANY
  /// geometry change — size push, resize settle, drag (via initFloatingWindow's onGeometryChange), and
  /// viewport resize — because each of them can move the window's right edge past the viewport.
  /// Mobile is exempt: the focused window is pinned full-bleed there and can never overflow.
  private pinControls(el: HTMLElement): void {
    const controls = el.querySelector(".win-controls") as HTMLElement | null;
    if (!controls) return;
    if (isPinnedLayout(this.ui)) { controls.style.transform = ""; return; }
    const dx = controlOffset(el.getBoundingClientRect().right - (this.context?.viewport.rect().left ?? 0), this.viewportWidth);
    controls.style.transform = dx > 0 ? `translateX(${-dx}px)` : "";
    if (el.classList.contains("settings-modal"))
      positionSettingsCard(el.querySelector<HTMLElement>(".win-settings-sheet")!, el);
  }

  /// The viewport itself changed size: re-pin every window's controls, and re-FIT every fitted window —
  /// the band it must fit inside changed with the viewport. Bound once so `clear()` can remove it.
  ///
  /// LOAD-BEARING: this honours the same `resizing` guard `setSourceSize` uses. While the grip is held the
  /// user owns the frame, and dragging the BROWSER window fires `resize` continuously — re-fitting then
  /// would yank the frame out from under the pointer mid-drag. (Not unit-testable: `resizeState` is
  /// reachable only through a real pointer-driven grip drag, which jsdom cannot produce. Covered by
  /// `e2e/fit-check.mjs` and by mirroring the guard `setSourceSize` already applies.)
  private readonly onViewportResize = (): void => {
    for (const [source, w] of this.wins) {
      if (this.fitted.has(source) && this.resizeState.get(source) !== "resizing") this.applySize(w.el, source);
      else this.pinControls(w.el);   // applySize pins for us; this covers everything else
    }
  };

  /// The session's forced FEC overhead, or null for adaptive control. SESSION STATE rather than
  /// per-view, which is why it has its own setter instead of riding `sync`'s WindowView list — the
  /// value is one per connection and every window renders the same one.
  private recoveryOverrideBp: number | null = null;

  /// Reflect the host's echoed forced-FEC setting into EVERY window's titlebar. All of them change
  /// together because there is only one value; that is what makes a per-window control honest for a
  /// setting that is not per window.
  setRecoveryOverride(bp: number | null): void {
    this.recoveryOverrideBp = bp;
    const value = bp === null ? AUTO_RECOVERY : String(bp);
    for (const w of this.wins.values()) {
      if (w.recoverySel.value !== value) w.recoverySel.value = value;
      syncSettingsChoice(w.recoverySel);
    }
  }

  /// Whether the HOST's curtain is up, or null when the host has not said. NULL IS NOT FALSE: an older
  /// host, or a view-set that predates the answer, must leave the control disabled rather than assert a
  /// state — the same absent-means-unknown rule the wire follows.
  private curtainUp: boolean | null = null;

  /// Reflect the host's echoed curtain state into every window's panel at once. Host state, so every
  /// open panel shows the same thing and they all change together.
  setCurtainUp(up: boolean | null): void {
    this.curtainUp = up;
    for (const w of this.wins.values()) {
      const btn = w.panel.querySelector<HTMLButtonElement>(".win-curtain");
      if (!btn) continue;
      btn.disabled = up === null;
      btn.setAttribute("aria-checked", String(up === true));
    }
  }

  private playoutDelayMs = 20;

  setPlayoutDelayMin(minMs: number | null): void {
    this.playoutDelayMs = minMs ?? 20;
    for (const w of this.wins.values()) w.delaySel.setAttribute("aria-checked", String(this.playoutDelayMs === 100));
  }

  // The product has two fixed floors. Arrival measurements remain available for diagnostics.
  playoutDelayIsAuto(): boolean { return false; }

  togglePointerMode(): void {
    if ([...this.wins.values()].some(w => w.focused && w.source.startsWith("sim:"))) return;
    this.changeDevicePrefs({ pointerMode: this.pointerMode === "direct" ? "trackpad" : "direct" });
  }

  /// Close every open settings panel — the click-outside and Esc paths, and the one-at-a-time rule.
  ///
  /// NOT called on geometry changes any more. It used to be, because a floating popover had to be
  /// re-pinned against a window whose `getBoundingClientRect` still reports the OLD box for the whole
  /// of a CSS transition. A panel that IS the window has nothing to re-pin: it moves with it.
  closeAllSettings(): void {
    for (const w of this.wins.values()) this.setSettingsOpen(w, false);
  }

  /// Attach or drop this window's glasses nav ids.
  ///
  /// The ids are UNQUALIFIED (`win:settings`, not `win:settings:<source>`) to match what `navOrder`
  /// emits for the window screen, which is screen-scoped because the glasses show ONE window
  /// (`.source-window.focused { display: flex }`). Carrying them on every window would leave
  /// `querySelector` picking whichever came first in the DOM — a control the wearer cannot see. Only
  /// the focused window holds them, so exactly one element answers each id.
  private setNavIds(w: Win, focused: boolean): void {
    const targets: Array<[HTMLElement | null, string]> = [
      [w.gear, "win:settings"],
      [w.panel.querySelector<HTMLElement>(".win-settings-close"), "win:settings:close"],
    ];
    for (const row of SETTINGS_ROWS) {
      targets.push([w.panel.querySelector<HTMLElement>(`.win-${row.key}`), `win:settings:${row.key}`]);
    }
    for (const [el, id] of targets) {
      if (!el) continue;
      if (focused) el.dataset.navId = id;
      else delete el.dataset.navId;
    }
  }

  /// Desktop uses the top layer to escape the owning window's clipping and stacking context.
  /// Pinned layouts retain the in-window sheet.
  private setSettingsOpen(w: Win, open: boolean): void {
    const modal = open && this.ui.dataset.layout === "floating";
    const wasModal = w.el.classList.contains("settings-modal");
    const restoreFocus = !open && wasModal && w.panel.contains(activeWithin(this.container));
    if (w.panel.open && (!open || modal !== wasModal)) closeClientDialog(w.panel);
    if (open && !w.panel.open) { if (modal) openClientDialog(w.panel); else w.panel.show(); }
    w.panel.classList.toggle("open", open);
    if (modal) positionSettingsCard(w.panel.querySelector<HTMLElement>(".win-settings-sheet")!, w.el);
    w.gear.setAttribute("aria-expanded", String(open));
    w.el.classList.toggle("settings-modal", modal);
    if (modal || wasModal) {
      for (const child of w.el.children) if (child !== w.panel && child instanceof HTMLElement) child.inert = modal;
    }
    if (modal && (!this.context || this.context.input.focused())) w.panel.querySelector<HTMLButtonElement>(".win-settings-close")?.focus({ preventScroll: true });
    else if (restoreFocus) w.gear.focus({ preventScroll: true });
  }

  /// `keysTo`: the host LANDED the person on a terminal tab (`landedOnTerminal`) — the keys of a window that
  /// goes holding them are handed THERE (told whether they were typing), never to the next window, whose
  /// surface a phone no longer shows. Called before that window leaves the page.
  sync(views: WindowView[], streams: Map<string, MediaStream>, keysTo?: (typing: boolean) => void): void {
    this.lastStreams = streams;
    const want = new Set(views.map((v) => v.source));
    // A full-screen window that goes (×, −, the host closing it) takes the mode with it, BEFORE its
    // element does — or the page is left full screen over nothing, with the Exit button gone too.
    // Focus moving elsewhere does not: the window stays on screen, and a tap on it focuses it again.
    if (this.fullscreen !== null && !want.has(this.fullscreen)) this.setFullscreen(null);
    // A window that goes (×, −, its app quitting) WITH THE KEYS hands them to the window the host focuses
    // next — the one before it (`SessionState.focused`) — as closing the terminal tab being typed into
    // does (`TermDeck.close`); the keys used to fall to <body>, where none reaches the Mac. Its element
    // leaves the page only AFTER: a focused element removed first sends focus through <body>, and iOS
    // drops the soft keyboard. Keys in its hidden INPUT go to the next window's input (the keyboard stays).
    // When the person LANDED on a terminal tab instead, they go to `keysTo` — the terminal.
    // ITS KEYBOARD TOO leaves only after: tearing it down removes the hidden input, and an input removed
    // while focused sent focus through <body> before the hand-off ran (measured, 2026-10-02: `focusout` to
    // null, then the next input — the keyboard the hand-off exists to keep was dropped on the way).
    const active = activeWithin(this.container);
    let carry: { typing: boolean; el: HTMLElement; source: string } | null = null;
    for (const [src, w] of this.wins) if (!want.has(src)) {
      w.pointer.cancelGesture();
      w.workspace?.dispose();
      w.pacer?.stop();
      w.listeners.abort();
      const holds = !!active && w.el.contains(active);
      if (holds) carry = { typing: active.classList.contains("win-key-input"), el: w.el, source: src };
      else w.el.remove();
      this.wins.delete(src); this.disposeAuto(src, holds); this.views.delete(src); this.viewModes.delete(src); this.sentCrops.delete(src);
    }
    for (const v of views) {
      let w = this.wins.get(v.source);
      if (!w) w = this.create(v.source);
      w.title.textContent = v.name;
      w.title.title = v.name;
      this.ensureWorkspace(w, v.activeCodec && v.activeCodec !== "av1" ? undefined : v.presentation);
      this.ensurePacer(v.source, w);
      const stream = streams.get(v.source);
      // REBIND ON THE TRACK, NOT ON THE STREAM OBJECT. A codec change removes the source's track and
      // adds a fresh one carrying the SAME MSID, so comparing stream objects misses it on any browser
      // that reuses the object — which is why a codec switch freezes the picture on WebKit and not on
      // Chrome. See shouldRebindVideo.
      const incomingTrack = stream?.getVideoTracks()[0];
      const incomingIdentity = incomingTrack && this.opts.trackIdentity?.(incomingTrack);
      if (stream && shouldRebindVideo(w.video.srcObject as MediaStream | null, w.boundTrack, stream, w.boundTrackIdentity, incomingIdentity)) {
        w.pointer.cancelGesture();
        w.workspace?.reset();
        bindVideo(w.video, stream);
        w.workspace?.reset();
        w.boundTrack = incomingTrack;
        w.boundTrackIdentity = incomingIdentity;
      }
      if (!incomingTrack || incomingTrack === w.workspaceSuspendedTrack) w.workspace?.stop(); else w.workspace?.start();
      // focus: highlight + raise + move id="screen" onto the focused window's video (e2e/tap-injection anchor)
      if (w.focused && !v.focused) w.pointer.cancelGesture();
      w.focused = v.focused;
      w.el.classList.toggle("focused", v.focused);
      this.syncKeyboard(v.source, w);
      // GLASSES ADDRESSES CONTROLS BY `data-nav-id`, and only the FOCUSED window is displayed there
      // (`.source-window.focused { display: flex }`). Carrying the id on every window would leave
      // `querySelector` picking whichever came first in the DOM — a control the wearer cannot see.
      // Exactly one element holds each id at a time, so the D-pad reaches the window on screen.
      this.setNavIds(w, v.focused);
      if (v.focused) { w.el.style.zIndex = "5"; w.video.id = "screen"; } else { w.el.style.zIndex = "3"; if (w.video.id === "screen") w.video.removeAttribute("id"); }
      // Bitrate follows the device's request. Codec is negotiated per window and is read-only.
      this.paintDevicePrefs(w, { fps: v.fps, bitrateBps: v.bitrateBps, activeCodec: v.activeCodec });
      const codec = this.devicePrefs.codec;
      w.codecInfo.textContent = ({ av1: "AV1", h265: "H.265", h264: "H.264" } as Record<string, string>)[v.activeCodec ?? ""] ?? "—";
      const unmet = codecUnmet(codec, v.activeCodec);
      if (unmet) w.codecInfo.setAttribute("data-unmet", "");
      else w.codecInfo.removeAttribute("data-unmet");
      // Stored codec pins still mark a fallback on both the readout and the gear.
      // AUDIO. The switch shows this device's choice; the badge distinguishes muted from yielded —
      // another window of the same app may own the audio even while this switch is on.
      const locallyMuted = this.opts.audioIsMuted?.(v.source) ?? false;
      w.audioBtn.setAttribute("aria-checked", String(!locallyMuted));
      const badge = audioBadge(v, locallyMuted);
      if (badge) {
        w.audioTag.dataset.audio = badge.state;
        w.audioTag.textContent = badge.state === "muted" ? "muted" : "audio elsewhere";
        w.audioTag.title = badge.title;
      } else {
        delete w.audioTag.dataset.audio;
        w.audioTag.textContent = "";
        w.audioTag.title = "";
      }
      if (unmet) w.gear.setAttribute("data-unmet", "");
      else w.gear.removeAttribute("data-unmet");
      this.applyLiveness(v.source, w);
    }
    if (carry) {
      if (keysTo) keysTo(carry.typing);
      else {
        const next = [...this.wins.values()].find((w) => w.focused)?.el;
        const to = (carry.typing ? next?.querySelector<HTMLElement>(".win-key-input") : null) ?? next?.querySelector<HTMLElement>(".win-body");
        to?.focus({ preventScroll: true });
      }
      this.disposeKeyboard(carry.source);
      carry.el.remove();
    }
  }

  /// Start the selected paced renderer for one window, if it is not running already.
  ///
  /// CALLED FROM `create` AND FROM `sync`, because the two halves race: the window is created from a
  /// `view-set`, and the RTCRtpReceiver the WebCodecs path needs arrives on `ontrack`, which can land
  /// either side of it. Retrying on every sync is cheaper than a join and cannot get stuck.
  ///
  /// A renderer that refuses to start (no receiver yet, no RTCRtpScriptTransform, no 2D context) is
  /// left for the next sync rather than latched off — but one that starts and then FAILS tears itself
  /// down and reports why, and is not retried: a path that silently re-attached in a loop would look
  /// like it was working.
  private pictureSize(win: Win): { w: number; h: number } {
    return win.source.startsWith("apps:") ? { w: 1280, h: 800 } : { w: win.video.videoWidth, h: win.video.videoHeight };
  }

  private ensureWorkspace(win: Win, presentation?: WorkspaceFormat): void {
    if (!win.source.startsWith("apps:")) return;
    if (!presentation || !this.opts.workspaceSupported) {
      win.pointer.cancelGesture(); win.workspace?.dispose(); win.workspace = undefined;
      if (win.workspaceNote) win.workspaceNote.hidden = false;
      return;
    }
    if (win.workspace) return;
    try {
      const renderer = new WorkspaceRenderer(win.video, presentation);
      win.workspace = renderer;
      renderer.canvas.addEventListener("workspacereadychange", () => {
        if (win.workspaceNote) win.workspaceNote.hidden = renderer.isReady;
        if (!renderer.isReady) win.pointer.cancelGesture();
      });
      win.video.parentElement!.append(renderer.canvas);
      this.refreshView(win.source);
    } catch { if (win.workspaceNote) win.workspaceNote.hidden = false; }
  }

  private ensurePacer(source: string, win: Win): void {
    if (source.startsWith("apps:")) return;
    const cfg = this.opts.pacedRender;
    if (!cfg || this.pacerFailed.has(source)) return;
    if (cfg.mode === "canvas") {
      if (win.pacer) return;
      win.pacer = startCanvasPacer(win.video, { marginMs: cfg.marginMs, cadenceLock: cfg.cadenceLock, probe: cfg.probe }) ?? undefined;
      return;
    }
    const wc = cfg.webcodecs;
    if (!wc) return;
    const receiver = wc.receiverFor(source);
    if (!receiver) return;                       // the track has not arrived yet; try again next sync
    if (win.pacer) {
      if (win.pacerReceiver === receiver) return;          // already presenting this one
      win.pacer.stop();
      win.pacer = undefined;
    }
    // The handle already exists — main.ts created it at `ontrack`, because the transform has to be
    // attached before RTP starts. All that is left is to give it a canvas.
    const handle = wc.pacerFor(source);
    if (!handle) return;
    handle.attachCanvas?.(win.video);
    win.pacerReceiver = receiver;
    win.pacer = handle;
  }

  /// Attach the paced renderer for one source NOW, rather than waiting for the next `view-set`.
  ///
  /// A stall rebuild has no `view-set` to ride on — nothing about the subscription changed — so
  /// leaving it to `sync` means the fresh handle never gets a canvas and the window stays dead while
  /// the watchdog rebuilds it every four seconds forever. Measured exactly that way.
  attachPacer(source: string): void {
    const w = this.wins.get(source);
    if (w) this.ensurePacer(source, w);
  }

  /// This source's paced renderer has failed for good: stop it, drop its canvas, and never attach
  /// another. The `<video>` underneath becomes visible again the moment the canvas goes.
  ///
  /// `pacerFailed` was read by `ensurePacer` and cleared by `releasePacer` from the day it was
  /// written, but nothing ever ADDED to it — so the "starts and then fails, and is not retried"
  /// behaviour its comment promises has never once happened. This is the writer.
  failPacer(source: string): void {
    this.pacerFailed.add(source);
    const w = this.wins.get(source);
    if (!w) return;
    w.pacer?.stop();
    w.pacer = undefined;
    w.pacerReceiver = undefined;
  }

  /// Forget this source's paced renderer so the next `sync` attaches a fresh one.
  ///
  /// Needed because `ensurePacer` short-circuits when the receiver is unchanged — which is exactly
  /// the case after a stall rebuild, where the receiver is the same object and only the worker behind
  /// it is new. Without this the window keeps showing the dead handle's canvas forever.
  releasePacer(source: string): void {
    const w = this.wins.get(source);
    if (!w) return;
    w.pacer = undefined;
    w.pacerReceiver = undefined;
    this.pacerFailed.delete(source);
  }

  /// TESTING (`?render=canvas`): per-source pacer counters, for `window.__rdev.pacer`.
  pacerStats(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [src, w] of this.wins) if (w.pacer) out[src] = w.pacer.stats();
    return out;
  }

  /// TESTING: retune every window's pacing margin live, so a session can be A/B'd without a reload.
  setPacerMargin(ms: number | "auto"): void {
    for (const w of this.wins.values()) w.pacer?.setMargin(ms);
  }

  resetPacerStats(): void {
    for (const w of this.wins.values()) w.pacer?.resetStats();
  }

  /// Re-derive one window's aspect from the source's point size. Called when that size first arrives
  /// or changes; deliberately NOT called when the encoder's resolution changes.
  private reapplyRatio(source: string): void {
    const win = this.wins.get(source);
    const pt = this.sizes.get(source);
    if (!win || !pt) return;
    if (this.fitted.has(source)) { this.applySize(win.el, source); return; }
    const ratio = windowAspectRatio(pt, undefined);
    if (ratio !== null) win.setRatio(ratio);
  }

  videos(): HTMLVideoElement[] { return [...this.wins.values()].map(w => w.video); }

  focusedVideo(): HTMLVideoElement | undefined {
    for (const w of this.wins.values()) if (w.focused) return w.video;
    return undefined;
  }

  /// Reflect the host's per-window liveness (`source-status`): overlay any window whose source is not live
  /// (minimized / closed). Called from main.ts on every source-status; also applied per-window inside `sync`
  /// so a freshly-created window inherits the current state immediately.
  /// The host's simulator states (`source-status.simState`), for the not-live overlay's words.
  setSimStates(m: Map<string, SimStateWire>): void {
    this.simStates = m;
    for (const [source, w] of this.wins) this.applyLiveness(source, w);
  }

  setLiveness(liveness: Map<string, boolean>): void {
    this.liveness = liveness;
    for (const [source, w] of this.wins) this.applyLiveness(source, w);
  }

  private applyLiveness(source: string, w: Win): void {
    w.offline.classList.toggle("hidden", sourceIsLive(source, this.liveness));
    if (source.startsWith("sim:")) w.offline.textContent = simOfflineText(this.simStates.get(source));
  }

  /// Everything this manager holds, released: the session is over (`session.ts`). The on-screen
  /// keyboards go through `disposeAuto` → `disposeKeyboard`, which clears their modifiers first — on
  /// the wire too — so there is exactly one path that tears a window down, not two.
  ///
  /// EVERY STEP THAT CAN THROW IS ITS OWN try/catch. `disposeKeyboard`'s modifier release and
  /// `cancelGesture`'s release-in-flight both SEND, and a channel already closing under this teardown
  /// (measured: `RTCDataChannel.send` throws `InvalidStateError`) must not strand every window still
  /// queued behind the one that threw, NOR skip that same window's own remaining steps — `el.remove()`
  /// always runs, and `wins` is cleared unconditionally below regardless of what any one step did.
  clear(): void {
    clearInterval(this.rxInterval);
    // FIRST, while its listeners still exist: the root attribute would otherwise outlive the session and
    // hide the next one's bars, and the browser would stay full screen over the dashboard.
    try { this.setFullscreen(null); } catch (e) { console.warn("[wm] clear: leaving full screen failed", e); }
    this.clearExitTimer();
    (this.context?.resizeSettle ?? windowResizeSettle).cancel(this);
    this.pageListeners.abort();
    this.dprDispose?.();
    for (const t of this.settleTimers.values()) window.clearTimeout(t);
    this.settleTimers.clear();
    for (const t of this.geometryTimers) window.clearTimeout(t);
    this.geometryTimers.clear();
    for (const source of [...this.wins.keys()]) {
      try { this.disposeAuto(source); }
      catch (e) { console.warn("[wm] clear: teardown failed", source, e); }
    }
    for (const w of this.wins.values()) {
      try { w.pointer.cancelGesture(); } catch (e) { console.warn("[wm] clear: cancelGesture failed", w.source, e); }
      try { w.pacer?.stop(); } catch (e) { console.warn("[wm] clear: pacer stop failed", w.source, e); }
      w.workspace?.dispose();
      w.listeners.abort();
      w.el.remove();
    }
    this.wins.clear();
  }

  // Live incoming-bitrate readout, one shared ~1s tick across all windows (per-window state - the meter -
  // lives on the Win record, so removed windows drop their meter for free when this.wins.delete() runs).
  private tickRxBitrate(): void {
    const pc = this.opts.pc();
    for (const [source, w] of this.wins) {
      const track = this.lastStreams.get(source)?.getVideoTracks()[0];
      const receiver = pc?.getReceivers().find((r) => r.track === track);
      if (!receiver) { w.rate.textContent = ""; continue; }
      void receiver.getStats().then((report) => {
        const mbps = w.meter(report);
        w.rate.textContent = mbps > 0 ? `${mbps.toFixed(1)} Mbps` : "";
      });
    }
  }

  private create(source: string): Win {
    // Captured BEFORE the auto-decision: a source already fitted when its window is re-created is a
    // restore, and re-centres. A window auto-fitted right now keeps its cascade spot instead.
    const wasFitted = this.fitted.has(source);
    this.maybeAutoFit(source);
    const listeners = new AbortController();
    const { signal } = listeners;
    const el = document.createElement("section"); el.className = "source-window"; el.dataset.source = source;
    const titlebar = document.createElement("div"); titlebar.className = "win-titlebar";
    const dot = document.createElement("span"); dot.className = "win-dot"; dot.setAttribute("aria-hidden", "true");
    // ON THE TITLEBAR, NOT INSIDE THE GEAR PANEL. Two states must be visible without opening
    // anything: muted (a setting the user chose) and yielded (another window of the same app carries
    // this application's audio). Both are silent, and a correct outcome indistinguishable from a
    // broken one becomes a bug report — the reasoning behind the amber `data-unmet` on a codec pin.
    const audioTag = document.createElement("span"); audioTag.className = "win-audio-badge";
    const title = document.createElement("span"); title.className = "win-title";
    const bitrateSel = document.createElement("select"); bitrateSel.className = "win-bitrate"; bitrateSel.title = "Bitrate";
    fillSelect(bitrateSel, BITRATE_STEPS_BPS, bitrateLabel);
    const codecInfo = document.createElement("span"); codecInfo.className = "win-codec";
    codecInfo.textContent = "—";
    const recoverySel = document.createElement("select");
    recoverySel.className = "win-recovery";
    recoverySel.title = "Forced FEC overhead (session-wide)";
    const autoRec = document.createElement("option");
    autoRec.value = AUTO_RECOVERY; autoRec.textContent = "Auto";
    recoverySel.append(autoRec);
    for (const bp of RECOVERY_STEPS_BP) {
      const o = document.createElement("option");
      o.value = String(bp); o.textContent = recoveryLabel(bp);
      recoverySel.append(o);
    }
    // A window created later must open showing the session's CURRENT setting, not Auto — the value
    // is one per connection, so a fresh titlebar disagreeing with its neighbours would be a lie.
    recoverySel.value = this.recoveryOverrideBp === null
      ? AUTO_RECOVERY : String(this.recoveryOverrideBp);
    const rate = document.createElement("span"); rate.className = "win-rate";
    // A text label, not a glyph: the self-hosted JetBrains Mono subsets are latin + latin-ext only, so a
    // fullscreen glyph (U+26F6 / U+2922) would fall back to a system font at unpredictable ink — the same
    // trap as the two close-x glyphs. The titlebar is already text-dense (60, 100%, 2.0M).
    const fit = document.createElement("button");
    fit.type = "button"; fit.className = "win-fit"; fit.textContent = "Fit";
    fit.title = "Fit to screen";
    fit.setAttribute("aria-pressed", String(this.fitted.has(source)));   // a re-created window keeps its mode
    // A WORD, NOT A GLYPH — the self-hosted JetBrains Mono subsets are latin + latin-ext only, so a
    // glyph like U+2295 falls back to a system font at unpredictable ink. Same trap as `Fit`,
    // `Settings` and the two close-x glyphs.
    const zoomBtn = document.createElement("button");
    zoomBtn.type = "button"; zoomBtn.className = "win-zoom"; zoomBtn.textContent = "Zoom";
    zoomBtn.title = "Zoom and pan the picture";
    zoomBtn.setAttribute("aria-pressed", "false");
    // WORDS, NOT GLYPHS — the reason `Fit` and `Zoom` are words: a full-screen glyph (U+26F6 / U+2922)
    // is outside the self-hosted subsets and falls back at unpredictable ink.
    const fsBtn = document.createElement("button");
    fsBtn.type = "button"; fsBtn.className = "win-fullscreen"; fsBtn.textContent = "Full screen";
    fsBtn.title = "Fill the screen with this window";
    fsBtn.setAttribute("aria-pressed", String(this.fullscreen === source));
    // The way out, for as long as the titlebar is gone. A CHILD OF THE WINDOW, like the settings panel,
    // so it stacks in the window's own context and is removed with it; hidden by CSS until full screen.
    const fsExit = document.createElement("button");
    fsExit.type = "button"; fsExit.className = "win-fullscreen-exit"; fsExit.textContent = "Exit";
    fsExit.title = "Exit full screen"; fsExit.setAttribute("aria-label", "Exit full screen");
    const minimize = document.createElement("button");
    minimize.type = "button"; minimize.className = "win-minimize"; minimize.textContent = "−";
    minimize.title = "Minimize"; minimize.setAttribute("aria-label", "Minimize");
    const close = document.createElement("button"); close.type = "button"; close.className = "win-close"; close.textContent = "×"; close.setAttribute("aria-label", "Close");
    // The right-hand cluster is its own element so `pinControls` can slide the WHOLE group back into the
    // viewport when the window overflows — the prefs selects are as unreachable as the buttons otherwise.
    const referenceRecovery = document.createElement("button");
    referenceRecovery.type = "button"; referenceRecovery.className = "win-referenceRecovery win-switch";
    referenceRecovery.setAttribute("role", "switch");
    referenceRecovery.setAttribute("aria-checked", String(this.devicePrefs.av1ReferenceRecovery === true));
    const delaySel = document.createElement("button");
    delaySel.type = "button"; delaySel.className = "win-delay";
    delaySel.setAttribute("role", "switch");
    delaySel.setAttribute("aria-checked", String(this.playoutDelayMs === 100));

    // A WORD, NOT A GLYPH — the self-hosted JetBrains Mono subsets are latin + latin-ext only, so a
    // gear glyph (U+2699) falls back to a system font at unpredictable ink. Same trap as the two
    // close-x glyphs and the reason `Fit` is a word.
    const gear = document.createElement("button");
    gear.type = "button"; gear.className = "win-gear"; gear.textContent = "Settings";
    gear.title = "Settings"; gear.setAttribute("aria-expanded", "false");

    const panel = document.createElement("dialog");
    panel.className = "win-settings"; panel.dataset.source = source;
    const panelHead = document.createElement("div"); panelHead.className = "win-settings-head";
    const panelTitle = document.createElement("span");
    panelTitle.className = "win-settings-title"; panelTitle.textContent = "Window settings";
    // ALWAYS PRESENT, NEVER LAYOUT-GATED. Desktop dismisses with esc or a click outside; glasses have
    // NEITHER — no Esc key on a D-pad and no pointer to click outside with. A close hidden on one
    // layout is a room with no door, which is exactly how `#palette-close` was once broken.
    const panelClose = document.createElement("button");
    panelClose.type = "button"; panelClose.className = "win-settings-close";
    panelClose.innerHTML = '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="m5 5 8 8M13 5l-8 8"/></svg>'; panelClose.setAttribute("aria-label", "Close settings");
    panelHead.append(panelTitle, panelClose);
    panel.append(panelHead);
    // On means the host screen is curtained (locked); the host echo remains authoritative.
    const curtainBtn = document.createElement("button");
    curtainBtn.type = "button"; curtainBtn.className = "win-curtain win-switch";
    curtainBtn.setAttribute("role", "switch");
    curtainBtn.setAttribute("aria-checked", String(this.curtainUp === true));
    curtainBtn.setAttribute("aria-label", "Curtain (this Mac)");
    curtainBtn.title = "Black the host's physical screen and suppress its local keyboard/trackpad";
    curtainBtn.disabled = this.curtainUp === null;      // a window opened before the host said anything
    curtainBtn.addEventListener("click", () => {
      const on = curtainBtn.getAttribute("aria-checked") !== "true";
      curtainBtn.setAttribute("aria-checked", String(on));
      this.opts.onCurtain?.(on);
    });

    // On means this device asks the host to send this window's audio. The badge still reports when
    // a sibling window owns it instead; the switch describes the person's choice, not ownership.
    const audioBtn = document.createElement("button");
    audioBtn.type = "button"; audioBtn.className = "win-audio win-switch";
    audioBtn.setAttribute("role", "switch");
    audioBtn.setAttribute("aria-checked", String(!(this.opts.audioIsMuted?.(source) ?? false)));
    audioBtn.setAttribute("aria-label", "Audio (this window)");
    audioBtn.title = "Stop sending this window's audio to this device";
    audioBtn.addEventListener("click", () => {
      const enabled = audioBtn.getAttribute("aria-checked") !== "true";
      audioBtn.setAttribute("aria-checked", String(enabled));
      this.opts.onSourceAudio?.(source, enabled);
    });

    const controlFor: Record<string, HTMLElement> = {
      bitrate: bitrateSel, codec: codecInfo, audio: audioBtn,
      recovery: recoverySel, referenceRecovery, delay: delaySel, rate, curtain: curtainBtn,
    };
    const groups = new Map<string, HTMLElement>();
    const groupFor: Record<string, string> = {
      bitrate: "MEDIA", recovery: "MEDIA", referenceRecovery: "MEDIA", delay: "MEDIA", audio: "MEDIA", curtain: "PRIVACY",
    };
    let info: HTMLElement | null = null;
    const descriptions: Record<string, string> = {
      recovery: "Extra recovery data for unreliable networks.",
      referenceRecovery: "Use acknowledged frames to recover remote AV1 video. Applies to all windows viewed on this device when supported.",
      curtain: "Hide the Mac’s display and block its local input.",
    };
    for (const row of SETTINGS_ROWS) {
      const control = controlFor[row.key];
      if (!control) continue;
      const line = document.createElement("label");
      line.className = "win-settings-row";
      // The CSS hides a gated row; `visibleSettingsRows` must agree with it, or the glasses D-pad
      // walks onto something invisible.
      if (row.layouts) line.dataset.layouts = row.layouts.join(" ");
      if (row.scope !== "window") line.classList.add("scope-wide");
      const name = document.createElement("span");
      name.className = "win-settings-label";
      // The scope is written next to the control, not only in its tooltip: a control that reaches
      // further than the window you opened it from, rendered identically to one that does not, is how
      // someone comes to believe their FEC percentage applies to that window alone.
      const labelText = document.createElement("span"); labelText.textContent = row.label;
      name.append(labelText);
      const scopeText = settingsRowLabel(row).slice(row.label.length).trim();
      if (scopeText) {
        const scope = document.createElement("small"); scope.className = "win-settings-scope";
        scope.textContent = scopeText; name.append(scope);
      }
      if (row.key !== "audio" && row.key !== "curtain") control.setAttribute("aria-label", settingsRowLabel(row));
      line.append(name, control);
      if (control === bitrateSel || control === recoverySel) {
        line.append(mountSettingsChoice(control as HTMLSelectElement, signal));
        syncSettingsChoice(control as HTMLSelectElement);
      }
      const sectionName = groupFor[row.key];
      if (sectionName) {
        let section = groups.get(sectionName);
        if (!section) {
          section = document.createElement("section"); section.className = "win-settings-section";
          section.setAttribute("aria-label", sectionName);
          const heading = document.createElement("h3"); heading.textContent = sectionName;
          section.append(heading); groups.set(sectionName, section); panel.append(section);
        }
        section.append(line);
      } else {
        if (!info) {
          info = document.createElement("div"); info.className = "win-settings-info";
          panel.append(info);
        }
        info.append(line);
      }
      if (descriptions[row.key]) {
        const hint = document.createElement("small"); hint.className = "win-settings-hint";
        hint.textContent = descriptions[row.key]!;
        line.append(hint);
      }
    }

    const sheet = document.createElement("div"); sheet.className = "win-settings-sheet";
    sheet.setAttribute("role", "dialog"); sheet.setAttribute("aria-label", "Window settings");
    sheet.append(...panel.childNodes); panel.append(sheet);

    const controls = document.createElement("div"); controls.className = "win-controls";
    // `Zoom` goes FIRST so the desktop cluster reads as it always has — it is hidden on every layout but
    // tabbed, where the bar is `[Zoom] [Settings] [Fit] [Full screen] [x]` (`Fit` only while zoomed).
    // Keep the underlying buttons and handlers on every layout. Only the floating chrome renders
    // these glyphs; the footer and glasses retain their existing accessible controls.
    for (const [button, glyph, label] of [
      [gear, "settings", "Settings"], [fit, "fit", "Fit to screen"],
      [fsBtn, "fullscreen", "Full screen"], [minimize, "minimize", "Minimize"], [close, "close", "Close"],
    ] as const) {
      const text = document.createElement("span"); text.className = "win-control-label";
      text.textContent = button.textContent;
      button.replaceChildren(text);
      const image = document.createElement("span"); image.className = "win-control-icon";
      image.innerHTML = windowControlIcon(glyph); button.prepend(image);
      button.setAttribute("aria-label", label); button.title = label;
    }
    if (source.startsWith("sim:")) {
      for (const [action, label] of [["home", "Home"], ["keyboard", "Keyboard"]] as const) {
        const button = document.createElement("button"); button.type = "button"; button.className = `win-sim-${action}`;
        button.setAttribute("aria-label", label); button.title = label;
        button.innerHTML = `<span class="win-control-icon">${windowControlIcon(action)}</span><span class="win-control-label">${label}</span>`;
        button.addEventListener("pointerdown", e => e.stopPropagation());
        button.addEventListener("mousedown", e => e.preventDefault());
        button.addEventListener("click", () => this.opts.onSimAction?.(source, action));
        controls.append(button);
      }
    }
    controls.append(zoomBtn, gear, fit, fsBtn, minimize, close);
    titlebar.append(dot, title, audioTag, controls);
    // THE WINDOW'S PASTE MENU (paste-and-drop design §2.2): a held finger or a right-click on the TITLEBAR —
    // never on one of its controls (a hold on `Fit` or `×` is that control's), and never on the picture,
    // where a one-finger hold is the Mac's own press-and-hold. The settings panel covers the window,
    // titlebar included, but is the titlebar's SIBLING, so nothing pressed in it reaches here; it is named
    // anyway, with `select`, so a control ever moved back into the bar stays that control's.
    //
    // THE TITLEBAR IS ALSO THE DRAG HANDLE (floating layout). The drag starts on the press and moves the
    // window until the hold fires — by the slop at most, since a move past it cancels the hold — and once
    // held, `attachPressHold` stops every later move AT the titlebar, ahead of the drag's own listener
    // there (pointer capture retargets them all to it), so the rest of the gesture is the menu's.
    const offTitleControls = (t: EventTarget | null) => !(t as Element | null)?.closest?.("button, select, .win-settings");
    const mayPaste = () => !source.startsWith("apps:") && (this.opts.canPaste?.() ?? false);
    attachPressHold(titlebar, {
      accepts: (e) => offTitleControls(e.target) && mayPaste(),
      onHold: (at) => this.opts.onWindowMenu?.(source, at),
    }, signal);
    // A MOUSE never holds — it right-clicks. On a control the browser's own menu stays.
    titlebar.addEventListener("contextmenu", (e) => {
      if (!offTitleControls(e.target) || !mayPaste()) return;
      e.preventDefault();
      this.opts.onWindowMenu?.(source, { x: e.clientX, y: e.clientY });
    }, { signal });
    const body = document.createElement("div"); body.className = "win-body";
    // Focusable by POINTER, never by Tab (tabindex -1): Tab is a key we forward to the host, so it
    // must not also walk the client's own focus ring. DOM focus is what gates key forwarding, and
    // the class tells the user which window is currently eating their keystrokes.
    body.tabIndex = -1;
    body.addEventListener("focus", () => el.classList.add("has-keyboard"));
    body.addEventListener("blur", () => el.classList.remove("has-keyboard"));
    const video = document.createElement("video"); video.autoplay = true; video.playsInline = true; video.muted = true;
    // `videoWidth` is 0 until metadata lands, so the FIRST fit rect is only knowable here. Without
    // this, a window that opens already zoomed — a layout flip back to tabbed — draws from a fit of 0.
    video.addEventListener("loadedmetadata", () => this.refreshView(source));
    const offline = document.createElement("div"); offline.className = "win-offline hidden"; offline.textContent = "No video — window minimized or closed";
    // The trackpad cursor. An <img> so the PNG's own size is used verbatim — the host renders it at
    // 1x precisely so CSS pixels equal the hotspot's point units. `pointer-events: none`, or it
    // would eat the taps it exists to represent.
    const padCursor = document.createElement("img");
    padCursor.className = "trackpad-cursor";
    padCursor.alt = "";
    padCursor.src = FALLBACK_CURSOR;
    body.append(video, offline, padCursor);
    // All four corners resize, like a native window. They carry NO visual indicator — the cursor is the
    // whole affordance — which is also why the NE corner sharing the titlebar with the −/× cluster is
    // harmless: nothing is drawn there, and `.win-controls` (positioned, z-index 1, opaque) paints above
    // these (z-index auto), so it wins the 5px where they overlap and the buttons stay clickable. NE is
    // still reachable across the titlebar's 11px right padding. Measured in `e2e/corner-resize-check.mjs`.
    const grips = (["nw", "ne", "sw", "se"] as const).map((corner) => {
      const g = document.createElement("div");
      g.className = "win-resize"; g.dataset.corner = corner; g.setAttribute("aria-hidden", "true");
      return { el: g, corner };
    });
    el.append(titlebar, body, panel, fsExit, ...grips.map((g) => g.el));

    // WHERE THE SESSION LEFT IT on the desktop layout — the host remembers every window's position, so
    // another device, or this one after a reload, opens it there — else the cascade.
    const remembered = isPinnedLayout(this.ui) ? undefined : this.statePositions.get(source);
    const off = remembered ?? tileOffset(this.created, this.viewportWidth);
    this.created++;
    el.style.left = `${off.x}px`; el.style.top = `${off.y}px`; el.style.width = "280px";
    this.applySize(el, source, wasFitted && !remembered ? "center" : "keep");   // actual size when the host has told us; the 280px above is the fallback
    this.applyCursor(el);         // a window opened after the last cursor push still wears it
    this.container.append(el);
    this.pinControls(el);         // in the DOM now, so getBoundingClientRect is meaningful
    if (remembered) this.placeAt(el, remembered);   // clamped now that its real size is known

    // Track the window's EFFECTIVE OUTPUT SIZE by observing the box itself rather than enumerating the
    // events that change it (viewport resize, Fit toggle, grip drag, host-side window resize, layout-mode
    // switch, orientation change) — one mechanism covers all of them and cannot miss one added later.
    // jsdom has no ResizeObserver, hence the feature test.
    if (typeof ResizeObserver !== "undefined") {
      // The trackpad cursor too: it is placed in PIXELS inside the picture, so a box that changes under
      // it (full screen, a rotation) leaves it at its old offset until the finger next moves.
      const ro = new ResizeObserver(() => {
        this.refreshView(source); this.recomputeAuto(source);
        const w = this.wins.get(source);
        if (w) this.paintTrackpadCursor(w);
      });
      ro.observe(body);
      this.autoObservers.set(source, ro);
    }

    // `pointer` is a placeholder here and is replaced by `attachPointer`'s handle below: the options
    // it is constructed with close over `win`, so the record has to exist first. The placeholder is
    // never reachable from a click — `setViewMode` reads the `Win` out of `this.wins`, which is set
    // at the very end of `create`.
    const win: Win = { source, zoomBtn, pointer: { cancelGesture: () => {} }, el, video, title, setRatio: () => {}, focused: false, bitrateSel, codecInfo, recoverySel, rate, referenceRecovery, delaySel, panel, gear, meter: makeRxBitrateMeter(), offline, fit, fsBtn, fsExit, padCursor, audioBtn, audioTag, cursorPos: { x: 0.5, y: 0.5 }, listeners };
    if (source.startsWith("apps:")) {
      el.classList.add("workspace-window");
      this.sizes.set(source, { w: 1280, h: 800 });
      this.pixelSizes.set(source, { w: 1280, h: 800 });
      const note = document.createElement("div"); note.className = "workspace-unavailable";
      note.textContent = "Apps unavailable — waiting for a supported workspace frame";
      body.append(note); win.workspaceNote = note;
    }
    this.paintDevicePrefs(win, undefined);
    el.dataset.pointerMode = source.startsWith("sim:") ? "direct" : this.pointerMode;
    el.dataset.viewMode = this.viewModeOf(source);
    this.ensurePacer(source, win);
    const fw = initFloatingWindow({
      signal, onResizeCancel:()=>this.settle(source,el),
      el, dragHandle: titlebar, resizeHandles: source.startsWith("apps:") ? [] : grips, ratio: 390 / 844, minW: 160, minH: 120,
      onDragEnd: (rect) => this.opts.onMoved?.(source, rect.x, rect.y),
      // Blur while dragging: the frame is a REQUEST, not a preview of decoded video, so there is nothing to
      // keep sharp — and it makes the provisional state obvious.
      onResizeStart: () => { this.resizeState.set(source, "resizing"); el.classList.add("resizing"); },
      onResizeEnd: (rect) => {
        const k = this.drawScale(source);
        const req = resizeRequest(rect.w, rect.h, WIN_CHROME_PX, WIN_BORDER_PX, k);
        if (!req) { this.settle(source, el); return; }   // degenerate drag: fall back to the known size
        // PIN the scale the body was drawn at, so the host's confirmed `req` is redrawn at `req x k` —
        // exactly the size just dragged to. Without this the drag is invisible: applySize re-fits the
        // smaller window back out to fill the band (see `drawnFitScale`). No-op when not fitted (k === 1).
        if (this.fitted.has(source)) this.fitPin.set(source, k);
        this.resizeState.set(source, "pending");         // stay blurred until the host answers
        this.opts.onResize?.(source, req.w, req.h);
        // Safety net only — the host replies to every request, so this fires just if that reply is lost.
        this.clearSettleTimer(source);
        this.settleTimers.set(source, window.setTimeout(() => this.settle(source, el), 2000));
      },
      // Oversized windows overflow the viewport BY DESIGN (spec: actual size, no shrink-to-fit), so there
      // is no 90%-of-viewport cap here.
      maxH: Number.POSITIVE_INFINITY, chrome: WIN_CHROME_PX + 2 * WIN_BORDER_PX,
      onGeometryChange: () => this.pinControls(el),
    });
    win.setRatio = fw.setRatio;
    // FROM THE SOURCE'S POINT SIZE WHEN WE HAVE IT — see window-aspect.ts. Deriving the aspect from
    // the decoded frame closes a loop through setRatio -> window height -> .win-body box ->
    // autoScale -> a new encode resolution, and every lap costs an encoder recreate and an IDR.
    const applyRatio = () => {
      // A FITTED window's geometry comes from the fit, not from the video: setRatio writes
      // h = w/ratio + chrome off el.style.width, which bypasses the fit path and re-clamps against the
      // drag band rather than the stage band. Route it to the one method that owns fitted geometry.
      if (this.fitted.has(source)) { this.applySize(el, source); return; }
      const ratio = windowAspectRatio(
        this.sizes.get(source),
        source.startsWith("apps:") || video.videoWidth > 0 ? this.pictureSize(win) : undefined,
      );
      if (ratio !== null) win.setRatio(ratio);
    };
    video.addEventListener("loadedmetadata", applyRatio);
    video.addEventListener("resize", applyRatio);   // source resolution/orientation change → re-fit aspect
    applyRatio();   // initial aspect/height (390/844 default) before the first frame's metadata arrives

    // Focus on interaction: clicking an UNFOCUSED window focuses it (no tap injected — attachPointer's gate below
    // is false while unfocused). Use pointerdown (capture) so it precedes the body's attachPointer handler.
    el.addEventListener("pointerdown", (e) => {
      // × and − own their clicks; don't focus-flash a window that is being closed or minimized.
      if ((e.target as HTMLElement).closest(".win-close, .win-minimize")) return;
      // A tap anywhere else in the window closes the settings panel — but NOT a tap inside the panel
      // itself, and not the gear that opens it.
      //
      // THIS LISTENER IS IN THE CAPTURE PHASE (see the `true` at the end of this call), so it runs
      // BEFORE any bubble-phase handler inside the panel — the panel's own `stopPropagation` cannot
      // save it. While the panel lived in a sibling layer, taps on it never reached this element at
      // all and the omission was invisible; as a child of the window, every tap passes through here,
      // and a guard naming only `.win-gear` dismissed the panel on contact with any control in it.
      if (!(e.target as HTMLElement).closest(".win-gear, .win-settings")) this.closeAllSettings();
      if (!win.focused) this.opts.onFocus(source);
      // Take DOM focus as well as SOURCE focus. They are different things — source focus decides
      // which injector the host routes to, DOM focus decides whether the browser hands rdev the keys
      // at all — and attachWindowKeys requires both, so one gesture must set both.
      //
      // EXCEPT a tap on the touch KEY STRIP while this window already holds focus: the strip and its
      // hidden input are children of this element, and moving focus from that input to the picture
      // closes the iOS soft keyboard — every Ctrl or Esc dismissed the keyboard it complements, and the
      // ⌨ toggle, finding the input already blurred, raised it again instead of hiding it. The strip's
      // own `mousedown` guard stops only the BROWSER's focus transfer, never this programmatic one.
      // Only the window's KEYBOARD focus is kept — its hidden input or the picture. Focus on a titlebar
      // button (Chromium focuses a tapped Zoom) still moves to the picture, or the physical key after
      // an armed Ctrl would press that button instead of reaching the host.
      const onStrip = (e.target as HTMLElement).closest(".key-strip") !== null;
      const a = activeWithin(this.container);
      const keyboardFocus = a === body || (a instanceof HTMLElement && el.contains(a) && a.classList.contains("win-key-input"));
      // A native picture's sibling editor already owns this window's keyboard. Moving focus
      // through the body releases its held modifiers (and the host's scoped mouse press).
      const nativeEditorFocus = a instanceof HTMLElement && el.contains(a) && a.classList.contains("native-source-text-input");
      if (!nativeEditorFocus && !(onStrip && keyboardFocus)) body.focus({ preventScroll: true });
    }, true);
    close.addEventListener("click", (e) => { e.stopPropagation(); this.opts.onClose(source); });
    minimize.addEventListener("click", (e) => { e.stopPropagation(); this.opts.onMinimize(source); });
    // A press on × or − moves no focus: the keys stay where they were — in this window, for `sync` to
    // hand on when it goes, or in the terminal. Chromium focused the pressed button, which took them from
    // the terminal and then went with the window.
    for (const b of [close, minimize]) b.addEventListener("mousedown", (e) => e.preventDefault());
    // ON A PINNED LAYOUT `Fit` MEANS RESET THE ZOOM, and it MUST NOT call `toggleFit` there.
    // `toggleFit` does nothing VISIBLE on a pinned layout — `applySize` returns early — but it still
    // flips `fitted` and clears `fitPin`, which are DESKTOP state that `maybeAutoFit` has often
    // already decided. So a press here would silently rewrite how the same window is drawn on the
    // floating layout, and the user would meet it on the next rotation with no idea what did it.
    fit.addEventListener("click", (e) => {
      e.stopPropagation();
      if (isPinnedLayout(this.ui)) this.resetView(source); else this.toggleFit(source);
    });
    zoomBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this.setViewMode(source, this.viewModeOf(source) === "zoom" ? "input" : "zoom");
    });
    // Synchronous from the click, all the way to `requestFullscreen` — a browser grants full screen only
    // inside the gesture that asked for it.
    fsBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      this.setFullscreen(this.fullscreen === source ? null : source);
    });
    fsExit.addEventListener("click", (e) => {
      e.stopPropagation();
      this.setFullscreen(null);
      // Back to the picture, which the window's own pointerdown already gave focus to — the button
      // that took it on the click is hidden now, and would hand it to <body>.
      body.focus({ preventScroll: true });
    });
    // Prefs controls: stopPropagation on pointerdown so interacting with a select doesn't start a window
    // drag (the titlebar is the drag handle, wired via bubble-phase pointerdown in initFloatingWindow).
    for (const sel of [bitrateSel, recoverySel, referenceRecovery, delaySel]) sel.addEventListener("pointerdown", (e) => e.stopPropagation());
    bitrateSel.addEventListener("change", () => this.changeDevicePrefs({ bitrateBps: Number(bitrateSel.value) }));
    recoverySel.addEventListener("change", () => this.opts.onRecovery(
      recoverySel.value === AUTO_RECOVERY ? null : Number(recoverySel.value)));
    referenceRecovery.addEventListener("click", () => {
      this.changeDevicePrefs({ av1ReferenceRecovery: this.devicePrefs.av1ReferenceRecovery !== true });
    });
    delaySel.addEventListener("click", () => {
      const minMs = this.playoutDelayMs === 100 ? 20 : 100;
      this.setPlayoutDelayMin(minMs);
      this.opts.onPlayoutDelay(minMs);
    });
    gear.addEventListener("click", (e) => {
      e.stopPropagation();
      const opening = !win.panel.classList.contains("open");
      // ONE PANEL AT A TIME. Two open panels would overlap and both would claim to own the same
      // session-wide values.
      this.closeAllSettings();
      if (opening) { gear.focus({ preventScroll: true }); this.setSettingsOpen(win, true); }
    });
    panelClose.addEventListener("click", () => this.setSettingsOpen(win, false));
    panel.addEventListener("cancel", e => { e.preventDefault(); this.setSettingsOpen(win, false); });
    // The panel lives in a top-level layer, so a pointerdown inside it must not reach the document
    // handler that closes it.
    panel.addEventListener("pointerdown", (e) => e.stopPropagation());
    panel.addEventListener("click", (e) => {
      if (e.target === panel && el.classList.contains("settings-modal")) this.setSettingsOpen(win, false);
    });
    panel.addEventListener("keydown", (e) => {
      if (e.key !== "Tab" || !el.classList.contains("settings-modal")) return;
      const focusable = [...sheet.querySelectorAll<HTMLElement>('button:not(:disabled), select:not(:disabled), [tabindex="0"]')]
        .filter(item => item.getClientRects().length > 0);
      const first = focusable[0], last = focusable.at(-1);
      if (e.shiftKey && activeWithin(this.container) === first) { e.preventDefault(); last?.focus(); }
      else if (!e.shiftKey && activeWithin(this.container) === last) { e.preventDefault(); first?.focus(); }
    });
    // Input: only the FOCUSED window injects touches (the host routes input to the focused source).
    // NORMALIZE AGAINST THE PICTURE, NOT THE BODY. `object-fit: contain` letterboxes the video
    // inside the body on any layout where the two aspects differ — which is every pinned layout,
    // since applySize returns early there and CSS pins the window full-bleed.
    // ...AND AGAINST THE ZOOMED PICTURE, which is the same rule one step further: the rect a touch
    // is normalized against is wherever the picture actually is, letterbox and zoom both.
    const contentRect = () => videoViewRect(
      body.getBoundingClientRect(), this.pictureSize(win), this.viewOf(source));
    const viewGesture = new ViewGesture();
    // AGAINST THE BODY RECT, NEVER `contentRect`. The content rect is measured against the very
    // picture this gesture is moving, so a pinch measured there feeds on itself frame by frame.
    const onViewGesture = (kind: ViewGestureKind, id: number, clientX: number, clientY: number): void => {
      if (kind === "cancel") { viewGesture.clear(); return; }
      const r = body.getBoundingClientRect();
      const p = { x: clientX - r.left, y: clientY - r.top };
      if (kind === "down") { viewGesture.down(id, p); return; }
      if (kind === "up") {
        viewGesture.up(id);
        // THE SETTLE, and the only place a gesture recomputes the Auto request. The 1000ms debounce
        // and the 16px deadband then buy exactly one encoder recreate and one IDR for the whole
        // pinch, rather than one per frame.
        if (!viewGesture.active) this.recomputeAuto(source);
        return;
      }
      const next = viewGesture.move(id, p, this.viewOf(source));
      if (next) this.applyView(source, next);
    };
    // A SIMULATOR IS TOUCHED, NOT POINTED AT: every finger passes through (`sim-touch.ts`), and the window machinery —
    // deferred press, two-finger scroll, trackpad cursor, hover — would only get in its way.
    const isSim = source.startsWith("sim:");
    const isWorkspace = source.startsWith("apps:");
    const workspacePointer = isWorkspace ? attachWorkspaceInput(this.container.closest<HTMLElement>("#session") ?? this.ui, {
      accepts: (e) => {
        if (el.hidden || !el.getClientRects().length) return false;
        const target = e.target as HTMLElement;
        if (target.closest?.("#palette, #claim")) return false;
        const other = target.closest?.(".source-window");
        if (other === el && target.closest?.(".win-titlebar, .win-settings, .win-resize, .win-fs-exit")) return false;
        if (other && other !== el) {
          const ours = Number(getComputedStyle(el).zIndex), theirs = Number(getComputedStyle(other).zIndex);
          if (theirs > ours || (theirs === ours && !!(el.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_FOLLOWING))) return false;
        }
        const r = body.getBoundingClientRect(), p = e as MouseEvent;
        return p.clientX >= r.left && p.clientX < r.right && p.clientY >= r.top && p.clientY < r.bottom;
      },
      hit: e => { const r = contentRect(); return win.workspace?.hitAt((e.clientX-r.left)/r.width, (e.clientY-r.top)/r.height) ?? null; },
      point: e => toNormalized(contentRect(), e.clientX, e.clientY), rect: contentRect,
      drawScale: () => this.drawScale(source), active: () => this.opts.workspaceActive?.() ?? false,
      focused: () => win.focused,
      focus: () => { if (!win.focused) this.opts.onFocus(source); body.focus({ preventScroll: true }); },
      // The session proxy gates the live channel; it intentionally exposes send() only.
      send: message => this.opts.inputChannel.send(encodeJson(message) as Uint8Array<ArrayBuffer>),
    }) : undefined;
    if (workspacePointer) signal.addEventListener("abort", () => workspacePointer.dispose(), { once: true });
    win.pointer = workspacePointer ?? (isSim
      ? attachSimTouch(body, this.opts.inputChannel, {
          isActive: () => win.focused, contentRect, viewMode: () => this.viewModeOf(source), onViewGesture,
        })
      : attachPointer(body, this.opts.inputChannel, this.opts.nowMs, {
          isActive: () => win.focused,
          contentRect,
          mode: () => this.pointerMode,
          trackpad: new Trackpad(),
          drawScale: () => this.drawScale(source),
          onCursorMove: (x, y) => this.paintTrackpadCursor(win, x, y),
          viewMode: () => this.viewModeOf(source),
          onViewGesture,
        }));
    const offPointerRelease=this.context?.input.onRelease(()=>win.pointer.cancelGesture());
    if(offPointerRelease)signal.addEventListener("abort",offPointerRelease,{once:true});
    // `drawScale` converts client pixels into host points, so a flick over a fitted (shrunk) window
    // moves its content by what it LOOKS like it moves it by — the same rule resizeRequest follows.
    if (!isWorkspace) attachScroll(body, this.opts.inputChannel, {
      isActive: () => win.focused, drawScale: () => this.drawScale(source), contentRect,
      viewMode: () => this.viewModeOf(source),
    });
    attachWindowKeys(body, this.opts.inputChannel, () => win.focused && (!isWorkspace || (!!win.workspace?.isReady && !!this.opts.workspaceActive?.())),
                     () => this.keyboards.get(source)?.mask() ?? 0);
    // A DROP ON THE PICTURE lands at that point on the Mac (paste-and-drop design §5): the point is
    // normalized against the PICTURE — the same `contentRect` a touch uses — so a letterbox and a zoom map
    // as a touch does, and a drop in the letterbox's bar is clamped onto the picture's edge. Any window's
    // picture, focused or not: the host focuses the window it drops on (§4.2).
    //
    // `preventDefault` is the take: the session refuses every OTHER file drop at the document (a browser
    // opens a dropped file by navigating to it), and it leaves alone a drop already prevented here.
    // `.drop-target` marks the window while a drag is over its picture; the drag's bytes are not readable
    // before the drop, so the Mac learns nothing until then.
    body.addEventListener("dragover", (e) => {
      if (!mayPaste() || !e.dataTransfer) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
      el.classList.add("drop-target");
    }, { signal });
    // Leaving for the picture's own element is not leaving: only a drag that goes OUT of the body unmarks.
    body.addEventListener("dragleave", (e) => {
      if (!(e.relatedTarget instanceof Node && body.contains(e.relatedTarget))) el.classList.remove("drop-target");
    }, { signal });
    body.addEventListener("drop", (e) => {
      el.classList.remove("drop-target");
      if (!mayPaste()) return;
      e.preventDefault();
      this.opts.onWindowDrop?.(source, toNormalized(contentRect(), e.clientX, e.clientY), e.dataTransfer);
    }, { signal });

    this.wins.set(source, win);
    this.recomputeAuto(source);   // the window now has a real box; decide before waiting on an observer
    return win;
  }
}
