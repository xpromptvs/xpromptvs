/// Inverting `object-fit: contain`, which is the transform that decides WHERE the picture is inside
/// its element.
///
/// WHY THIS EXISTS. `attachPointer` normalized every pointer event against `.win-body`'s rect. The
/// <video> inside that body is `object-fit: contain`, so the picture is letterboxed whenever the
/// body's aspect ratio differs from the picture's. On the floating layout it never does — applySize
/// sizes the window to the source's own aspect, so the body IS the picture and normalizing against
/// it is right by accident. On a pinned layout applySize returns early and CSS makes the window
/// full-bleed, so the bars are real and every touch was offset by them and scaled wrong on BOTH axes.

export interface Box { w: number; h: number }
export interface Rect { x: number; y: number; w: number; h: number }

/// The four fields `toNormalized` actually reads. Structural rather than `DOMRect` so a computed
/// rect can be handed to it without constructing a DOM object.
export interface ClientRect { left: number; top: number; width: number; height: number }

/// The sub-rect of `box` the picture occupies under `object-fit: contain`.
///
/// An unknown intrinsic size — 0 on either axis, which is what a <video> reports before its first
/// frame — returns the WHOLE box. That degrades to the pre-fix behaviour rather than to a divide by
/// zero, and it is correct: nothing has been laid out, so there is no letterbox to invert.
export function containedRect(box: Box, natural: Box): Rect {
  if (!(natural.w > 0) || !(natural.h > 0) || !(box.w > 0) || !(box.h > 0)) {
    return { x: 0, y: 0, w: Math.max(0, box.w), h: Math.max(0, box.h) };
  }
  const k = Math.min(box.w / natural.w, box.h / natural.h);
  const w = natural.w * k, h = natural.h * k;
  return { x: (box.w - w) / 2, y: (box.h - h) / 2, w, h };
}

/// The same rect in CLIENT coordinates, which is the space pointer events report in.
///
/// USE THE VIDEO'S INTRINSIC SIZE, never the host point size in `WindowManager.sizes`. `object-fit:
/// contain` lays the picture out from the video's own aspect, so inverting it must use the same
/// numbers the browser used — and the two can genuinely disagree, because `EncodeDimensions.fit`
/// clamps to libaom's 3840x2160 ceiling and sacrifices aspect at the floor.
export function videoContentRect(bodyRect: ClientRect, natural: Box): ClientRect {
  const c = containedRect({ w: bodyRect.width, h: bodyRect.height }, natural);
  return { left: bodyRect.left + c.x, top: bodyRect.top + c.y, width: c.w, height: c.h };
}
