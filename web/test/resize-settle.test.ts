import { describe, it, expect } from "vitest";
import { ResizeSettle } from "../src/client/resize-settle";

function fixture() {
  let frames: Array<() => void> = [];
  return { gate: new ResizeSettle(run => frames.push(run)),
    frame: () => { const batch = frames; frames = []; batch.forEach(run => run()); } };
}
describe("controlled window resize", () => {
  it("leaves manual resizing live and coalesces animated reactions at final geometry", () => {
    const { gate, frame } = fixture(), owner = {}, seen: number[] = [];
    let width = 100;
    expect(gate.defer(owner, "fit", () => seen.push(width))).toBe(false);
    gate.setActive(true);
    for (width = 101; width <= 150; width++) gate.defer(owner, "fit", () => seen.push(width));
    expect(seen).toEqual([]);
    gate.setActive(false); frame();
    width = 200; gate.defer(owner, "fit", () => seen.push(width));
    expect(seen).toEqual([]); frame();
    expect(seen).toEqual([200]);
  });
  it("ignores superseded completion and cancels disposed sessions", () => {
    const { gate, frame } = fixture(), alive = {}, disposed = {}, seen: string[] = [];
    gate.setActive(true);
    gate.defer(alive, "crop", () => seen.push("crop"));
    gate.defer(alive, "auto", () => seen.push("auto"));
    gate.defer(disposed, "fit", () => seen.push("disposed"));
    gate.setActive(false); frame(); gate.setActive(true); frame();
    expect(seen).toEqual([]);
    gate.cancel(disposed); gate.setActive(false); frame(); frame();
    expect(seen).toEqual(["crop", "auto"]);
  });
});
