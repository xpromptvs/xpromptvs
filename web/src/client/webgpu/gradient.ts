/// **THE EXPERIMENTAL BACKGROUND GRADIENT'S COLOURS** (docs/client-web.md, "The WebGPU renderer"). Two background
/// colours get a gradient — the diff's added-line green and removed-line red — and each has STORED colours for the
/// terminal area's top edge and its bottom edge: a cell of that colour is drawn as the blend between them by where
/// it sits (shaders.ts, in HSL, the hue the short way round), dithered. Every other colour stays flat. What ships
/// is `GRADIENT_DEFAULTS`; the design workbench picks the colours on HSL wheels (src/design/gradient-controls.ts).
/// Pure — no WebGPU — so the workbench page and the tests read it without the renderer.

/// The colours that get a gradient, matched by the cell's COLOUR: the theme's diff line backgrounds — xterm-view.ts
/// `DIFF_SLOTS`' 22 and 52 (Sonokai's bg_green and bg_red), what Claude Code paints added and removed lines with. A
/// theme without them (the light one draws 22 and 52 as the cube's) has no gradient, and a program painting
/// exactly these colours in truecolor gets it too.
export const GRADIENT_SOURCES = { green: "#394634", red: "#55393d" } as const;
export type GradientSource = keyof typeof GRADIENT_SOURCES;
export const GRADIENT_SOURCE_LIST: readonly GradientSource[] = ["green", "red"];

/// A source colour's stored colours, `#rrggbb`: at the area's top edge and at its bottom edge.
export interface GradientStops { top: string; bottom: string }
export interface GradientTuning { green: GradientStops; red: GradientStops; dither: boolean }

/// What ships: the colours picked on the design workbench's wheels (2026-10-04) — each richer than its flat diff
/// colour, the green towards teal at the bottom, the red from a warm brick at the top to a dusky rose.
export const GRADIENT_DEFAULTS: GradientTuning = {
  green: { top: "#235f37", bottom: "#265745" },
  red: { top: "#6c352b", bottom: "#633e46" },
  dither: true,
};

const HEX = /^#[0-9a-f]{6}$/;

/// A tuning from anything — a saved JSON, what a workbench frame is handed: every colour `#rrggbb` (lower case), a
/// missing or malformed one the default's.
export function gradientTuning(raw: unknown): GradientTuning {
  const o = (raw && typeof raw === "object" ? raw : {}) as Partial<Record<keyof GradientTuning, unknown>>;
  const stops = (v: unknown, fallback: GradientStops): GradientStops => {
    const r = (v && typeof v === "object" ? v : {}) as Partial<Record<keyof GradientStops, unknown>>;
    const pick = (c: unknown, d: string) => (typeof c === "string" && HEX.test(c.toLowerCase()) ? c.toLowerCase() : d);
    return { top: pick(r.top, fallback.top), bottom: pick(r.bottom, fallback.bottom) };
  };
  return {
    green: stops(o.green, GRADIENT_DEFAULTS.green),
    red: stops(o.red, GRADIENT_DEFAULTS.red),
    dither: typeof o.dither === "boolean" ? o.dither : GRADIENT_DEFAULTS.dither,
  };
}

// ---- colour arithmetic (the renderer's uniforms, the workbench's wheels) ----------------------------------

/// Hue in degrees [0, 360); saturation and lightness 0…1.
export interface Hsl { h: number; s: number; l: number }

export function hexToHsl(hex: string): Hsl {
  const n = parseInt(hex.slice(1), 16);
  const r = ((n >> 16) & 255) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
  if (d === 0) return { h: 0, s: 0, l };
  const s = Math.min(1, d / (1 - Math.abs(2 * l - 1)));
  const h = mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return { h: h * 60, s, l };
}

export function hslToRgb({ h, s, l }: Hsl): [number, number, number] {
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => {
    const k = (n + h / 30) % 12;
    return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))));
  };
  return [f(0), f(8), f(4)];
}

export function hslToHex(c: Hsl): string {
  return `#${hslToRgb(c).map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}

/// `#rrggbb` as xterm.js packs a colour: 0xRRGGBBAA, opaque.
export function hexToRgba(hex: string): number {
  return ((parseInt(hex.slice(1), 16) << 8) | 0xff) >>> 0;
}

/// The blend at `t` (0 the top edge, 1 the bottom) — the shader's: HSL, the hue the short way round.
export function blendStops(stops: GradientStops, t: number): Hsl {
  const a = hexToHsl(stops.top), b = hexToHsl(stops.bottom);
  let dh = b.h - a.h;
  dh -= 360 * Math.round(dh / 360);
  return { h: ((a.h + dh * t) % 360 + 360) % 360, s: a.s + (b.s - a.s) * t, l: a.l + (b.l - a.l) * t };
}
