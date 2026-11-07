import { describe, expect, it } from "vitest";
import {
  blendStops, GRADIENT_DEFAULTS, GRADIENT_SOURCES, gradientTuning, hexToHsl, hexToRgba, hslToHex,
} from "../src/client/webgpu/gradient";
import { DIFF_SLOTS } from "../src/client/xterm-view";
import { previewGradient, wheelPoint, wheelValue, withHueSat, withLightness } from "./support/hsl-wheel";

// The experimental background gradient's stored colours (docs/client-web.md, "The WebGPU renderer"), and the
// design workbench's HSL wheels that pick them.

describe("the gradient's colours", () => {
  it("takes the theme's diff line colours, matched by colour — DIFF_SLOTS' 22 and 52", () => {
    expect(GRADIENT_SOURCES).toEqual({ green: DIFF_SLOTS[22], red: DIFF_SLOTS[52] });
    expect(hexToRgba(GRADIENT_SOURCES.green), "as xterm.js packs a colour").toBe(0x394634ff);
  });

  it("ships the colours picked on the workbench's wheels, dithered", () => {
    expect(GRADIENT_DEFAULTS).toEqual({
      green: { top: "#235f37", bottom: "#265745" },
      red: { top: "#6c352b", bottom: "#633e46" },
      dither: true,
    });
    expect(gradientTuning(GRADIENT_DEFAULTS), "every one a colour the tuning keeps as it is").toEqual(GRADIENT_DEFAULTS);
  });

  it("anything malformed is the default; colours are kept lower case, field by field", () => {
    for (const raw of [null, undefined, 3, "x", [], { green: "no", red: null, dither: "yes" }]) {
      expect(gradientTuning(raw), JSON.stringify(raw)).toEqual(GRADIENT_DEFAULTS);
    }
    const t = gradientTuning({ green: { top: "#ABCDEF", bottom: "red" }, red: { bottom: "#123456" }, dither: false });
    expect(t.green).toEqual({ top: "#abcdef", bottom: GRADIENT_DEFAULTS.green.bottom });
    expect(t.red).toEqual({ top: GRADIENT_DEFAULTS.red.top, bottom: "#123456" });
    expect(t.dither).toBe(false);
  });

  it("is a copy: changing the result changes no default", () => {
    const t = gradientTuning(GRADIENT_DEFAULTS);
    t.green.top = "#000000";
    expect(GRADIENT_DEFAULTS.green.top).toBe("#235f37");
  });

  it("blends in HSL, the hue the short way round", () => {
    const stops = { top: "#ff0000", bottom: hslToHex({ h: 340, s: 1, l: 0.5 }) };
    expect(hexToHsl(hslToHex(blendStops(stops, 0))).h).toBeCloseTo(0, 0);
    expect(blendStops(stops, 0.5).h, "through 350°, not through 170°").toBeCloseTo(350, 0);
    expect(hslToHex(blendStops(GRADIENT_DEFAULTS.green, 1))).toBe(GRADIENT_DEFAULTS.green.bottom);
  });
});

describe("the workbench's HSL wheel", () => {
  it("angle is hue (0° at the right, counter-clockwise) and distance saturation, both ways", () => {
    expect(wheelValue(1, 0)).toEqual({ h: 0, s: 1 });
    expect(wheelValue(0, 1).h).toBeCloseTo(90);
    expect(wheelValue(-0.5, 0)).toEqual({ h: 180, s: 0.5 });
    expect(wheelValue(0, -3), "outside: the edge").toEqual({ h: 270, s: 1 });
    for (const [h, s] of [[0, 0.3], [120, 1], [250, 0.6]] as const) {
      const p = wheelPoint(h, s), back = wheelValue(p.x, p.y);
      expect(back.h).toBeCloseTo(h);
      expect(back.s).toBeCloseTo(s);
    }
  });

  it("a wheel move keeps the stop's lightness; the slider keeps its hue and saturation", () => {
    const moved = hexToHsl(withHueSat("#40523d", 200, 0.5));
    expect(moved.h).toBeCloseTo(200, -1);
    expect(moved.s).toBeCloseTo(0.5, 1);
    expect(moved.l).toBeCloseTo(hexToHsl("#40523d").l, 2);
    const lit = hexToHsl(withLightness("#40523d", 0.6));
    expect(lit.l).toBeCloseTo(0.6, 2);
    expect(lit.h).toBeCloseTo(hexToHsl("#40523d").h, -1);
  });

  it("the preview runs from the top colour to the bottom one", () => {
    const css = previewGradient(GRADIENT_DEFAULTS.red, 5);
    expect(css.startsWith(`linear-gradient(to bottom, ${GRADIENT_DEFAULTS.red.top} 0.0%`)).toBe(true);
    expect(css.endsWith(`${GRADIENT_DEFAULTS.red.bottom} 100.0%)`)).toBe(true);
  });
});
