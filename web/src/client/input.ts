import type { ChannelLike } from "../lib/channel";
import { encodeJson } from "../lib/codec";
import { DirectTouch, TWO_FINGER_WINDOW_MS } from "./direct-touch";
import type { ClientRect } from "./pointer-map";
import type { PointerMode } from "./pointer-mode";
import { Trackpad, type TrackpadOutput } from "./trackpad";

export function toNormalized(rect: ClientRect, clientX: number, clientY: number): { x: number; y: number } {
  const clamp = (v: number) => Math.min(1, Math.max(0, v));
  return {
    x: clamp((clientX - rect.left) / rect.width),
    y: clamp((clientY - rect.top) / rect.height),
  };
}

/// The wire spelling of a mouse button. `left` is NEVER SENT on any path — the host's
/// `MouseButton(wire:)` reads an absent field as left — so this names the press's state, not the
/// payload. One builder (`touchMessage`) enforces it, so the two gesture paths cannot drift.
export type ButtonWire = "left" | "right";

/// Is the CLIENT a Mac, an iPad or an iPhone? Decides one thing only: whether a control-click is a
/// secondary click.
///
/// BOTH LINKS OF THE CHAIN ARE LOAD-BEARING, ONE PER ENGINE — measured 2026-09-03: Chrome on macOS
/// supplies `userAgentData.platform === "macOS"` and NO `navigator.platform` fallback is needed;
/// desktop Safari supplies `userAgentData === null` and only `navigator.platform === "MacIntel"`.
/// Reading either alone breaks one of the two engines rdev is used on. `navigator.platform` is
/// deprecated, which is why it is second rather than first. iPadOS Safari also reports "MacIntel",
/// which is CORRECT here — the question is whether this user's platform means ctrl+click as a
/// right click, not what the hardware is.
///
/// Takes the navigator so the rule is testable; every caller uses the default.
export function isApplePlatform(nav: {
  platform?: string; userAgent?: string; userAgentData?: { platform?: string };
} = navigator): boolean {
  const p = nav.userAgentData?.platform || nav.platform || "";
  return /mac|iphone|ipad|ipod/i.test(p || nav.userAgent || "");
}

/// Which host button a pointer event drives.
///
/// TWO ARMS. `button === 2` is the secondary button on every platform and every engine.
///
/// THE CTRL ARM IS REQUIRED, NOT DEFENSIVE — measured 2026-09-03 against real desktop Safari
/// (605.1.15) and real Chrome on macOS, driven with real `CGEvent`s rather than a synthesized
/// click: BOTH report a control-click as `pointerdown button=0 ctrlKey=true`, and NEITHER
/// translates it to button 2. Without this arm a Mac user's control-click reaches the host as a
/// plain LEFT click. The arms still overlap harmlessly if some engine ever does report button 2.
///
/// Also measured there: `contextmenu` fires BETWEEN the down and the up, and preventing it does
/// NOT suppress `pointerup` on either engine — so the press is always released and the host is
/// never left holding a right button.
///
/// THE PLATFORM GATE IS LOAD-BEARING. On Windows and Linux a ctrl+click is a genuine ctrl+click —
/// multi-select in every file list and editor — and mapping it to right would make it unreachable.
///
/// Anything else, `undefined` included, is left: an unknown button must degrade to the ordinary
/// click rather than to nothing, the same rule the host's `MouseButton(wire:)` follows.
export function pointerButton(e: { button: number; ctrlKey: boolean }, apple: boolean): ButtonWire {
  if (e.button === 2) return "right";
  return apple && e.button === 0 && e.ctrlKey ? "right" : "left";
}

export type ViewGestureKind = "down" | "move" | "up" | "cancel";

export interface PointerHandle {
  /// Abandon whatever gesture is in flight, RELEASING ANY PRESS THE HOST IS HOLDING. Called when the
  /// view mode is toggled under a finger already on the glass — without it the mode button is a
  /// stuck-button generator, the exact defect the deferred press exists to prevent.
  cancelGesture(): void;
}

export interface PointerOptions {
  /// Gates pointerdown/pointermove — when it returns false the surface neither sends nor mutates its
  /// down/id state (a no-op). It does NOT gate the up/cancel release (`endTouch`): a press must
  /// always be released once started, even if focus flips away mid-press, or the host is left
  /// holding a stuck touch. Omitted means always send, matching the pre-existing behaviour.
  isActive?: () => boolean;
  /// The rect pointer coordinates are normalized against, in CLIENT coordinates. Omitted means the
  /// surface's own rect — correct ONLY where the surface IS the picture. `.win-body` is not: the
  /// <video> inside it is `object-fit: contain`, so the picture is letterboxed on any layout whose
  /// aspect differs from the source's, and every coordinate is then offset by the bar.
  contentRect?: () => ClientRect;
  /// Direct unless this says otherwise, so a caller that does not pass it is unchanged.
  mode?: () => PointerMode;
  /// The gesture machine. One per surface — it owns that window's cursor.
  trackpad?: Trackpad;
  /// Converts content pixels into host points for trackpad scroll, exactly as `scrollToWire` does
  /// for a wheel: a flick must move the content by what it looks like it moves it by.
  drawScale?: () => number;
  /// Called with the normalized cursor whenever it moves, so the window can draw it.
  onCursorMove?: (x: number, y: number) => void;
  /// "zoom" routes every pointer to `onViewGesture` and feeds the gesture machines NOTHING, so host
  /// input and view manipulation can never compete for the same fingers — which is why this is a MODE
  /// and not a gesture latch, two fingers already meaning "scroll the remote" in both pointer modes.
  /// Omitted means "input", which is what every caller that does not zoom keeps doing.
  viewMode?: () => "input" | "zoom";
  /// CLIENT coordinates, deliberately RAW. The receiver converts them against the BODY rect, never
  /// the content rect: the content rect is measured against the very picture the gesture is moving,
  /// so a pinch measured there feeds on itself frame by frame.
  onViewGesture?: (kind: ViewGestureKind, id: number, clientX: number, clientY: number) => void;
}

/** Wire pointer + touch on the sim surface to the input channel. */
export function attachPointer(
  surface: HTMLElement, inputChannel: ChannelLike, nowMs: () => number,
  opts: PointerOptions = {},
): PointerHandle {
  const { isActive, contentRect, mode, trackpad, drawScale, onCursorMove, viewMode, onViewGesture } = opts;
  const rectOf = (): ClientRect => contentRect?.() ?? surface.getBoundingClientRect();
  /// Every pointer currently down, and where it last was in CLIENT coordinates. `cancelGesture` needs
  /// both: the ids to feed the machine, and the positions so the release it sends is at the place the
  /// finger actually is rather than at the origin.
  const live = new Map<number, { x: number; y: number }>();
  const inZoom = () => viewMode?.() === "zoom";
  let id = 0;
  /// The button the CURRENT press resolved to, or null when nothing is held. It replaces a bare
  /// `down` flag because the button must survive the whole gesture: the host maps a move to
  /// `rightMouseDragged` off this field, and per the Pointer Events spec a chorded second button
  /// fires `pointermove`, not another `pointerdown` — so the press is the only honest place to
  /// read it, and re-reading `pe.button` on the release would report whatever changed last.
  let pressed: ButtonWire | null = null;
  const send = (obj: unknown) => inputChannel.send(encodeJson(obj) as Uint8Array<ArrayBuffer>);

  // ── TRACKPAD MODE ────────────────────────────────────────────────────────────────────────────
  // Indirect control: the finger moves a cursor and every message reports the CURSOR's position,
  // not the finger's. The gesture vocabulary lives in the pure `Trackpad`; this is only transport.
  const usingTrackpad = () => mode?.() === "trackpad" && trackpad !== undefined;

  // HOVER IS THROTTLED TO ONE PER FRAME, exactly as the direct path's `flushHover` is — a finger
  // can produce more pointermove events than there are frames, and every one of them would be a
  // control-channel message. The CURSOR PAINT is deliberately NOT throttled: it is a local style
  // write the browser coalesces anyway, and delaying it reads as the cursor lagging the finger.
  let padHoverPending = 0;
  let padHover: { x: number; y: number } | undefined;
  const flushPadHover = () => {
    padHoverPending = 0;
    if (padHover) send({ t: "hover", x: padHover.x, y: padHover.y });
  };

  // `paintCursor` is FALSE for direct mode: the dot `onCursorMove` draws is the indirect mode's
  // virtual cursor, and painting one in direct mode would show a cursor that the finger is not
  // driving — the picture already shows the host's own.
  const emit = (outs: TrackpadOutput[], paintCursor: boolean) => {
    for (const o of outs) {
      if (o.t === "hover") {
        padHover = { x: o.x, y: o.y };
        if (!padHoverPending) padHoverPending = requestAnimationFrame(flushPadHover);
        if (paintCursor) onCursorMove?.(o.x, o.y);
        continue;
      }
      if (o.t === "scroll") {
        const k = drawScale?.() ?? 1;
        const d = k > 0 ? k : 1;
        send({ t: "scroll", x: o.x, y: o.y, dx: o.dx / d, dy: o.dy / d, unit: "px", mods: 0 });
        continue;
      }
      if (o.t === "fling") {
        // THE HOST RUNS THE GLIDE. A rAF loop here would send every frame of the decay over the
        // input channel, where it picks up exactly the delivery jitter that makes a coast judder;
        // generated on the host it never touches the wire. Divided by `drawScale` for the same
        // reason the deltas are — a velocity is a length per second, and the length half is drawn.
        const k = drawScale?.() ?? 1;
        const d = k > 0 ? k : 1;
        send({ t: "scroll-fling", x: o.x, y: o.y, vx: o.vx / d, vy: o.vy / d });
        continue;
      }
      // `id` increments per press so the host can tell two presses apart, matching the direct path.
      if (o.phase === "down") id++;
      send(touchMessage(o.phase, o.button, o.x, o.y));
      if (paintCursor) onCursorMove?.(o.x, o.y);
    }
  };

  const padEvent = (kind: "down" | "move" | "up" | "cancel", pe: PointerEvent) => {
    const r = rectOf();
    emit(trackpad!.handle(
      { kind, id: pe.pointerId, x: pe.clientX - r.left, y: pe.clientY - r.top, t: nowMs() },
      { w: r.width, h: r.height },
    ), true);
  };

  // ── DIRECT MODE, MULTI-FINGER ────────────────────────────────────────────────────────────────
  // TOUCH POINTERS ONLY. A mouse and a pen keep the immediate path below, byte for byte: a mouse can
  // never produce a second pointer, and the press deferral would otherwise put `TWO_FINGER_WINDOW_MS`
  // on every desktop click. An UNKNOWN `pointerType` takes the mouse path too — the conservative
  // side, since that is what every client did before this existed.
  const directTouch = new DirectTouch();
  const isFinger = (pe: PointerEvent) => pe.pointerType === "touch";
  const touchEvent = (kind: "down" | "move" | "up" | "cancel", pe: PointerEvent) => {
    const r = rectOf();
    emit(directTouch.handle(
      { kind, id: pe.pointerId, x: pe.clientX - r.left, y: pe.clientY - r.top, t: nowMs() },
      { w: r.width, h: r.height },
    ), false);
  };
  // THE MACHINE IS PURE AND THE CLOCK LIVES HERE. A finger that lands and never moves produces no
  // further events, so without this timer its press would wait for the lift — a press-and-hold
  // would reach the host as a tap. `nowMs` is `performance.now()` and `setTimeout` cannot fire
  // early on that timeline, so the flush always sees the full window elapsed; `flush` re-checks it
  // anyway, which is what makes a stale timer from a previous press harmless.
  let flushTimer = 0;
  const armFlush = () => {
    clearTimeout(flushTimer);
    flushTimer = setTimeout(() => {
      const r = rectOf();
      emit(directTouch.flush(nowMs(), { w: r.width, h: r.height }), false);
    }, TWO_FINGER_WINDOW_MS);
  };
  // A LEFT PRESS OMITS `button` ENTIRELY, and that is deliberate rather than lazy: the host reads an
  // absent field as left, so the mouse path's messages stay byte-identical to their pre-right-click
  // form and that absent-means-left rule keeps being exercised instead of becoming dead code.
  // ONE BUILDER for every path — the mouse, the trackpad machine and the direct-touch machine — so
  // the rule cannot hold on one of them and quietly not on another.
  const touchMessage = (phase: string, button: ButtonWire, x: number, y: number) => {
    const ts = Math.floor(nowMs());
    return button === "right"
      ? { t: "touch", phase, button: "right", id, x, y, ts }
      : { t: "touch", phase, id, x, y, ts };
  };
  const sendTouch = (phase: string, pe: PointerEvent) => {
    const { x, y } = toNormalized(rectOf(), pe.clientX, pe.clientY);
    send(touchMessage(phase, pressed ?? "left", x, y));
  };
  // THE BROWSER'S OWN CONTEXT MENU IS SUPPRESSED OVER THE PICTURE, AND IT IS NOT GATED ON
  // `isActive` — unlike the wheel, which is. The wheel's gate buys something: an unfocused window's
  // scroll falls through to ordinary page scrolling. There is no useful fallthrough for Chrome's
  // video menu painted over the video, and the FIRST right click into an unfocused window — the one
  // that focuses it and injects nothing — is exactly the one that would pop it. Scoped to this
  // surface, so Inspect stays reachable everywhere else in the app.
  surface.addEventListener("contextmenu", (e) => e.preventDefault());
  // A PRESSED pointer relays a `touch` drag. A BARE hover (no button) is relayed as a distinct `hover`
  // message — never as a touch "move": the host injects every touch move as a held-finger report, so a
  // hover sent that way would read as a stuck drag. `hover` exists so the host can move its real pointer
  // and report the cursor SHAPE under it (cursor passthrough); it is throttled to one per frame.
  surface.addEventListener("pointerdown", (e) => {
    if (isActive && !isActive()) return;
    const pe = e as PointerEvent;
    live.set(pe.pointerId, { x: pe.clientX, y: pe.clientY });
    // BEFORE EVERY OTHER BRANCH: in zoom mode neither gesture machine is fed at all, so none of them
    // may claim this pointer.
    if (inZoom()) {
      surface.setPointerCapture(pe.pointerId);
      onViewGesture?.("down", pe.pointerId, pe.clientX, pe.clientY);
      return;
    }
    if (usingTrackpad()) {
      surface.setPointerCapture(pe.pointerId);
      padEvent("down", pe);
      return;
    }
    if (isFinger(pe)) {
      surface.setPointerCapture(pe.pointerId);
      touchEvent("down", pe);
      armFlush();
      return;
    }
    pressed = pointerButton(pe, isApplePlatform());
    id++;
    surface.setPointerCapture(pe.pointerId); // keep getting move/up even if the cursor leaves
    sendTouch("down", pe);
  });
  let hoverPending = 0;
  let lastHover: PointerEvent | undefined;
  const flushHover = () => {
    hoverPending = 0;
    if (!lastHover) return;
    const { x, y } = toNormalized(rectOf(), lastHover.clientX, lastHover.clientY);
    send({ t: "hover", x, y });
  };
  surface.addEventListener("pointermove", (e) => {
    if (isActive && !isActive()) return;
    const pe = e as PointerEvent;
    if (live.has(pe.pointerId)) live.set(pe.pointerId, { x: pe.clientX, y: pe.clientY });
    if (inZoom()) { onViewGesture?.("move", pe.pointerId, pe.clientX, pe.clientY); return; }
    if (usingTrackpad()) { padEvent("move", pe); return; }
    if (isFinger(pe)) { touchEvent("move", pe); return; }
    if (pressed) { sendTouch("move", pe); return; }
    lastHover = pe;
    if (!hoverPending) hoverPending = requestAnimationFrame(flushHover);
  });
  const endTouch = (e: Event) => {
    // No isActive guard here (unlike pointerdown/pointermove): if focus flips away mid-press
    // (multitouch at cap>=2, or a subscribe triggering focus-follows-newest mid-drag), we must
    // still release — otherwise `down` stays true and no "up" is ever sent, leaving the host
    // holding a stuck pressed touch. `!down` below already no-ops a press that never started
    // while unfocused, so always-releasing on up/cancel is safe.
    //
    // THE TRACKPAD BRANCH RUNS FIRST, before the `!down` guard: `down` is direct-mode state and is
    // always false here, so leaving the guard ahead of it would swallow every trackpad release —
    // including the one that ends a drag, leaving the host holding a stuck button.
    //
    // ...AND THE ZOOM BRANCH RUNS BEFORE THAT, for the same shape of reason: in zoom mode the
    // machines were never fed, so no other branch may claim the release.
    const zoomPe = e as PointerEvent;
    live.delete(zoomPe.pointerId);
    if (inZoom()) {
      try { surface.releasePointerCapture(zoomPe.pointerId); } catch { /* already released */ }
      // A pointer that went down in INPUT mode and is released after the toggle lands here too. That
      // is safe only because `cancelGesture` ran on the toggle and already released the press.
      onViewGesture?.(e.type === "pointerup" ? "up" : "cancel",
                      zoomPe.pointerId, zoomPe.clientX, zoomPe.clientY);
      return;
    }
    if (usingTrackpad()) {
      const tp = e as PointerEvent;
      try { surface.releasePointerCapture(tp.pointerId); } catch { /* already released */ }
      padEvent(e.type === "pointerup" ? "up" : "cancel", tp);
      return;
    }
    // Ungated for the same reason the mouse release below is: a gesture must always be able to
    // finish, or the host is left holding whatever the machine had started.
    if (isFinger(e as PointerEvent)) {
      const tp = e as PointerEvent;
      try { surface.releasePointerCapture(tp.pointerId); } catch { /* already released */ }
      touchEvent(e.type === "pointerup" ? "up" : "cancel", tp);
      return;
    }
    if (!pressed) return;
    const pe = e as PointerEvent;
    try { surface.releasePointerCapture(pe.pointerId); } catch { /* already released */ }
    sendTouch("up", pe);
    pressed = null;   // AFTER the send: `sendTouch` reads it to label the release
  };
  /// Abandon the gesture in flight. See `PointerHandle.cancelGesture`.
  const cancelGesture = (): void => {
    const r = rectOf();
    const box = { w: r.width, h: r.height };
    for (const [pid, p] of live) {
      try { surface.releasePointerCapture(pid); } catch { /* already released */ }
      const ev = { kind: "cancel" as const, id: pid, x: p.x - r.left, y: p.y - r.top, t: nowMs() };
      // Exactly the dispatch `endTouch` uses, so the two cannot disagree about which machine is live.
      if (usingTrackpad()) emit(trackpad!.handle(ev, box), true);
      else emit(directTouch.handle(ev, box), false);
      // THE MOUSE PATH KEEPS ITS OWN FLAG rather than a machine, and a press it started must be
      // released here too or the host holds the button. Inside the loop so the release carries the
      // position of the pointer that actually made it.
      if (pressed) {
        const n = toNormalized(r, p.x, p.y);
        send(touchMessage("up", pressed, n.x, n.y));
        pressed = null;
      }
    }
    live.clear();
    // A later native activation can reuse this document and input facade. No old rAF/timer may
    // acquire its new source lease after this gesture has been abandoned.
    clearTimeout(flushTimer); flushTimer = 0;
    if (hoverPending) cancelAnimationFrame(hoverPending); hoverPending = 0; lastHover = undefined;
    if (padHoverPending) cancelAnimationFrame(padHoverPending); padHoverPending = 0; padHover = undefined;
    onViewGesture?.("cancel", -1, 0, 0);
  };

  surface.addEventListener("pointerup", endTouch);
  surface.addEventListener("pointercancel", endTouch);
  surface.addEventListener("lostpointercapture", e=>{if(live.has(e.pointerId))endTouch(e);});
  return { cancelGesture };
}

export interface ScrollWire {
  t: "scroll"; x: number; y: number; dx: number; dy: number; unit: "px" | "line"; mods: number;
}

/** The modifier bitmask the host's `InputModifiers` reads: 1 shift · 2 ctrl · 4 alt · 8 meta · 16 caps.
 * Taken from the originating DOM event rather than accumulated, so a modifier held down BEFORE the
 * window took keyboard focus (which produced no keydown to forward) is still reported correctly. */
export function modsBitmask(e: {
  shiftKey: boolean; ctrlKey: boolean; altKey: boolean; metaKey: boolean;
  getModifierState?: (key: string) => boolean;
}): number {
  return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0)
       | (e.getModifierState?.("CapsLock") ? 16 : 0);
}

/** Build the `scroll` message for a wheel event.
 *
 * The unit is what the BROWSER reported and is forwarded as-is: `deltaMode === 1` is a notched
 * wheel and stays lines (the host posts discrete `.line` events); anything else is pixels and the
 * host posts continuous, phase-bearing `.pixel` events. Pixels are NOT divided by 40 any more —
 * that division is what made a slow trackpad drag round to zero and move nothing.
 *
 * PIXELS ONLY are divided by `drawScale` to convert client pixels into host points, the same rule
 * `resizeRequest` follows for a drag: a flick must move the content by what it looks like it moves
 * it by. A line delta is a notch count, not a length, so scaling it would be meaningless. */
export function scrollToWire(we: WheelEvent, rect: ClientRect, drawScale: number): ScrollWire {
  const { x, y } = toNormalized(rect, we.clientX, we.clientY);
  const line = we.deltaMode === 1;
  const k = line || !(drawScale > 0) ? 1 : drawScale;
  return {
    t: "scroll", x, y,
    dx: we.deltaX / k, dy: we.deltaY / k,
    unit: line ? "line" : "px",
    mods: modsBitmask(we),
  };
}

export interface ScrollOptions {
  /// Gated FIRST, so an unfocused window's wheel falls through to native page scroll instead of
  /// becoming a dead zone; only the focused surface preventDefaults to own the scroll.
  isActive?: () => boolean;
  /// Converts client pixels into host points for PIXEL deltas only — see `scrollToWire`.
  drawScale?: () => number;
  /// See `PointerOptions.contentRect`. The wheel's x/y are normalized the same way a touch's are.
  contentRect?: () => ClientRect;
  /// See `PointerOptions.viewMode`. A mode that claims to send nothing must send nothing.
  viewMode?: () => "input" | "zoom";
}

/** Wire wheel events on the video surface to the input channel as {t:"scroll"}. Only meaningful for
 * a window source (a sim injector no-ops scroll). */
export function attachScroll(
  surface: HTMLElement, inputChannel: ChannelLike, opts: ScrollOptions = {},
): void {
  const { isActive, drawScale, contentRect, viewMode } = opts;

  // ── ZOOM GESTURES ARE SUPPRESSED, NOT FORWARDED ──────────────────────────────────────────────
  // A trackpad PINCH reaches a page as a wheel event carrying `ctrlKey` — the de-facto convention
  // every engine follows. MEASURED 2026-09-03 on real Safari with a real pinch: 140 such wheels,
  // `deltaMode: 0`, fractional deltas — AND 78 non-standard `gesture*` events beside them, `scale`
  // climbing 1.00 → 1.14. Chrome fires only the first stream; Safari fires both.
  //
  // Forwarding the ctrl-bearing wheel sends the host a MODIFIER THE USER NEVER PRESSED, and on
  // macOS ctrl+scroll is the screen-zoom idiom, so a pinch silently half-worked in whichever remote
  // apps happen to honour it. Posting a REAL pinch is not reachable: apps listen for
  // `NSEventTypeMagnify` and `CGEvent` has no public API for it — private-API territory, and its
  // own spike if it is ever wanted.
  //
  // KNOWN AND UNAVOIDABLE COST: a genuine Ctrl+wheel from a real mouse is INDISTINGUISHABLE from a
  // pinch — that ambiguity is the convention, not a bug here — so it is dropped too.
  //
  // BOTH SUPPRESSIONS ARE UNGATED BY FOCUS, the same rule (and the same reasoning) as the context
  // menu in `attachPointer`: an unfocused window's ordinary wheel usefully falls through to page
  // scrolling, but a zoom falling through scales the CLIENT — and rdev's layout is viewport-width
  // driven, so `chooseLayoutMode` can flip underneath it. Scoped to this surface on a DESKTOP, where a
  // pinch elsewhere in the app still zooms the page; on a touch device the page blocks zoom everywhere
  // (viewport-fit.ts `blockPageZoom`, asked for 2026-10-04).
  for (const g of ["gesturestart", "gesturechange", "gestureend"]) {
    surface.addEventListener(g, (e) => e.preventDefault());
  }

  surface.addEventListener("wheel", (e) => {
    const we = e as WheelEvent;
    if (we.ctrlKey) { we.preventDefault(); return; }   // a pinch: swallow it, never forward it
    if (viewMode?.() === "zoom") { we.preventDefault(); return; }   // the mode sends nothing at all
    if (isActive && !isActive()) return;   // unfocused → don't preventDefault; let the page scroll
    we.preventDefault();
    const rect = contentRect?.() ?? surface.getBoundingClientRect();
    inputChannel.send(encodeJson(scrollToWire(we, rect, drawScale?.() ?? 1)) as Uint8Array<ArrayBuffer>);
  }, { passive: false });

}

