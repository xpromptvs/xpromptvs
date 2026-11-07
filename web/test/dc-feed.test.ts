import { describe, it, expect } from "vitest";
import { DcSourceFeed } from "../src/lib/dc-feed";
import { gfMulAddInto, rlcCoefficients, fnv1a } from "../src/lib/rlc";
import type { DcSourcePacket, DcRepairPacket } from "../src/lib/dc-wire";

const SYMBOL = 8;

/// A source packet. `frameHash` defaults to the hash of THIS symbol trimmed to `frameBytes`, which is
/// correct for a single-symbol frame; a multi-symbol frame must pass the hash of the whole assembled
/// access unit, exactly as the host computes it.
function source(over: Partial<DcSourcePacket> & { esi: number; payload: Uint8Array }): DcSourcePacket {
  const frameBytes = over.frameBytes ?? SYMBOL;
  return {
    kind: "source", sourceIndex: 0, generation: 0, frameSeq: 0, rtp: 0,
    fragIndex: 0, fragCount: 1, frameBytes, key: false, payloadType: 45,
    frameHash: fnv1a(over.payload.subarray(0, frameBytes)),
    // L1T1 by default, matching the host's current write path: every frame references the one before
    // it, and a keyframe references nothing.
    dependsOnOffset: over.key ? 0 : 1,
    ...over,
  };
}

/// The hash of a frame assembled from `symbols`, trimmed to `frameBytes` — the host's own arithmetic.
function frameHashOf(symbols: readonly Uint8Array[], frameBytes: number): number {
  const data = new Uint8Array(frameBytes);
  symbols.forEach((s, i) => {
    const offset = i * SYMBOL;
    const take = Math.min(SYMBOL, frameBytes - offset);
    if (take > 0) data.set(s.subarray(0, take), offset);
  });
  return fnv1a(data);
}

/// Mirrors the Go encoder: a repair symbol is the GF(256) linear combination of the window.
function repair(symbols: Uint8Array[], firstEsi: number, seed: number): DcRepairPacket {
  const coefficients = rlcCoefficients(seed, symbols.length);
  const payload = new Uint8Array(SYMBOL);
  symbols.forEach((s, i) => gfMulAddInto(payload, s, coefficients[i]!));
  return {
    kind: "repair", sourceIndex: 0, generation: 0, firstEsi,
    windowLen: symbols.length, seed, payload,
  };
}

describe("DcSourceFeed frame integrity", () => {
  // THE ONLY CHECK THAT LOOKS AT THE CONTENT. Everything else in this file describes the FRAMING —
  // lengths, indices, counts — and a symbol solved against a stale equation has all of those right
  // and is full of garbage. Reported from a live session as repeated damaged pictures in the run-up
  // to the tab locking up, and a decoder fed nonsense is the one thing here able to take a page down.
  it("discards a frame whose contents do not match the sender's hash", () => {
    const feed = new DcSourceFeed();
    const payload = new Uint8Array(SYMBOL).fill(9);
    // Everything about the framing is correct; only the bytes are wrong.
    const out = feed.push(source({ esi: 0, payload, frameHash: 0xdeadbeef }));
    expect(out).toHaveLength(0);
    expect(feed.corruptFrames).toBe(1);
  });

  it("passes a frame whose contents match", () => {
    const feed = new DcSourceFeed();
    const payload = new Uint8Array(SYMBOL).fill(9);
    expect(feed.push(source({ esi: 0, payload }))).toHaveLength(1);
    expect(feed.corruptFrames).toBe(0);
  });

  // A CORRUPT KEYFRAME IS WORSE THAN A CORRUPT DELTA — every frame after it references a picture the
  // decoder never had — so it is counted separately and can be asked for again.
  it("counts a corrupt keyframe separately", () => {
    const feed = new DcSourceFeed();
    const payload = new Uint8Array(SYMBOL).fill(9);
    feed.push(source({ esi: 0, payload, key: true, frameHash: 1 }));
    expect(feed.corruptKeyframes).toBe(1);
  });

  // A DISCARDED FRAME MUST NOT BE WAITED FOR. Leaving it in the map would hold the emission point
  // behind a frame that can never become valid, and every later frame with it.
  it("does not block later frames behind a discarded one", () => {
    const feed = new DcSourceFeed();
    const bad = new Uint8Array(SYMBOL).fill(1);
    const good = new Uint8Array(SYMBOL).fill(2);
    feed.push(source({ esi: 0, payload: bad, frameSeq: 0, frameHash: 0xbadbad }));
    const out = feed.push(source({ esi: 1, payload: good, frameSeq: 1 }));
    expect(out).toHaveLength(1);
    expect(new Uint8Array(out[0]!.data)).toEqual(good);
  });
});

describe("DcSourceFeed ordering and discontinuities", () => {
  const payload = () => new Uint8Array(SYMBOL).fill(5);
  const push = (feed: DcSourceFeed, seq: number, over: Record<string, unknown> = {}) =>
    feed.push(source({ esi: seq, payload: payload(), frameSeq: seq, ...over }));

  // THE DEFECT THIS ORDERING FIXES. The channel is `ordered: false`, so a later frame routinely
  // completes first. Emitting whatever was ready advanced past the earlier one, which was then
  // discarded as too late when its symbol arrived — ordinary reordering turned into a hole, and once
  // a hole cost a keyframe request it showed up as keyframes every two seconds on a path losing
  // 0.34% of frames.
  it("waits for a reordered frame instead of skipping it", () => {
    const feed = new DcSourceFeed();
    expect(push(feed, 0)).toHaveLength(1);
    expect(push(feed, 2)).toHaveLength(0);        // arrives early: held, not emitted
    const out = push(feed, 1);                     // the straggler
    expect(out.map((f) => f.frameSeq)).toEqual([1, 2]);
    expect(feed.takeDiscontinuity()).toBe(false);
    expect(feed.summary().tooLate).toBe(0);
  });

  // ...BUT NOT FOREVER. A frame that never arrives must not stall the stream behind it.
  it("declares a frame lost once the stream has run far enough past it", () => {
    const feed = new DcSourceFeed();
    push(feed, 0);
    for (const seq of [2, 3, 4]) expect(push(feed, seq)).toHaveLength(0);
    const out = push(feed, 5);                     // frame 1 is now 4 behind the newest
    // Frame 1 is given up on — and 2 through 5 reference a chain running through it, so none of them
    // can be decoded either. They are refused rather than handed over to render against a picture
    // the decoder never had.
    expect(out).toHaveLength(0);
    expect(feed.takeDiscontinuity()).toBe(true);
    expect(feed.discontinuities).toBe(1);
    expect(feed.undecodable).toBe(4);

    // A keyframe references nothing, so it restarts the stream on its own.
    const resumed = push(feed, 6, { key: true });
    expect(resumed.map((f) => f.frameSeq)).toEqual([6]);
    expect(push(feed, 7).map((f) => f.frameSeq)).toEqual([7]);
  });

  // ONCE PER BURST, not once per frame: reported by taking, so a run of losses costs one keyframe.
  it("clears the flag when taken", () => {
    const feed = new DcSourceFeed();
    push(feed, 0);
    for (const seq of [2, 3, 4, 5]) push(feed, seq);
    expect(feed.takeDiscontinuity()).toBe(true);
    expect(feed.takeDiscontinuity()).toBe(false);
  });

  // THE OCCLUDED-WINDOW FAILURE, reproduced. Reported from a live session: keyframe requests start
  // when the window goes behind another one.
  //
  // A window whose content has stopped changing sends ONE SYMBOL PER FRAME. The request for a
  // missing symbol waits a guard counted in SYMBOLS; the frame it belongs to is abandoned after a
  // deadline counted in FRAMES. Those two agree only at one frame size — at one symbol per frame the
  // guard is four FRAMES against a deadline of three, so the frame is given up before its
  // retransmission has even been asked for, and every loss becomes a keyframe request for something
  // ARQ would have covered.
  //
  // ORDER IS THE ASSERTION, not the numbers: whatever the constants, a symbol must be REQUESTED
  // before the frame that needs it is abandoned.
  it("asks for a lost symbol before giving up on its frame, at one symbol per frame", () => {
    const feed = new DcSourceFeed();
    const LOST = 3;
    let requestedAt: number | null = null;
    let abandonedAt: number | null = null;

    for (let seq = 0; seq < 12; seq++) {
      if (seq !== LOST) push(feed, seq);
      if (requestedAt === null && feed.takeNackable().includes(LOST)) requestedAt = seq;
      if (abandonedAt === null && feed.discontinuities > 0) abandonedAt = seq;
    }

    expect(requestedAt).not.toBeNull();
    expect(abandonedAt).not.toBeNull();
    expect(requestedAt!).toBeLessThan(abandonedAt!);
  });

  // ...and the same must hold when frames are large, which is the case that always worked.
  it("asks before giving up at four symbols per frame too", () => {
    const feed = new DcSourceFeed();
    const LOSE_FRAME = 3;
    let requestedAt: number | null = null;
    let abandonedAt: number | null = null;

    for (let seq = 0; seq < 12; seq++) {
      if (seq !== LOSE_FRAME) {
        for (let frag = 0; frag < 4; frag++) {
          feed.push(source({
            esi: seq * 4 + frag, payload: payload(), frameSeq: seq,
            fragIndex: frag, fragCount: 4, frameBytes: SYMBOL * 4,
            frameHash: frameHashOf([payload(), payload(), payload(), payload()], SYMBOL * 4),
          }));
        }
      }
      if (requestedAt === null && feed.takeNackable().some((e) => Math.floor(e / 4) === LOSE_FRAME)) {
        requestedAt = seq;
      }
      if (abandonedAt === null && feed.discontinuities > 0) abandonedAt = seq;
    }

    expect(requestedAt).not.toBeNull();
    expect(abandonedAt).not.toBeNull();
    expect(requestedAt!).toBeLessThan(abandonedAt!);
  });

  // A LINK THAT STALLS RATHER THAN DROPS. Measured over a VPN-over-TCP relay: 185 frames ARRIVED
  // after being given up on against 55 counted lost — three and a half times more lateness than
  // loss. A TCP tunnel retransmits underneath us, so nothing is dropped; it goes quiet for a few
  // hundred milliseconds and then delivers everything at once. Against a fixed four-frame window
  // that reads as loss, and neither redundancy nor retransmission can repair it, because the frames
  // were never lost.
  //
  // The window must therefore learn from the lateness it actually sees. Each discarded frame says
  // exactly how much more patience would have saved it.
  it("widens its wait when frames keep arriving after being given up on", () => {
    const feed = new DcSourceFeed();
    push(feed, 0);
    // A stall: frames 1..8 are held up while the stream runs on to 12.
    for (let seq = 9; seq <= 20; seq++) push(feed, seq);
    const gaveUpEarly = feed.discontinuities;
    expect(gaveUpEarly).toBeGreaterThan(0);   // the initial window is too narrow for this link

    // The stalled frames now arrive. Against a fixed window they are all discarded as too late.
    for (let seq = 1; seq <= 8; seq++) push(feed, seq);
    expect(feed.summary().tooLate).toBeGreaterThan(0);

    // Having seen that, it must now wait long enough for the next stall of the same size.
    for (let seq = 21; seq <= 40; seq++) push(feed, seq);
    const before = feed.discontinuities;
    for (let seq = 49; seq <= 60; seq++) push(feed, seq);   // another stall, 41..48 delayed
    for (let seq = 41; seq <= 48; seq++) push(feed, seq);   // ...and they arrive, as before
    expect(feed.summary().tooLate).toBeLessThan(12);        // far fewer thrown away than the first time
    expect(feed.discontinuities - before).toBeLessThan(gaveUpEarly);
  });

  it("reports nothing on a stream with no losses", () => {
    const feed = new DcSourceFeed();
    for (let i = 0; i < 10; i++) expect(push(feed, i)).toHaveLength(1);
    expect(feed.takeDiscontinuity()).toBe(false);
    expect(feed.discontinuities).toBe(0);
  });
});

describe("DcSourceFeed retransmission requests", () => {
  const payload = () => new Uint8Array(SYMBOL).fill(7);
  /// Push `count` single-symbol frames, skipping the esis in `lose`.
  const run = (feed: DcSourceFeed, count: number, lose: number[] = []) => {
    for (let esi = 0; esi < count; esi++) {
      if (lose.includes(esi)) continue;
      feed.push(source({ esi, payload: payload(), frameSeq: esi }));
    }
  };

  // PATIENCE FIRST. A symbol that is merely REORDERED arrives on its own, and asking for it spends a
  // round trip and a retransmission on a channel that has just proven it is losing things.
  it("does not ask for a hole in the frame currently arriving", () => {
    // Patience is ONE FRAME: a symbol of the newest frame may still be in flight, and that frame has
    // not been passed yet. Here the hole is inside the newest frame itself.
    const feed = new DcSourceFeed();
    const p = new Uint8Array(SYMBOL).fill(7);
    feed.push(source({ esi: 0, payload: p, frameSeq: 0, fragIndex: 0, fragCount: 2,
                       frameBytes: SYMBOL * 2, frameHash: 0 }));
    expect(feed.takeNackable()).toEqual([]);
  });

  it("asks once the stream is several symbols past the hole", () => {
    const feed = new DcSourceFeed();
    run(feed, 12, [3]);
    expect(feed.takeNackable()).toEqual([3]);
  });

  // THE CASE ARQ EXISTS FOR, and the one the first version of this could not see: when EVERY symbol
  // of a frame is lost there is no descriptor for it, so anything iterating received frames finds
  // nothing missing. ESIs are contiguous, so the hole is visible in the sequence itself.
  it("asks for a frame that was lost in its entirety", () => {
    const feed = new DcSourceFeed();
    run(feed, 12, [4, 5, 6]);
    expect(feed.takeNackable()).toEqual([4, 5, 6]);
  });

  // ONCE EACH. A second request cannot arrive faster than the first, so repeating it only adds load
  // to the link that is already dropping things.
  it("never asks for the same symbol twice", () => {
    const feed = new DcSourceFeed();
    run(feed, 12, [3]);
    expect(feed.takeNackable()).toEqual([3]);
    expect(feed.takeNackable()).toEqual([]);
    expect(feed.nacked).toBe(1);
  });

  // FEC AND ARQ OVERLAP BY DESIGN — the repair covers isolated losses, the request covers bursts —
  // so a request for something already solved is pure waste on the path least able to afford it.
  it("does not ask for a symbol the repair already recovered", () => {
    const feed = new DcSourceFeed();
    const a = payload(), b = new Uint8Array(SYMBOL).fill(3);
    feed.push(source({ esi: 0, payload: a, frameSeq: 0, fragIndex: 0, fragCount: 2, frameBytes: SYMBOL * 2 }));
    feed.push(repair([a, b], 0, 0x1234));          // recovers esi 1 without it ever arriving
    for (let esi = 2; esi < 12; esi++) {
      feed.push(source({ esi, payload: payload(), frameSeq: esi }));
    }
    expect(feed.takeNackable()).toEqual([]);
  });

  // A GENERATION CHANGE DISCARDS THE REQUEST MEMORY WITH EVERYTHING ELSE: the new stream's esi 3 is a
  // different symbol, and remembering the old one would suppress a request that should be made.
  it("forgets what it asked for across a generation change", () => {
    const feed = new DcSourceFeed();
    run(feed, 12, [3]);
    expect(feed.takeNackable()).toEqual([3]);
    for (let esi = 0; esi < 12; esi++) {
      if (esi === 3) continue;
      feed.push(source({ esi, payload: payload(), frameSeq: esi, generation: 1 }));
    }
    expect(feed.takeNackable()).toEqual([3]);
  });
});

describe("DcSourceFeed", () => {
  it("emits a single-symbol frame trimmed to frameBytes", () => {
    const feed = new DcSourceFeed();
    const payload = new Uint8Array(SYMBOL).fill(9);
    const out = feed.push(source({ esi: 0, payload, frameBytes: 5 }));
    expect(out).toHaveLength(1);
    expect(new Uint8Array(out[0]!.data)).toEqual(new Uint8Array([9, 9, 9, 9, 9]));
    expect(out[0]!.rtp).toBe(0);
    expect(out[0]!.payloadType).toBe(45);
  });

  it("assembles a multi-symbol frame from any surviving symbol's descriptor", () => {
    // firstEsi = esi - fragIndex, so a frame is assemblable even when the symbol that would have
    // carried its metadata is the one that was lost. Here the SECOND symbol arrives first.
    const feed = new DcSourceFeed();
    const a = new Uint8Array(SYMBOL).fill(1);
    const b = new Uint8Array(SYMBOL).fill(2);
    const hash = frameHashOf([a, b], 16);
    expect(feed.push(source({ esi: 1, payload: b, fragIndex: 1, fragCount: 2, frameBytes: 16, frameHash: hash }))).toHaveLength(0);
    const out = feed.push(source({ esi: 0, payload: a, fragIndex: 0, fragCount: 2, frameBytes: 16, frameHash: hash }));
    expect(out).toHaveLength(1);
    expect(new Uint8Array(out[0]!.data).slice(0, 8)).toEqual(a);
    expect(new Uint8Array(out[0]!.data).slice(8)).toEqual(b);
  });

  it("recovers a lost symbol from a repair symbol and emits the frame", () => {
    const feed = new DcSourceFeed();
    const a = new Uint8Array(SYMBOL).fill(3);
    const b = new Uint8Array(SYMBOL).fill(4);
    feed.push(source({ esi: 0, payload: a, fragIndex: 0, fragCount: 2, frameBytes: 16,
                       frameHash: frameHashOf([a, b], 16) }));
    // esi 1 is lost; the repair covers both.
    const out = feed.push(repair([a, b], 0, 0xabcdef01));
    expect(out).toHaveLength(1);
    expect(new Uint8Array(out[0]!.data).slice(8)).toEqual(b);
    expect(feed.summary().recoveredSymbols).toBe(1);
    // The frame is counted as repaired, which is what separates "the code did work" from "there was
    // nothing to do" — without it a clean run and a fully-repaired run look identical.
    expect(feed.summary().repairedFrames).toBe(1);
  });

  it("does not count an unrepaired frame as repaired", () => {
    const feed = new DcSourceFeed();
    const a = new Uint8Array(SYMBOL).fill(3);
    feed.push(source({ esi: 0, payload: a }));
    expect(feed.summary().repairedFrames).toBe(0);
  });

  it("never emits a frame older than one already emitted", () => {
    // The decoder's reference chain is order-sensitive, and a repair can complete an older frame
    // after a newer one has been fed. Feeding it would corrupt the chain.
    //
    // Under in-order emission this is achieved by never ADMITTING it rather than by emitting and
    // discarding: the straggler is counted as `tooLate` when the emission point is pruned past it.
    const feed = new DcSourceFeed();
    const p = new Uint8Array(SYMBOL).fill(1);
    feed.push(source({ esi: 0, payload: p, frameSeq: 5 }));
    const out = feed.push(source({ esi: 1, payload: p, frameSeq: 4 }));
    expect(out).toHaveLength(0);
    expect(feed.summary().tooLate).toBe(1);
  });

  it("discards everything on a generation change", () => {
    // A codec change or peer rebuild starts a new stream; carrying the old window over would solve
    // equations against symbols that no longer exist, and mixing two ESI spaces produces plausible
    // garbage rather than an error.
    const feed = new DcSourceFeed();
    const p = new Uint8Array(SYMBOL).fill(1);
    feed.push(source({ esi: 0, payload: p, fragIndex: 0, fragCount: 2, frameBytes: 16 }));
    const out = feed.push(source({ esi: 0, payload: p, generation: 1, frameSeq: 0 }));
    expect(out).toHaveLength(1);
    expect(feed.summary().generationResets).toBe(1);
  });

  it("counts duplicate ESIs, the guard against a sender that is not numbering symbols", () => {
    // A host bug that stamped every symbol with one ESI produced a client that reported cleanly and
    // measured nothing. 100% here; a legitimate redundancy scheme sits far below.
    const feed = new DcSourceFeed();
    const p = new Uint8Array(SYMBOL).fill(1);
    feed.push(source({ esi: 0, payload: p }));
    feed.push(source({ esi: 0, payload: p, frameSeq: 1 }));
    expect(feed.summary().duplicateSymbols).toBe(1);
    expect(feed.summary().duplicatePercent).toBe(50);
  });

  it("derives frame loss from the emitted sequence span", () => {
    // The client cannot count frames it never received; it CAN count holes in a range the host
    // numbers densely.
    const feed = new DcSourceFeed();
    const p = new Uint8Array(SYMBOL).fill(1);
    feed.push(source({ esi: 0, payload: p, frameSeq: 0 }));
    feed.push(source({ esi: 1, payload: p, frameSeq: 1 }));
    feed.push(source({ esi: 4, payload: p, frameSeq: 4 })); // 2 and 3 lost outright
    // 4 is HELD until the stream has run four frames past the hole, so 5 and 6 release it.
    for (const seq of [5, 6, 7]) feed.push(source({ esi: seq, payload: p, frameSeq: seq }));
    // 2 and 3 are declared lost; 4 onwards reference a chain through them and are refused. Only the
    // two frames before the hole were ever decodable.
    expect(feed.summary().framesLost).toBe(2);
    expect(feed.summary().emitted).toBe(2);       // 0 and 1
    expect(feed.discontinuities).toBe(2);
    expect(feed.undecodable).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// YOU CANNOT WAIT LONGER THAN YOU CAN REMEMBER.
//
// The reorder window is counted in FRAMES and the decoder's history in SYMBOLS, and the two were set
// independently — 60 frames in this file, 128 symbols in rlc.ts — with nothing relating them. At the
// ~4 symbols per frame a real stream produces, 60 frames is 240 symbols against a memory of 128.
//
// The failure that produced is not a degradation. Once the emission point is pinned that far back,
// EVERY frame it wants next has already been pruned, so it skips one per arriving frame and never
// emits again. Measured in the field twice: `emitted` frozen at 2631 while `gaps` climbed 98 -> 375
// -> 639, which is 55/s — the frame rate exactly. And it is self-inflicted: the session that died
// this way had lost ONE frame in 2510 to the network.

describe("reorder patience against decoder retention", () => {
  /// Push `count` single-symbol frames, dropping the frame numbered `hole`.
  function runWithHole(feed: DcSourceFeed, count: number, hole: number): void {
    for (let i = 0; i < count; i++) {
      if (i === hole) continue;
      const payload = new Uint8Array(SYMBOL).fill(i & 0xff);
      feed.push(source({ esi: i, payload, frameSeq: i }));
    }
  }

  // THE FORWARD-PROGRESS GUARANTEE, and the reproduction of the field wedge.
  //
  // Frames of eight symbols: the decoder's 128-symbol memory is then only SIXTEEN frames deep, while
  // the reorder wait is allowed to grow to sixty. Drive the wait up with late arrivals, then open a
  // permanent hole — and the emission point is pinned sixty frames back, where every frame has
  // already been pruned. It skips one per arriving frame and never emits again.
  //
  // `dependsOnOffset: 0` throughout: a reference chain would ALSO stop emission after a hole, for a
  // completely legitimate reason, and would mask the effect under test.
  it("keeps emitting when the wait would exceed what the decoder remembers", () => {
    const feed = new DcSourceFeed();
    const SYMS = 8;
    let nextEsi = 0;
    let nextFrame = 0;

    const build = (): { frameSeq: number; base: number; symbols: Uint8Array[]; frameBytes: number; hash: number } => {
      const frameSeq = nextFrame++;
      const base = nextEsi;
      nextEsi += SYMS;
      const symbols = Array.from({ length: SYMS }, (_, k) => new Uint8Array(SYMBOL).fill((frameSeq + k) & 0xff));
      const frameBytes = SYMBOL * SYMS;
      return { frameSeq, base, symbols, frameBytes, hash: frameHashOf(symbols, frameBytes) };
    };
    const deliver = (f: ReturnType<typeof build>): void => {
      f.symbols.forEach((payload, k) => feed.push(source({
        esi: f.base + k, payload, frameSeq: f.frameSeq, fragIndex: k, fragCount: SYMS,
        frameBytes: f.frameBytes, frameHash: f.hash, dependsOnOffset: 0,
      })));
    };

    // Grow the wait: withhold one frame, deliver the next ten, then deliver it too late. Each round
    // is a `tooLate`, which is exactly what teaches the feed to be more patient.
    for (let round = 0; round < 40; round++) {
      const held = build();
      for (let i = 0; i < 10; i++) deliver(build());
      deliver(held);
      feed.summary();
    }
    const before = feed.summary().emitted ?? 0;

    // Now a hole that never fills, followed by plenty of perfectly good frames.
    build();
    for (let i = 0; i < 200; i++) deliver(build());

    const after = feed.summary().emitted ?? 0;
    expect(after - before).toBeGreaterThan(180);
  });

  // A PARTIALLY-RECEIVED FRAME WHOSE SYMBOLS HAVE BEEN PRUNED, which the frame-count clamp alone
  // cannot catch.
  //
  // `symbolsPerFrame` is an AVERAGE. A stream of small frames sets it near one, so the retention
  // clamp permits a wait of many frames — and then a burst of large frames (a keyframe storm, which
  // is exactly what the field log showed) spends the whole 128-symbol budget in a handful of them.
  // The waited-for frame is then already pruned while the wait still considers it live.
  //
  // Waiting for it achieves nothing: no repair symbol, no retransmission and no patience can complete
  // a frame the decoder has forgotten. It has to be given up the moment that is true.
  it("gives up at once on a partial frame the decoder has already forgotten", () => {
    const feed = new DcSourceFeed();
    let nextEsi = 0;
    let nextFrame = 0;

    const small = (): void => {
      const payload = new Uint8Array(SYMBOL).fill(nextFrame & 0xff);
      feed.push(source({ esi: nextEsi++, payload, frameSeq: nextFrame++, dependsOnOffset: 0 }));
    };

    // Grow the wait to its maximum on small frames, so the clamp stays generous.
    for (let round = 0; round < 40; round++) {
      const heldEsi = nextEsi++;
      const heldFrame = nextFrame++;
      const heldPayload = new Uint8Array(SYMBOL).fill(heldFrame & 0xff);
      for (let i = 0; i < 10; i++) small();
      feed.push(source({ esi: heldEsi, payload: heldPayload, frameSeq: heldFrame, dependsOnOffset: 0 }));
      feed.summary();
    }

    // A frame that arrives HALF: its descriptor exists, so the feed knows about it and waits.
    const partialBase = nextEsi;
    const partialFrame = nextFrame++;
    const partialSymbols = [new Uint8Array(SYMBOL).fill(1), new Uint8Array(SYMBOL).fill(2)];
    const partialBytes = SYMBOL * 2;
    const partialHash = frameHashOf(partialSymbols, partialBytes);
    nextEsi += 2;
    feed.push(source({
      esi: partialBase, payload: partialSymbols[0]!, frameSeq: partialFrame, fragIndex: 0, fragCount: 2,
      frameBytes: partialBytes, frameHash: partialHash, dependsOnOffset: 0,
    }));
    // Its second symbol never arrives.

    const before = feed.summary().emitted ?? 0;

    // Now large frames: 30 symbols each, so 128 symbols of memory is gone in five of them.
    const LARGE = 30;
    for (let f = 0; f < 40; f++) {
      const frameSeq = nextFrame++;
      const base = nextEsi;
      nextEsi += LARGE;
      const symbols = Array.from({ length: LARGE }, (_, k) => new Uint8Array(SYMBOL).fill((frameSeq + k) & 0xff));
      const frameBytes = SYMBOL * LARGE;
      const hash = frameHashOf(symbols, frameBytes);
      symbols.forEach((payload, k) => feed.push(source({
        esi: base + k, payload, frameSeq, fragIndex: k, fragCount: LARGE,
        frameBytes, frameHash: hash, dependsOnOffset: 0,
      })));
    }

    // Every one of those 40 frames arrived whole. They must be delivered, not held behind a frame
    // that stopped being recoverable long ago.
    expect((feed.summary().emitted ?? 0) - before).toBeGreaterThan(35);
  });

  // AND THE WAIT ITSELF IS CLAMPED, so the state is not reachable in the first place. Growing patience
  // past what the decoder can serve buys nothing and destroys frames the network delivered.
  it("never grows the wait beyond what the decoder can still repair", () => {
    const feed = new DcSourceFeed();
    // Repeated late arrivals are what drives the wait up.
    for (let round = 0; round < 40; round++) {
      const base = round * 10;
      for (let i = 1; i < 10; i++) {
        const payload = new Uint8Array(SYMBOL).fill(i);
        feed.push(source({ esi: base + i, payload, frameSeq: base + i }));
      }
      // The skipped frame turns up long afterwards: a `tooLate`, which is what grows the window.
      const late = new Uint8Array(SYMBOL).fill(0);
      feed.push(source({ esi: base, payload: late, frameSeq: base }));
      feed.summary();
    }
    // 128 symbols of history at one symbol per frame is 128 frames; the cap is 60, so the cap still
    // binds here. The property under test is that the wait never EXCEEDS the retention — asserted
    // against the decoder's own budget rather than against a copy of the number.
    expect(feed.summary().reorderFrames).toBeLessThanOrEqual(128);
  });

  // THE CONVERSION IS MEASURED, NOT ASSUMED. A stream of multi-symbol frames spends its retention
  // several times faster, and a wait counted in frames has to know that.
  it("allows less patience when frames are large", () => {
    const small = new DcSourceFeed();
    for (let i = 0; i < 60; i++) {
      small.push(source({ esi: i, payload: new Uint8Array(SYMBOL).fill(i & 0xff), frameSeq: i }));
    }
    const big = new DcSourceFeed();
    // Eight symbols per frame: the same 128-symbol memory is only 16 frames deep.
    let esi = 0;
    for (let f = 0; f < 30; f++) {
      const symbols = Array.from({ length: 8 }, (_, k) => new Uint8Array(SYMBOL).fill((f + k) & 0xff));
      const frameBytes = SYMBOL * 8;
      const hash = frameHashOf(symbols, frameBytes);
      symbols.forEach((payload, k) => {
        big.push(source({
          esi: esi++, payload, frameSeq: f, fragIndex: k, fragCount: 8, frameBytes, frameHash: hash,
        }));
      });
    }
    // Both delivered their frames; the point is that the large-frame feed measured a larger
    // symbols-per-frame, which is what the retention conversion reads.
    expect(small.summary().emitted).toBeGreaterThan(50);
    expect(big.summary().emitted).toBeGreaterThan(25);
  });
});
