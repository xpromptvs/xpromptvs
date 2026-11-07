// The web package has no node types (tsconfig.json), so the fixture comes in as a JSON module, as the other suites do.
import fixture from "../../protocol/fixtures/lane-vectors.json";

// THE LANE AGAINST A THIRD IMPLEMENTATION (scripts/gen_lane_vectors.py → protocol/fixtures/lane-vectors.json).
// A helper module, not a test file: importing a .test.ts would register its tests a second time in the importer.
export interface LaneVectorFile {
  coefficients: { seed: number; values: number[] }[];
  nextSeed: { seed: number; next: number }[];
  rlc: { name: string; seed: number; symbols: string[]; repair: string }[];
  packets: ({ name: string; kind: "source" | "repair" | "feedback"; bytes: string; pkt: number; ts: number }
    & Partial<{ esi: number; symbol: string; firstEsi: number; count: number; seed: number; payload: string;
                cumEsi: number; ranges: [number, number][]; lossPermille: number; echoTs: number; held: number }>)[];
  malformedPackets: { name: string; bytes: string }[];
  symbols: { name: string; chunks: { stream: number; offset: number; bytes: string }[]; bytes: string }[];
  malformedSymbols: { name: string; bytes: string }[];
  unwrap: { reference: number; wire: number; full: number }[];
}
export const laneVectors = fixture as unknown as LaneVectorFile;
export const hex = (s: string) => new Uint8Array((s.match(/../g) ?? []).map((b) => parseInt(b, 16)));
