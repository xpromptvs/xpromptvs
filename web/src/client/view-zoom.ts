/// Zoom and pan of the PICTURE on the mobile layout, as pure geometry.
///
/// WHY THIS EXISTS. The tabbed layout pins the focused window full-bleed (`applySize` returns early
/// under `isPinnedLayout()`), so a landscape Mac window on a portrait phone is a thin strip in a
/// field of black — measured in `docs/client-web.md` as a 420x236 picture with 205px bars in a
/// 420x646 body. There is no way to make it bigger, and Auto correctly asks the host for only the
/// pixels that strip can show.
///
/// THE WHOLE DESIGN IS THAT ZOOM IS A PROPERTY OF THE PICTURE'S RECT. Every consumer that needs to
/// know where the picture is already derives from `containedRect`, so composing a zoomed rect on top
/// of it leaves each of them correct with no change to its contract. See
/// `docs/superpowers/specs/2026-09-07-mobile-picture-zoom-design.md`.
///
/// PURE — no DOM, no timers, no layout, in the manner of `trackpad.ts` and `direct-touch.ts`.
import { containedRect, type Box, type ClientRect, type Rect } from "./pointer-map";

/// `z` is the factor over contain-fit, so 1 is exactly today's picture. `ox`/`oy` are the picture's
/// top-left corner relative to the BODY, in body CSS px.
export interface View { z: number; ox: number; oy: number }

/// Unzoomed. The offsets are ignored at z = 1 — every axis fits, so both are centred — which is what
/// lets this be the default before anything has been laid out.
export const FIT_VIEW: View = { z: 1, ox: 0, oy: 0 };

/// The ceiling when native parity is unknowable: a simulator publishes no native size, and neither
/// does a window before its first capture push. Same "absent means UNKNOWN, keep something usable"
/// rule `autoScale` follows when it returns null.
export const FALLBACK_MAX_ZOOM = 4;

/// One axis of the pan clamp, and the ONE place the rule lives.
///
/// AN AXIS THAT FITS IS CENTRED, NOT PANNABLE. Letting a fitting axis drift would put a black gap
/// beside a picture that has room to be centred, which reads as the picture having come loose.
const axisOffset = (o: number, len: number, boxLen: number): number =>
  len <= boxLen ? (boxLen - len) / 2 : Math.min(0, Math.max(boxLen - len, o));

/// The picture's rect inside the body after zoom and pan. `fit` is `containedRect`'s answer.
///
/// THE OFFSETS ARE CLAMPED HERE, not merely on the way in, so the invariant
/// `z === 1 => zoomedRect(fit, view, box) === fit` holds for ANY view rather than only a
/// pre-clamped one. The returned rect may extend outside the body; that is correct and is what the
/// browser clips.
export function zoomedRect(fit: Rect, view: View, box: Box): Rect {
  const z = Math.max(1, view.z);
  const w = fit.w * z, h = fit.h * z;
  return { x: axisOffset(view.ox, w, box.w), y: axisOffset(view.oy, h, box.h), w, h };
}

/// The view as it will actually be drawn: z into [1, zMax], offsets as `zoomedRect` would place
/// them. Defined IN TERMS OF `zoomedRect` so the two cannot disagree about the clamp.
export function clampView(view: View, box: Box, fit: Rect, zMax: number): View {
  const z = Math.min(Math.max(view.z, 1), Math.max(1, zMax));
  const r = zoomedRect(fit, { ...view, z }, box);
  return { z, ox: r.x, oy: r.y };
}

/// Change z about a fixed point in BODY coordinates: the source pixel under `anchor` does not move.
export function anchoredZoom(view: View, anchor: { x: number; y: number }, z1: number): View {
  const k = z1 / view.z;
  return { z: z1, ox: anchor.x - (anchor.x - view.ox) * k, oy: anchor.y - (anchor.y - view.oy) * k };
}

/// The zoom at which ONE HOST NATIVE PIXEL LANDS ON ONE DEVICE PIXEL — past it there are no more
/// host pixels to ask for, so more zoom is upscaling and the Auto request has already saturated at
/// native. Floored at 1: the fit is the floor even for a source with fewer pixels than the phone
/// paints.
export function maxZoom(fitW: number, pxW: number, dpr: number): number {
  if (!(fitW > 0) || !(pxW > 0) || !(dpr > 0)) return FALLBACK_MAX_ZOOM;
  return Math.max(1, pxW / (fitW * dpr));
}

/// The CSS transform that makes the browser paint `fit` as `target`, for `transform-origin: 0 0`.
export function transformFor(fit: Rect, target: Rect): { tx: number; ty: number; z: number } {
  const z = fit.w > 0 ? target.w / fit.w : 1;
  return { tx: target.x - z * fit.x, ty: target.y - z * fit.y, z };
}

/// The picture's rect in CLIENT coordinates, which is the space pointer events report in. The
/// zoom-aware `videoContentRect`, and identical to it at `FIT_VIEW`.
export function videoViewRect(bodyRect: ClientRect, natural: Box, view: View): ClientRect {
  const box = { w: bodyRect.width, h: bodyRect.height };
  const t = zoomedRect(containedRect(box, natural), view, box);
  return { left: bodyRect.left + t.x, top: bodyRect.top + t.y, width: t.w, height: t.h };
}

/// Pan and zoom from finger positions, in BODY PIXELS.
///
/// BODY PIXELS RATHER THAN CONTENT PIXELS IS LOAD-BEARING. A content rect is measured against the
/// very picture this is moving, so a pinch measured there feeds on itself frame by frame — the
/// finger separation shrinks in content units exactly as the zoom grows. The body rect is a stable
/// frame no transform touches.
///
/// INCREMENTAL, NOT ANCHORED TO THE GESTURE'S START. Each move is computed against the view the
/// caller is holding NOW — which is the CLAMPED one — so a picture parked against an edge does not
/// accumulate invisible offset and then jump when the finger comes back.
///
/// PURE — no DOM, no timers, no layout. The caller owns the clamp, because clamping needs the box
/// and the fit rect, which are layout.
export class ViewGesture {
  private readonly pointers = new Map<number, { x: number; y: number }>();
  /// The centroid and spread the next move is measured against. Null exactly when no finger is down.
  private last: { c: { x: number; y: number }; spread: number } | null = null;

  get active(): boolean { return this.pointers.size > 0; }

  down(id: number, p: { x: number; y: number }): void { this.pointers.set(id, p); this.rebase(); }
  up(id: number): void { this.pointers.delete(id); this.rebase(); }
  clear(): void { this.pointers.clear(); this.last = null; }

  /// The new view for this finger position, or null when there is nothing to apply.
  move(id: number, p: { x: number; y: number }, view: View): View | null {
    const prev = this.last;
    if (!prev || !this.pointers.has(id)) return null;
    this.pointers.set(id, p);
    this.rebase();
    const now = this.last!;
    // ZOOM FIRST, ABOUT THE CENTROID THE FINGERS ARE AT NOW, then translate by how far that centroid
    // travelled. A single finger has spread 0 and therefore pans without zooming.
    const zoomed = prev.spread > 0 && now.spread > 0
      ? anchoredZoom(view, now.c, view.z * (now.spread / prev.spread))
      : view;
    return { z: zoomed.z, ox: zoomed.ox + (now.c.x - prev.c.x), oy: zoomed.oy + (now.c.y - prev.c.y) };
  }

  /// Re-anchor on the current fingers. Called on EVERY down and up as well as every move, which is
  /// what stops a lift from lurching: the centroid of two fingers jumps by half their gap when one
  /// goes, and a baseline taken before the lift would pan by that jump.
  private rebase(): void {
    if (this.pointers.size === 0) { this.last = null; return; }
    const n = this.pointers.size;
    let x = 0, y = 0;
    for (const p of this.pointers.values()) { x += p.x; y += p.y; }
    const c = { x: x / n, y: y / n };
    let s = 0;
    for (const p of this.pointers.values()) s += Math.hypot(p.x - c.x, p.y - c.y);
    // MEAN DISTANCE FROM THE CENTROID, so one finger is spread 0 (pan only) and a third finger
    // degrades gracefully instead of needing a case of its own.
    this.last = { c, spread: s / n };
  }
}

/// The part of the SOURCE the viewer can actually see, normalized to the picture's own coordinates.
///
/// WHY THE HOST WANTS IT. Everything outside this rect is filled with a checkerboard at encode time,
/// so the bitrate goes where the viewer is looking rather than being spread over a window they are
/// seeing a tenth of. The encoded frame's geometry does NOT change — see
/// `docs/superpowers/specs/2026-09-07-crop-aware-encoding-design.md` — so nothing here has to be
/// synchronised with any particular frame, and nothing in the render path changes.
///
/// AT THE FIT VIEW THIS IS THE WHOLE RECT, so the feature is inert unzoomed and inert on every layout
/// that has no zoom. The same property `zoomedRect` has, and it is asserted the same way.
export function visibleSourceRect(fit: Rect, view: View, box: Box): {
  x: number; y: number; w: number; h: number;
} {
  const t = zoomedRect(fit, view, box);
  if (!(t.w > 0) || !(t.h > 0)) return { x: 0, y: 0, w: 1, h: 1 };
  // The visible part of the picture, in body coordinates.
  const left = Math.max(0, t.x), top = Math.max(0, t.y);
  const right = Math.min(box.w, t.x + t.w), bottom = Math.min(box.h, t.y + t.h);
  if (!(right > left) || !(bottom > top)) return { x: 0, y: 0, w: 1, h: 1 };
  return {
    x: (left - t.x) / t.w,
    y: (top - t.y) / t.h,
    w: (right - left) / t.w,
    h: (bottom - top) / t.h,
  };
}
