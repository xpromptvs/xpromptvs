import { describe, it, expect } from "vitest";
import { parseDcPacket, DC_HEADER_BYTES } from "../src/lib/dc-wire";

/// Builds a v7 SOURCE header byte-for-byte as rdev_dc_stream.go writes it. HAND-BUILT ON PURPOSE:
/// the point is to pin the LAYOUT, and generating it from the parser would assert nothing.
function sourcePacket(fields: Partial<{
  esi: number; frameSeq: number; rtp: number; fragIndex: number; fragCount: number;
  frameBytes: number; key: boolean; payloadType: number; sourceIndex: number; generation: number;
  frameHash: number; dependsOnOffset: number;
}> = {}): ArrayBuffer {
  const symbolBytes = 8;
  const buffer = new ArrayBuffer(DC_HEADER_BYTES + symbolBytes);
  const view = new DataView(buffer);
  view.setUint32(0, 0x53564452, true);
  view.setUint8(4, 7);
  view.setUint8(5, 0);
  view.setUint16(6, symbolBytes, true);
  view.setUint32(8, fields.esi ?? 0, true);
  view.setUint32(12, fields.frameSeq ?? 0, true);
  view.setUint32(16, fields.rtp ?? 0, true);
  view.setUint16(20, fields.fragIndex ?? 0, true);
  view.setUint16(22, fields.fragCount ?? 1, true);
  view.setUint32(24, fields.frameBytes ?? 8, true);
  view.setUint8(28, fields.key ? 1 : 0);
  view.setUint8(29, fields.payloadType ?? 45);
  view.setUint16(30, fields.sourceIndex ?? 0, true);
  view.setUint8(32, fields.generation ?? 0);
  view.setUint32(36, fields.frameHash ?? 0, true);
  view.setUint8(33, fields.dependsOnOffset ?? 1);
  return buffer;
}

describe("the v7 wire parser", () => {
  it("reads every field of a source packet at the layout Go writes", () => {
    const parsed = parseDcPacket(sourcePacket({
      esi: 12345, frameSeq: 7, rtp: 90000, fragIndex: 2, fragCount: 3,
      frameBytes: 3000, key: true, payloadType: 45, sourceIndex: 9, generation: 2,
      frameHash: 0xfeedface, dependsOnOffset: 3,
    }));
    expect(parsed).not.toBeNull();
    expect(parsed!.kind).toBe("source");
    if (parsed!.kind !== "source") return;
    expect(parsed!.esi).toBe(12345);
    expect(parsed!.frameSeq).toBe(7);
    expect(parsed!.rtp).toBe(90000);
    expect(parsed!.fragIndex).toBe(2);
    expect(parsed!.fragCount).toBe(3);
    expect(parsed!.frameBytes).toBe(3000);
    expect(parsed!.key).toBe(true);
    expect(parsed!.payloadType).toBe(45);
    expect(parsed!.sourceIndex).toBe(9);
    expect(parsed!.generation).toBe(2);
    // UNSIGNED, like the repair seed: read signed, a hash with the high bit set would never match
    // the sender's and every such frame would be discarded as corrupt.
    expect(parsed!.frameHash).toBe(0xfeedface);
    expect(parsed!.dependsOnOffset).toBe(3);
  });

  it("refuses a wrong version rather than reading fields at the wrong offsets", () => {
    // A host and a client disagreeing about a fixed-size header would otherwise produce entirely
    // plausible garbage. Refusing is the only safe direction.
    const buffer = sourcePacket();
    new DataView(buffer).setUint8(4, 6);
    expect(parseDcPacket(buffer)).toBeNull();
  });

  it("refuses a bad magic and a truncated packet", () => {
    const wrongMagic = sourcePacket();
    new DataView(wrongMagic).setUint32(0, 0xdeadbeef, true);
    expect(parseDcPacket(wrongMagic)).toBeNull();
    expect(parseDcPacket(new ArrayBuffer(DC_HEADER_BYTES - 1))).toBeNull();
  });

  // v5: A SOURCE SYMBOL IS SENT UNPADDED AND ZERO-EXTENDED HERE. The host stops paying 1200 bytes to
  // carry a 27-byte frame; the decoder still needs the full-width symbol its encoder combined.
  it("zero-extends a short source symbol back to the symbol length", () => {
    const symbolBytes = 8;
    const wire = 3;
    const buffer = new ArrayBuffer(DC_HEADER_BYTES + wire);
    const view = new DataView(buffer);
    view.setUint32(0, 0x53564452, true);
    view.setUint8(4, 7);
    view.setUint8(5, 0);
    view.setUint16(6, symbolBytes, true);
    view.setUint32(24, wire, true);              // frameBytes
    new Uint8Array(buffer, DC_HEADER_BYTES).set([0xaa, 0xbb, 0xcc]);
    const parsed = parseDcPacket(buffer);
    if (parsed!.kind !== "source") return expect.fail("not a source packet");
    expect(parsed!.payload.length).toBe(symbolBytes);
    expect([...parsed!.payload]).toEqual([0xaa, 0xbb, 0xcc, 0, 0, 0, 0, 0]);
  });

  // A REPAIR IS DENSE ONLY OVER THE LONGEST SYMBOL IN ITS WINDOW. Past that it is a combination of
  // zeroes, so the sender trims it and this puts the zeroes back — the same treatment a short source
  // symbol gets, for the same reason.
  it("zero-extends a trimmed repair symbol", () => {
    const buffer = new ArrayBuffer(DC_HEADER_BYTES + 3);
    const view = new DataView(buffer);
    view.setUint32(0, 0x53564452, true);
    view.setUint8(4, 7);
    view.setUint8(5, 1);
    view.setUint16(6, 8, true);
    new Uint8Array(buffer, DC_HEADER_BYTES).set([1, 2, 3]);
    const parsed = parseDcPacket(buffer);
    if (parsed!.kind !== "repair") return expect.fail("not a repair packet");
    expect(parsed!.payload.length).toBe(8);
    expect([...parsed!.payload]).toEqual([1, 2, 3, 0, 0, 0, 0, 0]);
  });

  it("refuses a payload LONGER than the symbol length it claims", () => {
    // The two ends disagreeing about the layout. Longer is never trimmable — it means the reader is
    // about to take its fields from the wrong offsets.
    const buffer = new ArrayBuffer(DC_HEADER_BYTES + 9);
    const view = new DataView(buffer);
    view.setUint32(0, 0x53564452, true);
    view.setUint8(4, 7);
    view.setUint8(5, 0);
    view.setUint16(6, 8, true);
    expect(parseDcPacket(buffer)).toBeNull();
  });

  it("reads a repair packet's window and seed", () => {
    const symbolBytes = 8;
    const buffer = new ArrayBuffer(DC_HEADER_BYTES + symbolBytes);
    const view = new DataView(buffer);
    view.setUint32(0, 0x53564452, true);
    view.setUint8(4, 7);
    view.setUint8(5, 1);
    view.setUint16(6, symbolBytes, true);
    view.setUint32(8, 100, true);          // firstESI
    view.setUint16(12, 16, true);          // windowLen
    view.setUint32(16, 0x12345678, true);  // seed
    view.setUint16(30, 5, true);
    view.setUint8(32, 1);
    const parsed = parseDcPacket(buffer);
    expect(parsed!.kind).toBe("repair");
    if (parsed!.kind !== "repair") return;
    expect(parsed!.firstEsi).toBe(100);
    expect(parsed!.windowLen).toBe(16);
    expect(parsed!.seed).toBe(0x12345678);
    expect(parsed!.sourceIndex).toBe(5);
    expect(parsed!.generation).toBe(1);
  });

  it("reads a seed with the high bit set as unsigned", () => {
    // getUint32 is correct here and getInt32 would not be. The seed drives the coefficient
    // generator, so a sign-flipped one produces a different sequence from the host's — and the
    // symptom is wrong pixels, not an error.
    const symbolBytes = 8;
    const buffer = new ArrayBuffer(DC_HEADER_BYTES + symbolBytes);
    const view = new DataView(buffer);
    view.setUint32(0, 0x53564452, true);
    view.setUint8(4, 7);
    view.setUint8(5, 1);
    view.setUint16(6, symbolBytes, true);
    view.setUint32(16, 0xfedcba98, true);
    const parsed = parseDcPacket(buffer);
    if (parsed!.kind !== "repair") return expect.fail("not a repair packet");
    expect(parsed!.seed).toBe(0xfedcba98);
  });

  it("refuses an unknown kind", () => {
    const buffer = sourcePacket();
    new DataView(buffer).setUint8(5, 9);
    expect(parseDcPacket(buffer)).toBeNull();
  });
});
