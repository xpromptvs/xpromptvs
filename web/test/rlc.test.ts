/// THE OTHER HALF OF THE CROSS-IMPLEMENTATION VECTOR. Its twin is
/// host/streaming-engine/PionBridge/rdev_dc_rlc_test.go, and the pair exists because a Go/TS
/// disagreement about the field, the coefficient generator or the byte order DECODES TO PLAUSIBLE
/// GARBAGE rather than to an error — the picture would be wrong in ways that read as a codec bug.
/// Neither test alone can catch a one-sided edit; both asserting the same literals can.
///
/// The literals below were taken FROM the Go implementation, not derived by hand. A first pass wrote
/// values from reasoning and three of the four were wrong, which is the argument for the vector
/// coming out of the code it is pinning rather than out of an author's head.
import { describe, it, expect } from "vitest";
import { gfMul, gfDiv, gfMulAddInto, rlcCoefficients, rlcRepair, rlcNextSeed, RlcDecoder, fnv1a } from "../src/lib/rlc";
import { laneVectors } from "./lane-vectors";

describe("GF(256) matches the shared vector", () => {
  it("agrees with Go on multiplication and division", () => {
    expect(gfMul(3, 7)).toBe(9);
    expect(gfMul(200, 150)).toBe(118);
    expect(gfDiv(1, 3)).toBe(244);
  });

  it("inverts every non-zero element", () => {
    // The property the decoder's back-substitution rests on, checked across the whole field rather
    // than at a sampled point.
    for (let a = 1; a < 256; a++) expect(gfMul(a, gfDiv(1, a))).toBe(1);
  });
});

describe("the coefficient generator matches the shared vector", () => {
  it("agrees with Go on the first eight coefficients", () => {
    // If this drifts, every repair symbol is a linear combination of the wrong things and recovery
    // silently produces wrong bytes rather than failing.
    expect([...rlcCoefficients(0x12345678, 8)]).toEqual([33, 57, 35, 123, 59, 3, 193, 118]);
  });

  it("never emits a zero coefficient", () => {
    // A zero would drop a symbol out of the window without saying so, making the measured code rate
    // a lie and the protection weaker than configured.
    const coefficients = rlcCoefficients(0xdeadbeef, 256);
    expect([...coefficients].every((c) => c !== 0)).toBe(true);
  });

  it("survives a seed with the high bit set", () => {
    // THE SIGNED-SHIFT TRAP. JavaScript's bitwise operators produce SIGNED 32-bit results, so
    // without `>>> 0` after every step the generator diverges from Go's uint32 exactly when the high
    // bit is set — and only then, which is why a small-seed test would pass while production broke.
    expect([...rlcCoefficients(0xffffffff, 4)].every((c) => c >= 1 && c <= 255)).toBe(true);
    expect(rlcCoefficients(0x80000000, 1)[0]).toBe(rlcCoefficients(0x80000000, 1)[0]);
  });
});

/// Mirrors the Go encoder: a repair symbol is the GF(256) linear combination of the window.
function buildRepair(symbols: Uint8Array[], seed: number): Uint8Array {
  const coefficients = rlcCoefficients(seed, symbols.length);
  const out = new Uint8Array(symbols[0]!.length);
  symbols.forEach((symbol, i) => gfMulAddInto(out, symbol, coefficients[i]!));
  return out;
}

describe("the sliding-window decoder", () => {
  const symbol = (fill: number, len = 8) => new Uint8Array(len).fill(fill);

  it("recovers a single erasure from one repair symbol", () => {
    const sources = [symbol(11), symbol(22), symbol(33)];
    const repair = buildRepair(sources, 0xabcdef01);
    const decoder = new RlcDecoder();
    decoder.addSource(0, sources[0]!);
    decoder.addSource(2, sources[2]!);          // esi 1 is erased
    expect(decoder.has(1)).toBe(false);
    decoder.addRepair(0, 3, 0xabcdef01, repair);
    expect(decoder.has(1)).toBe(true);
    expect([...decoder.get(1)!]).toEqual([...sources[1]!]);
    expect(decoder.recovered).toBe(1);
  });

  it("recovers two erasures once two independent repairs arrive", () => {
    // The graded behaviour that makes a sliding window worth more than a block code: one loss is
    // free, and a second becomes recoverable when the NEXT frame's repair arrives rather than never.
    const sources = [symbol(1), symbol(2), symbol(3), symbol(4)];
    const first = buildRepair(sources, 0x11111111);
    const second = buildRepair(sources, 0x22222222);
    const decoder = new RlcDecoder();
    decoder.addSource(0, sources[0]!);
    decoder.addSource(3, sources[3]!);          // esi 1 and 2 both erased
    decoder.addRepair(0, 4, 0x11111111, first);
    expect(decoder.has(1)).toBe(false);         // one equation, two unknowns — not yet solvable
    decoder.addRepair(0, 4, 0x22222222, second);
    expect([...decoder.get(1)!]).toEqual([...sources[1]!]);
    expect([...decoder.get(2)!]).toEqual([...sources[2]!]);
  });

  it("solves when a late source symbol completes a stored equation", () => {
    // The other direction: an equation parked with two unknowns must be revisited when one of them
    // arrives on its own. Without that cascade the decoder strands repairs it could have used.
    const sources = [symbol(5), symbol(6), symbol(7)];
    const repair = buildRepair(sources, 0x33333333);
    const decoder = new RlcDecoder();
    decoder.addSource(0, sources[0]!);
    decoder.addRepair(0, 3, 0x33333333, repair);  // unknowns: 1 and 2
    expect(decoder.has(1)).toBe(false);
    decoder.addSource(2, sources[2]!);
    expect([...decoder.get(1)!]).toEqual([...sources[1]!]);
  });

  it("treats a redundant repair as redundant rather than as a recovery", () => {
    const sources = [symbol(9), symbol(8)];
    const repair = buildRepair(sources, 0x44444444);
    const decoder = new RlcDecoder();
    decoder.addSource(0, sources[0]!);
    decoder.addSource(1, sources[1]!);
    decoder.addRepair(0, 2, 0x44444444, repair);
    expect(decoder.recovered).toBe(0);
    expect(decoder.redundant).toBe(1);
  });
});


// THE FRAME HASH IS MIRRORED IN GO AND THE MIRRORING IS LOAD-BEARING — the same reason the
// coefficients are derived from a shared generator rather than shipped on the wire. A disagreement
// here does not degrade gracefully: EVERY frame fails its check and the picture stops entirely.
// These exact vectors are asserted in the Go suite too, in rdev_dc_arq_test.go.
describe("fnv1a", () => {
  it("matches the host's arithmetic", () => {
    expect(fnv1a(new TextEncoder().encode("rdev"))).toBe(0x472bcbcc);
  // HIGH-BIT BYTES, which is where this would break: JavaScript multiplies as doubles and its
  // bitwise operators return SIGNED 32-bit values, so without `Math.imul` and `>>> 0` the two
  // implementations diverge exactly when a byte exceeds 0x7f — silently, and on real video.
    expect(fnv1a(new Uint8Array([0, 1, 2, 255]))).toBe(0x6fab6075);
    expect(fnv1a(new Uint8Array(0))).toBe(2166136261);
  });

// A HASH IS ONLY USEFUL IF IT CHANGES. One flipped byte in a kilobyte must not pass.
  it("detects a single flipped byte", () => {
    const clean = new Uint8Array(1024).fill(7);
    const damaged = new Uint8Array(clean);
    damaged[512] = 8;
    expect(fnv1a(damaged)).not.toBe(fnv1a(clean));
  });
});


// ---- the pivot invariant ------------------------------------------------------------------------

/// A random-but-deterministic soak: symbols and repairs over a sliding window, with a loss pattern
/// that forces the decoder through re-keying, pivot collisions and cascading substitution.
///
/// EVERY PIVOT MUST HAVE A LEADING COEFFICIENT OF 1, and elimination TERMINATING depends on it:
/// cancelling a term relies on `coefficient ^ gfMul(1, coefficient)` being zero. A pivot stored
/// un-normalised makes `reduceAndStore` reduce the same term against the same pivot forever — a
/// wedged main thread, not a wrong picture. That shipped: `substitute` re-keyed a pivot onto a new
/// leading unknown without re-normalising it, and a live session's client stopped reporting
/// mid-stream with a healthy `mainLate` in its last line.
describe("RlcDecoder under sustained loss", () => {
  const SYM = 16;
  const symbolFor = (esi: number) => {
    const out = new Uint8Array(SYM);
    for (let i = 0; i < SYM; i++) out[i] = (esi * 31 + i * 7 + 11) & 0xff;
    return out;
  };
  const repairOver = (firstEsi: number, windowLen: number, seed: number) => {
    const coefficients = rlcCoefficients(seed, windowLen);
    const payload = new Uint8Array(SYM);
    for (let i = 0; i < windowLen; i++) gfMulAddInto(payload, symbolFor(firstEsi + i), coefficients[i]!);
    return payload;
  };

  it("terminates and recovers correctly through re-keying and collisions", () => {
    const decoder = new RlcDecoder();
    const WINDOW = 8;
    let seed = 0x1234567;
    // Lose two symbols out of every seven, which is far past what one repair per window covers — so
    // equations pile up, collide on the same leading unknown, and get re-keyed as later symbols
    // arrive. That is the machinery the defect lived in.
    for (let esi = 0; esi < 400; esi++) {
      const lost = esi % 7 === 3 || esi % 7 === 4;
      if (!lost) decoder.addSource(esi, symbolFor(esi));
      if (esi >= WINDOW) {
        seed = (seed * 1103515245 + 12345) >>> 0;
        decoder.addRepair(esi - WINDOW + 1, WINDOW, seed, repairOver(esi - WINDOW + 1, WINDOW, seed));
      }
    }
    // Whatever it recovered must be RIGHT. A decoder that returns garbage passes any test that only
    // checks it finished.
    let checked = 0;
    for (let esi = 300; esi < 380; esi++) {
      const got = decoder.get(esi);
      if (!got) continue;
      expect([...got]).toEqual([...symbolFor(esi)]);
      checked++;
    }
    expect(checked).toBeGreaterThan(40);
    expect(decoder.recovered).toBeGreaterThan(0);
  });

  // THE RE-KEY PATH, REACHED DELIBERATELY. A soak does not find it: it fires only when a pivot still
  // holds two or more terms AFTER its LEADING unknown becomes known, and under ordinary loss the
  // equation collapses to a single term and is solved instead. Constructed here in three steps.
  it("re-keys a pivot without breaking its normalisation", () => {
    const decoder = new RlcDecoder();
    const seed = 0xc0ffee;
    // 1. A repair over four symbols, NONE of them known: stored as a pivot with four terms, keyed
    //    and normalised on esi 0.
    decoder.addRepair(0, 4, seed, repairOver(0, 4, seed));
    expect(decoder.debugPivotLeadingCoefficients()).toEqual([1]);

    // 2. esi 0 arrives. Its term is eliminated, three terms remain — too many to solve — so the
    //    equation must be re-keyed onto esi 1.
    decoder.addSource(0, symbolFor(0));

    // 3. Whatever it is keyed on now must still lead with a coefficient of 1. Storing it unchanged
    //    leaves the coefficient esi 1 happened to carry, and every later reduction against this
    //    pivot then fails to cancel its term — reducing the same term forever.
    for (const leadingCoefficient of decoder.debugPivotLeadingCoefficients()) {
      expect(leadingCoefficient).toBe(1);
    }
  });

  // THE INVARIANT ITSELF, asserted directly. Elimination cancels a term by relying on the pivot's
  // leading coefficient being 1; a pivot stored without normalising makes the reduction loop run
  // forever. It is checked here rather than through behaviour because the loop's own bound now turns
  // that infinite loop into a quiet early exit — survivable and unobservable at once.
  it("keeps every pivot normalised through re-keying", () => {
    const decoder = new RlcDecoder();
    const WINDOW = 8;
    let seed = 0x7654321;
    for (let esi = 0; esi < 400; esi++) {
      // A pattern that recovers symbols LATER, which is what drives a pivot's leading unknown to
      // become known and forces the re-key path this invariant lives in.
      // THREE LOSSES IN EVERY EIGHT, so a window carries three unknowns and its equation is stored as
      // a pivot with three terms. The re-key path only fires when a pivot still has two or more terms
      // AFTER its leading unknown becomes known — with lighter loss the equation collapses to one
      // term and is solved instead, and the path is never reached. Two repairs per step give the
      // system enough rank to keep solving, which is what makes leading unknowns become known.
      if (esi % 8 > 3) decoder.addSource(esi, symbolFor(esi));
      if (esi >= WINDOW) {
        for (let r = 0; r < 2; r++) {
          seed = (seed * 1103515245 + 12345) >>> 0;
          decoder.addRepair(esi - WINDOW + 1, WINDOW, seed, repairOver(esi - WINDOW + 1, WINDOW, seed));
        }
      }
      for (const leadingCoefficient of decoder.debugPivotLeadingCoefficients()) {
        expect(leadingCoefficient).toBe(1);
      }
    }
  });
});

// THE LANE'S HALVES (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §3): an encoder on the page, over a window
// of any size, and a decoder whose history the caller sets.
describe("the lane's encoder and decoder", () => {
  const W = 32;
  const pad = (b: Uint8Array) => { const out = new Uint8Array(W); out.set(b); return out; };
  const patterned = (esi: number, length: number) => {
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) out[i] = (esi * 31 + i * 7 + 11) & 0xff;
    return out;
  };

  it("a repair over symbols of different lengths recovers one erasure", () => {
    const symbols = [patterned(0, 3), patterned(1, 9), patterned(2, 5)];
    const repair = rlcRepair(symbols, 0x12345678);
    expect(repair.length).toBe(9);   // sized to the longest symbol
    const d = new RlcDecoder(1024);
    d.addSource(0, pad(symbols[0]!));
    d.addSource(2, pad(symbols[2]!));
    expect(d.addRepair(0, 3, 0x12345678, pad(repair))).toEqual([1]);
    expect([...d.get(1)!]).toEqual([...pad(symbols[1]!)]);
  });

  it("abandons an equation reaching past its history instead of truncating it", () => {
    // Dropping the old unknown's term would make the equation WRONG — a wrong keystroke, a corrupt terminal stream.
    // ESIs 2 and 8 are both withheld: 2 is past the history (newest 9, history 4), 8 is inside it. Dropping 2's term
    // would leave 8 alone and solve it — so 8 must stay unknown too, or the bug is invisible.
    const d = new RlcDecoder(4);
    const symbols = Array.from({ length: 10 }, (_, i) => patterned(i, W));
    symbols.forEach((s, i) => { if (i !== 2 && i !== 8) d.addSource(i, s); });
    expect(d.addRepair(2, 8, 77, rlcRepair(symbols.slice(2), 77))).toEqual([]);
    expect(d.has(2)).toBe(false);
    expect(d.has(8)).toBe(false);
  });

  it("keeps a history the caller sets", () => {
    const d = new RlcDecoder(1024);
    for (let esi = 0; esi < 900; esi++) d.addSource(esi, patterned(esi, W));
    expect(d.has(0)).toBe(true);           // 900 symbols in: the default 128 would have pruned it
    expect(new RlcDecoder().floorEsi()).toBe(-1 - 128);
  });

  it("rlcNextSeed is the coefficient generator's step", () => {
    // The generator's first output for a seed IS the next seed: the first coefficient is next(seed) % 255 + 1.
    for (const seed of [1, 0x12345678, 0x80000000, 0xffffffff]) {
      expect(rlcCoefficients(seed, 1)[0]).toBe((rlcNextSeed(seed) % 255) + 1);
    }
    // Seed 0 is a fixed point of xorshift, so both generators substitute 0x9e3779b9: pinned by the third implementation.
    const zero = laneVectors.nextSeed.find((s) => s.seed === 0)!;
    expect(rlcNextSeed(0)).toBe(zero.next);
  });
});

// A SOURCE BELOW THE FLOOR IS REFUSED: prune deletes it at once, so the esi addSource returned named a symbol `get` could
// not give — and the lane's engine threw on it. rdev_rlc_lane_test.go runs the same case.
it("the decoder refuses a source below its floor", () => {
  const d = new RlcDecoder(1024);
  const payload = new Uint8Array(32);
  d.addSource(2000, payload);
  expect([d.addSource(500, payload), d.has(500)], "a source below the floor (976)").toEqual([[], false]);
  expect([d.addSource(976, payload), d.has(976)], "a source AT the floor is kept by prune and taken").toEqual([[976], true]);
});
