import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { installNativeWindowGrip } from "../src/client/native-window-grip";

// The app uses a reported gap only at the width it was measured at (`ChromeGap` in app/Core), so the page
// must report again whenever its WIDTH changes — even when the gap's own numbers do not (jsdom lays out
// nothing, so they are 0 here throughout). In a lockstep zoom the page's width runs ahead of the window.
describe("native window grip reports", () => {
  let frames: Array<FrameRequestCallback> = [];
  const saved: Record<string, unknown> = {};
  const g = globalThis as Record<string, unknown>;
  beforeEach(() => {
    for (const k of ["requestAnimationFrame", "ResizeObserver", "innerWidth", "matchMedia"]) saved[k] = g[k];
    frames = [];
    g.requestAnimationFrame = (cb: FrameRequestCallback) => { frames.push(cb); return frames.length; };
    g.ResizeObserver = class { observe() {} disconnect() {} };
    g.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
    Object.defineProperty(window, "innerWidth", { value: 1280, configurable: true, writable: true });
  });
  afterEach(() => {
    g.requestAnimationFrame = saved.requestAnimationFrame;
    g.ResizeObserver = saved.ResizeObserver;
    g.matchMedia = saved.matchMedia;
    Object.defineProperty(window, "innerWidth", { value: saved.innerWidth, configurable: true, writable: true });
  });
  const frame = () => { const batch = frames; frames = []; batch.forEach(cb => cb(0)); };

  it("disposal cancels queued reports and ignores later page events", () => {
    const sent: number[][]=[];
    const stop=installNativeWindowGrip({setChromeGap:(...gap)=>sent.push(gap)});
    expect(typeof stop).toBe('function');
    if(typeof stop==='function')stop();
    frame();window.dispatchEvent(new Event('resize'));frame();
    expect(sent).toEqual([]);
  });

  it("carries the measured width, and reports again when only the width changes", () => {
    const sent: number[][] = [];
    installNativeWindowGrip({ setChromeGap: (left, right, width) => sent.push([left, right, width]) });
    frame();
    expect(sent).toEqual([[0, 0, 1280]]);
    window.innerWidth = 1512;
    window.dispatchEvent(new Event("resize"));
    frame();
    expect(sent).toEqual([[0, 0, 1280], [0, 0, 1512]]);
    window.dispatchEvent(new Event("resize"));
    frame();
    expect(sent.length, "an unchanged report is not sent again").toBe(2);
  });
});
