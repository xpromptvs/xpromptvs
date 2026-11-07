import { beforeEach, describe, expect, it, vi } from "vitest";
import { captureSessionDom } from "../src/client/session-dom";

const MARKUP = `<div id="session"><header id="tabbar"><button id="session-disconnect">×</button></header>`
             + `<main id="stage"><div id="windows"></div></main></div>`;
const root = (): HTMLElement => document.getElementById("session")!;

beforeEach(() => {
  document.body.innerHTML = MARKUP;
  document.documentElement.dataset.tab = "terminal";
  document.documentElement.dataset.keystrip = "expanded";
  Reflect.deleteProperty(window, "ShellstormMotion");
});

describe("captureSessionDom", () => {
  it("takes the markup OUT at capture — nothing can bind to it before a session exists", () => {
    captureSessionDom(root());
    expect(root().childElementCount).toBe(0);
    expect(document.getElementById("stage")).toBeNull();
  });

  it("mount puts back a FRESH copy each time: a listener bound in one session dies with it", () => {
    const dom = captureSessionDom(root());
    dom.mount();
    const first = document.getElementById("session-disconnect")!;
    const click = vi.fn();
    first.addEventListener("click", click);
    dom.unmount();
    dom.mount();
    const second = document.getElementById("session-disconnect")!;
    expect(second).not.toBe(first);
    second.click();
    expect(click).not.toHaveBeenCalled();
    expect(document.querySelectorAll("#stage")).toHaveLength(1);
    expect(dom.mounted).toBe(true);
  });

  it("mount resets the root attributes a session writes", () => {
    const dom = captureSessionDom(root());
    dom.mount();
    expect(document.documentElement.dataset.tab).toBe("sim");
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
  });

  it("unmount empties #session and resets its motion state and the root attributes", () => {
    const dom = captureSessionDom(root());
    dom.mount();
    root().inert = true;
    root().classList.add("ss-session-pending", "ss-session-moving");
    root().dataset.ready = "true";
    document.documentElement.dataset.tab = "terminal";
    document.documentElement.dataset.keystrip = "expanded";
    dom.unmount();
    expect(root().childElementCount).toBe(0);
    expect(root().inert).toBe(false);
    expect(root().classList.contains("ss-session-pending")).toBe(false);
    expect(root().classList.contains("ss-session-moving")).toBe(false);
    expect(root().dataset.ready).toBeUndefined();
    expect(document.documentElement.dataset.tab).toBe("sim");
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
    expect(dom.mounted).toBe(false);
  });

  it("mount asks motion.js to resync — it binds to markup once, and this markup is new", () => {
    const resync = vi.fn();
    (window as { ShellstormMotion?: unknown }).ShellstormMotion = { resync };
    const dom = captureSessionDom(root());
    dom.mount();
    expect(resync).toHaveBeenCalledTimes(1);
  });

  // **A SECOND MOUNT WITHOUT AN UNMOUNT IS A LIFECYCLE BUG, AND IT THROWS.** Quietly unmounting first
  // would pull the DOM out from under a session that is still running (its window manager, its
  // canvas, its listeners), and quietly re-mounting would do the same by replacing the children — so
  // either "fix" hides a controller that lost track of its session behind a session that stopped
  // painting. The controller pairs every mount with an unmount; this makes the day it does not loud.
  it("mount twice without an unmount THROWS, and leaves the mounted copy in place", () => {
    const dom = captureSessionDom(root());
    dom.mount();
    const stage = document.getElementById("stage");
    expect(() => dom.mount()).toThrow(/already mounted/);
    expect(document.getElementById("stage")).toBe(stage);
    expect(dom.mounted).toBe(true);
    dom.unmount();
    expect(() => dom.mount()).not.toThrow();
  });
});
