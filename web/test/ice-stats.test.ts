import { describe, it, expect } from "vitest";
import { connectionKind, iceRoundTripMs, statusCells, type StatusInfo } from "../src/lib/ice-stats";

function statsMap(entries: Record<string, unknown>[]): RTCStatsReport {
  const m = new Map<string, unknown>();
  for (const e of entries) m.set(e.id as string, e);
  return m as unknown as RTCStatsReport;
}

/// A succeeded pair plus its two candidates.
const pair = (local: string, remote: string, extra: Record<string, unknown> = {}) => statsMap([
  { id: "p", type: "candidate-pair", state: "succeeded", nominated: true,
    localCandidateId: "L", remoteCandidateId: "R", ...extra },
  { id: "L", type: "local-candidate", candidateType: local },
  { id: "R", type: "remote-candidate", candidateType: remote },
]);

describe("connectionKind", () => {
  it("is p2p for direct and NAT-traversed paths", () => {
    expect(connectionKind(pair("host", "host"))).toBe("p2p");
    expect(connectionKind(pair("srflx", "host"))).toBe("p2p");
    // peer-reflexive remote against a non-relay local is ordinary NAT behaviour, not a relay
    expect(connectionKind(pair("host", "prflx"))).toBe("p2p");
  });

  it("is relay when EITHER end goes through a TURN server", () => {
    expect(connectionKind(pair("relay", "relay"))).toBe("relay");
    expect(connectionKind(pair("relay", "prflx"))).toBe("relay");
    expect(connectionKind(pair("host", "relay"))).toBe("relay");
  });

  it("is null while gathering or when candidate stats are missing", () => {
    expect(connectionKind(statsMap([]))).toBeNull();
    expect(connectionKind(statsMap([{ id: "p", type: "candidate-pair", state: "failed" }]))).toBeNull();
    expect(connectionKind(statsMap([
      { id: "p", type: "candidate-pair", state: "succeeded", localCandidateId: "L", remoteCandidateId: "R" },
    ]))).toBeNull();
  });

  it("prefers an explicitly selected pair over a stale succeeded one", () => {
    const stats = statsMap([
      { id: "old", type: "candidate-pair", state: "succeeded", localCandidateId: "L1", remoteCandidateId: "R1" },
      { id: "new", type: "candidate-pair", state: "succeeded", selected: true, localCandidateId: "L2", remoteCandidateId: "R2" },
      { id: "L1", type: "local-candidate", candidateType: "relay" },
      { id: "R1", type: "remote-candidate", candidateType: "relay" },
      { id: "L2", type: "local-candidate", candidateType: "host" },
      { id: "R2", type: "remote-candidate", candidateType: "host" },
    ]);
    expect(connectionKind(stats)).toBe("p2p");
  });
});

describe("iceRoundTripMs", () => {
  it("reads currentRoundTripTime off the succeeded pair, in ms", () => {
    expect(iceRoundTripMs(pair("host", "host", { currentRoundTripTime: 0.024 }))).toBe(24);
  });
  it("returns null when there is no pair or no rtt yet", () => {
    expect(iceRoundTripMs(statsMap([]))).toBeNull();
    expect(iceRoundTripMs(pair("host", "host"))).toBeNull();
  });
});

const base: StatusInfo = {
  state: "connected", stateText: "connected", transport: null, rttMs: null, rxMbps: 0,
};

describe("statusCells — This Mac's remote access", () => {
  const base: StatusInfo = { state: "connected", stateText: "connected", transport: null, rttMs: null, rxMbps: 0 };
  it("says \"remote access enabled\" LAST while the app shares, and nothing otherwise", () => {
    expect(statusCells({ ...base, remoteAccess: true }).map((c) => [c.key, c.text]))
      .toEqual([["state", "connected"], ["remote", "remote access enabled"]]);
    expect(statusCells({ ...base, rttMs: 4, remoteAccess: true }).at(-1)?.key).toBe("remote");
    expect(statusCells({ ...base, remoteAccess: false }).some((c) => c.key === "remote")).toBe(false);
    expect(statusCells(base).some((c) => c.key === "remote")).toBe(false);
  });
  it("not while the window is not connected — only the state cell shows then", () => {
    expect(statusCells({ ...base, state: "connecting", stateText: "connecting…", remoteAccess: true }).map((c) => c.key)).toEqual(["state"]);
  });
});

describe("statusCells", () => {
  it("carries the transport as a secondary DETAIL on the state cell, not its own cell", () => {
    const cells = statusCells({ ...base, transport: "p2p" });
    expect(cells).toEqual([{ key: "state", text: "connected", detail: "p2p" }]);
    expect(statusCells({ ...base, transport: "relay" })[0]?.detail).toBe("relay");
  });

  it("omits the detail entirely while the transport is unknown", () => {
    expect(statusCells(base)).toEqual([{ key: "state", text: "connected" }]);
  });

  it("says 'no FEC' only when the connection actually lost it", () => {
    // The footer was deliberately cut back to three cells, so "recovery is normal" must stay
    // invisible. A receiver that declined FlexFEC is meaningfully less resilient — FEC repairs
    // without a round trip, which is the only thing that helps where RTX is age-refused — and
    // nothing else on screen would say so.
    expect(statusCells({ ...base, activeRecovery: "nack-rtx-flexfec" })).toEqual([
      { key: "state", text: "connected" },
    ]);
    // null is UNRESOLVED, not degraded: before the answer settles there is nothing to report.
    expect(statusCells({ ...base, activeRecovery: null })).toEqual([
      { key: "state", text: "connected" },
    ]);
    expect(statusCells({ ...base, activeRecovery: "nack-rtx" })).toEqual([
      { key: "state", text: "connected" },
      { key: "recovery", text: "no FEC" },
    ]);
  });

  it("adds ping and bitrate once known", () => {
    expect(statusCells({ ...base, transport: "p2p", rttMs: 24, rxMbps: 1.42 })).toEqual([
      { key: "state", text: "connected", detail: "p2p" },
      { key: "rtt", text: "24 ms" },
      { key: "rate", text: "1.4 Mbps" },
    ]);
  });

  it("omits unknown cells rather than showing empty ones", () => {
    const keys = statusCells({ ...base, transport: "p2p" }).map((c) => c.key);
    expect(keys).toEqual(["state"]);
  });

  it("shows kbps below 1 Mbps so a near-idle stream doesn't read as 0.0 Mbps", () => {
    expect(statusCells({ ...base, rxMbps: 0.64 }).find((c) => c.key === "rate")?.text).toBe("640 kbps");
  });

  it("while not connected, ONLY the state cell shows — no stale ping beside 'reconnecting…'", () => {
    const cells = statusCells({
      ...base, state: "connecting", stateText: "waiting for host…",
      transport: "p2p", rttMs: 9, rxMbps: 2,
    });
    expect(cells).toEqual([{ key: "state", text: "waiting for host…" }]);
  });
});

describe("the FEC share on the rate cell", () => {
  const connected = (over: Partial<StatusInfo> = {}): StatusInfo => ({
    state: "connected", stateText: "connected", transport: "p2p", rttMs: 5, rxMbps: 2, ...over,
  });
  const rate = (info: StatusInfo) => statusCells(info).find((c) => c.key === "rate")?.text;

  // IT RIDES THE RATE CELL because it is a share OF that rate, not an independent fact — the same
  // reasoning that puts the transport inside the state cell, and it keeps the footer at three.
  it("reads as a share of the rate", () => {
    expect(rate(connected({ fecFraction: 0.244 }))).toBe("2.0 Mbps (FEC 24%)");
  });

  it("rides a kbps rate too", () => {
    expect(rate(connected({ rxMbps: 0.4, fecFraction: 0.5 }))).toBe("400 kbps (FEC 50%)");
  });

  // NOTHING TO SAY WHEN THERE IS NO FEC. An idle controller sends no repair and the rate stands
  // alone rather than carrying a "(FEC 0%)" that only adds noise.
  it("is omitted when there is no FEC", () => {
    expect(rate(connected({ fecFraction: 0 }))).toBe("2.0 Mbps");
    expect(rate(connected({ fecFraction: null }))).toBe("2.0 Mbps");
    expect(rate(connected())).toBe("2.0 Mbps");
  });

  // TESTED ON THE ROUNDED VALUE, not the raw fraction — a share below half a percent would
  // otherwise render as exactly the "(FEC 0%)" this omits.
  it("omits a share that rounds to zero rather than printing it", () => {
    expect(rate(connected({ fecFraction: 0.004 }))).toBe("2.0 Mbps");
    expect(rate(connected({ fecFraction: 0.006 }))).toBe("2.0 Mbps (FEC 1%)");
  });

  // A connection that declined FlexFEC says so once, in its own cell, and the rate stays clean.
  it("leaves the no-FEC cell to speak for a declined connection", () => {
    const info = connected({ activeRecovery: "nack-rtx", fecFraction: 0 });
    expect(rate(info)).toBe("2.0 Mbps");
    expect(statusCells(info).map((c) => c.key)).toContain("recovery");
  });
});
