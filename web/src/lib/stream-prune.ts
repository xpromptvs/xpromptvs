/// WHEN an inbound video stream may be forgotten.
///
/// The client keys incoming streams by source id and reconciles windows against the host's view-set.
/// A stream whose source is no longer subscribed has to be dropped, or an unsubscribed window keeps a
/// live decoder — but the decision needs EVIDENCE that postdates the stream, and only a view-set
/// that arrived after the track is that.
///
/// THE RACE, measured on the real Cloudflare relay 2026-09-04 (three runs of three, UDP and TCP
/// alike): a subscribe makes the host renegotiate AND send a view-set. The offer travels over
/// signalling (the control-plane WebSocket) and the view-set over the control DataChannel, and on a
/// relayed path the DataChannel is the slower. `ontrack` therefore fired while the last view-set
/// in hand was the one from BEFORE the subscribe; the sync that ran on the track's arrival pruned the
/// stream it had just registered, nothing re-added it, and the window stayed black with every
/// counter healthy — frames decoding, `activeDelivery: rtp`, the subscription present. On loopback
/// the view-set always won the race, which is why no gate ever saw it.
///
/// So: a sync triggered by a VIEW-SET prunes against that view-set; a sync triggered by anything
/// else — a track arriving, the channels opening, a rebuild — prunes nothing.
export type SyncTrigger =
  | { kind: "track" }
  | { kind: "view-set"; subscribed: readonly string[] }
  | { kind: "other" };

/// The source ids among `held` that this sync should forget. `unlisted` (`UnlistedStreams.protectedIds`) are
/// streams no view-set has listed yet — never forgotten by a view-set that may predate their subscribe.
export function staleStreams(trigger: SyncTrigger, held: readonly string[],
                             unlisted: ReadonlySet<string> = new Set()): string[] {
  if (trigger.kind !== "view-set") return [];
  const live = new Set(trigger.subscribed);
  return held.filter((id) => !live.has(id) && !unlisted.has(id));
}

/// How long a stream no view-set has listed is kept from a prune: a view-set the host had already sent when it
/// renegotiated is seconds behind on the slowest relay. Past this, a source the host never listed is stale.
export const UNLISTED_GRACE_MS = 15_000;

/// **A VIEW-SET THAT ARRIVES AFTER THE TRACK MAY STILL PREDATE THE SUBSCRIBE** (2026-10-08: "if I press on a window to
/// stream it before its preview loads in the palette, sharing doesn't work … I see the traffic going up, but no
/// video"). A palette pick from the terminal surface sends `set-view` and THEN `subscribe`, so the host sends a view-set
/// WITHOUT the source just ahead of the one with it; while previews load, the control channel carries a JPEG per
/// window and those view-sets queue behind them, so the offer — on the relay's WebSocket — won by seconds. The track
/// arrived and was kept (the rule above), then the EARLIER view-set arrived and pruned it, and the later one made a
/// window with no stream left to show: frames received and decoded, `<video>` never made, a black window.
///
/// So a stream whose source no view-set had listed when it arrived is kept from every prune until one does — the host
/// lists a source before it adds its track (`state.streamed` drives the tracks), so that view-set is coming — or
/// `UNLISTED_GRACE_MS` passes.
export class UnlistedStreams {
  private readonly since = new Map<string, number>();
  constructor (private readonly now: () => number = () => performance.now(),
               private readonly graceMs = UNLISTED_GRACE_MS) {}

  /// A stream for `id` arrived; `listed` is whether the newest view-set in hand already lists its source.
  arrived (id: string, listed: boolean): void {
    if (listed) this.since.delete(id);
    else if (!this.since.has(id)) this.since.set(id, this.now());
  }

  /// A view-set listing `ids` arrived: those streams are known, and its successors may prune them.
  listed (ids: readonly string[]): void {
    for (const id of ids) this.since.delete(id);
  }

  /// The streams a prune must leave alone now.
  protectedIds (): Set<string> {
    const now = this.now();
    for (const [id, at] of [...this.since]) if (now - at >= this.graceMs) this.since.delete(id);
    return new Set(this.since.keys());
  }
}
