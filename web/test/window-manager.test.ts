import { describe, it, expect, afterEach, beforeEach, vi } from "vitest";
import { windowViews, tileOffset, sourceIsLive, windowElementSize, resizeRequest, cursorCssValue, WIN_CHROME_PX, WIN_BORDER_PX, controlOffset, stageBand, fitScale, drawnFitScale, centerIn, nudgeInto, WindowManager, type WindowView } from "../src/client/window-manager";
import { tabBarHeight, statusBarHeight } from "../src/client/floating-window";
import type { Source } from "../src/client/source-picker";
import type { ClientPrefs } from "../src/shared/client-prefs";
import { HOLD_MS, TOUCH_SLOP_PX } from "../src/client/press-hold";

const sources: Source[] = [
  { id: "sim:A", kind: "sim", name: "iPhone A", inputCapable: true, running: true },
  { id: "win:B", kind: "win", name: "Safari", inputCapable: false, running: true },
];

// THE DEVICE SET IS READ FROM STORAGE when a manager is built without one, so every test gets a fresh
// one: a test that changed it must not hand its choice to the next. A Storage the test owns — Node's own
// `localStorage` global shadows jsdom's here, and is not usable (as in `smooth-scroll-pref.test.ts`).
function memStorage(): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k),
    clear: () => m.clear(),
    key: (i) => [...m.keys()][i] ?? null,
    get length() { return m.size; },
  } as Storage;
}
beforeEach(() => {
  vi.stubGlobal("localStorage", memStorage());
  // jsdom has no dialog/top layer implementation; real clipping and interaction are browser-tested.
  HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  HTMLDialogElement.prototype.show = function () { this.open = true; };
  HTMLDialogElement.prototype.close = function () { this.open = false; };
});
afterEach(() => { vi.unstubAllGlobals(); });

describe("windowViews", () => {
  const sub = (source: string, fps: number, bitrateBps: number) => ({ source, scale: 1, fps, bitrateBps });

  it("one per OPEN window of the session, with the host's live echo, focused flag", () => {
    const vs = { windows: [{ source: "sim:A", minimized: false }, { source: "win:B", minimized: false }],
                 subs: [sub("sim:A", 60, 2_000_000), sub("win:B", 30, 1_000_000)], focused: "win:B" };
    expect(windowViews(vs, sources)).toEqual([
      { source: "sim:A", name: "iPhone A", focused: false, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: undefined, activeCodec: undefined, audio: undefined, audioOwner: undefined },
      { source: "win:B", name: "Safari", focused: true, fps: 30, scale: 1, bitrateBps: 1_000_000, codec: undefined, activeCodec: undefined, audio: undefined, audioOwner: undefined },
    ]);
  });

  it("a minimized window has no window — only its tab", () => {
    const vs = { windows: [{ source: "win:B", minimized: true }], subs: [], focused: null };
    expect(windowViews(vs, sources)).toEqual([]);
  });

  // A RESTORED WINDOW IS IN THE STATE BEFORE ITS STREAM: the host re-establishes it only once this
  // driver's hello is in. It gets its window at once, showing the host's defaults until the echo lands.
  it("an open window the host is not streaming yet still gets a window, at the host's defaults", () => {
    const vs = { windows: [{ source: "sim:Z", minimized: false }], subs: [], focused: null };
    expect(windowViews(vs, sources)).toEqual([
      { source: "sim:Z", name: "sim:Z", focused: false, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: undefined, activeCodec: undefined, audio: undefined, audioOwner: undefined },
    ]);
  });
});

describe("windowViews — a window the driver named", () => {
  it("is titled by its name, as its tab is", () => {
    const vs = { windows: [{ source: "win:B", minimized: false, name: "logs" }], subs: [], focused: null };
    expect(windowViews(vs, sources)[0]?.name).toBe("logs");
  });
});

describe("tileOffset", () => {
  // THE invariant, and the reason this is a cascade rather than a row-tiler: consecutive windows must
  // never share a y, and must be separated by MORE than the titlebar height. Windows render at their
  // actual host size (400-1700px), so any same-row placement overlaps the neighbour by hundreds of pixels
  // — and since the controls sit at the RIGHT end of the titlebar, they are exactly what gets buried.
  // Measured before this changed: with 4 windows, `elementFromPoint` over one window's ✕ returned a
  // DIFFERENT window's .win-title, and the click did nothing.
  it("separates consecutive windows vertically by more than the titlebar height", () => {
    const w = 1400;
    for (let i = 0; i < 7; i++) {
      const a = tileOffset(i, w), b = tileOffset(i + 1, w);
      expect(b.y - a.y).toBeGreaterThan(WIN_CHROME_PX + 2 * 1);
    }
  });

  it("offsets horizontally too, so stacked windows are individually visible", () => {
    const w = 1400;
    expect(tileOffset(1, w).x).toBeGreaterThan(tileOffset(0, w).x);
  });

  it("is bounded (a long run of opens never marches off-screen)", () => {
    const w = 1400;
    const pts = Array.from({ length: 50 }, (_, i) => tileOffset(i, w));
    expect(Math.max(...pts.map((p) => p.y))).toBeLessThanOrEqual(500);
    expect(Math.max(...pts.map((p) => p.x))).toBeLessThanOrEqual(w - 100);
  });
});

describe("sourceIsLive", () => {
  it("absence means live (the load-bearing convention)", () => {
    expect(sourceIsLive("win:1", new Map())).toBe(true);
    expect(sourceIsLive("sim:A", new Map([["win:1", false]]))).toBe(true);   // sims never appear → live
  });
  it("explicit false means not live; explicit true means live", () => {
    expect(sourceIsLive("win:1", new Map([["win:1", false]]))).toBe(false);
    expect(sourceIsLive("win:1", new Map([["win:1", true]]))).toBe(true);
  });
});

describe("windowElementSize", () => {
  it("adds the titlebar AND both borders, so the BODY is exactly the source size", () => {
    // border-box: a 1px border per side eats into the content box, so the element must be 2px wider and
    // (40 + 2)px taller than the body for the body to measure exactly 892x655.
    expect(windowElementSize(892, 655)).toEqual({ w: 894, h: 697 });
  });
  it("is parameterizable for other chrome/border values", () => {
    expect(windowElementSize(400, 300, 0, 0)).toEqual({ w: 400, h: 300 });
  });
});

describe("resizeRequest", () => {
  it("converts an element size back to the BODY size to request", () => {
    // inverse of windowElementSize(892, 655) = {w: 894, h: 697}
    expect(resizeRequest(894, 697)).toEqual({ w: 892, h: 655 });
  });
  it("never requests a non-positive body size", () => {
    expect(resizeRequest(200, 10)).toBeNull();
    expect(resizeRequest(1, 400)).toBeNull();
  });

  // A FITTED window's body is drawn at `scale`, so the dragged pixels must be divided back out. Without
  // this the request is off by 1/scale: measured, a window fitted at 0.559x and dragged 60px narrower
  // (8% of its on-screen width) asked the host for 721pt against a real 1400pt window — a 48% collapse
  // from an 8% drag. A drag must move the real window by what it LOOKS like it moves it by.
  it("divides a fitted window's dragged pixels back out to host points", () => {
    // The fitted element for a 1400x950 host at 0.559x: body 782.6x531.05, element 784.6x567.05.
    const k = 0.559;
    const el = windowElementSize(1400 * k, 950 * k);
    expect(resizeRequest(el.w, el.h, WIN_CHROME_PX, WIN_BORDER_PX, k)).toEqual({ w: 1400, h: 950 });
  });

  it("maps a proportional drag to a proportional host change, not a collapse", () => {
    const k = 0.559;
    const el = windowElementSize(1400 * k, 950 * k);
    const dragged = resizeRequest(el.w - 60, el.h, WIN_CHROME_PX, WIN_BORDER_PX, k)!;
    expect(dragged.w).toBe(1400 - Math.round(60 / k));   // 1293, not 721
    expect(dragged.w).toBeGreaterThan(1200);
  });

  it("is unchanged at scale 1 (the default), so an unfitted resize still maps 1:1", () => {
    expect(resizeRequest(894, 697, WIN_CHROME_PX, WIN_BORDER_PX, 1)).toEqual({ w: 892, h: 655 });
    expect(resizeRequest(894, 697)).toEqual({ w: 892, h: 655 });
  });

  it("treats a degenerate scale as 1 rather than dividing by zero", () => {
    expect(resizeRequest(894, 697, WIN_CHROME_PX, WIN_BORDER_PX, 0)).toEqual({ w: 892, h: 655 });
  });
});

describe("cursorCssValue", () => {
  it("builds a CSS cursor with the hotspot and an arrow fallback", () => {
    expect(cursorCssValue("data:image/png;base64,QUJD", 4, 9))
      .toBe('url("data:image/png;base64,QUJD") 4 9, auto');
  });
  it("falls back to auto with no image", () => {
    expect(cursorCssValue(null, 0, 0)).toBe("auto");
  });
  it("rounds fractional hotspots (CSS wants integers)", () => {
    expect(cursorCssValue("data:x", 4.6, 9.2)).toBe('url("data:x") 5 9, auto');
  });
});

describe("window chrome height", () => {
  it("is 40px, matching the redesigned titlebar", () => {
    expect(WIN_CHROME_PX).toBe(40);
  });

  it("round-trips windowElementSize -> resizeRequest through the new chrome height", () => {
    const el = windowElementSize(892, 655);
    expect(el).toEqual({ w: 894, h: 697 });          // 892 + 2 border, 655 + 40 chrome + 2 border
    expect(resizeRequest(el.w, el.h)).toEqual({ w: 892, h: 655 });
  });
});

describe("controlOffset", () => {
  // Windows render at their ACTUAL host size and are deliberately allowed to overflow the viewport
  // ("actual size, overflow ALLOWED"). The titlebar controls sit at the right end, so an oversized window
  // pushes them outside the viewport where they cannot be hit-tested at all — measured live: a 1730px
  // window put its ✕ at x=1720 in a 1280px viewport, and elementFromPoint returned null.
  it("is zero while the window's right edge is inside the viewport", () => {
    expect(controlOffset(800, 1280)).toBe(0);
    expect(controlOffset(1280, 1280)).toBe(0);
  });

  it("equals the overhang once the window extends past the right edge", () => {
    expect(controlOffset(1324, 1280)).toBe(44);
    expect(controlOffset(1754, 1280)).toBe(474);
  });

  it("never goes negative, so a fully-visible window is never shifted", () => {
    expect(controlOffset(100, 1280)).toBe(0);
  });
});

describe("stageBand", () => {
  it("is the viewport minus both bars, inset by the margin", () => {
    // 1280 - 2*16 wide; y starts below the tab bar; height loses both bars and both margins.
    expect(stageBand(1280, 800, 64, 38, 16)).toEqual({ x: 16, y: 80, w: 1248, h: 666 });
  });
  it("never returns a negative size on a viewport shorter than the two bars", () => {
    const b = stageBand(20, 40, 64, 38, 16);
    expect(b.w).toBeGreaterThanOrEqual(0);
    expect(b.h).toBeGreaterThanOrEqual(0);
  });
});

describe("fitScale", () => {
  // SHRINK ONLY. Fit is a rescue for a window too big to see, not a maximize: the stream is encoded at the
  // host's size x the resolution pref, so upscaling would only produce a softer picture.
  it("is exactly 1 when the window already fits — fit never upscales", () => {
    expect(fitScale(400, 300, 1248, 666)).toBe(1);
  });
  it("shrinks on the constraining axis (width), borders subtracted first", () => {
    expect(fitScale(2000, 300, 1248, 666)).toBeCloseTo(1246 / 2000, 10);
  });
  it("shrinks on the constraining axis (height), chrome AND borders subtracted first", () => {
    // The 40px titlebar and the 1px borders do NOT scale, so they come off the available space before the
    // ratio is taken — never multiplied by it.
    expect(fitScale(400, 1200, 1248, 666)).toBeCloseTo(624 / 1200, 10);
  });
  it("takes the smaller of the two axes", () => {
    expect(fitScale(2000, 1200, 1248, 666)).toBeCloseTo(624 / 1200, 10);
  });
  it("is 1 for a degenerate body rather than dividing by zero", () => {
    expect(fitScale(0, 0, 1248, 666)).toBe(1);
  });
  it("floors at 0.1 so a viewport too short for the chrome cannot produce a 0-sized window", () => {
    expect(fitScale(400, 300, 1248, 30)).toBe(0.1);
  });
});

describe("fitScale + windowElementSize round-trip", () => {
  // The invariant the whole feature rests on: a fitted window fits inside the band, and the BODY (not the
  // element) keeps the host window's aspect ratio.
  it("puts an oversized window fully inside the band with the body aspect preserved", () => {
    const band = stageBand(1280, 800, 64, 38);
    const hostW = 1730, hostH = 1080;
    const k = fitScale(hostW, hostH, band.w, band.h);
    const el = windowElementSize(hostW * k, hostH * k);
    expect(k).toBeLessThan(1);
    expect(el.w).toBeLessThanOrEqual(band.w + 1e-9);
    expect(el.h).toBeLessThanOrEqual(band.h + 1e-9);
    expect((hostW * k) / (hostH * k)).toBeCloseTo(hostW / hostH, 10);
  });
});

describe("centerIn", () => {
  it("centres the box in the band", () => {
    expect(centerIn({ w: 400, h: 300 }, { x: 16, y: 80, w: 1248, h: 666 }))
      .toEqual({ x: 440, y: 263 });
  });
});

describe("nudgeInto", () => {
  // The placement rule for every recompute AFTER the toggle: keep the user's own placement, move only if an
  // edge would leave the band. A window dragged aside to see one behind it must stay where it was put.
  const band = { x: 16, y: 80, w: 1248, h: 666 };
  it("leaves a window that is already inside exactly where it is", () => {
    expect(nudgeInto({ x: 300, y: 200, w: 400, h: 300 }, band)).toEqual({ x: 300, y: 200 });
  });
  it("pulls an overhanging window back in WITHOUT resizing it", () => {
    expect(nudgeInto({ x: 1200, y: 700, w: 400, h: 300 }, band)).toEqual({ x: 864, y: 446 });
  });
  it("pins a box bigger than the band to the band's origin", () => {
    expect(nudgeInto({ x: 500, y: 500, w: 2000, h: 1000 }, band)).toEqual({ x: 16, y: 80 });
  });
});

describe("WindowManager fit mode", () => {
  const HOST_W = 1730, HOST_H = 1080;   // a window larger than the jsdom viewport (1024x768)
  const view = (source: string): WindowView =>
    ({ source, name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 });

  let container!: HTMLElement;
  let wm!: WindowManager;

  const mk = (prefs?: ClientPrefs) => {
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {}, onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0,
      pc: () => undefined,
      prefs,
    });
    wm.sync([view("win:1")], new Map());
    // Auto-fit decides ONCE, on the first size we learn. Start with a size that FITS so the decision
    // latches as "no", then grow — which is exactly the "not re-evaluated later" rule, and leaves every
    // test below starting from an UNFITTED oversized window as they were written to.
    wm.setSourceSize("win:1", 320, 240);
    wm.setSourceSize("win:1", HOST_W, HOST_H);
    return container.querySelector(".source-window") as HTMLElement;
  };
  const band = () => stageBand(window.innerWidth, window.innerHeight, tabBarHeight(), statusBarHeight());
  const rect = (el: HTMLElement) => ({
    x: parseFloat(el.style.left), y: parseFloat(el.style.top),
    w: parseFloat(el.style.width), h: parseFloat(el.style.height),
  });

  afterEach(() => {
    wm.clear();
    container.remove();
    delete document.documentElement.dataset.layout;
  });

  // A real grip drag needs pointer capture, which jsdom cannot produce, so these set the pin directly —
  // exactly what `onResizeEnd` does — and then let the host's confirmed size flow through `applySize`.
  const pinAs = (k: number) => (wm as unknown as { fitPin: Map<string, number> }).fitPin.set("win:1", k);

  // The re-pin after a fit's geometry transition is a 260 ms timer. `clear()` left it running, so it
  // fired on a removed window — and, in a loaded suite run, after the test environment was gone
  // ("document is not defined", an unhandled error that failed the run with every test green).
  it("clear() cancels a pending post-transition re-pin", () => {
    vi.useFakeTimers();
    try {
      mk();
      wm.toggleFit("win:1");
      const spy = vi.spyOn(wm as unknown as { pinControls: (el: HTMLElement) => void }, "pinControls");
      wm.clear();
      vi.advanceTimersByTime(1000);
      expect(spy).not.toHaveBeenCalled();
    } finally { vi.useRealTimers(); }
  });

  it("keeps a grip-pinned zoom instead of re-fitting a smaller window back out to the band", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const b = band();
    const k = fitScale(HOST_W, HOST_H, b.w, b.h);
    const before = rect(el).w;
    pinAs(k);
    const half = { w: Math.round(HOST_W / 2), h: Math.round(HOST_H / 2) };
    wm.setSourceSize("win:1", half.w, half.h);          // the host confirms the smaller window
    expect(rect(el).w).toBeCloseTo(windowElementSize(half.w * k, half.h * k).w, 0);
    // Without the pin the half-size window FITS the band, so applySize redrew it at 1:1 — bigger than the
    // drag asked for, and visually identical to never having dragged at all.
    expect(rect(el).w).toBeLessThan(before * 0.6);
  });

  it("lets the band override a pin, so a window that GROWS on the host is still shown whole", () => {
    const el = mk();
    wm.toggleFit("win:1");
    pinAs(0.9);                                          // a barely-zoomed pin...
    wm.setSourceSize("win:1", HOST_W * 2, HOST_H * 2);    // ...against a window twice as big
    const b = band();
    expect(rect(el).w).toBeLessThanOrEqual(b.w + 0.5);
  });

  it("toggling Fit discards a pinned zoom — it means \"show me this whole window\" again", () => {
    const el = mk();
    wm.toggleFit("win:1");
    pinAs(0.2);
    wm.toggleFit("win:1");                               // off
    wm.toggleFit("win:1");                               // and on again
    const b = band();
    expect(rect(el).w).toBeCloseTo(windowElementSize(HOST_W, HOST_H, 0, 0).w * fitScale(HOST_W, HOST_H, b.w, b.h) + 2, 0);
  });

  it("renders at the host's actual size until fit is switched on", () => {
    const el = mk();
    expect(rect(el).w).toBe(windowElementSize(HOST_W, HOST_H).w);
  });

  it("toggling fit shrinks the window into the band and preserves the BODY aspect", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const r = rect(el), b = band();
    expect(r.w).toBeLessThan(windowElementSize(HOST_W, HOST_H).w);
    expect(r.x).toBeGreaterThanOrEqual(b.x);
    expect(r.y).toBeGreaterThanOrEqual(b.y);
    expect(r.x + r.w).toBeLessThanOrEqual(b.x + b.w + 1e-9);
    expect(r.y + r.h).toBeLessThanOrEqual(b.y + b.h + 1e-9);
    const bodyW = r.w - 2 * WIN_BORDER_PX, bodyH = r.h - WIN_CHROME_PX - 2 * WIN_BORDER_PX;
    expect(bodyW / bodyH).toBeCloseTo(HOST_W / HOST_H, 6);
  });

  it("centres the window on toggle", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const r = rect(el), b = band();
    expect(r.x + r.w / 2).toBeCloseTo(b.x + b.w / 2, 6);
    expect(r.y + r.h / 2).toBeCloseTo(b.y + b.h / 2, 6);
  });

  it("toggling off restores the host's actual size in place", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const centred = rect(el);
    wm.toggleFit("win:1");
    const r = rect(el);
    expect(r.w).toBe(windowElementSize(HOST_W, HOST_H).w);
    expect(r.h).toBe(windowElementSize(HOST_W, HOST_H).h);
    expect(r.x).toBe(centred.x);   // position is kept, never restored to a remembered pre-fit spot
    expect(r.y).toBe(centred.y);
  });

  it("never upscales a window that already fits, but ARMS and engages when it later grows", () => {
    const el = mk();
    wm.setSourceSize("win:1", 320, 240);
    wm.toggleFit("win:1");
    expect(rect(el).w).toBe(windowElementSize(320, 240).w);   // no upscale
    wm.setSourceSize("win:1", 3000, 2000);                    // the host window grows
    expect(rect(el).w).toBeLessThanOrEqual(band().w + 1e-9);  // the armed mode engages
  });

  it("rescales in place — NOT re-centred — when the host window resizes", () => {
    // A TALL window, so height is the constraining axis. Note what that means: the constraining axis
    // fills the band exactly by definition, so it can only ever sit at the band's origin — it is the
    // FREE axis that carries the user's placement. Asserting both is the honest version of "in place".
    const el = mk();
    wm.toggleFit("win:1");
    el.style.left = "40px"; el.style.top = "120px";     // the user drags it aside
    wm.setSourceSize("win:1", 1200, 2400);             // the host window grows, taller than it is wide
    const r = rect(el), b = band();
    // The "keep" placement nudges against the VIEWPORT, not the band — windows paint above both bars, so
    // a window parked over one is legitimately placed and must not be yanked back on a re-fit.
    expect(r.x).toBe(40);                               // free axis: placement survives, no re-centring
    expect(r.y).toBe(window.innerHeight - r.h);         // constrained axis: pinned as low as it still fits
    expect(r.w).toBeLessThan(b.w);                      // and it really was re-fitted (sized off the band)
    expect(r.h).toBeLessThanOrEqual(b.h + 1e-9);
  });

  it("nudges a fitted window back inside the VIEWPORT when it would overhang", () => {
    const el = mk();
    wm.toggleFit("win:1");
    el.style.left = "9000px";                           // parked far off the right edge
    wm.setSourceSize("win:1", HOST_W, HOST_H);
    const r = rect(el);
    // Bounded by the viewport rather than the stage band: a fitted window is still guaranteed wholly
    // visible (windows paint above the bars, so avoiding them is no longer what "visible" means).
    expect(r.x + r.w).toBeLessThanOrEqual(window.innerWidth + 1e-9);
    expect(r.x).toBeGreaterThanOrEqual(0);
  });

  it("exposes the mode on the button as aria-pressed", () => {
    const el = mk();
    const btn = el.querySelector(".win-fit") as HTMLButtonElement;
    expect(btn.getAttribute("aria-pressed")).toBe("false");
    btn.click();
    expect(btn.getAttribute("aria-pressed")).toBe("true");
    expect(rect(el).w).toBeLessThan(windowElementSize(HOST_W, HOST_H).w);
    btn.click();
    expect(btn.getAttribute("aria-pressed")).toBe("false");
  });

  it("the video's aspect callback does not stomp a fitted window's geometry", () => {
    // setRatio writes h = w/ratio + chrome from el.style.width, bypassing the fit path entirely and
    // re-clamping against the drag band. A fitted window must never go through it.
    const el = mk();
    wm.toggleFit("win:1");
    const before = rect(el);
    (el.querySelector("video") as HTMLVideoElement).dispatchEvent(new Event("resize"));
    expect(rect(el)).toEqual(before);
  });

  it("leaves an UNFITTED window's aspect callback alone", () => {
    const el = mk();
    (el.querySelector("video") as HTMLVideoElement).dispatchEvent(new Event("resize"));
    expect(parseFloat(el.style.height)).toBeGreaterThan(0);   // setRatio still owns it, exactly as before
  });

  it("a re-created window for a still-fitted source comes back fitted and centred", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const fitted = rect(el);
    wm.sync([], new Map());                       // unsubscribe: the window element is destroyed
    wm.sync([view("win:1")], new Map());          // resubscribe: a fresh element
    const el2 = container.querySelector(".source-window") as HTMLElement;
    expect(el2).not.toBe(el);
    expect((el2.querySelector(".win-fit") as HTMLButtonElement).getAttribute("aria-pressed")).toBe("true");
    expect(rect(el2)).toEqual(fitted);
  });

  it("re-fits every fitted window when the viewport itself changes size", () => {
    const el = mk();
    wm.toggleFit("win:1");
    const before = rect(el).w;
    Object.defineProperty(window, "innerWidth", { value: 400, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: 300, configurable: true });
    window.dispatchEvent(new Event("resize"));
    expect(rect(el).w).toBeLessThan(before);
    expect(rect(el).w).toBeLessThanOrEqual(band().w + 1e-9);
    Object.defineProperty(window, "innerWidth", { value: 1024, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: 768, configurable: true });
  });

  it("leaves an UNFITTED window's size alone on a viewport resize", () => {
    const el = mk();
    const before = rect(el);
    window.dispatchEvent(new Event("resize"));
    expect(rect(el).w).toBe(before.w);
    expect(rect(el).h).toBe(before.h);
  });

  it("is inert in the tabbed (mobile) layout, where CSS owns the frame", () => {
    const el = mk();
    const before = rect(el);
    document.documentElement.dataset.layout = "tabbed";
    wm.toggleFit("win:1");
    expect(rect(el)).toEqual(before);
  });

  // Auto-fit on add: a window too big for the band opens fitted, without being clicked. The size can
  // arrive either side of the window existing, so both orders are exercised.
  const mkAuto = () => {
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {}, onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel, nowMs: () => 0, pc: () => undefined,
    });
    return {
      size: (w: number, h: number) => wm.setSourceSize("win:1", w, h),
      add: () => wm.sync([view("win:1")], new Map()),
    };
  };
  const el1 = () => container.querySelector(".source-window") as HTMLElement;
  const pressed = () => (el1().querySelector(".win-fit") as HTMLButtonElement).getAttribute("aria-pressed");

  it("opens an oversized window already fitted (size known BEFORE the window exists)", () => {
    const t = mkAuto();
    t.size(3000, 2000); t.add();
    expect(pressed()).toBe("true");
    expect(rect(el1()).w).toBeLessThanOrEqual(band().w + 1e-9);
  });

  it("opens an oversized window already fitted (size arrives AFTER the window exists)", () => {
    const t = mkAuto();
    t.add(); t.size(3000, 2000);
    expect(pressed()).toBe("true");
    expect(rect(el1()).w).toBeLessThanOrEqual(band().w + 1e-9);
  });

  it("keeps the cascade spot rather than centring — so several oversized windows stay reachable", () => {
    const t = mkAuto();
    t.size(3000, 300); t.add();          // wide but short: the fitted box is far shorter than the band
    const r = rect(el1()), b = band();
    expect(r.y).toBeLessThan(b.y + (b.h - r.h) / 2);   // NOT vertically centred
  });

  it("leaves a window that already fits unfitted", () => {
    const t = mkAuto();
    t.size(320, 240); t.add();
    expect(pressed()).toBe("false");
    expect(rect(el1()).w).toBe(windowElementSize(320, 240).w);
  });

  it("decides ONCE: a later host resize never overrides the user turning fit off", () => {
    const t = mkAuto();
    t.size(3000, 2000); t.add();
    wm.toggleFit("win:1");                 // user turns it off
    t.size(3200, 2100);                    // host window resizes; the 300ms poll pushes it
    expect(pressed()).toBe("false");
    expect(rect(el1()).w).toBe(windowElementSize(3200, 2100).w);
  });

  it("the decision survives minimize -> restore (which destroys and recreates the element)", () => {
    const t = mkAuto();
    t.size(3000, 2000); t.add();
    wm.toggleFit("win:1");                 // user turns it off
    wm.sync([], new Map());                // minimize: unsubscribe
    wm.sync([view("win:1")], new Map());   // restore: a fresh element
    expect(pressed()).toBe("false");
  });
  // A request is not a decision: the browser's answer settles the codec, so the select must keep showing
  // what was ASKED for. Reflecting activeCodec would silently drop the window out of the pin — the same
  // failure the Auto-resolution rule exists to prevent.
  it("shows the negotiated codec even when a stored pin was refused", () => {
    mk({ scale: "auto", codec: "av1" });
    wm.sync([{ ...view("win:1"), codec: "av1", activeCodec: "h265" }], new Map());
    expect(container.querySelector(".win-codec")?.textContent).toBe("H.265");
  });

  it("shows the actual codec for Auto", () => {
    mk({ scale: "auto", codec: "auto" });
    wm.sync([{ ...view("win:1"), activeCodec: "av1" }], new Map());
    expect(container.querySelector(".win-codec")?.textContent).toBe("AV1");
  });

  // EVERY CODEC THE HOST NEGOTIATES, in its preference order. The list was cut to AV1-only on
  // 2026-08-18, correctly at the time: the engine registered AV1 alone, so an H.265 or H.264 entry was
  // a pin nothing could satisfy and the select sat permanently amber. The wire increment registered all
  // three again, and this restores the surface to match. Asserted on the BUILT DOM, not only on
  // CODEC_STEPS, because this is what the user actually gets.
  it("shows unknown codec as information until negotiation", () => {
    mk();
    expect(container.querySelector("select.win-codec")).toBeNull();
    expect(container.querySelector(".win-codec")?.textContent).toBe("—");
  });

  // A REFUSED PIN MUST BE VISIBLE. sync() keeps showing the REQUEST — writing the negotiated codec back
  // would silently drop the window out of the pin — so without this marking an unmet pin is
  // indistinguishable from an honoured one. That is exactly what shipped between the wire increment and
  // now: an iPad with no AV1 decoder answers H.265 for an AV1 pin, and the select went on saying AV1.
  it("marks a pin the connection did not settle on, and clears it when it agrees", () => {
    mk({ scale: "auto", codec: "av1" });
    const sel = container.querySelector(".win-codec") as HTMLSelectElement;

    wm.sync([{ ...view("win:1"), codec: "av1", activeCodec: "h265" }], new Map());
    expect(sel.dataset.unmet).toBe("");
    expect(sel.textContent).toBe("H.265");

    wm.sync([{ ...view("win:1"), codec: "av1", activeCodec: "av1" }], new Map());
    expect(sel.dataset.unmet).toBeUndefined();
  });
});

describe("WindowManager device preferences", () => {
  const view = (source: string, scale = 1): WindowView =>
    ({ source, name: "Safari", focused: true, fps: 60, scale, bitrateBps: 2_000_000 });

  let container!: HTMLElement;
  let wm!: WindowManager;
  let derived!: Array<{ source: string; patch: Record<string, unknown> }>;
  let device!: ClientPrefs[];

  const simulatorActions: [string, string][] = [];
  const mk = (prefs: ClientPrefs = { scale: "auto", codec: "auto" }) => {
    derived = []; device = []; simulatorActions.length = 0;
    localStorage.clear();
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {},
      onPrefs: (source, patch) => derived.push({ source, patch: patch as Record<string, unknown> }),
      onDevicePrefs: (p) => device.push(p),
      onSimAction: (source, action) => simulatorActions.push([source, action]),
      prefs,
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([view("win:1"), view("win:2")], new Map());
  };
  const sel = (cls: string, i = 0) => container.querySelectorAll<HTMLSelectElement>(`.${cls}`)[i]!;

  afterEach(() => { wm.clear(); container.remove(); });

  it("toggles reference recovery for every window and saves both on and off", () => {
    mk();
    const buttons = () => [...container.querySelectorAll<HTMLButtonElement>(".win-referenceRecovery")];
    expect(buttons()).toHaveLength(2);
    expect(buttons().map(b => b.getAttribute("aria-checked"))).toEqual(["false", "false"]);
    buttons()[0]!.click();
    expect(buttons().map(b => b.getAttribute("aria-checked"))).toEqual(["true", "true"]);
    expect(JSON.parse(localStorage.getItem("rdev.clientPrefs")!).av1ReferenceRecovery).toBe(true);
    expect(device.at(-1)).toMatchObject({ av1ReferenceRecovery: true });
    wm.sync([view("win:1"), view("win:2"), view("win:3")], new Map());
    expect(buttons().map(b => b.getAttribute("aria-checked"))).toEqual(["true", "true", "true"]);
    buttons()[1]!.click();
    expect(buttons().map(b => b.getAttribute("aria-checked"))).toEqual(["false", "false", "false"]);
    expect(JSON.parse(localStorage.getItem("rdev.clientPrefs")!).av1ReferenceRecovery).toBe(false);
    expect(device.at(-1)).toMatchObject({ av1ReferenceRecovery: false });
  });

  it("removes frame rate and resolution controls", () => {
    mk();
    expect(container.querySelector(".win-fps, .win-scale")).toBeNull();
  });

  it("a change in ONE window is the device's: every window shows it, it is saved, the caller is told", () => {
    mk();
    wm.changeDevicePrefs({ fps: 30 });
    expect(device).toEqual([{ scale: "auto", codec: "auto", fps: 30 }]);
    expect(JSON.parse(localStorage.getItem("rdev.clientPrefs")!).fps).toBe(30);
    expect(derived).toEqual([]);                               // nothing per window for a device setting
  });

  it("a pinned resolution is the device's: no per-window request, shown in every window, even one opened later", () => {
    mk();
    wm.changeDevicePrefs({ scale: 0.5 });
    expect(device.at(-1)?.scale).toBe(0.5);
    expect(derived.filter((d) => "scale" in d.patch)).toEqual([]);
    wm.sync([view("win:1"), view("win:2"), view("win:3")], new Map());
    expect(JSON.parse(localStorage.getItem("rdev.clientPrefs")!).scale).toBe(0.5);
  });

  it("sync does not rewrite saved Auto preferences", () => {
    mk(); wm.changeDevicePrefs({ scale: "auto" });
    wm.sync([view("win:1", 0.5), view("win:2", 0.5)], new Map());
    expect(JSON.parse(localStorage.getItem("rdev.clientPrefs")!).scale).toBe("auto");
  });

  it("shows requested bitrate and uses the echo before a preference exists", () => {
    mk();
    wm.sync([{ ...view("win:1"), bitrateBps: 2_000_000 }, view("win:2")], new Map());
    expect(sel("win-bitrate").value).toBe("2000000");
    wm.changeDevicePrefs({ bitrateBps: 10_000_000 });
    wm.sync([{ ...view("win:1"), bitrateBps: 2_000_000 }, view("win:2")], new Map());
    expect(sel("win-bitrate").value).toBe("10000000");
  });

  it("the codec select shows the device's request, and marks it where this window's connection settled elsewhere", () => {
    mk({ scale: "auto", codec: "av1" });
    wm.sync([{ ...view("win:1"), activeCodec: "h265" }, { ...view("win:2"), activeCodec: "av1" }], new Map());
    expect(sel("win-codec").textContent).toBe("H.265");
    expect(sel("win-codec").hasAttribute("data-unmet")).toBe(true);
    expect(sel("win-codec", 1).hasAttribute("data-unmet")).toBe(false);
  });

  it("Home and Keyboard target their simulator even when another window is focused", () => {
    mk();
    wm.sync([{ ...view("sim:A"), focused: false }, view("win:2")], new Map());
    container.querySelector<HTMLButtonElement>('.win-sim-home')!.click();
    container.querySelector<HTMLButtonElement>('.win-sim-keyboard')!.click();
    expect(simulatorActions).toEqual([["sim:A", "home"], ["sim:A", "keyboard"]]);
    expect(container.querySelector('[data-source="win:2"] .win-sim-home')).toBeNull();
  });

  it("simulators stay direct even with a saved trackpad preference and cannot toggle it", () => {
    mk({ scale: "auto", codec: "auto", pointerMode: "trackpad" });
    wm.sync([view("sim:A")], new Map());
    expect(container.querySelector<HTMLElement>(".source-window")!.dataset.pointerMode).toBe("direct");
    wm.togglePointerMode();
    expect(device).toEqual([]);
    wm.changeDevicePrefs({ pointerMode: "direct" });
    wm.changeDevicePrefs({ pointerMode: "trackpad" });
    expect(container.querySelector<HTMLElement>(".source-window")!.dataset.pointerMode).toBe("direct");
  });

  it("the touch mode is one of them", () => {
    mk();
    wm.togglePointerMode();
    expect(device.at(-1)?.pointerMode).toBe("trackpad");
    expect([...container.querySelectorAll<HTMLElement>(".source-window")].every(w => w.dataset.pointerMode === "trackpad")).toBe(true);
    wm.togglePointerMode(); expect(device.at(-1)?.pointerMode).toBe("direct");
  });
});

describe("WindowManager Auto tracking", () => {
  const HOST = { w: 1400, h: 950, pxW: 2800, pxH: 1900 };
  const view = (source: string): WindowView =>
    ({ source, name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 });

  let container!: HTMLElement;
  let wm!: WindowManager;
  let prefs!: Array<Record<string, number>>;
  let fire!: () => void;              // fire every ResizeObserver callback
  let realRO: unknown;

  beforeEach(() => {
    vi.useFakeTimers();
    // jsdom has no ResizeObserver. Install one that records its callbacks so the test can fire them —
    // this exercises the REAL wiring rather than reaching past it.
    const cbs: Array<() => void> = [];
    realRO = (globalThis as Record<string, unknown>).ResizeObserver;
    (globalThis as Record<string, unknown>).ResizeObserver = class {
      constructor(cb: () => void) { cbs.push(cb); }
      observe() {} disconnect() {}
    };
    fire = () => { for (const cb of cbs) cb(); };
    Object.defineProperty(window, "devicePixelRatio", { value: 2, configurable: true });
  });

  afterEach(() => {
    wm.clear(); container.remove();
    (globalThis as Record<string, unknown>).ResizeObserver = realRO;
    vi.useRealTimers();
  });

  // jsdom has no layout engine, so every getBoundingClientRect is 0x0. Stub the body's box to the size
  // the window would really be drawn at.
  const setBox = (w: number, h: number) => {
    const body = container.querySelector(".win-body") as HTMLElement;
    Object.defineProperty(body, "getBoundingClientRect", {
      configurable: true,
      value: () => ({ width: w, height: h, x: 0, y: 0, top: 0, left: 0, right: w, bottom: h, toJSON: () => ({}) }),
    });
  };

  const mk = () => {
    prefs = [];
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {},
      onPrefs: (_s, patch) => prefs.push(patch as Record<string, number>),
      onRecovery: () => {}, onPlayoutDelay: () => {},
      onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([view("win:1")], new Map());
    setBox(HOST.w, HOST.h);
  };

  it("the FIRST computation is immediate, so the stream never sits at the host default", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    expect(prefs).toEqual([{ scale: 1 }]);   // unfitted, dpr 2 -> full native
  });

  it("later changes are debounced 1s and an unchanged value sends nothing", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    prefs.length = 0;
    setBox(782.6, 531.05);            // the window is fitted
    fire();
    vi.advanceTimersByTime(999);
    expect(prefs).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(prefs).toEqual([{ scale: 0.56 }]);
    fire();                            // same box -> same scale
    vi.advanceTimersByTime(1000);
    expect(prefs).toEqual([{ scale: 0.56 }]);
  });

  it("a burst of changes produces ONE request", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    prefs.length = 0;
    for (let i = 0; i < 20; i++) { setBox(1000 - i, 680 - i); fire(); vi.advanceTimersByTime(30); }
    vi.advanceTimersByTime(1000);
    expect(prefs.length).toBe(1);
  });

  it("a degenerate box sends nothing and keeps the last value", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    prefs.length = 0;
    setBox(0, 0);                      // hidden window (every unfocused window on mobile)
    fire();
    vi.advanceTimersByTime(1000);
    expect(prefs).toEqual([]);
  });

  // THE RECONNECT CASE. `source-list` carries POINTS for every listed window, but the native PIXEL size
  // arrives separately — and for a client joining an already-capturing source it arrives on its own, in
  // the baseline `source-status`, with no point size beside it. Learning it must therefore be enough on
  // its own to unblock Auto; before this, that client silently never sent anything.
  it("learning the native pixel size ALONE unblocks Auto", () => {
    mk();
    wm.setSourceSize("win:1", HOST.w, HOST.h);            // points only, as source-list delivers them
    expect(prefs).toEqual([]);                             // native size unknown -> nothing to send
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH);    // the baseline source-status
    expect(prefs).toEqual([{ scale: 1 }]);
  });

  it("an unknown native size sends nothing", () => {
    mk();
    wm.setSourceSize("win:1", HOST.w, HOST.h);   // points only — a sim, or a pre-capture window
    vi.advanceTimersByTime(1000);
    expect(prefs).toEqual([]);
  });

  it("a pinned percentage stops Auto tracking entirely", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    wm.changeDevicePrefs({ scale: 0.25 });
    prefs.length = 0;
    setBox(782.6, 531.05); fire();
    vi.advanceTimersByTime(1000);
    expect(prefs).toEqual([]);
  });

  it("re-selecting Auto resumes tracking immediately, without waiting for a geometry change", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    wm.changeDevicePrefs({ scale: 0.25 });
    setBox(782.6, 531.05);              // the box changed while pinned, so Auto has catching up to do
    prefs.length = 0;
    wm.changeDevicePrefs({ scale: "auto" });
    expect(prefs).toEqual([{ scale: 0.56 }]);   // immediate: nothing else is going to nudge it
  });

  it("leaving the view set clears the sent-cache, so a re-subscribe asks again", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    expect(prefs).toEqual([{ scale: 1 }]);
    wm.sync([], new Map());                    // unsubscribed: the host drops back to defaultPrefs
    wm.sync([view("win:1")], new Map());
    setBox(HOST.w, HOST.h);
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    expect(prefs).toEqual([{ scale: 1 }, { scale: 1 }]);   // the SAME value, sent again
  });

  // CONTRACT ISSUE 3: a new driver or a new connection starts with the host holding NO ceiling from this
  // client — the host drops a driver's derived values with it — so every window reports its own again.
  it("resendDerived re-reports every window's Auto ceiling, even an unchanged one", () => {
    mk();
    wm.setSourcePixelSize("win:1", HOST.pxW, HOST.pxH); wm.setSourceSize("win:1", HOST.w, HOST.h);
    expect(prefs).toEqual([{ scale: 1 }]);
    wm.resendDerived();
    expect(prefs).toEqual([{ scale: 1 }, { scale: 1 }]);
  });
});

describe("drawnFitScale (fit + grip)", () => {
  it("is the band fit when nothing is pinned", () => {
    expect(drawnFitScale(1658, 1084, 968, 566)).toBeCloseTo(fitScale(1658, 1084, 968, 566), 6);
  });

  it("honours a pin that is SMALLER than the band fit", () => {
    // The user dragged the window down to half the fit — that is what they want to see.
    expect(drawnFitScale(818, 535, 968, 566, 0.4889)).toBeCloseTo(0.4889, 6);
  });

  it("never lets a pin EXCEED the band fit, so the whole window stays visible", () => {
    // The host window later grew: the band now allows only 0.32, so the 0.4889 pin must yield.
    expect(drawnFitScale(3000, 1960, 968, 566, 0.4889)).toBeCloseTo(fitScale(3000, 1960, 968, 566), 6);
  });

  // THE REGRESSION. In fit mode the drawn size is a function of the BAND and the host size, never of the
  // drag — so the grip shrinks the real window and applySize immediately re-fits it back out to fill the
  // band. Measured before the pin existed, host 1658x1084 in a 1000x700 viewport (fit 0.4889, drawn 811):
  //   drag body -> 600px  asks host 1227pt  refit 0.6608  REDRAWN 811  (wanted 600)
  //   drag body -> 400px  asks host  818pt  refit 0.9907  REDRAWN 810  (wanted 400)
  //   drag body -> 200px  asks host  409pt  refit 1.0000  REDRAWN 409  (wanted 200)  <- "1:1 on the host"
  // The drag had NO visible effect until the host window became small enough to fit unscaled, at which
  // point the window snapped to the host's size and fit was silently over.
  it("redraws a fit-mode grip drag at the size dragged to, not back out to the band", () => {
    const band = stageBand(1000, 700, 64, 38);
    const HOST = { w: 1658, h: 1084 };
    const k = drawnFitScale(HOST.w, HOST.h, band.w, band.h);
    for (const target of [600, 400, 200]) {
      const el = windowElementSize(target, target * (HOST.h / HOST.w));
      const req = resizeRequest(el.w, el.h, WIN_CHROME_PX, WIN_BORDER_PX, k)!;
      // The grip pins the scale the body was drawn at; the host's confirmed size is redrawn at that pin.
      const redrawn = req.w * drawnFitScale(req.w, req.h, band.w, band.h, k);
      expect(redrawn).toBeCloseTo(target, 0);
    }
  });

});

// THE SETTING IS SESSION-WIDE AND THE CONTROL IS PER WINDOW, which is only honest if every window
// shows the same number and they all change together. That is the property this asserts — a
// per-window control reflecting per-window state would pass a single-window test and be wrong.
describe("WindowManager settings panel", () => {
  const opts = () => ({
    onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
    onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
    inputChannel: { send: () => {} } as unknown as RTCDataChannel,
    nowMs: () => 0,
    pc: () => undefined,
  });
  const view = (source: string) => ({
    source, name: source, focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto",
  });

  it("offers a two-state smoothing switch and read-only codec", () => {
    const container = document.createElement("div"); document.body.append(container);
    const onPlayoutDelay = vi.fn();
    const onCurtain = vi.fn();
    const onSourceAudio = vi.fn();
    const wm = new WindowManager(container, { ...opts(), onPlayoutDelay, onCurtain, onSourceAudio });
    wm.sync([{ ...view("win:1"), activeCodec: "h265" }], new Map());
    const panel = container.querySelector(".win-settings")!;
    expect(panel.querySelector(".win-pointer, .win-fps, .win-scale, select.win-codec")).toBeNull();
    expect(panel.querySelector(".win-codec")?.textContent).toBe("H.265");
    const toggle = panel.querySelector<HTMLButtonElement>('button.win-delay')!;
    expect(toggle?.getAttribute("aria-checked")).toBe("false");
    toggle.click(); expect(onPlayoutDelay).toHaveBeenLastCalledWith(100);
    expect(toggle.getAttribute("aria-checked")).toBe("true");
    toggle.click(); expect(onPlayoutDelay).toHaveBeenLastCalledWith(20);
    wm.setPlayoutDelayMin(100);
    expect(toggle.getAttribute("aria-checked")).toBe("true");
    expect(wm.playoutDelayIsAuto()).toBe(false);
    const curtain = panel.querySelector<HTMLButtonElement>(".win-curtain")!;
    expect(curtain.getAttribute("role")).toBe("switch");
    wm.setCurtainUp(false); expect(curtain.getAttribute("aria-checked")).toBe("false");
    curtain.click(); expect(onCurtain).toHaveBeenLastCalledWith(true);
    wm.setCurtainUp(true); expect(curtain.getAttribute("aria-checked")).toBe("true");
    curtain.click(); expect(onCurtain).toHaveBeenLastCalledWith(false);
    const audio = panel.querySelector<HTMLButtonElement>(".win-audio")!;
    expect(audio.getAttribute("role")).toBe("switch");
    expect(audio.getAttribute("aria-checked")).toBe("true");
    audio.click(); expect(onSourceAudio).toHaveBeenLastCalledWith("win:1", false);
    expect(audio.getAttribute("aria-checked")).toBe("false");
    wm.clear(); container.remove();
  });

  it("always gives the fallback cursor a valid image source instead of a broken-image box", () => {
    const container = document.createElement("div"); document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    const cursor = container.querySelector<HTMLImageElement>(".trackpad-cursor")!;
    const fallback = cursor.getAttribute("src");
    expect(fallback).toMatch(/^data:image\/svg\+xml,/);
    expect(decodeURIComponent(fallback!)).toContain('stroke="#000"');
    wm.setCursor("data:image/png;base64,bG93", 0, 0);
    wm.setCursor(null, 0, 0);
    expect(cursor.getAttribute("src")).toBe(fallback);
    wm.clear(); container.remove();
  });

  it("uses the high-density cursor at logical size without changing the desktop cursor or hotspot", () => {
    const container = document.createElement("div"); document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    wm.setCursor("data:image/png;base64,bG93", 2, 3, { url: "data:image/png;base64,aGk=", w: 16, h: 24 });
    const cursor = container.querySelector<HTMLImageElement>(".trackpad-cursor")!;
    expect(cursor.src).toBe("data:image/png;base64,aGk=");
    expect(cursor.style.width).toBe("16px");
    expect(cursor.style.height).toBe("24px");
    expect(container.querySelector<HTMLElement>(".win-body")!.style.cursor).toContain('2 3, auto');
    expect(container.querySelector<HTMLElement>(".win-body")!.style.cursor).toContain('bG93');
    wm.setCursor("data:image/png;base64,bG93", 2, 3);
    expect(cursor.style.width).toBe("");
    expect(cursor.src).toBe("data:image/png;base64,bG93");
    wm.clear(); container.remove();
  });

  it("groups media and privacy controls, with codec and rate as unheaded information", () => {
    const container = document.createElement("div"); document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    const panel = container.querySelector(".win-settings")!;
    expect([...panel.querySelectorAll("section > h3")].map(h => h.textContent)).toEqual(["MEDIA", "PRIVACY"]);
    expect([...panel.querySelectorAll(".win-settings-section:first-of-type .win-settings-row")]
      .map(row => row.querySelector(".win-settings-label > span")?.textContent))
      .toEqual(["Bitrate", "Forced FEC overhead", "AV1 reference recovery (experimental)", "Prefer smooth video over latency", "Audio"]);
    expect(panel.querySelector(".win-settings-section:last-of-type .win-curtain")).not.toBeNull();
    expect([...panel.querySelectorAll(".win-settings-info .win-settings-row")]
      .map(row => row.querySelector(".win-settings-label > span")?.textContent))
      .toEqual(["Incoming", "Codec"]);
    wm.clear(); container.remove();
  });

  it("keeps the titlebar to the gear and the window buttons", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    const controls = container.querySelector(".win-controls")!;
    // The prefs controls MOVED OUT. Leaving one behind would put the strip back over the width limit
    // this panel exists to solve, and would give the same setting two places to disagree.
    expect(controls.querySelector(".win-codec")).toBeNull();
    expect(controls.querySelector(".win-recovery")).toBeNull();
    expect(controls.querySelector(".win-gear")).not.toBeNull();
    expect(controls.querySelector(".win-close")).not.toBeNull();
    container.remove();
  });

  it("makes desktop settings a dialog over its window and restores focus on dismissal", () => {
    const previousLayout = document.documentElement.dataset.layout;
    document.documentElement.dataset.layout = "floating";
    const container = document.createElement("div"); document.body.append(container);
    const wm = new WindowManager(container, opts());
    try {
      wm.sync([view("win:1")], new Map());
      const gear = container.querySelector<HTMLButtonElement>(".win-gear")!;
      const panel = container.querySelector<HTMLElement>(".win-settings")!;
      const window = panel.parentElement!;
      gear.click();
      expect(window.classList.contains("settings-modal")).toBe(true);
      expect(document.activeElement).toBe(panel.querySelector(".win-settings-close"));
      for (const child of window.children)
        if (child !== panel) expect((child as HTMLElement).inert).toBe(true);
      panel.click();
      expect(panel.classList.contains("open")).toBe(false);
      expect(document.activeElement).toBe(gear);
      for (const child of window.children)
        if (child !== panel) expect((child as HTMLElement).inert).toBe(false);
    } finally {
      wm.clear(); container.remove();
      if (previousLayout === undefined) delete document.documentElement.dataset.layout;
      else document.documentElement.dataset.layout = previousLayout;
    }
  });

  it("toggles on the gear and closes on a geometry change", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    const gear = container.querySelector<HTMLButtonElement>(".win-gear")!;
    const panel = container.querySelector<HTMLElement>(".win-settings")!;
    expect(panel.classList.contains("open")).toBe(false);
    gear.click();
    expect(panel.classList.contains("open")).toBe(true);
    expect(gear.getAttribute("aria-expanded")).toBe("true");
    // CLOSING ON GEOMETRY CHANGE rather than following the window: a panel that tracked a moving
    // window would re-pin against a getBoundingClientRect that still reports the OLD box for the
    // whole of a CSS transition — the trap that once parked the Fit/-/x cluster 426px off.
    wm.closeAllSettings();
    expect(panel.classList.contains("open")).toBe(false);
    container.remove();
  });

  it("drops the panel when its window goes away", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([view("win:1")], new Map());
    expect(container.querySelectorAll(".win-settings")).toHaveLength(1);
    // The panel lives in a shared layer, not inside the window, so nothing removes it for free.
    wm.sync([], new Map());
    expect(container.querySelectorAll(".win-settings")).toHaveLength(0);
    container.remove();
  });
});

describe("WindowManager refused-pin marking", () => {
  const opts = (codec: ClientPrefs["codec"]) => ({
    onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
    onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
    inputChannel: { send: () => {} } as unknown as RTCDataChannel,
    nowMs: () => 0,
    pc: () => undefined,
    prefs: { scale: "auto", codec } as ClientPrefs,
  });
  const view = (codec: string, activeCodec?: string) => ([{
    source: "win:1", name: "w", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000,
    codec, activeCodec,
  }]);

  it("marks the gear when the browser refused the pinned codec", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts("av1"));
    // THE MEASURED CASE: AV1 pinned, Safari's answer carried only H.265/H.264, rdev fell back.
    wm.sync(view("av1", "h265"), new Map());
    const gear = container.querySelector<HTMLElement>(".win-gear")!;
    const sel = container.querySelector<HTMLElement>(".win-codec")!;
    expect(sel.hasAttribute("data-unmet")).toBe(true);
    // The select is BEHIND the gear now, so marking only the select is marking nothing.
    expect(gear.hasAttribute("data-unmet")).toBe(true);
    container.remove();
  });

  it("clears the mark once the pin is honoured", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts("av1"));
    wm.sync(view("av1", "h265"), new Map());
    const gear = container.querySelector<HTMLElement>(".win-gear")!;
    expect(gear.hasAttribute("data-unmet")).toBe(true);
    // PAIRED: a mark that never clears is as useless as one that never sets, and would pass the
    // check above.
    wm.sync(view("av1", "av1"), new Map());
    expect(gear.hasAttribute("data-unmet")).toBe(false);
    container.remove();
  });

  it("never marks Auto", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts("auto"));
    // Auto asks for nothing, so it can never be refused — marking it would cry wolf on every
    // session where the browser simply picked something.
    wm.sync(view("auto", "h265"), new Map());
    const gear = container.querySelector<HTMLElement>(".win-gear")!;
    expect(gear.hasAttribute("data-unmet")).toBe(false);
    container.remove();
  });
});

describe("WindowManager forced recovery override", () => {
  const view = (source: string): WindowView =>
    ({ source, name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 });

  const mk = () => {
    const container = document.createElement("div");
    document.body.append(container);
    const sent: Array<number | null> = [];
    const wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: (bp) => sent.push(bp), onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0,
      pc: () => undefined,
    });
    return { container, wm, sent };
  };
  const selects = (c: HTMLElement) =>
    [...c.querySelectorAll<HTMLSelectElement>(".win-recovery")];

  it("reflects one echoed value into every window", () => {
    const { container, wm } = mk();
    wm.sync([view("win:1"), view("win:2")], new Map());
    expect(selects(container)).toHaveLength(2);
    wm.setRecoveryOverride(2000);
    expect(selects(container).map((s) => s.value)).toEqual(["2000", "2000"]);
    wm.setRecoveryOverride(null);
    expect(selects(container).map((s) => s.value)).toEqual(["auto", "auto"]);
  });

  // A window opened AFTER the setting was made must not show Auto: the value is one per connection,
  // so a fresh titlebar disagreeing with its neighbours would be a lie about session state.
  it("opens a later window on the current value", () => {
    const { container, wm } = mk();
    wm.sync([view("win:1")], new Map());
    wm.setRecoveryOverride(4000);
    wm.sync([view("win:1"), view("win:2")], new Map());
    expect(selects(container).map((s) => s.value)).toEqual(["4000", "4000"]);
  });

  it("sends null for Auto and basis points otherwise", () => {
    const { container, wm, sent } = mk();
    wm.sync([view("win:1")], new Map());
    const sel = selects(container)[0]!;
    sel.value = "3000"; sel.dispatchEvent(new Event("change"));
    sel.value = "auto"; sel.dispatchEvent(new Event("change"));
    expect(sent).toEqual([3000, null]);
  });
});

describe("WindowManager view zoom", () => {
  let container!: HTMLElement;
  let wm!: WindowManager;

  const mk = () => {
    document.documentElement.dataset.layout = "tabbed";
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([{ source: "win:1", name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 }],
            new Map());
    wm.setSourceSize("win:1", 1470, 827);
    wm.setSourcePixelSize("win:1", 2940, 1654);
    return container.querySelector(".source-window") as HTMLElement;
  };
  /// jsdom has no layout engine, so a real box has to be forced. `clientWidth`/`clientHeight` are
  /// what `refreshView` and `paintTrackpadCursor` read; `getBoundingClientRect` is what
  /// `contentRect` and `autoMeasure` read.
  const boxAs = (el: HTMLElement, w: number, h: number) => {
    const body = el.querySelector(".win-body") as HTMLElement;
    Object.defineProperty(body, "clientWidth", { value: w, configurable: true });
    Object.defineProperty(body, "clientHeight", { value: h, configurable: true });
    body.getBoundingClientRect = () => ({ left: 0, top: 0, width: w, height: h,
      right: w, bottom: h, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
    return body;
  };
  /// A 16:9 picture, which is what makes the tall mobile box letterbox.
  const pictureAs = (el: HTMLElement, w: number, h: number) => {
    const video = el.querySelector("video") as HTMLVideoElement;
    Object.defineProperty(video, "videoWidth", { value: w, configurable: true });
    Object.defineProperty(video, "videoHeight", { value: h, configurable: true });
    return video;
  };
  const setView = (z: number, ox: number, oy: number) =>
    (wm as unknown as { applyView: (s: string, v: { z: number; ox: number; oy: number }) => void })
      .applyView("win:1", { z, ox, oy });

  afterEach(() => {
    wm.clear();
    container.remove();
    delete document.documentElement.dataset.layout;
  });

  it("writes NO transform at the fit view, so the untouched path is byte-identical", () => {
    const el = mk();
    boxAs(el, 420, 646);
    const video = pictureAs(el, 1600, 900);
    setView(1, 0, 0);
    expect(video.style.transform).toBe("");
    expect(el.dataset.zoomed).toBe("false");
  });

  it("writes the transform and marks the window zoomed above the fit", () => {
    const el = mk();
    boxAs(el, 420, 646);
    const video = pictureAs(el, 1600, 900);
    setView(2, -100, 0);
    expect(video.style.transform).toMatch(/scale\(2\)/);
    expect(el.dataset.zoomed).toBe("true");
    expect(wm.viewDebug()["win:1"]!.z).toBeCloseTo(2);
  });

  it("clamps a stored view at native parity, dpr included", () => {
    // DPR IS PINNED rather than taken from jsdom (which reports 2), so the expectation is a concrete
    // number AND the assertion fails if the code ever stops reading dpr: without it zMax would be 7.
    // fit.w is the full 420 — 16:9 into a tall box binds on width — and pxW is 2940, so native parity
    // is 2940 / (420 * 3).
    const dpr = Object.getOwnPropertyDescriptor(window, "devicePixelRatio");
    Object.defineProperty(window, "devicePixelRatio", { value: 3, configurable: true });
    try {
      const el = mk();
      boxAs(el, 420, 646);
      pictureAs(el, 1600, 900);
      setView(99, 0, 0);
      expect(wm.viewDebug()["win:1"]!.z).toBeCloseTo(2940 / 1260);
    } finally {
      if (dpr) Object.defineProperty(window, "devicePixelRatio", dpr);
    }
  });

  it("raises the Auto measurement's box by the zoom", () => {
    const el = mk();
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    const before = (wm.autoDebug()["win:1"] as { scale: number; box: { w: number } });
    setView(2, 0, 0);
    const after = (wm.autoDebug()["win:1"] as { scale: number; box: { w: number } });
    expect(after.box.w).toBeCloseTo(before.box.w * 2);
    expect(after.scale).toBeGreaterThan(before.scale);
    expect(after.scale).toBeLessThanOrEqual(1);
  });

  it("resetView returns the picture to the fit", () => {
    const el = mk();
    boxAs(el, 420, 646);
    const video = pictureAs(el, 1600, 900);
    setView(2, -100, 0);
    wm.resetView("win:1");
    expect(wm.viewDebug()["win:1"]!.z).toBe(1);
    expect(video.style.transform).toBe("");
  });

  it("puts a Zoom button in the titlebar, spelled as a WORD", () => {
    // A GLYPH WOULD FALL BACK TO A SYSTEM FONT: the self-hosted JetBrains Mono subsets are
    // latin + latin-ext only. It is why Fit and Settings are words.
    const el = mk();
    const btn = el.querySelector(".win-zoom") as HTMLButtonElement;
    expect(btn).not.toBeNull();
    expect(btn.textContent).toBe("Zoom");
    expect(btn.getAttribute("aria-pressed")).toBe("false");
  });

  it("toggles the mode, and marks it on the window as well as the button", () => {
    const el = mk();
    const btn = el.querySelector(".win-zoom") as HTMLButtonElement;
    btn.click();
    expect(btn.getAttribute("aria-pressed")).toBe("true");
    expect(el.dataset.viewMode).toBe("zoom");
    btn.click();
    expect(btn.getAttribute("aria-pressed")).toBe("false");
    expect(el.dataset.viewMode).toBe("input");
  });

  it("keeps the zoom across a mode switch — working zoomed in is the point", () => {
    const el = mk();
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    setView(2, -100, 0);
    (el.querySelector(".win-zoom") as HTMLButtonElement).click();
    (el.querySelector(".win-zoom") as HTMLButtonElement).click();
    expect(wm.viewDebug()["win:1"]!.z).toBeCloseTo(2);
  });

  it("drops the zoom and the mode when the layout stops being pinned", () => {
    // A ROTATION TO LANDSCAPE RESOLVES TO `floating`, where `applySize` owns the geometry and a
    // stale transform would fight it. The ResizeObserver that carries this in the real client cannot
    // run in jsdom, so drive `refreshView` the way it does.
    const el = mk();
    boxAs(el, 420, 646);
    const video = pictureAs(el, 1600, 900);
    setView(2, -100, 0);
    (el.querySelector(".win-zoom") as HTMLButtonElement).click();
    document.documentElement.dataset.layout = "floating";
    (wm as unknown as { refreshView: (s: string) => void }).refreshView("win:1");
    expect(wm.viewDebug()["win:1"]!.z).toBe(1);
    expect(video.style.transform).toBe("");
    expect(el.dataset.viewMode).toBe("input");
  });

  it("Fit RESETS the view on a pinned layout and leaves the DESKTOP fit state alone", () => {
    // `maybeAutoFit` is NOT gated on layout, so a source larger than the jsdom band is already in
    // `fitted` here — which is the point. `toggleFit` would FLIP it, invisibly (applySize returns
    // early on a pinned layout), rewriting how this window is drawn on the floating layout. The
    // unchanged flag is what discriminates a reset from a toggle.
    const el = mk();
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    const fitted = (wm as unknown as { fitted: Set<string> }).fitted;
    const before = fitted.has("win:1");
    expect(before).toBe(true);   // the non-zero guard: a flip must have something to flip
    setView(2, -100, 0);
    (el.querySelector(".win-fit") as HTMLButtonElement).click();
    expect(wm.viewDebug()["win:1"]!.z).toBe(1);
    expect(fitted.has("win:1")).toBe(before);
  });

  it("sends the visible rect as a crop at the SETTLE, never per gesture frame", () => {
    const sent: unknown[] = [];
    // ZOOM IS A PINNED-LAYOUT FEATURE: without this, `refreshView` correctly resets the view to fit
    // and there is no crop to send at all.
    document.documentElement.dataset.layout = "tabbed";
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {},
      onPrefs: (_s, patch) => sent.push(patch),
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([{ source: "win:1", name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 }],
            new Map());
    wm.setSourceSize("win:1", 1470, 827);
    wm.setSourcePixelSize("win:1", 2940, 1654);
    const el = container.querySelector(".source-window") as HTMLElement;
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    const crops = () => sent.filter((p) => (p as { crop?: unknown }).crop !== undefined);

    sent.length = 0;
    setView(2, -100, 0);
    // A GESTURE FRAME ALONE SENDS NOTHING. `applyView` draws; it does not settle. Asserting this
    // first is what stops the test passing for a build that streams a crop per frame.
    expect(crops()).toHaveLength(0);

    // The settle, driven exactly as the view gesture's `up` branch drives it.
    (wm as unknown as { recomputeAuto: (s: string) => void }).recomputeAuto("win:1");
    const crop = crops().map((p) => (p as { crop: { w: number } }).crop).at(-1);
    expect(crop).toBeDefined();
    expect(crop!.w).toBeCloseTo(0.5, 2);   // half the picture's width is on screen at z = 2

    // A second settle that moved nothing must send nothing — several paths call recomputeAuto for
    // reasons that never touch the picture's position.
    sent.length = 0;
    (wm as unknown as { recomputeAuto: (s: string) => void }).recomputeAuto("win:1");
    expect(crops()).toHaveLength(0);
  });

  it("says NOTHING about a crop while the picture is unzoomed", () => {
    // A full crop is the host's default, so announcing it is pure noise on every source and every
    // size push — including for every desktop client that will never zoom.
    const sent: unknown[] = [];
    // ZOOM IS A PINNED-LAYOUT FEATURE: without this, `refreshView` correctly resets the view to fit
    // and there is no crop to send at all.
    document.documentElement.dataset.layout = "tabbed";
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {},
      onPrefs: (_s, patch) => sent.push(patch),
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([{ source: "win:1", name: "Safari", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 }],
            new Map());
    wm.setSourceSize("win:1", 1470, 827);
    wm.setSourcePixelSize("win:1", 2940, 1654);
    const el = container.querySelector(".source-window") as HTMLElement;
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    sent.length = 0;
    (wm as unknown as { recomputeAuto: (s: string) => void }).recomputeAuto("win:1");
    expect(sent.filter((p) => (p as { crop?: unknown }).crop !== undefined)).toHaveLength(0);

    // ...but a RETURN to full after a real crop must be sent, or the host keeps masking a window
    // nobody is zoomed into any more.
    setView(2, -100, 0);
    (wm as unknown as { recomputeAuto: (s: string) => void }).recomputeAuto("win:1");
    sent.length = 0;
    wm.resetView("win:1");
    const back = sent.filter((p) => (p as { crop?: unknown }).crop !== undefined)
                     .map((p) => (p as { crop: { w: number } }).crop).at(-1);
    expect(back).toBeDefined();
    expect(back!.w).toBeCloseTo(1);
  });

  it("forgets a source's view when it is unsubscribed", () => {
    const el = mk();
    boxAs(el, 420, 646);
    pictureAs(el, 1600, 900);
    setView(2, 0, 0);
    wm.sync([], new Map());
    expect(wm.viewDebug()["win:1"]).toBeUndefined();
  });
});

describe("WindowManager.clear", () => {
  const opts = () => ({
    onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
    onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
    inputChannel: { send: () => {} } as unknown as RTCDataChannel,
    nowMs: () => 0,
    pc: () => undefined,
  });

  it("removes its document listeners — a cleared manager no longer closes panels on a page click", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    const spy = vi.spyOn(wm, "closeAllSettings");
    document.dispatchEvent(new Event("pointerdown"));
    expect(spy).toHaveBeenCalledTimes(1);
    wm.clear();
    document.dispatchEvent(new Event("pointerdown"));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    expect(spy).toHaveBeenCalledTimes(1);
    container.remove();
  });

  it("stops its bitrate tick", () => {
    vi.useFakeTimers();
    try {
      const container = document.createElement("div");
      document.body.append(container);
      const wm = new WindowManager(container, opts());
      expect(vi.getTimerCount()).toBe(1);
      wm.clear();
      expect(vi.getTimerCount()).toBe(0);
      container.remove();
    } finally { vi.useRealTimers(); }
  });

  it("removes every window it built", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([{ source: "win:1", name: "a", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" }], new Map());
    expect(container.querySelector(".source-window")).not.toBeNull();
    wm.clear();
    expect(container.querySelector(".source-window")).toBeNull();
    container.remove();
  });

  it("cancels each window's gesture before removing it", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([{ source: "win:1", name: "a", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" }], new Map());
    const win = (wm as unknown as { wins: Map<string, { pointer: { cancelGesture: () => void } }> }).wins.get("win:1")!;
    const spy = vi.spyOn(win.pointer, "cancelGesture");
    wm.clear();
    expect(spy).toHaveBeenCalledTimes(1);
    container.remove();
  });

  /// `matchMedia` is undefined in this jsdom environment by default (verified), so `syncKeyboard`'s
  /// `(any-pointer: coarse)` check is always false unless stubbed — every other test in this file
  /// therefore mounts no on-screen keyboard at all, and could never catch its teardown regressing.
  const coarsePointer = (): (() => void) => {
    const orig = (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia;
    (window as unknown as { matchMedia: typeof window.matchMedia }).matchMedia = ((q: string) => ({
      matches: q.includes("any-pointer: coarse"),
      media: q,
      addEventListener() {}, removeEventListener() {},
      addListener() {}, removeListener() {},
      dispatchEvent: () => false,
    })) as unknown as typeof window.matchMedia;
    return () => { (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia = orig; };
  };

  it("disposes a coarse-pointer window's on-screen keyboard — deleting the disposeAuto loop leaves it mounted", () => {
    const restore = coarsePointer();
    try {
      const container = document.createElement("div");
      document.body.append(container);
      const wm = new WindowManager(container, opts());
      wm.sync([{ source: "win:1", name: "a", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" }], new Map());
      expect(container.querySelector(".win-key-input")).not.toBeNull();
      wm.clear();
      expect(container.querySelector(".win-key-input")).toBeNull();
      container.remove();
    } finally { restore(); }
  });

  it("one window's teardown throwing does not strand the rest — clear() is exception-safe per window", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([
      { source: "win:1", name: "a", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" },
      { source: "win:2", name: "b", focused: false, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" },
    ], new Map());
    const win1 = (wm as unknown as { wins: Map<string, { pointer: { cancelGesture: () => void } }> }).wins.get("win:1")!;
    // Stands in for `disposeKeyboard`'s modifier release throwing on a channel already closing under
    // it (measured: `InvalidStateError`) — any one window's teardown can fail this way, and it must
    // not strand every window queued after it.
    const spy = vi.spyOn(win1.pointer, "cancelGesture").mockImplementation(() => { throw new Error("boom"); });
    expect(() => wm.clear()).not.toThrow();
    expect(spy).toHaveBeenCalledTimes(1);
    expect(container.querySelectorAll(".source-window")).toHaveLength(0);
    container.remove();
  });
  /// A tap on the window's key strip must leave DOM focus where it is. The window's capture-phase
  /// `pointerdown` gives the picture (`.win-body`) DOM focus for any tap inside the window — and the strip
  /// and the hidden input are children of the window — so tapping Ctrl moved focus off the hidden input,
  /// and on iOS the soft keyboard closed. The strip's own `mousedown` guard cannot stop a PROGRAMMATIC focus.
  const tap = (el: Element) => {
    el.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    el.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    el.dispatchEvent(new Event("pointerup", { bubbles: true }));
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  };
  const touchWindow = () => {
    const container = document.createElement("div");
    document.body.append(container);
    const wm = new WindowManager(container, opts());
    wm.sync([{ source: "win:1", name: "a", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto" }], new Map());
    const q = <T extends Element>(sel: string) => container.querySelector<T>(sel)!;
    const body = q<HTMLElement>(".win-body");
    // jsdom's HTMLElement has neither method, and the picture's attachPointer calls both on a press.
    body.setPointerCapture = () => {}; body.releasePointerCapture = () => {};
    return { container, wm, q, input: q<HTMLInputElement>(".win-key-input"), body };
  };

  for (const key of ["ctrl", "esc", "shift"]) {
    it(`a tap on the strip's ${key} keeps the soft keyboard up — the hidden input keeps DOM focus`, () => {
      const restore = coarsePointer();
      try {
        const { container, wm, q, input } = touchWindow();
        input.focus();
        expect(document.activeElement).toBe(input);
        tap(q(`[data-key-id="${key}"]`));
        expect(document.activeElement).toBe(input);
        wm.clear(); container.remove();
      } finally { restore(); }
    });
  }

  it("the strip's keyboard toggle DISMISSES a raised keyboard (the tap no longer blurs the input first)", () => {
    const restore = coarsePointer();
    try {
      const { container, wm, q, input } = touchWindow();
      input.focus();
      tap(q('[data-key-id="kbd"]'));
      expect(document.activeElement).not.toBe(input);
      // To the PICTURE, not <body>: a hardware keyboard's keys still reach the window afterwards.
      expect(document.activeElement).toBe(q(".win-body"));
      tap(q('[data-key-id="kbd"]'));
      expect(document.activeElement).toBe(input);
      wm.clear(); container.remove();
    } finally { restore(); }
  });

  it("a strip tap with focus OUTSIDE the window still gives the window DOM focus (a hardware keyboard's keys)", () => {
    const restore = coarsePointer();
    try {
      const { container, wm, q, body } = touchWindow();
      const outside = document.createElement("input");
      document.body.append(outside);
      outside.focus();
      tap(q('[data-key-id="ctrl"]'));
      expect(document.activeElement).toBe(body);
      outside.remove(); wm.clear(); container.remove();
    } finally { restore(); }
  });

  it("a strip tap with focus on a titlebar BUTTON gives it to the picture — the exemption is the input and the picture only", () => {
    const restore = coarsePointer();
    try {
      const { container, wm, q, body } = touchWindow();
      const fit = q<HTMLElement>(".win-titlebar button");
      fit.focus();
      expect(document.activeElement).toBe(fit);
      tap(q('[data-key-id="ctrl"]'));
      expect(document.activeElement).toBe(body);
      wm.clear(); container.remove();
    } finally { restore(); }
  });

  it("a tap on the PICTURE still takes DOM focus from the hidden input — only the strip is exempt", () => {
    const restore = coarsePointer();
    try {
      const { container, wm, input, body } = touchWindow();
      input.focus();
      tap(body);
      expect(document.activeElement).toBe(body);
      wm.clear(); container.remove();
    } finally { restore(); }
  });
});

describe("WindowManager full screen", () => {
  const root = document.documentElement;
  let container!: HTMLElement;
  let wm!: WindowManager;
  const view = (source: string, focused = true): WindowView => ({
    source, name: source, focused, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto",
  });
  let transitions: Array<string | null> = [];
  const mk = (layout: "floating" | "tabbed" = "floating", views: WindowView[] = [view("win:1")]) => {
    root.dataset.layout = layout;
    container = document.createElement("div");
    document.body.append(container);
    transitions = [];
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      onFullscreen: (s) => transitions.push(s),
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync(views, new Map());
  };
  /// The window element for a source — its settings panel carries the id.
  const winOf = (source: string) => [...container.querySelectorAll<HTMLElement>(".source-window")]
    .find((el) => el.querySelector(".win-settings")?.getAttribute("data-source") === source)!;
  const q = <T extends HTMLElement>(el: HTMLElement, sel: string) => el.querySelector<T>(sel)!;

  afterEach(() => {
    wm.clear();
    container.remove();
    delete root.dataset.layout;
    delete root.dataset.fullscreen;
    vi.useRealTimers();
  });

  it("puts `Full screen` in the titlebar beside Fit, as a word", () => {
    mk();
    const labels = [...q(winOf("win:1"), ".win-controls").children].map((b) => b.textContent);
    expect(labels).toEqual(["Zoom", "Settings", "Fit", "Full screen", "−", "×"]);
  });

  it("enters on the button: the root and the window carry it, the picture takes the keys, the panel shuts", () => {
    mk();
    const el = winOf("win:1");
    q<HTMLButtonElement>(el, ".win-gear").click();
    expect(q(el, ".win-settings").classList.contains("open")).toBe(true);
    q<HTMLButtonElement>(el, ".win-fullscreen").click();
    expect(root.dataset.fullscreen).toBe("window");
    expect(el.classList.contains("fullscreen")).toBe(true);
    expect(q(el, ".win-fullscreen").getAttribute("aria-pressed")).toBe("true");
    expect(wm.fullscreenSource()).toBe("win:1");
    // The button that asked is hidden with the titlebar; focus must not fall to <body>, where no key
    // — Esc included — reaches the Mac.
    expect(document.activeElement).toBe(q(el, ".win-body"));
    expect(q(el, ".win-settings").classList.contains("open")).toBe(false);
  });

  it("leaves on Exit, handing the keys back to the picture", () => {
    mk();
    const el = winOf("win:1");
    q<HTMLButtonElement>(el, ".win-fullscreen").click();
    q<HTMLButtonElement>(el, ".win-fullscreen-exit").focus();
    q<HTMLButtonElement>(el, ".win-fullscreen-exit").click();
    expect(root.dataset.fullscreen).toBeUndefined();
    expect(el.classList.contains("fullscreen")).toBe(false);
    expect(q(el, ".win-fullscreen").getAttribute("aria-pressed")).toBe("false");
    expect(document.activeElement).toBe(q(el, ".win-body"));
  });

  it("the titlebar button toggles, and leaves the window's own desktop geometry untouched", () => {
    mk();
    wm.setSourceSize("win:1", 600, 400);
    const el = winOf("win:1");
    const before = { w: el.style.width, h: el.style.height, l: el.style.left, t: el.style.top };
    q<HTMLButtonElement>(el, ".win-fullscreen").click();
    expect(el.style.width).toBe(before.w);               // CSS overrides it; nothing rewrites it
    q<HTMLButtonElement>(el, ".win-fullscreen").click();
    expect(root.dataset.fullscreen).toBeUndefined();
    expect({ w: el.style.width, h: el.style.height, l: el.style.left, t: el.style.top }).toEqual(before);
  });

  it("entering leaves ZOOM MODE — its button is gone with the titlebar — but keeps the view", () => {
    mk("tabbed");
    const el = winOf("win:1");
    q<HTMLButtonElement>(el, ".win-zoom").click();
    expect(el.dataset.viewMode).toBe("zoom");
    wm.setFullscreen("win:1");
    expect(el.dataset.viewMode).toBe("input");
    expect(q(el, ".win-zoom").getAttribute("aria-pressed")).toBe("false");
  });

  it("a full-screen window that goes takes the mode with it; focus moving elsewhere does not", () => {
    mk("floating", [view("win:1"), view("win:2", false)]);
    wm.setFullscreen("win:1");
    wm.sync([view("win:1", false), view("win:2", true)], new Map());
    expect(wm.fullscreenSource()).toBe("win:1");
    expect(root.dataset.fullscreen).toBe("window");
    wm.sync([view("win:2", true)], new Map());
    expect(wm.fullscreenSource()).toBeNull();
    expect(root.dataset.fullscreen).toBeUndefined();
  });

  it("moves between windows without leaving, and ignores a source it has no window for", () => {
    mk("floating", [view("win:1"), view("win:2", false)]);
    wm.setFullscreen("win:1");
    wm.setFullscreen("win:2");
    expect(winOf("win:1").classList.contains("fullscreen")).toBe(false);
    expect(winOf("win:2").classList.contains("fullscreen")).toBe(true);
    expect(root.dataset.fullscreen).toBe("window");
    wm.setFullscreen("win:nope");
    expect(wm.fullscreenSource()).toBeNull();
    expect(root.dataset.fullscreen).toBeUndefined();
  });

  it("tells the session each way — it moves `data-tab` to the window surface on the way in", () => {
    mk();
    wm.setFullscreen("win:1");
    wm.setFullscreen(null);
    expect(transitions).toEqual(["win:1", null]);
  });

  it("leaving re-pins EVERY window's controls — the hidden ones were pinned against a 0x0 box meanwhile", () => {
    mk("floating", [view("win:1"), view("win:2", false)]);
    const other = winOf("win:2");
    // An oversized window reaching 276 px past the (jsdom 1024 px) viewport, whose shift a resize during
    // full screen dropped while it was `display: none`.
    other.getBoundingClientRect = () => ({ left: 100, right: 1300, top: 0, bottom: 400, width: 1200, height: 400,
                                           x: 100, y: 0, toJSON: () => ({}) }) as DOMRect;
    wm.setFullscreen("win:1");
    q(other, ".win-controls").style.transform = "";
    wm.setFullscreen(null);
    expect(q(other, ".win-controls").style.transform).toBe(`translateX(${-(1300 - window.innerWidth)}px)`);
  });

  it("clear() leaves it, so a finished session never hides the next one's bars", () => {
    mk();
    wm.setFullscreen("win:1");
    wm.clear();
    expect(root.dataset.fullscreen).toBeUndefined();
  });

  it("a MOUSE sees Exit on the way in, loses it after the linger, and gets it back at the top edge", () => {
    vi.useFakeTimers();
    mk();
    const el = winOf("win:1");
    const move = (clientY: number, pointerType = "mouse") => {
      const e = new MouseEvent("pointermove", { clientY, bubbles: true });
      Object.defineProperty(e, "pointerType", { value: pointerType });
      document.dispatchEvent(e);
    };
    wm.setFullscreen("win:1");
    expect(el.dataset.exitShown).toBe("true");
    vi.advanceTimersByTime(2500);
    expect(el.dataset.exitShown).toBeUndefined();
    move(600);
    expect(el.dataset.exitShown).toBeUndefined();
    move(10, "touch");                                    // a finger has its own rule: always shown, in CSS
    expect(el.dataset.exitShown).toBeUndefined();
    move(10);
    expect(el.dataset.exitShown).toBe("true");
    vi.advanceTimersByTime(10_000);                       // resting at the top keeps it
    expect(el.dataset.exitShown).toBe("true");
    move(600);
    vi.advanceTimersByTime(2499);
    expect(el.dataset.exitShown).toBe("true");
    vi.advanceTimersByTime(1);
    expect(el.dataset.exitShown).toBeUndefined();
    wm.setFullscreen(null);
    move(10);
    expect(el.dataset.exitShown).toBeUndefined();         // nothing to reveal out of full screen
  });

  it("a mouse reaching the top edge while the entry linger runs keeps Exit — the linger must not fire under it", () => {
    vi.useFakeTimers();
    mk();
    const el = winOf("win:1");
    wm.setFullscreen("win:1");
    const e = new MouseEvent("pointermove", { clientY: 12, bubbles: true });
    Object.defineProperty(e, "pointerType", { value: "mouse" });
    document.dispatchEvent(e);
    vi.advanceTimersByTime(10_000);
    expect(el.dataset.exitShown).toBe("true");
  });

  it("follows the BROWSER out of its full screen, and asks it for one on the way in", async () => {
    let element: Element | null = null;
    const requestFullscreen = vi.fn(async () => { element = root; document.dispatchEvent(new Event("fullscreenchange")); });
    const undo = [
      ["fullscreenEnabled", { value: true }], ["fullscreenElement", { get: () => element }],
      ["exitFullscreen", { value: vi.fn(async () => {}) }],
    ].map(([k, d]) => { Object.defineProperty(document, k as string, { configurable: true, ...(d as object) });
                        return () => Reflect.deleteProperty(document, k as string); });
    Object.defineProperty(root, "requestFullscreen", { configurable: true, value: requestFullscreen });
    try {
      mk();
      q<HTMLButtonElement>(winOf("win:1"), ".win-fullscreen").click();
      expect(requestFullscreen).toHaveBeenCalledTimes(1);   // from inside the click — before any await
      await Promise.resolve();
      element = null;                                        // Esc: the browser leaves by itself
      document.dispatchEvent(new Event("fullscreenchange"));
      expect(wm.fullscreenSource()).toBeNull();
      expect(root.dataset.fullscreen).toBeUndefined();
    } finally {
      for (const u of undo) u();
      Reflect.deleteProperty(root, "requestFullscreen");
    }
  });

  it("scales a flick by the picture it is drawn at, on the floating layout too", () => {
    mk();
    wm.setSourceSize("win:1", 1000, 500);
    const el = winOf("win:1");
    const body = q(el, ".win-body");
    Object.defineProperty(body, "clientWidth", { value: 1600, configurable: true });
    Object.defineProperty(body, "clientHeight", { value: 1000, configurable: true });
    const video = q<HTMLVideoElement>(el, "video");
    Object.defineProperty(video, "videoWidth", { value: 2000, configurable: true });
    Object.defineProperty(video, "videoHeight", { value: 1000, configurable: true });
    const drawScale = () => (wm as unknown as { drawScale(s: string): number }).drawScale("win:1");
    wm.setFullscreen("win:1");
    // A 2:1 picture contained in 1600x1000 is 1600 wide: 1.6 CSS px per host point.
    expect(drawScale()).toBeCloseTo(1.6, 6);
    wm.setFullscreen(null);
    expect(drawScale()).not.toBeCloseTo(1.6, 2);
  });
});

describe("WindowManager positions from the session state", () => {
  const view = (source: string): WindowView => ({ source, name: source, focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 });
  let container!: HTMLElement;
  let wm!: WindowManager;
  let moved!: Array<[string, number, number]>;
  const mk = () => {
    moved = [];
    delete document.documentElement.dataset.layout;          // unset behaves as floating
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      onMoved: (s, x, y) => moved.push([s, x, y]),
      inputChannel: { send: () => {} } as unknown as RTCDataChannel, nowMs: () => 0, pc: () => undefined,
    });
  };
  afterEach(() => { wm.clear(); container.remove(); });
  const el = (s: string) => container.querySelector<HTMLElement>(`.source-window[data-source="${s}"]`)!;

  it("opens a window where the state remembers it, instead of the cascade", () => {
    mk();
    wm.setStatePositions([{ source: "win:1", x: 300, y: 200 }]);
    wm.sync([view("win:1")], new Map());
    expect(el("win:1").style.left).toBe("300px");
    expect(el("win:1").style.top).toBe("200px");
  });

  it("cascades a window the state has no position for", () => {
    mk();
    wm.setStatePositions([]);
    wm.sync([view("win:1")], new Map());
    expect(el("win:1").style.left).toBe(`${tileOffset(0).x}px`);
  });

  it("moves an open window when the STATE moves it, and never for an unchanged position", () => {
    mk();
    wm.setStatePositions([{ source: "win:1", x: 100, y: 100 }]);
    wm.sync([view("win:1")], new Map());
    el("win:1").style.left = "150px";                         // the user dragging, mid-gesture
    wm.setStatePositions([{ source: "win:1", x: 100, y: 100 }]);   // an unrelated state change: same position
    expect(el("win:1").style.left).toBe("150px");             // NOT yanked back under the finger
    wm.setStatePositions([{ source: "win:1", x: 400, y: 120 }]);   // the state moved it
    expect(el("win:1").style.left).toBe("400px");
  });

  it("clamps a remembered position onto a smaller screen", () => {
    mk();
    wm.setStatePositions([{ source: "win:1", x: 50_000, y: 40_000 }]);
    wm.sync([view("win:1")], new Map());
    expect(parseFloat(el("win:1").style.left)).toBeLessThanOrEqual(window.innerWidth - 24);
    expect(parseFloat(el("win:1").style.top)).toBeLessThanOrEqual(window.innerHeight - 24);
  });

  it("ignores positions on a pinned layout, where CSS owns the frame", () => {
    mk();
    document.documentElement.dataset.layout = "tabbed";
    wm.setStatePositions([{ source: "win:1", x: 300, y: 200 }]);
    wm.sync([view("win:1")], new Map());
    expect(el("win:1").style.left).not.toBe("300px");
    delete document.documentElement.dataset.layout;
  });

  it("reports the end of a titlebar drag once, with where the window landed", () => {
    mk();
    wm.sync([view("win:1")], new Map());
    const bar = el("win:1").querySelector<HTMLElement>(".win-titlebar")!;
    bar.setPointerCapture = () => {}; bar.releasePointerCapture = () => {};
    let x = 100;
    Object.defineProperty(el("win:1"), "getBoundingClientRect", { configurable: true,
      value: () => ({ left: x, top: 80, width: 300, height: 200, right: x + 300, bottom: 280, x, y: 80, toJSON: () => ({}) }) });
    // jsdom has NO PointerEvent: a MouseEvent under the pointer type's name carries clientX/Y, which
    // is all the drag reads (pointerId is undefined, and the capture calls are stubbed above).
    bar.dispatchEvent(new MouseEvent("pointerdown", { clientX: 10, clientY: 10, bubbles: true }));
    bar.dispatchEvent(new MouseEvent("pointermove", { clientX: 60, clientY: 30 }));
    x = 150;                                                   // jsdom has no layout: the rect follows the write
    bar.dispatchEvent(new MouseEvent("pointerup", { clientX: 60, clientY: 30 }));
    expect(moved).toEqual([["win:1", 150, 80]]);
  });
});

describe("WindowManager full screen from the session state", () => {
  it("applies the mode WITHOUT asking the browser (or the app) for its full screen", () => {
    const container = document.createElement("div");
    document.body.append(container);
    const asked: string[] = [];
    const real = document.documentElement.requestFullscreen;
    Object.defineProperty(document, "fullscreenEnabled", { configurable: true, value: true });
    document.documentElement.requestFullscreen = (() => { asked.push("root"); return Promise.resolve(); }) as typeof real;
    const wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel, nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([{ source: "win:1", name: "w", focused: true, fps: 60, scale: 1, bitrateBps: 2_000_000 }], new Map());
    expect(wm.hasWindow("win:1")).toBe(true);
    wm.setFullscreen("win:1", { browser: false });
    expect(document.documentElement.dataset.fullscreen).toBe("window");
    expect(asked).toEqual([]);                                 // a restore is not a click
    wm.setFullscreen(null);
    wm.clear(); container.remove();
    document.documentElement.requestFullscreen = real;
  });
});

// Closing or parking the window that has the KEYS hands them to the window the host focuses next — the
// one before it (`SessionState.focused`) — as closing the terminal tab being typed into does
// (`TermDeck.close`). The picture only took keyboard focus on a press, so the keys fell to <body>, where
// no key reaches the Mac, and a press on × or − itself must not move them: Chromium focused the button
// and took them from the terminal.
describe("WindowManager: the keys after a window goes", () => {
  let container!: HTMLElement;
  let wm!: WindowManager;
  const view = (source: string, focused: boolean): WindowView => ({
    source, name: source, focused, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto",
  });
  const mk = (views: WindowView[]) => {
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: () => {}, onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync(views, new Map());
  };
  const winOf = (source: string) => [...container.querySelectorAll<HTMLElement>(".source-window")]
    .find((el) => el.querySelector(".win-settings")?.getAttribute("data-source") === source)!;
  const bodyOf = (source: string) => winOf(source).querySelector<HTMLElement>(".win-body")!;

  afterEach(() => {
    wm.clear();
    container.remove();
    (document.activeElement as HTMLElement | null)?.blur?.();
  });

  it("closing the window with the keys hands them to the window the host focuses next", () => {
    mk([view("win:1", false), view("win:2", true), view("win:3", false)]);
    bodyOf("win:2").focus();
    wm.sync([view("win:1", true), view("win:3", false)], new Map());          // × on win:2: focus fell before it
    expect(document.activeElement).toBe(bodyOf("win:1"));
  });

  it("parking it does the same (a minimized window leaves the view too)", () => {
    mk([view("win:1", false), view("win:2", true)]);
    bodyOf("win:2").focus();
    wm.sync([view("win:1", true)], new Map());
    expect(document.activeElement).toBe(bodyOf("win:1"));
  });

  it("a window that goes WITHOUT the keys takes nothing: the terminal keeps them", () => {
    mk([view("win:1", false), view("win:2", true)]);
    const terminal = document.createElement("textarea");
    document.body.append(terminal);
    terminal.focus();
    wm.sync([view("win:1", true)], new Map());
    expect(document.activeElement).toBe(terminal);
    terminal.remove();
  });

  it("the last window going leaves the keys nowhere to go, and nothing throws", () => {
    mk([view("win:1", true)]);
    bodyOf("win:1").focus();
    expect(() => wm.sync([], new Map())).not.toThrow();
    expect(container.querySelectorAll(".source-window")).toHaveLength(0);
  });

  // On a phone the keys are the window's hidden INPUT, and the soft keyboard is up: they go to the next
  // window's input (the keyboard stays), and the window leaving is removed only AFTER — a focused element
  // removed first sends focus through <body>, and iOS drops the keyboard.
  it("on a touch device the hidden input's keys go to the next window's input, before the old one leaves", () => {
    const orig = (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia;
    (window as unknown as { matchMedia: unknown }).matchMedia = (q: string) => ({
      matches: q.includes("any-pointer: coarse"), media: q,
      addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, dispatchEvent: () => false,
    });
    try {
      mk([view("win:1", false), view("win:2", true)]);
      const input = winOf("win:2").querySelector<HTMLInputElement>(".win-key-input")!;
      input.focus();
      const leaving = winOf("win:2");
      let heldWhenRemoved: boolean | null = null;
      const remove = leaving.remove.bind(leaving);
      leaving.remove = () => { heldWhenRemoved ??= leaving.contains(document.activeElement); remove(); };   // the FIRST removal
      // ITS INPUT TOO: the window's keyboard is torn down with it, and an input removed while focused sent
      // focus through <body> before the hand-off ran (measured in Chromium: `focusout` → null, then the next).
      let inputHeldWhenRemoved: boolean | null = null;
      const removeInput = input.remove.bind(input);
      input.remove = () => { inputHeldWhenRemoved ??= document.activeElement === input; removeInput(); };
      wm.sync([view("win:1", true)], new Map());
      expect(document.activeElement).toBe(winOf("win:1").querySelector(".win-key-input"));
      expect(heldWhenRemoved).toBe(false);
      expect(inputHeldWhenRemoved).toBe(false);
    } finally {
      (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia = orig;
    }
  });

  // THE HOST LANDED THE PERSON ON A TERMINAL TAB (`SessionState.landing`): the keys go where the caller says
  // — the terminal — and not to the next window, whose surface a phone no longer shows. Typing or not is
  // passed on (the terminal decides), and the window still leaves only AFTER the keys did.
  it("with a landing, the keys go where it says instead of to the next window, before the window leaves", () => {
    mk([view("win:1", false), view("win:2", true)]);
    bodyOf("win:2").focus();
    const terminal = document.createElement("textarea");
    document.body.append(terminal);
    const leaving = winOf("win:2");
    let typed: boolean | null = null;
    let inPageWhenHanded: boolean | null = null;
    wm.sync([view("win:1", true)], new Map(), (typing) => {
      typed = typing;
      inPageWhenHanded = leaving.isConnected;
      terminal.focus();
    });
    expect(typed).toBe(false);
    expect(inPageWhenHanded).toBe(true);
    expect(document.activeElement).toBe(terminal);
    expect(leaving.isConnected).toBe(false);
    terminal.remove();
  });

  it("a landing the terminal declines leaves the keys to no window", () => {
    mk([view("win:1", false), view("win:2", true)]);
    bodyOf("win:2").focus();
    wm.sync([view("win:1", true)], new Map(), () => {});
    expect(document.activeElement).not.toBe(bodyOf("win:1"));
  });

  it("a landing with no keys to carry asks nothing", () => {
    mk([view("win:1", false), view("win:2", true)]);
    let asked = false;
    wm.sync([view("win:1", true)], new Map(), () => { asked = true; });
    expect(asked).toBe(false);
  });

  // WHAT A CLOSE SAYS AS `land` (personAtWindow): floating, the window holding the keys; pinned, the window on
  // screen — the review's desktop case is the floating one: focused, but the keys in the terminal.
  it("personAt: floating, only the window holding the keys", () => {
    mk([view("win:1", false), view("win:2", true)]);
    expect(wm.personAt("win:2", true)).toBe(false);                     // focused, keys elsewhere
    bodyOf("win:2").focus();
    expect(wm.personAt("win:2", true)).toBe(true);
    expect(wm.personAt("win:2", false)).toBe(true);                     // the surface means nothing here
    expect(wm.personAt("win:1", true)).toBe(false);
    expect(wm.personAt("win:9", true)).toBe(false);                     // no such window
  });

  it("personAt: pinned, the focused window while the windows surface shows", () => {
    document.documentElement.dataset.layout = "tabbed";
    try {
      mk([view("win:1", false), view("win:2", true)]);
      expect(wm.personAt("win:2", true)).toBe(true);
      expect(wm.personAt("win:2", false)).toBe(false);
      expect(wm.personAt("win:1", true)).toBe(false);
    } finally {
      delete document.documentElement.dataset.layout;
    }
  });

  it("a press on × or − moves no focus by itself", () => {
    mk([view("win:1", true)]);
    for (const sel of [".win-close", ".win-minimize"]) {
      const e = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
      winOf("win:1").querySelector(sel)!.dispatchEvent(e);
      expect(e.defaultPrevented, sel).toBe(true);
    }
  });
});

/// PASTE INTO A WINDOW (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §1, §2.2, §2.5, §5): a held
/// finger or a right-click on the TITLEBAR opens the window's paste menu — never on one of its controls —
/// full screen's ⌨ does when there is no titlebar, and a drop on the PICTURE goes to the host at its point,
/// normalized against the picture exactly as a touch is.
describe("WindowManager paste — the titlebar's menu, full screen's ⌨, drops at the point", () => {
  const root = document.documentElement;
  let container!: HTMLElement;
  let wm!: WindowManager;
  let menus!: Array<[string, { x: number; y: number }]>;
  let drops!: Array<[string, { x: number; y: number }, DataTransfer | null]>;
  let focused!: string[];
  let moved!: Array<[string, number, number]>;
  let may = true;
  const view = (source: string, isFocused: boolean): WindowView => ({
    source, name: source, focused: isFocused, fps: 60, scale: 1, bitrateBps: 2_000_000, codec: "auto",
  });
  const mk = (layout: "floating" | "tabbed" = "floating") => {
    root.dataset.layout = layout;
    menus = []; drops = []; focused = []; moved = []; may = true;
    container = document.createElement("div");
    document.body.append(container);
    wm = new WindowManager(container, {
      onFocus: (s) => focused.push(s), onClose: () => {}, onMinimize: () => {}, onPrefs: () => {},
      onRecovery: () => {}, onPlayoutDelay: () => {}, onResize: () => {},
      onMoved: (s, x, y) => moved.push([s, x, y]),
      canPaste: () => may,
      onWindowMenu: (s, at) => menus.push([s, at]),
      onWindowDrop: (s, at, dt) => drops.push([s, at, dt]),
      inputChannel: { send: () => {} } as unknown as RTCDataChannel,
      nowMs: () => 0, pc: () => undefined,
    });
    wm.sync([view("win:1", true), view("win:2", false)], new Map());
    // The floating drag captures the pointer on a titlebar press, and jsdom's HTMLElement has neither call.
    for (const bar of container.querySelectorAll<HTMLElement>(".win-titlebar")) {
      bar.setPointerCapture = () => {}; bar.releasePointerCapture = () => {};
    }
  };
  const winOf = (source: string) => container.querySelector<HTMLElement>(`.source-window[data-source="${source}"]`)!;
  const barOf = (source: string) => winOf(source).querySelector<HTMLElement>(".win-titlebar")!;
  /// jsdom has no PointerEvent: a MouseEvent of the pointer type (press-hold.test.ts).
  const ptr = (type: string, x: number, y: number, pointerType = "touch") => {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
    for (const [k, v] of Object.entries({ pointerId: 4, pointerType, isPrimary: true })) Object.defineProperty(e, k, { value: v });
    return e as PointerEvent;
  };
  const hold = (el: Element, x = 40, y = 12) => {
    el.dispatchEvent(ptr("pointerdown", x, y));
    vi.advanceTimersByTime(HOLD_MS);
    window.dispatchEvent(ptr("pointerup", x, y));
  };
  const contextMenu = (el: Element, x: number, y: number) => {
    const e = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 });
    el.dispatchEvent(e);
    return e;
  };
  /// A DataTransfer as a drop carries it (paste-ui.test.ts), and a drag event carrying it — jsdom has no
  /// DragEvent, so a MouseEvent under the drag type's name with the field on it.
  const transfer = (files: File[]) =>
    ({ files, types: files.length ? ["Files"] : [], dropEffect: "none", getData: () => "" }) as unknown as DataTransfer;
  const drag = (el: Element, type: string, o: { x?: number; y?: number; dt?: DataTransfer | null; related?: Element | null } = {}) => {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: o.x ?? 0, clientY: o.y ?? 0, relatedTarget: o.related ?? null });
    Object.defineProperty(e, "dataTransfer", { value: o.dt === undefined ? transfer([new File([new Uint8Array(3)], "a.png", { type: "image/png" })]) : o.dt });
    el.dispatchEvent(e);
    return e;
  };
  /// A LETTERBOXED picture: a 16:9 stream in a tall 420x646 body at (100, 50) — the picture is 420x236.25,
  /// 204.875 px down — exactly the box the view-zoom tests use (jsdom has no layout, so both are stubbed).
  const letterbox = (source: string) => {
    const body = winOf(source).querySelector<HTMLElement>(".win-body")!;
    Object.defineProperty(body, "clientWidth", { value: 420, configurable: true });
    Object.defineProperty(body, "clientHeight", { value: 646, configurable: true });
    body.getBoundingClientRect = () => ({ left: 100, top: 50, width: 420, height: 646,
      right: 520, bottom: 696, x: 100, y: 50, toJSON: () => ({}) }) as DOMRect;
    const video = body.querySelector("video")!;
    Object.defineProperty(video, "videoWidth", { value: 1600, configurable: true });
    Object.defineProperty(video, "videoHeight", { value: 900, configurable: true });
    return { body, video };
  };
  /// `matchMedia` is undefined in this jsdom by default, so no on-screen keyboard mounts unless stubbed.
  const coarse = (): (() => void) => {
    const orig = (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia;
    (window as unknown as { matchMedia: unknown }).matchMedia = (q: string) => ({
      matches: q.includes("any-pointer: coarse"), media: q,
      addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, dispatchEvent: () => false,
    });
    return () => { (window as unknown as { matchMedia?: typeof window.matchMedia }).matchMedia = orig; };
  };

  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => {
    wm.clear();
    container.remove();
    delete root.dataset.layout;
    delete root.dataset.fullscreen;
    vi.useRealTimers();
    (document.activeElement as HTMLElement | null)?.blur?.();
  });

  it("a 500 ms touch hold on the title opens the menu for THAT window, at the finger", () => {
    mk();
    hold(winOf("win:1").querySelector(".win-title")!, 40, 12);
    expect(menus).toEqual([["win:1", { x: 40, y: 12 }]]);
  });

  it("a hold on an UNFOCUSED window's titlebar still focuses it, and the menu targets it", () => {
    mk();
    hold(winOf("win:2").querySelector(".win-title")!, 60, 58);
    expect(focused).toEqual(["win:2"]);
    expect(menus).toEqual([["win:2", { x: 60, y: 58 }]]);
  });

  it("a hold on one of the titlebar's controls is that control's, and a hold on a select is the select's", () => {
    mk();
    for (const sel of [".win-fit", ".win-zoom", ".win-close", ".win-gear"]) hold(winOf("win:1").querySelector(sel)!);
    // The settings panel covers its window (inset 0), titlebar included: a held finger on its select is
    // the select's, never the menu's.
    hold(winOf("win:1").querySelector(".win-settings select")!);
    expect(menus).toEqual([]);
  });

  it("a mouse never holds — it right-clicks: the menu opens at the pointer and the browser's own is prevented", () => {
    mk();
    const bar = barOf("win:1");
    bar.dispatchEvent(ptr("pointerdown", 40, 12, "mouse"));
    vi.advanceTimersByTime(HOLD_MS * 2);
    bar.dispatchEvent(ptr("pointerup", 40, 12, "mouse"));
    expect(menus).toEqual([]);
    const e = contextMenu(winOf("win:1").querySelector(".win-title")!, 140, 20);
    expect(e.defaultPrevented).toBe(true);
    expect(menus).toEqual([["win:1", { x: 140, y: 20 }]]);
  });

  it("a right-click on a titlebar BUTTON is not taken: no menu, the browser's own stays", () => {
    mk();
    for (const sel of [".win-fit", ".win-close"]) {
      const e = contextMenu(winOf("win:1").querySelector(sel)!, 300, 12);
      expect(e.defaultPrevented, sel).toBe(false);
    }
    expect(menus).toEqual([]);
  });

  it("a client that may not paste opens nothing — no hold, no right-click, no drop", () => {
    mk();
    may = false;
    hold(winOf("win:1").querySelector(".win-title")!);
    expect(contextMenu(winOf("win:1").querySelector(".win-title")!, 140, 20).defaultPrevented).toBe(false);
    const { body } = letterbox("win:1");
    expect(drag(body, "dragover", { x: 300, y: 300 }).defaultPrevented).toBe(false);
    expect(winOf("win:1").classList.contains("drop-target")).toBe(false);
    expect(drag(body, "drop", { x: 300, y: 300 }).defaultPrevented).toBe(false);
    expect(menus).toEqual([]);
    expect(drops).toEqual([]);
  });

  // THE DRAG IS THE TITLEBAR'S TOO (floating layout): until the hold it moves the window — within the slop
  // at most — and once the menu is open the rest of the gesture is the menu's.
  it("a hold that opened the menu neither continues the window drag nor leaves it moved past the slop", () => {
    mk();
    const bar = barOf("win:1");
    const el = winOf("win:1");
    // jsdom has no layout: the window's rect follows what the drag writes.
    el.style.left = "100px"; el.style.top = "80px";
    Object.defineProperty(el, "getBoundingClientRect", { configurable: true, value: () => {
      const x = parseFloat(el.style.left), y = parseFloat(el.style.top);
      return { left: x, top: y, width: 300, height: 200, right: x + 300, bottom: y + 200, x, y, toJSON: () => ({}) };
    } });
    bar.dispatchEvent(ptr("pointerdown", 140, 92));
    bar.dispatchEvent(ptr("pointermove", 144, 95));            // inside the slop: still a press
    vi.advanceTimersByTime(HOLD_MS);
    expect(menus).toEqual([["win:1", { x: 140, y: 92 }]]);
    const after = { left: el.style.left, top: el.style.top };
    expect(Math.abs(parseFloat(after.left) - 100)).toBeLessThanOrEqual(TOUCH_SLOP_PX);
    expect(Math.abs(parseFloat(after.top) - 80)).toBeLessThanOrEqual(TOUCH_SLOP_PX);
    // Pointer capture retargets every later move at the titlebar itself — where the drag listens.
    bar.dispatchEvent(ptr("pointermove", 400, 300));
    expect({ left: el.style.left, top: el.style.top }).toEqual(after);
    bar.dispatchEvent(ptr("pointerup", 400, 300));
    expect(moved).toHaveLength(1);                        // the in-slop move, reported once at the end
    for (const [, x, y] of moved) {
      expect(Math.abs(x - 100)).toBeLessThanOrEqual(TOUCH_SLOP_PX);
      expect(Math.abs(y - 80)).toBeLessThanOrEqual(TOUCH_SLOP_PX);
    }
  });

  it("a drop on a LETTERBOXED picture goes at its point on the PICTURE, not the body", () => {
    mk();
    const { body } = letterbox("win:1");
    const dt = transfer([new File([new Uint8Array(3)], "a.png", { type: "image/png" })]);
    // A quarter of the way across the picture and three quarters down it — not of the body.
    const e = drag(body, "drop", { x: 100 + 420 * 0.25, y: 50 + 204.875 + 236.25 * 0.75, dt });
    expect(e.defaultPrevented).toBe(true);             // or the session's document-level refusal takes it
    expect(drops).toHaveLength(1);
    const [source, at, got] = drops[0]!;
    expect(source).toBe("win:1");
    expect(at.x).toBeCloseTo(0.25, 6);
    expect(at.y).toBeCloseTo(0.75, 6);
    expect(got).toBe(dt);
  });

  it("a drop in the letterbox's bar lands on the picture's edge", () => {
    mk();
    const { body } = letterbox("win:1");
    drag(body, "drop", { x: 310, y: 60 });
    expect(drops[0]![1]).toEqual({ x: 0.5, y: 0 });
  });

  it("an UNFOCUSED window's picture takes a drop too — for itself", () => {
    mk();
    const { video } = letterbox("win:2");
    drag(video, "drop", { x: 310, y: 371 });
    expect(drops.map((d) => d[0])).toEqual(["win:2"]);
  });

  it("dragover marks the window and asks for a copy; leaving the body or dropping unmarks it", () => {
    mk();
    const { body, video } = letterbox("win:1");
    const el = winOf("win:1");
    const dt = transfer([new File([new Uint8Array(3)], "a.png", { type: "image/png" })]);
    const over = drag(video, "dragover", { x: 300, y: 300, dt });
    expect(over.defaultPrevented).toBe(true);
    expect(dt.dropEffect).toBe("copy");
    expect(el.classList.contains("drop-target")).toBe(true);
    // Moving between the body and its own picture is not leaving.
    drag(body, "dragleave", { x: 300, y: 300, related: video });
    expect(el.classList.contains("drop-target")).toBe(true);
    drag(video, "dragleave", { x: 600, y: 300, related: document.body });
    expect(el.classList.contains("drop-target")).toBe(false);
    drag(video, "dragover", { x: 300, y: 300 });
    expect(el.classList.contains("drop-target")).toBe(true);
    drag(video, "drop", { x: 300, y: 300 });
    expect(el.classList.contains("drop-target")).toBe(false);
  });

  it("in FULL SCREEN a hold on the key strip's ⌨ opens THAT window's menu, and swallows its toggle", () => {
    const restore = coarse();
    try {
      mk();
      wm.setFullscreen("win:1");
      const el = winOf("win:1");
      const input = el.querySelector<HTMLInputElement>(".win-key-input")!;
      const kbd = el.querySelector<HTMLElement>('[data-key-id="kbd"]')!;
      hold(kbd, 30, 700);
      kbd.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      expect(menus).toEqual([["win:1", { x: 30, y: 700 }]]);
      expect(document.activeElement).not.toBe(input);
    } finally { restore(); }
  });

  it("out of full screen, or for a client that may not paste, ⌨ is only the keyboard toggle", () => {
    const restore = coarse();
    try {
      mk();
      const el = winOf("win:1");
      const input = el.querySelector<HTMLInputElement>(".win-key-input")!;
      const kbd = el.querySelector<HTMLElement>('[data-key-id="kbd"]')!;
      hold(kbd, 30, 700);
      kbd.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      expect(document.activeElement).toBe(input);
      input.blur();
      may = false;
      wm.setFullscreen("win:1");
      hold(kbd, 30, 700);
      kbd.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      expect(document.activeElement).toBe(input);
      expect(menus).toEqual([]);
    } finally { restore(); }
  });

  // NO LEAK PER WINDOW: the hold listens on `window` (a finger's moves and release land anywhere), so a
  // window opened and closed a hundred times in one session must not leave a hundred sets behind.
  it("every page-level listener a window adds goes with the window — closed, or cleared with the session", () => {
    const signals: AbortSignal[] = [];
    const add = window.addEventListener.bind(window);
    const spy = vi.spyOn(window, "addEventListener").mockImplementation(((type: string, l: EventListenerOrEventListenerObject, o?: boolean | AddEventListenerOptions) => {
      if (typeof o === "object" && o.signal) signals.push(o.signal);
      add(type, l, o);
    }) as typeof window.addEventListener);
    try {
      mk();
      const constructed = signals.length;
      expect(constructed).toBeGreaterThan(0);              // the manager's own page listeners are counted too…
      wm.sync([view("win:1", true), view("win:2", false), view("win:3", false)], new Map());
      const win3 = signals.slice(constructed);
      expect(win3.length).toBeGreaterThan(0);              // …and the new window's are what is asserted on
      wm.sync([view("win:1", true), view("win:2", false)], new Map());
      expect(win3.every((s) => s.aborted)).toBe(true);
      wm.clear();
      expect(signals.every((s) => s.aborted)).toBe(true);
    } finally { spy.mockRestore(); }
  });
});
