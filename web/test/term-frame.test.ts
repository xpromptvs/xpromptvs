import { describe, expect, it } from "vitest";
import { encodeTermFrame, parseTermFrame, TERM_CLOSED, TERM_OUTPUT, TERM_SNAPSHOT_END, TERM_WIRE_START } from "../src/client/term-frame";

describe("terminal frames", () => {
  it("parses an output frame", () => {
    const b = new Uint8Array([0, 5, ...new TextEncoder().encode("pty:3"), 1, 2, 3]);
    expect(parseTermFrame(b)).toEqual({ kind: TERM_OUTPUT, tab: "pty:3", payload: new Uint8Array([1, 2, 3]) });
  });
  it("parses the grid of a snapshot frame", () => {
    const b = new Uint8Array([2, 7, ...new TextEncoder().encode("tmux:$2"), 0x01, 0x2c, 0x00, 0x28, 9]);
    expect(parseTermFrame(b)).toEqual({ kind: TERM_SNAPSHOT_END, tab: "tmux:$2", cols: 300, rows: 40, payload: new Uint8Array([9]) });
  });
  it("round-trips through encode", () => {
    const f = { kind: TERM_CLOSED, tab: "pty:1", payload: new Uint8Array() } as const;
    expect(parseTermFrame(encodeTermFrame(f))).toEqual(f);
  });
  it("rejects malformed frames", () => {
    // [5, …] an unknown kind; [4, 1, …] a wire start naming a tab; [4, 0, 9] a wire start with a
    // payload; [0, 0] an empty tab id on a tab-addressed kind.
    for (const bad of [[], [5, 1, 0x61], [4, 1, 0x61], [4, 0, 9], [0, 9, 0x61], [1, 1, 0x61, 0, 80], [0, 0], [3, 0]]) {
      expect(parseTermFrame(new Uint8Array(bad))).toBeNull();
    }
  });
  it("parses and encodes the wire start: exactly [4, 0], no tab", () => {
    expect(parseTermFrame(new Uint8Array([4, 0]))).toEqual({ kind: TERM_WIRE_START, tab: "", payload: new Uint8Array() });
    expect([...encodeTermFrame({ kind: TERM_WIRE_START, tab: "", payload: new Uint8Array() })]).toEqual([4, 0]);
  });
});
