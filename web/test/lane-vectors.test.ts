import { describe, expect, it } from "vitest";
import { RlcDecoder, rlcCoefficients, rlcNextSeed, rlcRepair } from "../src/lib/rlc";
import { hex, laneVectors } from "./lane-vectors";
import {
  buildLaneSymbol, decodeLanePacket, encodeLaneFeedback, encodeLaneRepair, encodeLaneSource, parseLaneSymbol,
  unwrapLane32, LANE_TYPE_FEEDBACK, LANE_TYPE_REPAIR, LANE_TYPE_SOURCE,
} from "../src/lib/lane-codec";

// host/streaming-engine/PionBridge/rdev_lane_vectors_test.go asserts the same file. Never edit it by hand to pass.
const pad = (b: Uint8Array) => { const out = new Uint8Array(1080); out.set(b); return out; };

it("no vector list is empty — an empty one would pass every assertion", () => {
  for (const k of ["coefficients", "nextSeed", "rlc", "packets", "malformedPackets", "symbols", "malformedSymbols", "unwrap"] as const) {
    expect(laneVectors[k].length, k).toBeGreaterThan(0);
  }
});

describe("the FEC against the vectors", () => {
  it("coefficients and seeds", () => {
    for (const c of laneVectors.coefficients) expect([...rlcCoefficients(c.seed, c.values.length)]).toEqual(c.values);
    for (const s of laneVectors.nextSeed) expect(rlcNextSeed(s.seed)).toBe(s.next);
  });
  for (const r of laneVectors.rlc) {
    it(`repairs and recovers: ${r.name}`, () => {
      const symbols = r.symbols.map(hex);
      expect([...rlcRepair(symbols, r.seed)]).toEqual([...hex(r.repair)]);
      const d = new RlcDecoder(1024);
      const lost = symbols.length - 1;
      symbols.slice(0, lost).forEach((s, i) => d.addSource(i, pad(s)));
      d.addRepair(0, symbols.length, r.seed, pad(hex(r.repair)));
      expect([...d.get(lost)!]).toEqual([...pad(symbols[lost]!)]);
    });
  }
});

describe("the codec against the vectors", () => {
  for (const p of laneVectors.packets) {
    it(`packet: ${p.name}`, () => {
      const want = hex(p.bytes);
      const got = p.kind === "source" ? encodeLaneSource(p.pkt, p.ts, p.esi!, hex(p.symbol!))
        : p.kind === "repair" ? encodeLaneRepair(p.pkt, p.ts, p.firstEsi!, p.count!, p.seed!, hex(p.payload!))
        : encodeLaneFeedback(p.pkt, p.ts, { cumEsi: p.cumEsi!, ranges: p.ranges!.map(([start, length]) => ({ start, length })),
                                            lossPermille: p.lossPermille!, echoTs: p.echoTs!, held: p.held! });
      expect([...got]).toEqual([...want]);
      const d = decodeLanePacket(want)!;
      expect(d).not.toBeNull();
      expect([d.pkt, d.ts]).toEqual([p.pkt, p.ts]);
      if (p.kind === "source") {
        expect(d.kind).toBe(LANE_TYPE_SOURCE);
        if (d.kind === LANE_TYPE_SOURCE) { expect(d.esi).toBe(p.esi); expect([...d.payload]).toEqual([...hex(p.symbol!)]); }
      } else if (p.kind === "repair") {
        expect(d.kind).toBe(LANE_TYPE_REPAIR);
        if (d.kind === LANE_TYPE_REPAIR) {
          expect([d.esi, d.count, d.seed]).toEqual([p.firstEsi, p.count, p.seed]);
          expect([...d.payload]).toEqual([...hex(p.payload!)]);
        }
      } else {
        expect(d.kind).toBe(LANE_TYPE_FEEDBACK);
        if (d.kind === LANE_TYPE_FEEDBACK) {
          expect(d.feedback).toEqual({ cumEsi: p.cumEsi, ranges: p.ranges!.map(([start, length]) => ({ start, length })),
                                       lossPermille: p.lossPermille, echoTs: p.echoTs, held: p.held });
        }
      }
    });
  }
  for (const m of laneVectors.malformedPackets) {
    it(`refuses packet: ${m.name}`, () => { expect(decodeLanePacket(hex(m.bytes))).toBeNull(); });
  }
  for (const s of laneVectors.symbols) {
    it(`symbol: ${s.name}`, () => {
      const raw = hex(s.bytes);
      const chunks = s.chunks.map((c) => ({ stream: c.stream, offset: c.offset, bytes: hex(c.bytes) }));
      const parsed = parseLaneSymbol(raw)!;
      expect(parsed.map((c) => ({ stream: c.stream, offset: c.offset, bytes: [...c.bytes] })))
        .toEqual(chunks.map((c) => ({ stream: c.stream, offset: c.offset, bytes: [...c.bytes] })));
      const built = buildLaneSymbol(chunks);
      expect([...built]).toEqual([...raw.subarray(0, built.length)]);       // up to a rebuilt symbol's zero padding
      expect(raw.subarray(built.length).every((b) => b === 0)).toBe(true);
    });
  }
  for (const m of laneVectors.malformedSymbols) {
    it(`refuses symbol: ${m.name}`, () => { expect(parseLaneSymbol(hex(m.bytes))).toBeNull(); });
  }
  it("unwraps 32-bit counters", () => {
    for (const u of laneVectors.unwrap) expect(unwrapLane32(u.reference, u.wire)).toBe(u.full);
  });
});
