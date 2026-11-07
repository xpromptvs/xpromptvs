import { blendStops, hexToHsl, hslToHex, type GradientStops } from "../../src/client/webgpu/gradient";

/**
 * **A GRADIENT STOP ON AN HSL WHEEL** — the pure half of gradient-controls.ts's wheels: angle is hue (0° red at
 * the right, counter-clockwise, as y goes up), distance from the centre saturation; the stop's lightness is its
 * own slider, and the wheel is drawn at it.
 */

/** Where a hue and saturation sit on the unit disc (y up). */
export function wheelPoint(h: number, s: number): { x: number; y: number } {
  const a = (h * Math.PI) / 180;
  return { x: Math.cos(a) * s, y: Math.sin(a) * s };
}

/** The hue and saturation at a point of the unit disc (y up); outside it, its edge. */
export function wheelValue(x: number, y: number): { h: number; s: number } {
  const s = Math.min(1, Math.hypot(x, y));
  const h = s === 0 ? 0 : ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
  return { h, s };
}

/** `hex` with the wheel's hue and saturation, its lightness kept. */
export function withHueSat(hex: string, h: number, s: number): string {
  return hslToHex({ h, s, l: hexToHsl(hex).l });
}

/** `hex` at another lightness, its hue and saturation kept. */
export function withLightness(hex: string, l: number): string {
  const c = hexToHsl(hex);
  return hslToHex({ ...c, l: Math.min(1, Math.max(0, l)) });
}

/** A stop pair's look as CSS — the shader's blend at `n` points, top to bottom (no dither). */
export function previewGradient(stops: GradientStops, n = 12): string {
  const at = Array.from({ length: n }, (_, k) => `${hslToHex(blendStops(stops, k / (n - 1)))} ${((k / (n - 1)) * 100).toFixed(1)}%`);
  return `linear-gradient(to bottom, ${at.join(", ")})`;
}
