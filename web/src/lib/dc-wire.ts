/// The v4 DataChannel video wire format. ONE PLACE THE LAYOUT IS DESCRIBED on this side; its twin is
/// `host/streaming-engine/PionBridge/rdev_dc_stream.go`, and the two are pinned by
/// `web/test/dc-wire.test.ts` building headers BY HAND — generating them from this parser would
/// assert nothing about the layout.
///
/// A VERSION MISMATCH IS REFUSED, NOT PARSED LENIENTLY. A host and a client disagreeing about a
/// fixed-size header read every field at the wrong offset and produce entirely plausible garbage — a
/// picture that is wrong rather than an error that says so.
export const DC_HEADER_BYTES = 40;
const DC_MAGIC = 0x53564452; // "RDVS"
const DC_VERSION = 7;

export interface DcSourcePacket {
  kind: "source";
  sourceIndex: number;
  generation: number;
  esi: number;
  frameSeq: number;
  /// The 90 kHz media clock the decoder paces on, anchored to the stream's first frame by the host.
  rtp: number;
  fragIndex: number;
  fragCount: number;
  frameBytes: number;
  key: boolean;
  payloadType: number;
  /// FNV-1a over the whole assembled access unit, repeated in every symbol of it — like
  /// `frameBytes`, so a frame is checkable from whichever symbols happen to survive.
  frameHash: number;
  /// How many frames back this frame's reference is, in the stream's own numbering. Zero means it
  /// references nothing — a keyframe. This is what lets a receiver decide whether a frame is
  /// decodable ON ARRIVAL, rather than inferring it from a hole in the sequence and a timer.
  dependsOnOffset: number;
  payload: Uint8Array;
}

export interface DcRepairPacket {
  kind: "repair";
  sourceIndex: number;
  generation: number;
  firstEsi: number;
  windowLen: number;
  seed: number;
  payload: Uint8Array;
}

export type DcPacket = DcSourcePacket | DcRepairPacket;

/// A source symbol as the encoder saw it: the wire bytes, zero-filled out to the symbol length.
///
/// The full-length case returns a VIEW, not a copy — that is the hot path on any source big enough to
/// fragment, and it is exactly the case the padding change does not help. Only short symbols allocate,
/// and those are the ones that were wasting the bandwidth.
function zeroExtend(buffer: ArrayBuffer, wireBytes: number, symbolBytes: number): Uint8Array {
  if (wireBytes === symbolBytes) return new Uint8Array(buffer, DC_HEADER_BYTES, symbolBytes);
  const out = new Uint8Array(symbolBytes);
  out.set(new Uint8Array(buffer, DC_HEADER_BYTES, wireBytes));
  return out;
}

export function parseDcPacket(buffer: ArrayBuffer): DcPacket | null {
  if (buffer.byteLength < DC_HEADER_BYTES) return null;
  const view = new DataView(buffer);
  if (view.getUint32(0, true) !== DC_MAGIC) return null;
  if (view.getUint8(4) !== DC_VERSION) return null;
  const symbolBytes = view.getUint16(6, true);
  if (symbolBytes === 0) return null;
  const wireBytes = buffer.byteLength - DC_HEADER_BYTES;
  // NEVER LONGER THAN THE SYMBOL. `symbolBytes` is the ALGEBRAIC length — the width the linear system
  // works at — and a message claiming more payload than that means the two ends disagree about the
  // layout, which is the case this refuses rather than parses.
  if (wireBytes > symbolBytes) return null;
  const sourceIndex = view.getUint16(30, true);
  const generation = view.getUint8(32);
  switch (view.getUint8(5)) {
    case 0:
      return {
        kind: "source", sourceIndex, generation,
        esi: view.getUint32(8, true),
        frameSeq: view.getUint32(12, true),
        rtp: view.getUint32(16, true),
        fragIndex: view.getUint16(20, true),
        fragCount: view.getUint16(22, true),
        frameBytes: view.getUint32(24, true),
        key: view.getUint8(28) === 1,
        payloadType: view.getUint8(29),
        // UNSIGNED, for the same reason as the repair seed below: read signed, a hash with the high
        // bit set would never match the sender's and every such frame would be thrown away.
        frameHash: view.getUint32(36, true),
        dependsOnOffset: view.getUint8(33),
        // ZERO-EXTENDED BACK TO THE SYMBOL LENGTH — v5. The host stops padding source symbols on the
        // wire (a near-static window was spending ~1.18 Mbit/s to carry 13 kbit/s of video), and this
        // reproduces exactly the bytes its encoder combined, so the linear system is unchanged.
        // Everything downstream still sees fixed-width symbols and needs no knowledge of this.
        payload: zeroExtend(buffer, wireBytes, symbolBytes),
      };
    case 1:
      // TRIMMED, AND ZERO-EXTENDED HERE — v7. This refused a short repair until the sender started
      // deliberately trimming them, and the reasoning behind that refusal was half right: a repair is
      // a dense combination, but only over the LONGEST SYMBOL IN ITS WINDOW. Past that it is a
      // combination of zeroes, so the sender stops at the useful width and this puts the zeroes back.
      //
      // What the refusal was guarding against — a truncated message read as a complete one — is not
      // reachable over SCTP, which delivers a message whole or not at all. A wrong repair is caught
      // where it matters anyway: it solves to a wrong symbol, which fails the frame's hash.
      return {
        kind: "repair", sourceIndex, generation,
        firstEsi: view.getUint32(8, true),
        windowLen: view.getUint16(12, true),
        // UNSIGNED. The seed drives the coefficient generator, so reading it signed would produce a
        // different sequence from the host's and the symptom would be wrong pixels, not an error.
        seed: view.getUint32(16, true),
        payload: zeroExtend(buffer, wireBytes, symbolBytes),
      };
    default:
      return null;
  }
}
