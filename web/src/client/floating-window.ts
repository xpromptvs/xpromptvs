import { contextFor, presentationRoot, queryRoot } from "./instance/context";
export interface Rect { x: number; y: number; w: number; h: number }

/// Lock height to width by the given aspect ratio (w/h), where `ratio` describes the BODY and `chrome` is
/// the non-video height (titlebar) stacked on top. Width is authoritative. Chrome-aware because the video
/// body — not the whole element — is what must match the source's real size; folding the titlebar into the
/// ratio squeezes the body and `object-fit: contain` then letterboxes it.
export function applyAspectLock(w: number, h: number, ratio: number, chrome = 0): { w: number; h: number } {
  return { w, h: w / ratio + chrome };
}

/// Keep at least `margin` px of the window visible on every edge (so the drag bar stays reachable), and
/// never above `top` — the tab bar owns that band, and a window dragged under it is unreachable.
export function clampToViewport(r: Rect, vw: number, vh: number, margin = 24, top = 0): Rect {
  const x = Math.min(Math.max(r.x, margin - r.w), vw - margin);
  const y = Math.min(Math.max(r.y, top), vh - margin);
  return { ...r, x, y };
}

/// A band token's height in px, read from the custom property rather than hardcoded so the two can't
/// drift. Read per call (it is cheap, and a cached value would go stale if the token ever became
/// responsive). Returns 0 when the property is unset — which is what jsdom does in unit tests.
function barHeight(token: string, element?: HTMLElement): number {
  return parseFloat(getComputedStyle(element ? presentationRoot(element) : document.documentElement).getPropertyValue(token)) || 0;
}

/// The tab bar owns the band above `#stage`: a window is never dragged or fitted under it.
export function tabBarHeight(element?: HTMLElement): number { return barHeight("--tabbar-h", element); }

/// The status bar owns the band below `#stage`. Used by fit-to-screen; the DRAG clamp deliberately does
/// not use it (a dragged window may still sit over the status bar — pre-existing behaviour, left alone).
///
/// MEASURED, not read from `--statusbar-h`, because the bar grows by `env(safe-area-inset-bottom)` to
/// clear the home indicator and that inset is NOT in the variable — it cannot be, since `barHeight`
/// parses the custom property's literal token stream and a `calc()` there yields NaN. Measuring is
/// also the honest quantity: fit-to-screen wants the band the bar actually occupies.
///
/// Falls back to the variable when the element is absent or measures 0, which is what keeps this
/// working under jsdom (no layout engine, every rect is 0x0).
export function statusBarHeight(element?: HTMLElement): number {
  const el = typeof document !== "undefined" ? (element ? queryRoot(element) : document).getElementById("statusbar") : null;
  const measured = el?.getBoundingClientRect().height ?? 0;
  return measured > 0 ? measured : barHeight("--statusbar-h", element);
}

/// Resize from the bottom-left grip: the top-right corner stays fixed. Positive dx (grip moves
/// right) shrinks width; negative dx widens. Height follows the aspect ratio. Clamped to [minW, maxH].
export function rectFromResize(
  start: Rect, dx: number, _dy: number, ratio: number, min: { w: number }, max: { h: number }, chrome = 0,
): Rect {
  const right = start.x + start.w;
  let w = start.w - dx;
  w = Math.max(min.w, w);
  let h = applyAspectLock(w, 0, ratio, chrome).h;
  if (h > max.h) { h = max.h; w = (h - chrome) * ratio; }
  return { x: right - w, y: start.y, w, h };
}

/// Free-form resize from the bottom-left grip: the TOP-RIGHT corner stays fixed and width/height move
/// INDEPENDENTLY (no aspect lock) — we are sizing a real host window, whose proportions are its own, not
/// the stream's. Clamped to the minimums rather than inverting through zero.
export type ResizeCorner = "nw" | "ne" | "sw" | "se";

export function rectFromFreeResize(
  start: Rect, dx: number, dy: number, min: { w: number; h: number }, corner: ResizeCorner = "sw",
): Rect {
  const west = corner === "nw" || corner === "sw";
  const north = corner === "nw" || corner === "ne";
  const w = Math.max(min.w, west ? start.w - dx : start.w + dx);
  const h = Math.max(min.h, north ? start.h - dy : start.h + dy);
  // The OPPOSITE corner is the anchor. Deriving x/y from the FAR EDGE rather than by adding the delta is
  // what keeps that anchor still once the drag passes the minimum size — adding the delta would let the
  // window keep creeping away under the pointer after it had stopped shrinking.
  return {
    x: west ? start.x + start.w - w : start.x,
    y: north ? start.y + start.h - h : start.y,
    w, h,
  };
}

/// Aspect ratio (w/h) from a video's intrinsic dimensions; falls back to iPhone-portrait for 0/invalid dims
/// (e.g. before the first frame arrives).
export function aspectRatioFromDims(w: number, h: number): number {
  return w > 0 && h > 0 ? w / h : 390 / 844;
}

/// Wire pointer-driven drag (from `dragHandle`) and resize (from every entry of `resizeHandles`) onto
/// `el`. `el` must be position:fixed; this writes left/top/width/height in px.
export function initFloatingWindow(opts: {
  signal?: AbortSignal;
  onResizeCancel?(): void;
  el: HTMLElement; dragHandle: HTMLElement; resizeHandles: Array<{ el: HTMLElement; corner: ResizeCorner }>;
  ratio: number; minW: number; maxH: number; chrome?: number; minH?: number;
  /// Grip pressed: the caller blurs the body and stops applying host size pushes for the duration.
  onResizeStart?(): void;
  /// Grip released with the final LOCAL rect. The caller sends one resize request and waits for the host's
  /// authoritative reply — this rect is a request, never the truth.
  onResizeEnd?(rect: Rect): void;
  /// The title-bar drag ENDED with the window moved — once, with where it landed (never per frame, which
  /// `onGeometryChange` is). The caller remembers it in the session's state.
  onDragEnd?(rect: Rect): void;
  /// The element's geometry was just written (drag, resize, or a ratio reflow). Fires on every frame of a
  /// drag, so keep the handler cheap. Used to keep the titlebar controls inside the viewport.
  onGeometryChange?(): void;
}): { setRatio(ratio: number): void } {
  const { el, dragHandle, resizeHandles, minW, maxH } = opts;
  const context = contextFor(el);
  const viewport = () => context?.viewport.size() ?? {width: window.innerWidth, height: window.innerHeight};
  const chrome = opts.chrome ?? 0;
  let ratio = opts.ratio;

  const currentRect = (): Rect => {
    const r = el.getBoundingClientRect();
    const local = context?.viewport.toLocal(r.left, r.top) ?? {x: r.left, y: r.top};
    return { ...local, w: r.width, h: r.height };
  };
  const writeRect = (r: Rect) => {
    el.style.left = `${r.x}px`; el.style.top = `${r.y}px`;
    el.style.width = `${r.w}px`; el.style.height = `${r.h}px`;
    el.style.right = "auto"; el.style.bottom = "auto";
    opts.onGeometryChange?.();   // single place geometry is written — so a single place to react to it
  };

  let cancelActive: (()=>void) | undefined;
  const track = (handle: HTMLElement, pointer: PointerEvent, move: (e:PointerEvent)=>void, finish:(cancelled:boolean)=>void) => {
    let done=false;
    const onMove=(e:PointerEvent)=>{if(e.pointerId===pointer.pointerId)move(e);};
    const end=(e?:Event)=>{
      if(done || (e && "pointerId" in e && e.pointerId!==pointer.pointerId))return;
      done=true;cancelActive=undefined;
      handle.removeEventListener("pointermove",onMove);
      for(const type of ["pointerup","pointercancel","lostpointercapture"])handle.removeEventListener(type,end);
      window.removeEventListener("blur",end);opts.signal?.removeEventListener("abort",end);offRelease?.();
      try{handle.releasePointerCapture(pointer.pointerId);}catch{}
      if(!opts.signal?.aborted)finish(e?.type!=="pointerup");
    };
    const offRelease=context?.input.onRelease(()=>end());
    cancelActive=()=>end();
    handle.addEventListener("pointermove",onMove);
    for(const type of ["pointerup","pointercancel","lostpointercapture"])handle.addEventListener(type,end);
    window.addEventListener("blur",end);opts.signal?.addEventListener("abort",end,{once:true});
  };
  dragHandle.addEventListener("pointerdown", (e) => {
    if(cancelActive)return;
    // Don't start a drag when the press lands on an interactive control inside the title bar (e.g. the
    // ✕ close button). setPointerCapture + preventDefault below otherwise swallow the button's click.
    if ((e.target as HTMLElement).closest("button")) return;
    const pe = e as PointerEvent;
    const start = currentRect();
    const ox = pe.clientX, oy = pe.clientY;
    dragHandle.setPointerCapture(pe.pointerId);
    const move = (ev: PointerEvent) => {
      const next: Rect = { ...start, x: start.x + (ev.clientX - ox), y: start.y + (ev.clientY - oy) };
      // No `top` argument (it defaults to 0): a window may be dragged over the tab bar as well as the
      // status bar, because `#windows` now paints ABOVE both — so its titlebar is always on top and
      // always grabbable. What keeps it recoverable is y >= 0 plus the 24px-visible rule.
      writeRect(clampToViewport(next, viewport().width, viewport().height, 24));
    };
    track(dragHandle,pe,move,()=>{
      const end = currentRect();
      if (end.x !== start.x || end.y !== start.y) opts.onDragEnd?.(end);
    });
    e.preventDefault();
  }, {signal:opts.signal});

  for (const { el: handle, corner } of resizeHandles) {
    handle.addEventListener("pointerdown", (e) => {
      if(cancelActive)return;
      const pe = e as PointerEvent;
      const start = currentRect();
      const ox = pe.clientX, oy = pe.clientY;
      handle.setPointerCapture(pe.pointerId);
      opts.onResizeStart?.();
      const move = (ev: PointerEvent) => {
        const r = rectFromFreeResize(start, ev.clientX - ox, ev.clientY - oy,
                                     { w: minW, h: opts.minH ?? 120 }, corner);
        writeRect(clampToViewport(r, viewport().width, viewport().height, 24));
      };
      track(handle,pe,move,cancelled=>{
        if(cancelled){writeRect(start);opts.onResizeCancel?.();}
        else opts.onResizeEnd?.(currentRect());
      });
      // stopPropagation as well as preventDefault: the top corners sit ON the titlebar, which is the DRAG
      // handle, so without it a corner press would start a move at the same time as a resize.
      e.preventDefault(); e.stopPropagation();
    }, {signal:opts.signal});
  }

  return {
    setRatio(r: number) {
      ratio = r;
      // Reflow from the INTENDED geometry (the inline styles we own), NOT getBoundingClientRect: a window that
      // isn't laid out (display:none in the tabbed layout, or measured before first layout) reads 0×0 there and
      // would get 0×0 written back — and a 0-sized box keeps measuring 0, so it stays collapsed forever unless a
      // later video-resize happens to fire while laid out. Style-based geometry is layout-independent; the
      // `minW` floor also RECOVERS a window already stuck at 0. Width is authoritative; height follows the ratio.
      const w = Math.max(parseFloat(el.style.width) || 0, minW);
      const x = parseFloat(el.style.left) || 0;
      const y = parseFloat(el.style.top) || 0;
      const locked = applyAspectLock(w, w / r, r, chrome);
      writeRect(clampToViewport({ x, y, w: locked.w, h: locked.h }, viewport().width, viewport().height, 24));
    },
  };
}
