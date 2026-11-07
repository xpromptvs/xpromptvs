import { describe, expect, it } from "vitest";
import { chooseLayoutMode, terminalFontSize, terminalMayAutofocus, GLASSES_SIZE } from "../src/client/layout-mode";

const desktop = { width: 1440, height: 900, coarsePointer: false, screen: { width: 1440, height: 900 } };
const phone = { width: 390, height: 844, coarsePointer: true, screen: { width: 390, height: 844 } };
const glasses = { width: GLASSES_SIZE, height: GLASSES_SIZE, coarsePointer: false,
  screen: { width: GLASSES_SIZE, height: GLASSES_SIZE } };
/// iOS reports `screen` in PORTRAIT points whatever the orientation; the window is what rotates.
const iPhoneAir = { width: 420, height: 844, coarsePointer: true, screen: { width: 420, height: 912 } };
const iPadAir = { width: 820, height: 1180, coarsePointer: true, screen: { width: 820, height: 1180 } };

describe("chooseLayoutMode", () => {
  it("keeps the existing desktop and phone answers", () => {
    expect(chooseLayoutMode(desktop, null)).toBe("floating");
    expect(chooseLayoutMode(phone, null)).toBe("tabbed");
  });
  it("auto-detects glasses at exactly 600x600", () => {
    expect(chooseLayoutMode(glasses, null)).toBe("glasses");
  });
  it("does NOT claim a 600-wide window that is not 600 tall", () => {
    expect(chooseLayoutMode({ width: 600, height: 900, coarsePointer: true, screen: { width: 600, height: 900 } }, null))
      .toBe("tabbed");
  });
  it("a PHONE in landscape stays tabbed — its screen, not its window, says it is a phone", () => {
    expect(chooseLayoutMode(iPhoneAir, null)).toBe("tabbed");
    expect(chooseLayoutMode({ ...iPhoneAir, width: 912, height: 420 }, null)).toBe("tabbed");
    // Android turns `screen` with the device, so the short side is taken either way round.
    expect(chooseLayoutMode({ width: 915, height: 412, coarsePointer: true, screen: { width: 915, height: 412 } }, null))
      .toBe("tabbed");
  });
  it("a TABLET keeps both answers: tabbed in portrait, floating in landscape", () => {
    expect(chooseLayoutMode(iPadAir, null)).toBe("tabbed");
    expect(chooseLayoutMode({ ...iPadAir, width: 1180, height: 820 }, null)).toBe("floating");
    // The smallest iPad, 744pt across, is not a phone.
    expect(chooseLayoutMode({ width: 1133, height: 744, coarsePointer: true, screen: { width: 744, height: 1133 } }, null))
      .toBe("floating");
  });
  it("a landscape tablet with its keyboard up stays floating — no rule reads a height the keyboard shrinks", () => {
    // iOS reported `innerHeight` 192 of 420 for a frame while an iPhone's keyboard opened (measured
    // 2026-09-28); an iPad doing the same is inferred. A rule on the WINDOW's short side would then flip
    // it to tabbed whenever its keyboard came up.
    expect(chooseLayoutMode({ ...iPadAir, width: 1180, height: 400 }, null)).toBe("floating");
  });
  it("a phone-sized screen with a FINE pointer is not a phone", () => {
    expect(chooseLayoutMode({ ...iPhoneAir, width: 912, height: 420, coarsePointer: false }, null)).toBe("floating");
  });
  it("?layout=glasses wins anywhere", () => {
    expect(chooseLayoutMode(desktop, "glasses")).toBe("glasses");
  });
  it("an explicit override still beats auto-detection", () => {
    expect(chooseLayoutMode(glasses, "floating")).toBe("floating");
  });
});

describe("terminalFontSize", () => {
  it("is 16px on glasses — the tabbed 12px is below the 14dp floor", () => {
    expect(terminalFontSize("glasses")).toBe(16);
  });
  it("leaves the other two modes alone", () => {
    expect(terminalFontSize("floating")).toBe(15);
    expect(terminalFontSize("tabbed")).toBe(12);
  });
});

describe("terminalMayAutofocus", () => {
  it("is false on glasses — the D-pad owns focus there", () => {
    // xterm grabbing DOM focus on a focus-driven device puts the cursor on an element the nav order
    // does not own, with no visible focus ring and no pointer to take it back.
    expect(terminalMayAutofocus("glasses")).toBe(false);
  });
  it("is true everywhere else, so desktop and phone keep autofocus", () => {
    expect(terminalMayAutofocus("floating")).toBe(true);
    expect(terminalMayAutofocus("tabbed")).toBe(true);
  });
});
