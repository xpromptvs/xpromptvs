import { describe, expect, it } from "vitest";
import { HeldMods } from "../src/client/held-mods";

describe("HeldMods", () => {
  it("is off until held, and off again on release", () => {
    const m = new HeldMods();
    expect(m.state("ctrl")).toBe("off");
    m.down("ctrl");
    expect(m.state("ctrl")).toBe("held");
    m.up("ctrl");
    expect(m.state("ctrl")).toBe("off");
  });

  it("tracks each modifier independently", () => {
    const m = new HeldMods();
    m.down("ctrl"); m.down("meta");
    expect(m.active()).toEqual(["ctrl", "meta"]);
    m.up("ctrl");
    expect(m.active()).toEqual(["meta"]);
  });

  // A modifier must NOT be released by a key press — that is the whole difference from sticky, and
  // it is what lets one finger hold ⌘ while another taps C, then V.
  it("survives any number of other keys — only a release clears it", () => {
    const m = new HeldMods();
    m.down("meta");
    expect(m.mask()).toBe(8);
    expect(m.mask()).toBe(8);
    expect(m.state("meta")).toBe("held");
  });

  it("reports whether down/up actually changed anything, so a duplicate event sends no extra wire message", () => {
    const m = new HeldMods();
    expect(m.down("alt")).toBe(true);
    expect(m.down("alt")).toBe(false);
    expect(m.up("alt")).toBe(true);
    expect(m.up("alt")).toBe(false);
  });
});

describe("HeldMods.mask", () => {
  it("matches modsBitmask: shift 1, ctrl 2, alt 4, meta 8", () => {
    const m = new HeldMods();
    m.down("shift"); expect(m.mask()).toBe(1);
    m.down("ctrl");  expect(m.mask()).toBe(3);
    m.down("alt");   expect(m.mask()).toBe(7);
    m.down("meta");  expect(m.mask()).toBe(15);
  });

  it("is 0 with nothing held", () => {
    expect(new HeldMods().mask()).toBe(0);
  });
});

describe("HeldMods.clearAll", () => {
  it("returns everything held and empties the set", () => {
    const m = new HeldMods();
    m.down("ctrl"); m.down("meta");
    expect([...m.clearAll()].sort()).toEqual(["ctrl", "meta"]);
    expect(m.mask()).toBe(0);
    expect(m.state("meta")).toBe("off");
  });

  it("returns an empty list when nothing was held, so a caller sends no key-ups", () => {
    expect(new HeldMods().clearAll()).toEqual([]);
  });
});
