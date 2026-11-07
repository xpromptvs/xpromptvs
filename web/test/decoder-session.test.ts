import { expect, test } from "vitest";
import { DecoderSession, type DecoderLike } from "../src/client/decoder-session";

class FakeDecoder implements DecoderLike {
  static made = 0;
  readonly id = ++FakeDecoder.made;
  state: "unconfigured" | "configured" | "closed" = "unconfigured";
  configured: string[] = [];
  configure(c: { codec: string }): void {
    if (this.state === "closed") throw new Error("Cannot call 'decode' on a closed codec.");
    this.configured.push(c.codec);
    this.state = "configured";
  }
  close(): void { this.state = "closed"; }
}
const session = () => { FakeDecoder.made = 0; return new DecoderSession(() => new FakeDecoder()); };

test("reuses one decoder while the codec is unchanged", () => {
  const s = session();
  const a = s.ready("av01.0.04M.08") as FakeDecoder;
  const b = s.ready("av01.0.04M.08") as FakeDecoder;
  expect(b).toBe(a);
  expect(a.configured).toEqual(["av01.0.04M.08"]);
});

test("reconfigures in place on a codec change — no new decoder", () => {
  const s = session();
  const a = s.ready("av01.0.04M.08") as FakeDecoder;
  const b = s.ready("avc1.42e01f") as FakeDecoder;
  expect(b).toBe(a);
  expect(a.configured).toEqual(["av01.0.04M.08", "avc1.42e01f"]);
});

test("A DECODER ERROR IS TERMINAL — the next ready() builds a NEW decoder", () => {
  // WebCodecs CLOSES the codec on error. Reusing it throws InvalidStateError from configure(), which
  // this renderer used to treat as fatal: one lost reference frame on a lossy link killed the path
  // until a page reload. Measured under 10% loss:
  //   configure av01.0.04M.08: InvalidStateError: Cannot call 'decode' on a closed codec.
  const s = session();
  const a = s.ready("av01.0.04M.08") as FakeDecoder;
  s.failed();
  const b = s.ready("av01.0.04M.08") as FakeDecoder;
  expect(b).not.toBe(a);
  expect(b.configured).toEqual(["av01.0.04M.08"]);
});

test("a decoder found CLOSED is replaced even without an error callback", () => {
  const s = session();
  const a = s.ready("av01.0.04M.08") as FakeDecoder;
  a.close();
  const b = s.ready("av01.0.04M.08") as FakeDecoder;
  expect(b).not.toBe(a);
  expect(b.state).toBe("configured");
});

test("recovers repeatedly — ten errors do not kill it, and never throw", () => {
  const s = session();
  for (let i = 0; i < 10; i++) {
    expect(() => s.ready("av01.0.04M.08")).not.toThrow();
    s.failed();
  }
  expect(FakeDecoder.made).toBe(10);
});

test("generation increments only when a decoder is actually replaced", () => {
  const s = session();
  s.ready("av01.0.04M.08");
  expect(s.generation).toBe(1);
  s.ready("avc1.42e01f");
  expect(s.generation).toBe(1);
  s.failed();
  s.ready("avc1.42e01f");
  expect(s.generation).toBe(2);
});
