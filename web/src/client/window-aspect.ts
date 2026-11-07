/// The aspect ratio a source window should be drawn at.
///
/// FROM THE SOURCE'S POINT SIZE, NOT THE DECODED FRAME. The decoded size moves every time auto
/// resolution picks a new scale; the host window's point size does not. Deriving the aspect from the
/// decoded frame closes a feedback loop:
///
///   scale -> encode WxH -> the <video>'s `resize` event -> setRatio -> the window's height changes
///   -> `.win-body` box changes -> ResizeObserver -> autoScale -> a DIFFERENT scale -> ...
///
/// and every lap recreates the libaom encoder and emits an IDR. Measured on a clean host with a
/// single client: `[encode] 1044x1472 -> 998x1408 -> 1044x1472`, each flip a visible hitch. The two
/// aspects differ only in the fourth decimal (0.709239 vs 0.708807), which is enough to land on a
/// different `ceil16` step.
///
/// AGENTS.md already records the rule for the scale itself — "Nothing may compute it from
/// `video.videoWidth` — that closes a feedback loop against bandwidth adaptation". The same hazard
/// reaches the ASPECT by a different route, which is how it survived.
export interface Dims { w: number; h: number }

export function windowAspectRatio(pointSize: Dims | undefined, decoded: Dims | undefined): number | null {
  const usable = (d: Dims | undefined): d is Dims => d !== undefined && d.w > 0 && d.h > 0;
  if (usable(pointSize)) return pointSize.w / pointSize.h;
  // Only until `source-status` arrives. The loop is tolerable here because it closes as soon as the
  // host reports the real size.
  if (usable(decoded)) return decoded.w / decoded.h;
  // Neither known: the caller keeps the ratio it already has. A fabricated 0 or 1 would resize the
  // window to something arbitrary on the first frame.
  return null;
}
