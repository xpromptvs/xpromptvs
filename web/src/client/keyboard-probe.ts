// INSTRUMENT (`?kbprobe=1`): WHEN a phone's soft keyboard moves the visual viewport, relative to the focus that raised
// it — once as it starts, once as it ends, or frame by frame along its slide. Asked 2026-10-13: "on mobile safari try
// to match the keyboard up/down animation with web animation api" — and which of the three iOS does decides whether an
// animation can start at the viewport's `resize` (it carries the final size as the slide starts), must start at the
// focus with a remembered height (it comes after the slide), or is not needed (the page already follows each frame).
// Nothing automated raises a soft keyboard, so this is read off a real phone: a rolling log at the top of the visible
// area — every focusin/focusout, every visualViewport and window resize/scroll with the viewport's height and offset,
// and, for 1.5 s after each focus change, every animation frame whose viewport height or offset changed — each line
// timed from that focus change. A screenshot of it is the measurement. The dashboard's input raises the keyboard as
// well as the terminal does, so it needs no session.

const SAMPLE_MS = 1500;
const LINES = 48;

export function installKeyboardProbe(win: Window = window): () => void {
  const vv = win.visualViewport;
  const doc = win.document;
  const box = doc.createElement("pre");
  box.id = "kbprobe";
  box.style.cssText = "position:fixed;left:4px;right:4px;top:4px;z-index:2147483647;margin:0;padding:6px 8px;"
    + "max-height:46vh;overflow:hidden;font:10.5px/1.35 ui-monospace,Menlo,monospace;background:rgba(0,0,0,.84);"
    + "color:#8f8;white-space:pre-wrap;pointer-events:none;border-radius:6px";
  doc.body.append(box);
  const lines: string[] = [];
  let t0 = performance.now();
  let samplingUntil = 0;
  let last = "";
  const shape = () => vv
    ? `vv ${Math.round(vv.width)}×${Math.round(vv.height)} top ${Math.round(vv.offsetTop)} · inner ${win.innerHeight}`
    : `no visualViewport · inner ${win.innerHeight}`;
  const log = (what: string) => {
    const ms = Math.round(performance.now() - t0);
    lines.push(`${String(ms >= 0 ? `+${ms}` : ms).padStart(6)} ${what.padEnd(14)} ${shape()}`);
    if (lines.length > LINES) lines.splice(0, lines.length - LINES);
    box.textContent = `kbprobe — ms after the last focus change · ${navigator.userAgent.match(/OS [\d_]+/)?.[0] ?? ""}\n` + lines.join("\n");
  };
  const sample = () => {
    if (performance.now() > samplingUntil) return;
    const now = vv ? `${Math.round(vv.height)}/${Math.round(vv.offsetTop)}` : "";
    if (now !== last) { last = now; log("frame"); }
    win.requestAnimationFrame(sample);
  };
  const trigger = (what: string) => (e: Event) => {
    t0 = performance.now();
    const target = e.target instanceof Element ? e.target.tagName.toLowerCase() : "?";
    log(`${what} ${target}`);
    last = vv ? `${Math.round(vv.height)}/${Math.round(vv.offsetTop)}` : "";
    const sampling = performance.now() < samplingUntil;
    samplingUntil = performance.now() + SAMPLE_MS;
    if (!sampling) win.requestAnimationFrame(sample);
  };
  const ac = new AbortController();
  const on = { signal: ac.signal, capture: true };
  doc.addEventListener("focusin", trigger("focusin"), on);
  doc.addEventListener("focusout", trigger("focusout"), on);
  vv?.addEventListener("resize", () => log("vv.resize"), { signal: ac.signal });
  vv?.addEventListener("scroll", () => log("vv.scroll"), { signal: ac.signal });
  win.addEventListener("resize", () => log("win.resize"), { signal: ac.signal });
  win.addEventListener("scroll", () => log(`win.scroll ${Math.round(win.scrollY)}`), { signal: ac.signal });
  log("installed");
  return () => { ac.abort(); box.remove(); };
}
