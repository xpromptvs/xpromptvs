import { describe, it, expect } from "vitest";
import { inboundVideoCodec } from "../src/lib/inbound-codec";

/** Minimal stand-in for RTCStatsReport: a Map with the same get()/forEach() surface. */
function report(entries: Record<string, unknown>): RTCStatsReport {
  return new Map(Object.entries(entries)) as unknown as RTCStatsReport;
}

describe("inboundVideoCodec", () => {
  it("returns the mimeType of the inbound video codec", () => {
    const r = report({
      i1: { type: "inbound-rtp", kind: "video", codecId: "c1" },
      c1: { type: "codec", mimeType: "video/AV1" },
    });
    expect(inboundVideoCodec(r)).toBe("video/AV1");
  });

  it("ignores audio and outbound entries", () => {
    const r = report({
      a1: { type: "inbound-rtp", kind: "audio", codecId: "c1" },
      c1: { type: "codec", mimeType: "audio/opus" },
      o1: { type: "outbound-rtp", kind: "video", codecId: "c2" },
      c2: { type: "codec", mimeType: "video/H264" },
    });
    expect(inboundVideoCodec(r)).toBeNull();
  });

  it("returns null before any video arrives", () => {
    expect(inboundVideoCodec(report({}))).toBeNull();
  });

  it("returns null when the codec entry is missing", () => {
    const r = report({ i1: { type: "inbound-rtp", kind: "video", codecId: "gone" } });
    expect(inboundVideoCodec(r)).toBeNull();
  });
});
