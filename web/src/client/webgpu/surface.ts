import { onGpuLost } from "./device";

/// **ONE CANVAS PER TERMINAL AREA** (2026-10-03; docs/client-web.md, "The WebGPU renderer"). Every WebGPU
/// terminal in an area — the deck's `#xterm`: every tab, and every snapshot's fresh instance — draws into THIS
/// canvas, and only the one that has CLAIMED it draws (the shown tab's live instance, `TermDeck.reveal`).
///
/// NOTHING SYNCHRONIZES A DOM CHANGE WITH A WEBGPU FRAME (on an iPhone a canvas showed its new frame a frame
/// after the CSS written with it). A canvas per instance made every tab switch and every snapshot's swap a DOM
/// change — one canvas shown, another removed in the same task — and the new one's first frame was free to
/// come late: the area blank or stale meanwhile. This canvas never moves, never hides and is never replaced; a
/// switch changes what is DRAWN into it — a frame late at worst, never blank. Its drawing buffer GROWS ONLY, to
/// the area's padding box plus headroom (the area clips it), so a window resize, a soft keyboard or a rotation
/// back does not replace it either. With nobody claiming it (no tab shown) it is cleared to transparent and
/// the area's own background shows.
///
/// It sits FIRST in the area, under the instances' DOM, `pointer-events: none`: xterm.js keeps its elements —
/// the mouse, the helper textarea, the composition view, decorations, the scrollbar rail — above it, and a
/// terminal drawing here makes its own background transparent (`.xterm-gpu`, style.css).

/// What a renderer attached to a surface hears.
export interface SurfaceUser {
  /// Its view claimed the canvas: draw everything now.
  claimed(): void;
  /// The area changed size (the canvas may have grown): measure again and, if it owns the canvas, redraw.
  hostResized(): void;
}

/// Device px the drawing buffer grows by at least, so a window dragged wider does not replace it every frame.
const GROW_STEP = 256;

const surfaces = new WeakMap<HTMLElement, GpuSurface>();
const live = new Set<GpuSurface>();
/// The view each area's canvas belongs to — set before any surface exists (a view claims while its device is
/// still being asked for), read by the surface once there is one.
const claims = new WeakMap<HTMLElement, object | null>();

export class GpuSurface {
  readonly canvas: HTMLCanvasElement;
  readonly context: GPUCanvasContext;
  private readonly users = new Map<object, SurfaceUser>();
  private readonly watch: ResizeObserver | null = null;
  private dpr = 0;

  constructor(readonly host: HTMLElement, private readonly device: GPUDevice, format: GPUTextureFormat) {
    const canvas = host.ownerDocument.createElement("canvas");
    canvas.className = "xterm-gpu-surface";
    canvas.style.cssText = "position:absolute;left:0;top:0;pointer-events:none";
    const context = canvas.getContext("webgpu");
    if (!context) throw new Error("no WebGPU canvas context");
    // PREMULTIPLIED, not opaque: unclaimed it is cleared to transparent, and an opaque canvas shows that black.
    context.configure({ device, format, alphaMode: "premultiplied" });
    this.canvas = canvas;
    this.context = context;
    host.prepend(canvas);
    this.grow();
    if (typeof ResizeObserver === "function") {
      this.watch = new ResizeObserver(() => {
        this.grow();
        for (const u of [...this.users.values()]) u.hostResized();
      });
      this.watch.observe(host);
    }
    live.add(this);
  }

  /// The drawing buffer covers the area's padding box: grown (with headroom) when the area outgrows it, never
  /// shrunk; started again only when the device pixel ratio changes. Its CSS box is its buffer at that ratio.
  grow(): void {
    const view = this.host.ownerDocument.defaultView;
    const dpr = view?.devicePixelRatio || 1;
    const needW = Math.ceil(this.host.clientWidth * dpr), needH = Math.ceil(this.host.clientHeight * dpr);
    const fresh = dpr !== this.dpr;
    const haveW = fresh ? 0 : this.canvas.width, haveH = fresh ? 0 : this.canvas.height;
    if (!fresh && needW <= haveW && needH <= haveH) return;
    const step = (n: number) => Math.max(1, Math.ceil(n / GROW_STEP) * GROW_STEP);
    const w = needW > haveW ? step(needW) : haveW, h = needH > haveH ? step(needH) : haveH;
    this.canvas.width = Math.max(1, w);
    this.canvas.height = Math.max(1, h);
    this.canvas.style.width = `${this.canvas.width / dpr}px`;
    this.canvas.style.height = `${this.canvas.height / dpr}px`;
    this.dpr = dpr;
  }

  attach(token: object, user: SurfaceUser): void { this.users.set(token, user); }

  /// A renderer leaves (its terminal disposed, or back on the DOM renderer). Its view's claim goes with it —
  /// a disposed picture is not left on screen — and the canvas with the last renderer.
  detach(token: object): void {
    if (!this.users.delete(token)) return;
    if (this.owns(token)) { claims.set(this.host, null); this.clear(); }
    if (this.users.size === 0) this.dispose();
  }

  owns(token: object): boolean { return claims.get(this.host) === token; }
  user(token: object | null): SurfaceUser | undefined { return token ? this.users.get(token) : undefined; }

  /// Nothing drawn: transparent, the area's background through it.
  clear(): void {
    const encoder = this.device.createCommandEncoder();
    encoder.beginRenderPass({
      colorAttachments: [{ view: this.context.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: "clear", storeOp: "store" }],
    }).end();
    this.device.queue.submit([encoder.finish()]);
  }

  dispose(): void {
    if (!live.delete(this)) return;
    this.watch?.disconnect();
    this.users.clear();
    try { this.context.unconfigure(); } catch { /* a lost device's context */ }
    this.canvas.remove();
    if (surfaces.get(this.host) === this) surfaces.delete(this.host);
  }
}

/// The area's canvas, made on first use.
export function surfaceFor(host: HTMLElement, device: GPUDevice, format: GPUTextureFormat): GpuSurface {
  const hit = surfaces.get(host);
  if (hit) return hit;
  const s = new GpuSurface(host, device, format);
  surfaces.set(host, s);
  return s;
}

/// The view `token` takes the area's canvas (null: nobody — it is cleared). Its renderer draws everything now;
/// a view with no WebGPU renderer (still waiting for the device, or on the DOM renderer) leaves it cleared, and
/// its renderer draws once it starts.
export function claimCanvas(host: HTMLElement, token: object | null): void {
  claims.set(host, token);
  const s = surfaces.get(host);
  if (!s) return;
  const u = s.user(token);
  if (u) u.claimed(); else s.clear();
}

// A lost device takes every canvas on it: the terminals go back to the DOM renderer (renderer.ts).
onGpuLost(() => { for (const s of [...live]) s.dispose(); });
