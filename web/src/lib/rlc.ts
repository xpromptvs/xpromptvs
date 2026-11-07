/// Decoder for the sliding-window Random Linear Code the host emits (RFC 8681 in shape).
/// The field, the coefficient generator and the wire layout are mirrored from
/// host/streaming-engine/PionBridge/rdev_dc_rlc.go — and the mirroring is LOAD-BEARING in a
/// way that will not announce itself: a disagreement between the two decodes to plausible garbage,
/// not to an error. Which is why the coefficients are DERIVED from a shared seeded generator on both
/// sides rather than shipped on the wire, so there is one definition to get wrong instead of two.
///
/// WHY A SLIDING WINDOW AND NOT A BLOCK CODE. Parity over K frames cannot repair the first of them
/// until the Kth is sent — K x 16.7 ms against a 7-16 ms playout margin. Here repair for frame i
/// rides WITH frame i, and more repair for it keeps arriving with i+1 and i+2, so a single loss is
/// free and a second one costs one frame instead of everything until the next IDR.

// ---- GF(256), primitive polynomial 0x11d, generator 2 -------------------------------------------
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  // Doubled so a sum of two logs needs no modulo in the inner loop.
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255]!;
}

export function gfMul(a: number, b: number): number {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a]! + GF_LOG[b]!]!;
}

export function gfDiv(a: number, b: number): number {
  if (a === 0) return 0;
  return GF_EXP[GF_LOG[a]! - GF_LOG[b]! + 255]!;
}

/// dst ^= coefficient * src. The only vector operation the scheme needs.
export function gfMulAddInto(dst: Uint8Array, src: Uint8Array, coefficient: number): void {
  if (coefficient === 0) return;
  const logC = GF_LOG[coefficient]!;
  for (let i = 0; i < dst.length; i++) {
    const s = src[i]!;
    // Written as an explicit read-modify-write: `^=` on an indexed access reads as possibly
    // undefined under noUncheckedIndexedAccess, and silencing that with a cast on the whole
    // statement would hide a genuine out-of-range one day.
    if (s !== 0) dst[i] = dst[i]! ^ GF_EXP[logC + GF_LOG[s]!]!;
  }
}

/// The coefficient generator. `>>> 0` after every step is what keeps this identical to Go's uint32:
/// JavaScript's bitwise operators produce SIGNED 32-bit results, so without it the shifts diverge
/// from the host's the moment the high bit is set — and diverge silently.
export function rlcCoefficients(seed: number, count: number): Uint8Array {
  let state = seed >>> 0;
  if (state === 0) state = 0x9e3779b9;   // a zero state is a fixed point for xorshift
  const out = new Uint8Array(count);
  for (let i = 0; i < count; i++) {
    state = (state ^ (state << 13)) >>> 0;
    state = (state ^ (state >>> 17)) >>> 0;
    state = (state ^ (state << 5)) >>> 0;
    out[i] = (state % 255) + 1;          // never zero: every window member must really participate
  }
  return out;
}

/// The seed after `seed`: one step of the coefficient generator — Go's `newXorshift32(seed).next()`.
export function rlcNextSeed(seed: number): number {
  let state = seed >>> 0;
  if (state === 0) state = 0x9e3779b9;
  state = (state ^ (state << 13)) >>> 0;
  state = (state ^ (state >>> 17)) >>> 0;
  state = (state ^ (state << 5)) >>> 0;
  return state;
}

/// One repair symbol over `symbols` — consecutive ESIs, the first being the window's: Σ cᵢ·Sᵢ, sized to the LONGEST
/// symbol (the others zero-extended). The lane's encoder on the page (docs/superpowers/specs/2026-10-12-terminal-lane-design.md
/// §3); mirrors Go's `rlcRepair`, and both answer to protocol/fixtures/lane-vectors.json.
export function rlcRepair(symbols: Uint8Array[], seed: number): Uint8Array {
  const coefficients = rlcCoefficients(seed, symbols.length);
  let width = 0;
  for (const s of symbols) width = Math.max(width, s.length);
  const out = new Uint8Array(width);
  symbols.forEach((s, i) => gfMulAddInto(out.subarray(0, s.length), s, coefficients[i]!));
  return out;
}

// ---- the decoder --------------------------------------------------------------------------------

/// One repair equation, reduced as far as current knowledge allows.
interface Equation {
  /// esi -> coefficient, for the unknowns still in play. Small: bounded by the window length.
  terms: Map<number, number>;
  payload: Uint8Array;
}

/// How far behind the newest symbol an equation or symbol is kept. Equations referencing symbols
/// this old can never become solvable — their other unknowns are gone — and keeping them would grow
/// the system without bound while making every reduction slower.
const RLC_HISTORY = 128;

/// A hard ceiling on one reduction, so no arithmetic error can spin the main thread. Each pass
/// removes a term, and an equation never holds more than the window, so a healthy reduction uses a
/// handful.
const MAX_ELIMINATION_PASSES = 4096;   // the lane's windows reach 64 symbols; a healthy reduction still uses a handful.

export class RlcDecoder {
  private readonly symbols = new Map<number, Uint8Array>();
  /// Reduced equations, keyed by their LEADING unknown's esi. At most one per esi, which is what
  /// makes this row-echelon form rather than an unbounded pile.
  private readonly pivots = new Map<number, Equation>();
  private newestEsi = -1;

  /// `history` is set by the CALLER: the lane's window and the video's history are different sizes.
  constructor(private readonly history: number = RLC_HISTORY) {}

  recovered = 0;
  redundant = 0;
  /// Source symbols arriving under an ESI already known.
  ///
  /// THE GUARD AGAINST A SENDER THAT IS NOT NUMBERING SYMBOLS. A host bug that stamped every symbol
  /// with the same ESI produced a client that reported cleanly and measured nothing — the decoder
  /// simply overwrote one slot forever. That is invisible in every other counter, and 100% here.
  /// The redundancy arm legitimately sends each symbol twice, which is 50%, so the two are far apart.
  duplicateSymbols = 0;

  /// TEST-ONLY. The leading coefficient of every stored pivot.
  ///
  /// Exposed because the invariant cannot be asserted through behaviour any more: a violation used to
  /// show up as an infinite reduction, and the bound in `reduceAndStore` now turns that into a quiet
  /// early exit. The guard makes the failure survivable and unobservable at the same time, so the
  /// property gets checked directly.
  debugPivotLeadingCoefficients(): number[] {
    return [...this.pivots].map(([leading, equation]) => equation.terms.get(leading) ?? 0);
  }

  has(esi: number): boolean { return this.symbols.has(esi); }
  get(esi: number): Uint8Array | undefined { return this.symbols.get(esi); }

  /// A source symbol arrived intact. Returns the esis this made newly known (itself, plus anything
  /// its arrival unlocked). One below the floor is refused: prune would delete it at once, and the esi
  /// returned would name a symbol `get` cannot give.
  addSource(esi: number, payload: Uint8Array): number[] {
    if (esi < this.newestEsi - this.history) return [];
    if (this.symbols.has(esi)) { this.duplicateSymbols++; return []; }
    this.symbols.set(esi, payload);
    if (esi > this.newestEsi) this.newestEsi = esi;
    const unlocked = this.substitute(esi);
    this.prune();
    return [esi, ...unlocked];
  }

  /// A repair symbol arrived. Returns the esis it made known, if any.
  addRepair(firstEsi: number, windowLen: number, seed: number, payload: Uint8Array): number[] {
    const coefficients = rlcCoefficients(seed, windowLen);
    const terms = new Map<number, number>();
    // COPIED, because reduction mutates it and the caller's view of the packet must stay intact.
    const residual = new Uint8Array(payload);
    for (let i = 0; i < windowLen; i++) {
      const esi = firstEsi + i;
      const coefficient = coefficients[i]!;
      const known = this.symbols.get(esi);
      if (known) {
        // Substituted out immediately: a known symbol is not an unknown.
        gfMulAddInto(residual, known, coefficient);
      } else if (esi > this.newestEsi - this.history) {
        terms.set(esi, coefficient);
      } else {
        // An unknown older than the history can never be solved, and DROPPING its term would make the equation
        // wrong — every recovery from it a wrong symbol. Abandon the equation.
        return [];
      }
    }
    if (firstEsi + windowLen - 1 > this.newestEsi) this.newestEsi = firstEsi + windowLen - 1;
    const unlocked = this.reduceAndStore({ terms, payload: residual });
    this.prune();
    return unlocked;
  }

  /// Reduce an equation against the current pivots, then either solve it, store it, or discard it.
  private reduceAndStore(equation: Equation): number[] {
    // Eliminate every term that some pivot already leads on.
    //
    // BOUNDED, and not as a formality. Termination rests on every pivot being normalised, since that
    // is what makes a term cancel; a single un-normalised pivot turns this into an infinite loop on
    // the main thread, which is a wedged tab rather than a wrong picture. One such defect has already
    // shipped from this file. The bound is far above any real reduction: the window is 16 symbols and
    // each pass removes one term.
    for (let guard = 0; guard < MAX_ELIMINATION_PASSES; guard++) {
      let eliminated = false;
      for (const [esi, coefficient] of equation.terms) {
        const pivot = this.pivots.get(esi);
        if (!pivot) continue;
        // pivot is normalised to a leading coefficient of 1, so scaling by `coefficient` and adding
        // cancels this term exactly.
        for (const [pesi, pcoefficient] of pivot.terms) {
          const scaled = gfMul(pcoefficient, coefficient);
          const current = equation.terms.get(pesi) ?? 0;
          const next = current ^ scaled;
          if (next === 0) equation.terms.delete(pesi);
          else equation.terms.set(pesi, next);
        }
        gfMulAddInto(equation.payload, pivot.payload, coefficient);
        eliminated = true;
        break;   // the map was mutated; restart the scan
      }
      if (!eliminated) break;
    }

    if (equation.terms.size === 0) { this.redundant++; return []; }
    if (equation.terms.size === 1) {
      const [esi, coefficient] = [...equation.terms][0]!;
      const solved = new Uint8Array(equation.payload.length);
      // symbol = payload / coefficient
      const inverse = gfDiv(1, coefficient);
      gfMulAddInto(solved, equation.payload, inverse);
      if (this.symbols.has(esi)) { this.redundant++; return []; }
      this.symbols.set(esi, solved);
      this.recovered++;
      return [esi, ...this.substitute(esi)];
    }

    // More than one unknown: normalise on the smallest esi and keep it as a pivot.
    const leading = Math.min(...equation.terms.keys());
    const leadingCoefficient = equation.terms.get(leading)!;
    if (leadingCoefficient !== 1) {
      const inverse = gfDiv(1, leadingCoefficient);
      const scaled = new Uint8Array(equation.payload.length);
      gfMulAddInto(scaled, equation.payload, inverse);
      equation.payload = scaled;
      for (const [esi, coefficient] of equation.terms) {
        equation.terms.set(esi, gfMul(coefficient, inverse));
      }
    }
    const existing = this.pivots.get(leading);
    if (existing) {
      // Two equations leading on the same unknown: their sum leads on a later one. Recurse rather
      // than overwrite, or one of the two is silently thrown away.
      for (const [pesi, pcoefficient] of existing.terms) {
        const current = equation.terms.get(pesi) ?? 0;
        const next = current ^ pcoefficient;
        if (next === 0) equation.terms.delete(pesi);
        else equation.terms.set(pesi, next);
      }
      gfMulAddInto(equation.payload, existing.payload, 1);
      return this.reduceAndStore(equation);
    }
    this.pivots.set(leading, equation);
    return [];
  }

  /// A symbol became known: substitute it into every equation that mentions it, and solve any that
  /// collapse to a single unknown. Cascades, because one solution can unlock another.
  private substitute(esi: number): number[] {
    const unlocked: number[] = [];
    const queue = [esi];
    while (queue.length > 0) {
      const known = queue.shift()!;
      const symbol = this.symbols.get(known)!;
      for (const [leading, equation] of [...this.pivots]) {
        const coefficient = equation.terms.get(known);
        if (coefficient === undefined) continue;
        gfMulAddInto(equation.payload, symbol, coefficient);
        equation.terms.delete(known);
        if (equation.terms.size === 0) { this.pivots.delete(leading); this.redundant++; continue; }
        if (equation.terms.size === 1) {
          const [rest, restCoefficient] = [...equation.terms][0]!;
          this.pivots.delete(leading);
          if (this.symbols.has(rest)) { this.redundant++; continue; }
          const solved = new Uint8Array(equation.payload.length);
          gfMulAddInto(solved, equation.payload, gfDiv(1, restCoefficient));
          this.symbols.set(rest, solved);
          this.recovered++;
          unlocked.push(rest);
          queue.push(rest);
          continue;
        }
        if (leading === known) {
          // IT NO LONGER LEADS ON `known`, SO IT MUST BE RE-KEYED **AND RE-NORMALISED**.
          //
          // This used to store it directly under its new leading esi, which left a pivot whose
          // leading coefficient was not 1 — and EVERY pivot having a leading coefficient of 1 is what
          // makes elimination work: cancelling term `esi` relies on
          // `coefficient ^ gfMul(1, coefficient)` being zero. Against an un-normalised pivot the term
          // survives, `eliminated` stays true, and `reduceAndStore`'s loop reduces the same term
          // against the same pivot forever.
          //
          // That is a main thread that stops dead, which is what a live session showed: the client's
          // reports ceased mid-stream with `mainLate=6ms` in the last one — healthy, then nothing —
          // while the host went on sending. Routing through `reduceAndStore` normalises, resolves a
          // pivot collision, and solves or discards, all of which this branch was doing by hand and
          // one of which it was getting wrong.
          this.pivots.delete(leading);
          for (const esi of this.reduceAndStore(equation)) {
            unlocked.push(esi);
            queue.push(esi);
          }
        }
      }
    }
    return unlocked;
  }

  /// The oldest ESI this decoder can still hold. Anything below it has been pruned and can never be
  /// recovered — not by a repair symbol, not by a retransmission, not by waiting.
  ///
  /// EXPORTED BECAUSE THE CALLER'S PATIENCE HAS TO RESPECT IT. The feed decides how long to wait for a
  /// missing frame; this decides how long its symbols survive. They were set independently — 60 frames
  /// there, 128 symbols here — and a feed waiting longer than the decoder remembers waits for
  /// something that is already gone.
  floorEsi(): number { return this.newestEsi - this.history; }

  /// How many symbols the decoder retains. The feed converts it into a frame count using the frame
  /// sizes it has actually seen.
  static get historySymbols(): number { return RLC_HISTORY; }

  private prune(): void {
    const floor = this.newestEsi - this.history;
    for (const esi of this.symbols.keys()) if (esi < floor) this.symbols.delete(esi);
    for (const [leading, equation] of this.pivots) {
      if (leading < floor) { this.pivots.delete(leading); continue; }
      // An equation still referencing a symbol that can never arrive is dead weight.
      for (const esi of equation.terms.keys()) {
        if (esi < floor) { this.pivots.delete(leading); break; }
      }
    }
  }
}

/// The 32-bit FNV-1a hash, matching `fnv1a` in rdev_dc_stream.go.
///
/// `>>> 0` AFTER THE MULTIPLY IS LOAD-BEARING, and it is the same trap as the coefficient generator
/// above: JavaScript multiplies as doubles, so without the coercion the value drifts out of 32-bit
/// range and stops matching the sender's arithmetic. `Math.imul` does the multiply in 32 bits.
export function fnv1a(data: Uint8Array): number {
  let hash = 2166136261;
  for (let i = 0; i < data.length; i++) {
    hash = Math.imul(hash ^ data[i]!, 16777619) >>> 0;
  }
  return hash >>> 0;
}
