import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { encodeFastRecord, decodeFastRecord, type FastRecord } from '../src/fast-data';
const vectors = JSON.parse(readFileSync(new URL('../fixtures/fast-data-vectors.json', import.meta.url), 'utf8'));
const bytes = (s: string) => new Uint8Array(Buffer.from(s, 'hex'));
describe('fast data wire', () => {
  for (const v of vectors.valid) it(`agrees with independent vector ${v.kind}/${v.stream}/${v.value}`, () => {
    const record: FastRecord = { kind: v.kind, generation: bytes(vectors.generation), stream: v.stream, value: BigInt(v.value), bytes: bytes(v.payload) };
    expect(encodeFastRecord(record)).toEqual(bytes(v.wire));
    expect(decodeFastRecord(bytes(v.wire))).toEqual(record);
  });
  for (const [i, v] of vectors.invalid.entries()) it(`refuses malformed record ${i}`, () => expect(decodeFastRecord(bytes(v))).toBeNull());
  it('refuses invalid outgoing counters, generations and payloads', () => {
    const r: FastRecord = {kind: 1, generation: bytes(vectors.generation), stream: 0, value: 0n, bytes: new Uint8Array(1)};
    for (const patch of [{value:-1n},{value:1n<<64n},{generation:new Uint8Array(15)},{bytes:new Uint8Array(8193)},{bytes:new Uint8Array()}]) expect(() => encodeFastRecord({...r,...patch})).toThrow();
  });
});
