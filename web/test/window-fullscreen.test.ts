import { describe, it, expect, vi, afterEach } from "vitest";
import {
  EXIT_REVEAL_PX, exitRevealed, isAppleTouch, wantsBrowserFullscreen, attachBrowserFullscreen,
} from "../src/client/window-fullscreen";

const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1";
/// iPadOS asks for the DESKTOP site by default, so its UA is a Mac's.
const IPAD_DESKTOP = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Safari/605.1.15";
const MAC_CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const ANDROID = "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36";

describe("exitRevealed", () => {
  it("brings a mouse's Exit back at the top edge, the button itself included", () => {
    expect(exitRevealed(0)).toBe(true);
    expect(exitRevealed(44)).toBe(true);          // the button's own bottom edge (top 8 + 36)
    expect(exitRevealed(EXIT_REVEAL_PX)).toBe(true);
    expect(exitRevealed(EXIT_REVEAL_PX + 1)).toBe(false);
  });
});

describe("isAppleTouch", () => {
  it("is an iPhone, and an iPad asking for the desktop site", () => {
    expect(isAppleTouch(IPHONE, 5)).toBe(true);
    expect(isAppleTouch(IPAD_DESKTOP, 5)).toBe(true);
  });
  it("is not a Mac, whose UA is the iPad's but has no touch points, nor Android", () => {
    expect(isAppleTouch(IPAD_DESKTOP, 0)).toBe(false);
    expect(isAppleTouch(MAC_CHROME, 0)).toBe(false);
    expect(isAppleTouch(ANDROID, 5)).toBe(false);
  });
});

describe("wantsBrowserFullscreen", () => {
  it("asks wherever the browser offers it, except on an iPhone or iPad", () => {
    expect(wantsBrowserFullscreen({ enabled: true, appleTouch: false })).toBe(true);
    expect(wantsBrowserFullscreen({ enabled: true, appleTouch: true })).toBe(false);
    expect(wantsBrowserFullscreen({ enabled: false, appleTouch: false })).toBe(false);
  });
});

/// Replace a property for one test, restoring the ORIGINAL descriptor — jsdom's own, when it has one.
function stub(target: object, key: string, desc: PropertyDescriptor): () => void {
  const before = Object.getOwnPropertyDescriptor(target, key);
  Object.defineProperty(target, key, { configurable: true, ...desc });
  return () => { if (before) Object.defineProperty(target, key, before); else Reflect.deleteProperty(target, key); };
}

/// A browser with the Fullscreen API and Keyboard Lock, which jsdom has neither of. `settle` decides
/// how the next request ends; `fullscreenElement` follows it, and each change fires `fullscreenchange`
/// the way a browser does.
function fakeBrowser(opts: { enabled?: boolean; ua?: string; touchPoints?: number } = {}) {
  let element: Element | null = null;
  let pending: { resolve(): void; reject(e: Error): void } | null = null;
  const change = (el: Element | null) => { element = el; document.dispatchEvent(new Event("fullscreenchange")); };
  const root = document.documentElement;
  const requestFullscreen = vi.fn(() => new Promise<void>((resolve, reject) => {
    pending = { resolve: () => { change(root); resolve(); }, reject };
  }));
  const exitFullscreen = vi.fn(async () => { change(null); });
  const keyboard = { lock: vi.fn(async (_codes?: string[]) => {}), unlock: vi.fn() };
  const undo = [
    stub(document, "fullscreenEnabled", { value: opts.enabled ?? true }),
    stub(document, "fullscreenElement", { get: () => element }),
    stub(document, "exitFullscreen", { value: exitFullscreen }),
    stub(root, "requestFullscreen", { value: requestFullscreen }),
    stub(navigator, "keyboard", { value: keyboard }),
    stub(navigator, "userAgent", { value: opts.ua ?? MAC_CHROME }),
    stub(navigator, "maxTouchPoints", { value: opts.touchPoints ?? 0 }),
  ];
  return {
    requestFullscreen, exitFullscreen, keyboard,
    grant: async () => { pending?.resolve(); pending = null; await Promise.resolve(); await Promise.resolve(); },
    refuse: async () => { pending?.reject(new Error("no activation")); pending = null; await Promise.resolve(); await Promise.resolve(); },
    /// The user pressing Esc (or holding it, or the browser's own control): the browser leaves by itself.
    userLeaves: () => change(null),
    /// Something else put the page full screen (F11 is not an element; the app's green button is not either,
    /// but a page script could be).
    alreadyFullscreen: () => { element = root; },
    restore: () => { for (const u of undo.reverse()) u(); },
  };
}

describe("attachBrowserFullscreen", () => {
  let restore: (() => void) | undefined;
  let controller: AbortController | undefined;
  afterEach(() => { controller?.abort(); restore?.(); restore = undefined; });

  const attach = (b: ReturnType<typeof fakeBrowser>) => {
    restore = b.restore;
    controller = new AbortController();
    const onLeft = vi.fn();
    return { fs: attachBrowserFullscreen({ onLeft, signal: controller.signal }), onLeft };
  };

  it("asks for the ROOT, hiding the navigation UI, and hands Esc to the page once it is granted", async () => {
    const b = fakeBrowser();
    const { fs } = attach(b);
    fs.enter();
    expect(b.requestFullscreen).toHaveBeenCalledWith({ navigationUI: "hide" });
    expect(b.keyboard.lock).not.toHaveBeenCalled();      // not before the browser has said yes
    await b.grant();
    expect(document.fullscreenElement).toBe(document.documentElement);
    expect(b.keyboard.lock).toHaveBeenCalledWith(["Escape"]);
  });

  it("gives back only what it asked for, and releases Esc", async () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    fs.enter();
    await b.grant();
    fs.exit();
    expect(b.exitFullscreen).toHaveBeenCalledTimes(1);
    expect(b.keyboard.unlock).toHaveBeenCalled();
    expect(onLeft).not.toHaveBeenCalled();                // leaving by our own hand is not the browser leaving
  });

  it("follows the browser out: Esc, a held Esc or its own control reports onLeft, once", async () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    fs.enter();
    await b.grant();
    b.userLeaves();
    expect(onLeft).toHaveBeenCalledTimes(1);
    expect(b.keyboard.unlock).toHaveBeenCalled();
    fs.exit();                                            // the page's own exit, arriving after: nothing left to give back
    expect(b.exitFullscreen).not.toHaveBeenCalled();
    b.userLeaves();
    expect(onLeft).toHaveBeenCalledTimes(1);
  });

  it("asks nothing where the browser offers no full screen", () => {
    const b = fakeBrowser({ enabled: false });
    const { fs } = attach(b);
    fs.enter();
    expect(b.requestFullscreen).not.toHaveBeenCalled();
  });

  it("asks nothing on an iPhone or an iPad, whose page keeps its own full screen", () => {
    const b = fakeBrowser({ ua: IPAD_DESKTOP, touchPoints: 5 });
    const { fs } = attach(b);
    fs.enter();
    expect(b.requestFullscreen).not.toHaveBeenCalled();
  });

  it("leaves a full screen it did not ask for alone — neither takes it over nor gives it back", () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    b.alreadyFullscreen();
    fs.enter();
    expect(b.requestFullscreen).not.toHaveBeenCalled();
    fs.exit();
    expect(b.exitFullscreen).not.toHaveBeenCalled();
    b.userLeaves();
    expect(onLeft).not.toHaveBeenCalled();
  });

  it("a REFUSED request leaves the page's mode on its own, and nothing to give back", async () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    fs.enter();
    await b.refuse();
    expect(b.keyboard.lock).not.toHaveBeenCalled();
    fs.exit();
    expect(b.exitFullscreen).not.toHaveBeenCalled();
    expect(onLeft).not.toHaveBeenCalled();
  });

  it("given back while the request was in flight, it leaves the moment the browser arrives", async () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    fs.enter();
    fs.exit();                                            // before the browser answered
    expect(b.exitFullscreen).not.toHaveBeenCalled();      // nothing to leave yet
    await b.grant();
    expect(b.exitFullscreen).toHaveBeenCalledTimes(1);
    expect(b.keyboard.lock).not.toHaveBeenCalled();
    expect(onLeft).not.toHaveBeenCalled();
    expect(document.fullscreenElement).toBeNull();
  });

  it("stops listening when its signal aborts", async () => {
    const b = fakeBrowser();
    const { fs, onLeft } = attach(b);
    fs.enter();
    await b.grant();
    controller!.abort();
    b.userLeaves();
    expect(onLeft).not.toHaveBeenCalled();
  });
});

/// The native app's client window: `__rdevShell` puts the WINDOW full screen, and says so when the person
/// takes it back out (`app/Core/FullScreenOwnership.swift` decides what is the page's to give back).
describe("attachBrowserFullscreen in the Mac app", () => {
  let undo: Array<() => void> = [];
  let controller: AbortController | undefined;
  afterEach(() => { controller?.abort(); for (const u of undo.reverse()) u(); undo = []; });

  const inApp = () => {
    const left = new Set<() => void>();
    const shell = {
      setFullscreen: vi.fn(async (_on: boolean) => {}),
      onFullscreenLeft: vi.fn((cb: () => void) => { left.add(cb); return () => { left.delete(cb); }; }),
    };
    // A browser full screen is ALSO on offer there (WebKit's), and must not be the one asked for.
    const b = fakeBrowser();
    undo.push(b.restore, stub(globalThis, "__rdevShell", { value: shell }));
    controller = new AbortController();
    const onLeft = vi.fn();
    const fs = attachBrowserFullscreen({ onLeft, signal: controller.signal });
    return { fs, onLeft, shell, b, personLeaves: () => { for (const cb of [...left]) cb(); }, listeners: () => left.size };
  };

  it("asks the APP for its window's full screen, never WebKit's", () => {
    const { fs, shell, b } = inApp();
    fs.enter();
    expect(shell.setFullscreen).toHaveBeenCalledWith(true);
    expect(b.requestFullscreen).not.toHaveBeenCalled();
    fs.exit();
    expect(shell.setFullscreen).toHaveBeenLastCalledWith(false);
  });

  it("follows the person out (the green button, ⌃⌘F) once, and gives nothing back after", () => {
    const { fs, onLeft, shell, personLeaves } = inApp();
    fs.enter();
    personLeaves();
    expect(onLeft).toHaveBeenCalledTimes(1);
    fs.exit();
    expect(shell.setFullscreen).toHaveBeenCalledTimes(1);   // the enter only
    personLeaves();
    expect(onLeft).toHaveBeenCalledTimes(1);
  });

  it("gives back nothing it never asked for, and ignores a leave it did not ask for", () => {
    const { fs, onLeft, shell, personLeaves } = inApp();
    fs.exit();
    personLeaves();
    expect(shell.setFullscreen).not.toHaveBeenCalled();
    expect(onLeft).not.toHaveBeenCalled();
  });

  it("stops listening when its signal aborts", () => {
    const { fs, onLeft, personLeaves, listeners } = inApp();
    fs.enter();
    controller!.abort();
    expect(listeners()).toBe(0);
    personLeaves();
    expect(onLeft).not.toHaveBeenCalled();
  });
});
