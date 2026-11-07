/// The active ICE candidate pair, or null while ICE is still gathering. Pure: `stats` is an RTCStatsReport
/// (a Map), so this is unit-tested with a plain Map.
///
/// Priority: an explicitly `selected` pair (Firefox), else the `nominated` + succeeded pair
/// (Chrome/Safari), else any succeeded pair. Order-independent so stale non-selected pairs don't win.
function selectedPair(stats: RTCStatsReport): any | null {
  const pairs: any[] = [];
  stats.forEach((s: any) => { if (s.type === "candidate-pair") pairs.push(s); });
  return (
    pairs.find((p) => p.selected === true) ??
    pairs.find((p) => p.nominated && p.state === "succeeded") ??
    pairs.find((p) => p.state === "succeeded") ??
    null
  );
}

export type ConnectionKind = "p2p" | "relay";

/// How media is reaching us: directly between peers, or through a TURN relay.
///
/// `relay` when EITHER end's candidate is a relay — the path traverses a TURN server either way, and that
/// is the thing worth surfacing (it costs latency and TURN bandwidth). A `prflx` (peer-reflexive) remote
/// against a non-relay local is ordinary NAT behaviour, NOT a relay.
export function connectionKind(stats: RTCStatsReport): ConnectionKind | null {
  const pair = selectedPair(stats);
  if (!pair) return null;
  const local = (stats.get(pair.localCandidateId) as { candidateType?: string } | undefined)?.candidateType;
  const remote = (stats.get(pair.remoteCandidateId) as { candidateType?: string } | undefined)?.candidateType;
  if (!local || !remote) return null;
  return local === "relay" || remote === "relay" ? "relay" : "p2p";
}

/// The active pair's round-trip time in whole milliseconds, or null before ICE has measured one.
export function iceRoundTripMs(stats: RTCStatsReport): number | null {
  const rtt = selectedPair(stats)?.currentRoundTripTime;
  return typeof rtt === "number" ? Math.round(rtt * 1000) : null;
}

export interface StatusCell {
  key: string;
  text: string;
  /// Rendered after `text` in a secondary colour, inside the SAME cell (e.g. "connected" + "p2p").
  detail?: string;
}

export interface StatusInfo {
  state: "connecting" | "connected" | "error";
  stateText: string;
  transport: ConnectionKind | null;
  rttMs: number | null;
  rxMbps: number;
  /// The recovery stack this connection actually runs, or null before the answer settles it.
  /// "nack-rtx-flexfec" | "nack-rtx".
  activeRecovery?: string | null;
  /// The share of received video bandwidth currently spent on FEC repair, 0..1, or null when the
  /// browser does not report the counters or nothing arrived in the window. NULL IS NOT ZERO.
  fecFraction?: number | null;
  /// THIS MAC's window only: the app is SHARING — other devices can reach this Mac over the relay. Its own cell,
  /// last ("remote access enabled", 2026-10-04): the window itself is local whatever the app does.
  remoteAccess?: boolean;
}

/// The status bar's cells, in display order: connection state (with the transport as a secondary-colour
/// detail on the same cell), ping, and incoming video bitrate. Pure so the footer is unit-testable.
///
/// Unknown values are OMITTED rather than rendered blank, and while we are not connected ONLY the state
/// cell shows — a stale ping beside "reconnecting…" reads as if the old connection were still live.
export function statusCells(info: StatusInfo): StatusCell[] {
  if (info.state !== "connected") return [{ key: "state", text: info.stateText }];

  const cells: StatusCell[] = [
    { key: "state", text: info.stateText, ...(info.transport ? { detail: info.transport } : {}) },
  ];
  if (info.rttMs !== null) cells.push({ key: "rtt", text: `${info.rttMs} ms` });
  // Show kbps below 1 Mbps so a low-motion (near-idle) stream reads sensibly instead of "0.0 Mbps".
  if (info.rxMbps > 0) {
    const rate = info.rxMbps >= 1
      ? `${info.rxMbps.toFixed(1)} Mbps`
      : `${Math.round(info.rxMbps * 1000)} kbps`;
    // FEC RIDES THE RATE CELL because it is a share OF that rate, not an independent fact — the same
    // reasoning that puts the transport inside the state cell rather than beside it, and it keeps
    // the footer at the three cells it was deliberately cut back to.
    //
    // TESTED ON THE ROUNDED VALUE, not the raw fraction: a share below half a percent would
    // otherwise render as the "(FEC 0%)" this is meant to omit.
    const percent = info.fecFraction === null || info.fecFraction === undefined
      ? 0
      : Math.round(info.fecFraction * 100);
    cells.push({ key: "rate", text: percent >= 1 ? `${rate} (FEC ${percent}%)` : rate });
  }
  // SHOWN ONLY WHEN FEC IS ABSENT, which keeps the footer as sparse as it was deliberately cut
  // back to be: "recovery is normal" is noise, "this connection has no in-band repair" is not.
  //
  // It matters because FlexFEC repairs WITHOUT a round trip, and on a path where RTX is age-refused
  // before a NACK can arrive it is the only mechanism that helps at all — so a receiver that
  // declined it is meaningfully less resilient, and nothing else on screen would say so.
  //
  // NULL IS UNRESOLVED, NOT DEGRADED: before the answer settles there is nothing to report.
  if (info.activeRecovery === "nack-rtx") cells.push({ key: "recovery", text: "no FEC" });
  if (info.remoteAccess) cells.push({ key: "remote", text: "remote access enabled" });
  return cells;
}
