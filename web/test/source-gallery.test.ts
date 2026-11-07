import { describe, it, expect } from "vitest";
import { parseSourceThumb, galleryTiles, type ThumbEntry } from "../src/client/source-gallery";
import type { Source } from "../src/client/source-picker";

const SRC: Source[] = [
  { id: "sim:U1", kind: "sim", name: "iPhone", inputCapable: true, running: true },
  { id: "sim:U2", kind: "sim", name: "iPad", inputCapable: true, running: false },
  { id: "win:7", kind: "window", name: "Safari", inputCapable: true, running: true },
  { id: "win:9", kind: "window", name: "Notes", inputCapable: true, running: false },
];

describe("parseSourceThumb", () => {
  it("builds a data URL from a jpeg message", () => {
    expect(parseSourceThumb({ t: "source-thumb", id: "win:7", w: 320, h: 200, fmt: "jpeg", data: "QUJD" }))
      .toEqual({ id: "win:7", dataUrl: "data:image/jpeg;base64,QUJD" });
  });
  it("parses an unavailable message", () => {
    expect(parseSourceThumb({ t: "source-thumb", id: "sim:U2", unavailable: true }))
      .toEqual({ id: "sim:U2", unavailable: true });
  });
  it("rejects wrong t / missing id / missing data / bad fmt", () => {
    expect(parseSourceThumb({ t: "nope", id: "win:7", fmt: "jpeg", data: "x" })).toBeNull();
    expect(parseSourceThumb({ t: "source-thumb", fmt: "jpeg", data: "x" })).toBeNull();
    expect(parseSourceThumb({ t: "source-thumb", id: "win:7", fmt: "png", data: "x" })).toBeNull();
    expect(parseSourceThumb({ t: "source-thumb", id: "win:7", fmt: "jpeg" })).toBeNull();
    expect(parseSourceThumb(null)).toBeNull();
  });
});

describe("galleryTiles", () => {
  it("maps thumb states: image / placeholder / loading", () => {
    const thumbs = new Map<string, ThumbEntry>([
      ["win:7", { dataUrl: "data:image/jpeg;base64,QUJD" }],
      ["sim:U1", { unavailable: true }],
    ]);
    const tiles = galleryTiles(SRC, ["win:7"], "win:7", thumbs);
    const by = (id: string) => tiles.find((t) => t.id === id)!;
    expect(by("win:7").thumb).toEqual({ kind: "image", dataUrl: "data:image/jpeg;base64,QUJD" });
    expect(by("sim:U1").thumb).toEqual({ kind: "placeholder" });   // running but reported unavailable
    expect(by("sim:U2").thumb).toEqual({ kind: "placeholder" });   // not running → no capture coming
    expect(by("win:9").thumb).toEqual({ kind: "placeholder" });    // minimized → not running
  });

  it("shows loading for a running source with no entry yet", () => {
    const tiles = galleryTiles(SRC, [], null, new Map());
    expect(tiles.find((t) => t.id === "win:7")!.thumb).toEqual({ kind: "loading" });
    expect(tiles.find((t) => t.id === "sim:U1")!.thumb).toEqual({ kind: "loading" });
  });

  it("flags subscribed / focused / state label", () => {
    const tiles = galleryTiles(SRC, ["win:7"], "win:7", new Map());
    const t7 = tiles.find((t) => t.id === "win:7")!;
    expect(t7.subscribed).toBe(true);
    expect(t7.focused).toBe(true);
    expect(tiles.find((t) => t.id === "win:9")!.stateLabel).toBe("minimized");
    expect(tiles.find((t) => t.id === "sim:U1")!.stateLabel).toBeNull();
  });
});
