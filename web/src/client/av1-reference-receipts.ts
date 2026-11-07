import type { ReferenceFrameNotice, ReferenceMessage } from "../shared/av1-reference-wire";

const LIMIT = 256, LIFETIME_MS = 5000;
type Binding = {
  epoch: string; track: MediaStreamTrack; generation: number;
  frames: Map<number, number>;
  notices: Map<string, { notice: ReferenceFrameNotice; at: number }>;
  acknowledged: Map<string, number>;
};
const identity = (m: ReferenceFrameNotice) => JSON.stringify([m.epoch, m.frameId, m.slot, m.slotGeneration, m.rtpTimestamp, m.purpose, m.recoveryId]);
function trim<K, V>(map: Map<K, V>): void { while (map.size > LIMIT) map.delete(map.keys().next().value!); }

/** One mounted client's receipts; no decoder readback, global state, timer or rVFC chain. */
export function createReferenceReceipts({ send, now }: { send: (message: ReferenceMessage) => void; now: () => number }) {
  const bindings = new Map<string, Binding>();
  const retired = new Map<string, true>();
  const unsupported = new Map<string, { track: MediaStreamTrack; generation: number }>();
  let disposed = false;
  const retiredKey = (source: string, epoch: string) => JSON.stringify([source, epoch]);
  function prune(b: Binding, time: number): void {
    for (const [stamp, at] of b.frames) if (time - at >= LIFETIME_MS) b.frames.delete(stamp);
    for (const [key, entry] of b.notices) if (time - entry.at >= LIFETIME_MS) b.notices.delete(key);
    for (const [key, at] of b.acknowledged) if (time - at >= LIFETIME_MS) b.acknowledged.delete(key);
  }
  function acknowledge(b: Binding, key: string, notice: ReferenceFrameNotice, time: number): void {
    if (b.acknowledged.has(key) || !b.frames.has(notice.rtpTimestamp)) return;
    b.notices.delete(key); b.acknowledged.set(key, time); trim(b.acknowledged);
    send({ ...notice, t: "av1-ref-ack" });
  }
  function reset(source: string, reason?: "timestamps-unavailable"): void {
    const b = bindings.get(source); if (!b) return;
    bindings.delete(source); retired.set(retiredKey(source, b.epoch), true); trim(retired);
    if (!disposed) send({ t: "av1-ref-reset", source, epoch: b.epoch, ...(reason ? { reason } : {}) });
  }
  return {
    bind(source: string, epoch: string, track: MediaStreamTrack, generation: number): boolean {
      if (disposed || retired.has(retiredKey(source, epoch)) || track.readyState === "ended") return false;
      const unavailable = unsupported.get(source);
      if (unavailable?.track === track && unavailable.generation === generation) return false;
      unsupported.delete(source);
      const previous = bindings.get(source);
      if (previous && (previous.epoch !== epoch || previous.track !== track || previous.generation !== generation)) {
        reset(source);
        if (previous.epoch === epoch) return false;
      }
      if (!bindings.has(source)) bindings.set(source, { epoch, track, generation, frames: new Map(), notices: new Map(), acknowledged: new Map() });
      send({ t: "av1-ref-bound", source, epoch });
      return true;
    },
    notice(notice: ReferenceFrameNotice): void {
      if (disposed || notice.t !== "av1-ref-frame") return;
      const b = bindings.get(notice.source); if (!b || b.epoch !== notice.epoch) return;
      const time = now(); prune(b, time);
      const key = identity(notice); if (b.acknowledged.has(key)) return;
      if (!b.notices.has(key)) b.notices.set(key, { notice, at: time });
      trim(b.notices); acknowledge(b, key, notice, time);
    },
    presented(source: string, track: MediaStreamTrack, generation: number, rtpTimestamp: number | undefined): void {
      if (disposed) return;
      const b = bindings.get(source);
      if (!b || b.track !== track || b.generation !== generation || track.readyState === "ended") return;
      if (rtpTimestamp === undefined || !Number.isInteger(rtpTimestamp) || rtpTimestamp < 0 || rtpTimestamp > 0xffffffff) {
        unsupported.set(source, { track, generation }); trim(unsupported); reset(source, "timestamps-unavailable"); return;
      }
      const time = now(); prune(b, time);
      b.frames.set(rtpTimestamp, time); trim(b.frames);
      for (const [key, { notice }] of b.notices) acknowledge(b, key, notice, time);
    },
    reset,
    resetAll(): void { for (const source of bindings.keys()) reset(source); },
    dispose(): void { disposed = true; bindings.clear(); retired.clear(); unsupported.clear(); },
  };
}
export type ReferenceReceipts = ReturnType<typeof createReferenceReceipts>;
