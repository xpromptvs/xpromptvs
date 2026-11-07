import { describe, it, expect } from "vitest";
import { containedRect, videoContentRect } from "../src/client/pointer-map";

describe("containedRect", () => {
  it("letterboxes a wide picture in a square box", () => {
    // 16:9 into 400x400 -> k = 400/16 = 25 -> 400x225, centred vertically.
    expect(containedRect({ w: 400, h: 400 }, { w: 16, h: 9 }))
      .toEqual({ x: 0, y: 87.5, w: 400, h: 225 });
  });

  it("pillarboxes a tall picture in a square box", () => {
    expect(containedRect({ w: 400, h: 400 }, { w: 9, h: 16 }))
      .toEqual({ x: 87.5, y: 0, w: 225, h: 400 });
  });

  it("fills a box that already matches the aspect, with no bars", () => {
    expect(containedRect({ w: 400, h: 225 }, { w: 16, h: 9 }))
      .toEqual({ x: 0, y: 0, w: 400, h: 225 });
  });

  it("returns the whole box when the intrinsic size is unknown", () => {
    // A <video> reports 0x0 until its first frame. Degrading to the box is the PRE-FIX behaviour,
    // which is right: no picture has been laid out yet, so there is no letterbox to invert.
    expect(containedRect({ w: 400, h: 300 }, { w: 0, h: 0 }))
      .toEqual({ x: 0, y: 0, w: 400, h: 300 });
    expect(containedRect({ w: 400, h: 300 }, { w: 16, h: 0 }))
      .toEqual({ x: 0, y: 0, w: 400, h: 300 });
  });

  it("survives a degenerate box rather than dividing by zero", () => {
    expect(containedRect({ w: 0, h: 0 }, { w: 16, h: 9 }))
      .toEqual({ x: 0, y: 0, w: 0, h: 0 });
  });
});

describe("videoContentRect", () => {
  it("offsets the content rect into client coordinates", () => {
    const body = { left: 10, top: 20, width: 400, height: 400 };
    expect(videoContentRect(body, { w: 16, h: 9 }))
      .toEqual({ left: 10, top: 107.5, width: 400, height: 225 });
  });
});
