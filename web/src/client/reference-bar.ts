/// Locally-drawn reference bars, for separating rdev's delivery from two other things it is
/// constantly confused with: the browser's compositing, and the frame RATE itself.
///
/// WHY TWO BARS. The first version drew ONE bar and moved it every animation frame — 120fps on a
/// 120Hz panel. The video updates at 60. Comparing them by eye is not a fair test: 60fps motion is
/// inherently less smooth than 120fps motion however perfectly it is presented, because each frame
/// is simply shown for twice as long. A 60fps bar that looks exactly as rough as the stream says the
/// roughness IS the frame rate, and no pacing work can touch it.
///
/// So: one bar stepping at 60fps, one at 120fps, same sweep, same compositor, nothing to do with the
/// network or the decoder.
///
///   60fps bar rough, 120fps bar smooth   -> the roughness is 60fps itself. Raise the capture rate.
///   both rough                           -> the browser, display or machine.
///   both smooth, stream rough            -> rdev's delivery, and now it is isolated.
///
/// `?refbar=1`. Off by default and never installed otherwise.
const PERIOD_MS = 3000;   // matches the host's motion overlay, so all three are directly comparable

function makeBar(label: string, top: number, container: HTMLElement): HTMLElement {
  const el = document.createElement("div");
  Object.assign(el.style, {
    position: "fixed", left: "0", top: `${top}px`, width: "72px", height: "44px",
    background: "#fff", zIndex: "9999", pointerEvents: "none", willChange: "transform",
    font: "11px/44px system-ui", color: "#000", textAlign: "center",
  });
  el.textContent = label;
  container.appendChild(el);
  return el;
}

export function installReferenceBar(container: HTMLElement = document.body): () => void {
  const a = makeBar("60", 0, container);
  const b = makeBar("120", 48, container);
  let handle = 0;
  let stopped = false;

  const place = (el: HTMLElement, ms: number): void => {
    const travel = Math.max(0, container.getBoundingClientRect().width - 72);
    // `transform`, not `left`: a transform is composited, which is the same path the video takes.
    el.style.transform = `translateX(${((ms % PERIOD_MS) / PERIOD_MS) * travel}px)`;
  };

  const step = (t: number): void => {
    if (stopped) return;
    // QUANTISED TO 60fps: the position advances only every 16.667ms of clock, so the bar moves in the
    // same discrete steps a 60fps source does — exactly what the stream delivers. Without this the
    // "reference" is smoother than anything rdev could ever produce, and the comparison is rigged.
    place(a, Math.floor(t / (1000 / 60)) * (1000 / 60));
    place(b, t);                                    // every animation frame: the display's own rate
    handle = requestAnimationFrame(step);
  };
  handle = requestAnimationFrame(step);
  return () => { stopped = true; cancelAnimationFrame(handle); a.remove(); b.remove(); };
}
