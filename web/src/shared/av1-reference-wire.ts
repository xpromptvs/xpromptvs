/** Control metadata only. Full encoder identities stay strings across the JS boundary. */
export interface ReferenceBinding {
  t: "av1-ref-bind" | "av1-ref-bound" | "av1-ref-reset";
  source: string;
  epoch: string;
  trackId?: string;
  reason?: "timestamps-unavailable";
}
export interface ReferenceFrameNotice {
  t: "av1-ref-frame" | "av1-ref-ack";
  source: string;
  epoch: string;
  frameId: string;
  slot: number;
  slotGeneration: string;
  rtpTimestamp: number;
  purpose: "candidate" | "recovery";
  recoveryId?: string;
}
export type ReferenceAck = ReferenceFrameNotice & { t: "av1-ref-ack" };
export type ReferenceMessage = ReferenceBinding | ReferenceFrameNotice;
const bounded = (v: unknown): v is string => typeof v === "string" && v.length > 0 && new TextEncoder().encode(v).length <= 128;
const uint64 = (v: unknown): v is string => typeof v === "string" && /^(0|[1-9][0-9]{0,19})$/.test(v) && BigInt(v) <= 18446744073709551615n;
const integer = (v: unknown, max: number): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= max;
export function parseReferenceMessage(value: unknown): ReferenceMessage | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const m = value as Record<string, unknown>;
  if (!bounded(m.source) || !bounded(m.epoch)) return null;
  const { source, epoch } = m;
  if (m.t === "av1-ref-bind" || m.t === "av1-ref-bound" || m.t === "av1-ref-reset") {
    if (m.trackId !== undefined && !bounded(m.trackId)) return null;
    if (m.reason !== undefined && (m.t !== "av1-ref-reset" || m.reason !== "timestamps-unavailable")) return null;
    return { t: m.t, source, epoch, ...(m.trackId !== undefined ? { trackId: m.trackId } : {}),
      ...(m.reason === "timestamps-unavailable" ? { reason: m.reason } : {}) };
  }
  if (m.t !== "av1-ref-frame" && m.t !== "av1-ref-ack") return null;
  if (!uint64(m.frameId) || !uint64(m.slotGeneration) || !integer(m.slot, 7) || !integer(m.rtpTimestamp, 4294967295)) return null;
  if (m.purpose !== "candidate" && m.purpose !== "recovery") return null;
  if (m.purpose === "recovery" ? !bounded(m.recoveryId) : m.recoveryId !== undefined) return null;
  return { t: m.t, source, epoch, frameId: m.frameId, slot: m.slot, slotGeneration: m.slotGeneration,
    rtpTimestamp: m.rtpTimestamp, purpose: m.purpose, ...(m.purpose === "recovery" ? { recoveryId: m.recoveryId as string } : {}) };
}
