import { describe, expect, it } from "vitest";
import {
  fitName, fitType, overCaps, parsePasteReply, pasteBegin, pasteCancel, pasteData, pasteEnd,
  PASTE_CHUNK_BYTES, PASTE_FILE_MAX_BYTES, PASTE_MAX_ITEMS, PASTE_TEXT_MAX_BYTES, PASTE_TOTAL_MAX_BYTES,
} from "../src/client/paste-wire";
import vectors from "../../protocol/fixtures/paste-messages.json";

const bytes = (s: string) => new TextEncoder().encode(s).length;

// THE SAME VECTORS SWIFT PARSES (RdevCore `PasteMessagesTests`): what the client builds, the host takes.
describe("the paste-* builders — protocol/fixtures/paste-messages.json, shared with the host", () => {
  it.each(vectors.built)("$call → $wire.t", (c) => {
    const a = c.args as Record<string, unknown>;
    const built =
      c.call === "begin" ? pasteBegin(a.id as string, a.to as never, a.items as never, a.at as never)
      : c.call === "data" ? pasteData(a.id as string, a.item as number, a.seq as number, Uint8Array.from(a.bytes as number[]))
      : c.call === "end" ? pasteEnd(a.id as string) : pasteCancel(a.id as string);
    expect(built).toEqual(c.wire);
  });
  it("refuses, before sending, every delivery the host answers too-large", () => {
    for (const m of vectors.tooLarge) expect(overCaps((m as unknown as { items: never }).items)).toBe(true);
  });
});

describe("the limits are the spec's", () => {
  it("is exactly §3", () => {
    expect([PASTE_CHUNK_BYTES, PASTE_FILE_MAX_BYTES, PASTE_TEXT_MAX_BYTES, PASTE_TOTAL_MAX_BYTES, PASTE_MAX_ITEMS])
      .toEqual([16384, 1073741824, 4194304, 1073741824, 32]);
  });
  it("a delivery at every cap is fine and one past is not", () => {
    expect(overCaps([{ kind: "file", name: "a", type: "", size: PASTE_FILE_MAX_BYTES }])).toBe(false);
    expect(overCaps([{ kind: "text", size: PASTE_TEXT_MAX_BYTES }])).toBe(false);
    expect(overCaps(Array.from({ length: 33 }, () => ({ kind: "file" as const, name: "a", type: "", size: 1 })))).toBe(true);
    expect(overCaps([])).toBe(true);
  });
});

describe("fitName — at most 255 UTF-8 bytes, cut on a character, the extension kept", () => {
  it("leaves a short name alone", () => { expect(fitName("IMG_0042.jpg")).toBe("IMG_0042.jpg"); });
  it("cuts a long one and keeps .png", () => {
    const n = fitName("é".repeat(300) + ".png");
    expect(bytes(n)).toBeLessThanOrEqual(255);
    expect(n.endsWith(".png")).toBe(true);
    expect(n).not.toContain("�");
  });
  it("never splits an emoji", () => {
    const n = fitName("😀".repeat(100));
    expect(bytes(n)).toBeLessThanOrEqual(255);
    expect([...n].every((c) => c === "😀")).toBe(true);
  });
  it("drops a type too long to send", () => { expect(fitType("x".repeat(200))).toBe(""); expect(fitType("image/png")).toBe("image/png"); });
});

describe("parsePasteReply", () => {
  it("reads an acceptance, a done and an error", () => {
    // The delivery's START, acknowledged (2026-10-02): the uploader sends no piece before it.
    expect(parsePasteReply({ t: "paste-accepted", id: "p1" })).toEqual({ t: "paste-accepted", id: "p1" });
    expect(parsePasteReply({ t: "paste-done", id: "p1", how: "drop" })).toEqual({ t: "paste-done", id: "p1", how: "drop" });
    expect(parsePasteReply({ t: "paste-error", id: "p1", reason: "no-target" })).toEqual({ t: "paste-error", id: "p1", reason: "no-target" });
  });
  it("refuses anything else", () => {
    expect(parsePasteReply({ t: "paste-done", id: "p1", how: "teleport" })).toBeNull();
    expect(parsePasteReply({ t: "paste-error", id: "p1", reason: "nope" })).toBeNull();
    expect(parsePasteReply({ t: "view-set" })).toBeNull();
    expect(parsePasteReply({ t: "paste-accepted" })).toBeNull();
    expect(parsePasteReply({ t: "paste-accepted", id: 7 })).toBeNull();
    expect(parsePasteReply(null)).toBeNull();
  });
});
