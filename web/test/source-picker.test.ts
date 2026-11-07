import { describe, it, expect } from "vitest";
import {
  parseSourceList, parseViewSet, subscribedSource, subscribedSources, subscribedPrefs, streamedWindows,
  sourceRows, sourceStateLabel, currentSourceLabel, parseSourceStatus,
  type Source, type SourceRow,
} from "../src/client/source-picker";

const SRC: Source[] = [
  { id: "sim:U1", kind: "sim", name: "iPhone 17e (iOS 26.0)", inputCapable: true, running: true },
  { id: "sim:U2", kind: "sim", name: "iPad (iOS 26.0)", inputCapable: true, running: false },
  { id: "win:7", kind: "window", name: "Safari - GitHub", inputCapable: false, running: true },
];

describe("parseSourceList", () => {
  it("accepts a well-formed source-list", () => {
    const r = parseSourceList({ t: "source-list", sources: SRC });
    expect(r?.sources.length).toBe(3);
    expect(r?.sources[0]!.id).toBe("sim:U1");
  });
  it("rejects wrong t / non-array / bad element", () => {
    expect(parseSourceList({ t: "nope", sources: [] })).toBeNull();
    expect(parseSourceList({ t: "source-list", sources: 5 })).toBeNull();
    expect(parseSourceList({ t: "source-list", sources: [{ id: "x" }] })).toBeNull();
    expect(parseSourceList(null)).toBeNull();
  });
});

describe("parseViewSet", () => {
  it("accepts subs + focused", () => {
    const r = parseViewSet({ t: "view-set", subs: [{ source: "sim:U1", scale: 0.5, fps: 60, bitrateBps: 2_000_000 }], focused: "sim:U1" });
    expect(r?.subs.length).toBe(1);
    expect(r?.focused).toBe("sim:U1");
  });
  it("accepts an empty view set with null focused", () => {
    const r = parseViewSet({ t: "view-set", subs: [], focused: null });
    expect(r?.subs.length).toBe(0);
    expect(r?.focused).toBeNull();
  });
  it("rejects wrong t / bad sub", () => {
    expect(parseViewSet({ t: "nope", subs: [], focused: null })).toBeNull();
    expect(parseViewSet({ t: "view-set", subs: [{ source: "x" }], focused: null })).toBeNull();
  });

  it("reads activeRecovery off the wire", () => {
    // REGRESSION: this field was declared on ViewSetMsg and never parsed, so main.ts overwrote
    // lastViewSet with an object missing it and the footer's `no FEC` cell could never render — on any
    // build, from the day it shipped. ice-stats.test.ts stayed green because it hands statusCells the
    // field directly: two green tests either side of a seam say nothing about the seam.
    const r = parseViewSet({ t: "view-set", subs: [], focused: null, activeRecovery: "nack-rtx" });
    expect(r?.activeRecovery).toBe("nack-rtx");
  });

  it("normalises an absent activeRecovery to null", () => {
    expect(parseViewSet({ t: "view-set", subs: [], focused: null })?.activeRecovery).toBeNull();
  });

  it("reads curtainUp in both directions", () => {
    expect(parseViewSet({ t: "view-set", subs: [], focused: null, curtainUp: true })?.curtainUp).toBe(true);
    expect(parseViewSet({ t: "view-set", subs: [], focused: null, curtainUp: false })?.curtainUp).toBe(false);
  });

  it("normalises an absent curtainUp to null, not false", () => {
    // ABSENT MEANS UNKNOWN. Reading it as `false` would make a host that predates the field assert
    // "the curtain is down", and the UI would render a confident wrong answer.
    expect(parseViewSet({ t: "view-set", subs: [], focused: null })?.curtainUp).toBeNull();
  });

  it("ignores a non-boolean curtainUp rather than coercing it", () => {
    expect(parseViewSet({ t: "view-set", subs: [], focused: null, curtainUp: "yes" })?.curtainUp).toBeNull();
  });
});

describe("parseViewSet — the session state's windows half", () => {
  const base = { t: "view-set", subs: [], focused: null };

  it("reads windows, view and version — EVERY field ViewSetMsg declares", () => {
    const r = parseViewSet({ ...base, version: 7,
      windows: [{ source: "win:1", minimized: false, x: 40, y: 72 }, { source: "win:2", minimized: true }],
      view: { surface: "windows", fullscreen: "win:1" } });
    expect(r?.windows).toEqual([{ source: "win:1", minimized: false, x: 40, y: 72 }, { source: "win:2", minimized: true }]);
    expect(r?.view).toEqual({ surface: "windows", fullscreen: "win:1" });
    expect(r?.version).toBe(7);
  });

  it("reads absent state as empty: no windows, the terminal showing, version 0", () => {
    const r = parseViewSet(base);
    expect(r?.windows).toEqual([]);
    expect(r?.view).toEqual({ surface: "terminal", fullscreen: null });
    expect(r?.version).toBe(0);
  });

  it("takes a position only WHOLE — x without y is no position at all", () => {
    const r = parseViewSet({ ...base, windows: [{ source: "win:1", minimized: false, x: 40 }] });
    expect(r?.windows).toEqual([{ source: "win:1", minimized: false }]);
  });

  it("refuses a message whose windows are malformed — a half-read state renders nothing true", () => {
    expect(parseViewSet({ ...base, windows: [{ source: "win:1" }] })).toBeNull();
    expect(parseViewSet({ ...base, windows: "win:1" })).toBeNull();
  });

  it("reads an unknown surface as the terminal and a non-string full screen as none", () => {
    const r = parseViewSet({ ...base, view: { surface: "sim", fullscreen: 3 } });
    expect(r?.view).toEqual({ surface: "terminal", fullscreen: null });
  });
});

describe("streamedWindows", () => {
  it("is the open windows in tab order — a minimized one streams nothing", () => {
    expect(streamedWindows({ windows: [
      { source: "win:1", minimized: false }, { source: "win:2", minimized: true }, { source: "dsp:1", minimized: false },
    ] })).toEqual(["win:1", "dsp:1"]);
  });
});

describe("view-set accessors", () => {
  const vs = { subs: [{ source: "sim:U1", scale: 0.5, fps: 60, bitrateBps: 2_000_000 }], focused: "sim:U1" };
  it("subscribedSource / subscribedPrefs read subs[0]", () => {
    expect(subscribedSource(vs)).toBe("sim:U1");
    expect(subscribedPrefs(vs)).toEqual({ scale: 0.5, fps: 60, bitrateBps: 2_000_000 });
  });
  it("empty view set → null", () => {
    expect(subscribedSource({ subs: [] })).toBeNull();
    expect(subscribedPrefs({ subs: [] })).toBeNull();
  });
});

describe("sourceRows / currentSourceLabel", () => {
  it("flags the current source", () => {
    const rows = sourceRows(SRC, ["win:7"]);
    expect(rows.map((r) => r.current)).toEqual([false, false, true]);
    expect(rows[1]!.running).toBe(false);
  });
  it("labels the current source, a count for multiple, or a placeholder", () => {
    expect(currentSourceLabel(SRC, ["sim:U1"])).toBe("iPhone 17e (iOS 26.0)");
    expect(currentSourceLabel(SRC, [])).toBe("No source");
    expect(currentSourceLabel(SRC, ["sim:U1", "win:7"])).toBe("2 sources");
  });
});

describe("sourceStateLabel", () => {
  const row = (o: Partial<SourceRow>): SourceRow =>
    ({ id: "x", kind: "window", name: "n", running: true, inputCapable: false, current: false, ...o });
  it("labels a not-running window minimized", () => {
    expect(sourceStateLabel(row({ kind: "window", running: false }))).toBe("minimized");
  });
  it("returns null for a running window and for any sim", () => {
    expect(sourceStateLabel(row({ kind: "window", running: true }))).toBeNull();
    expect(sourceStateLabel(row({ kind: "sim", running: false }))).toBeNull();
  });
});

describe("subscribedSources", () => {
  it("returns all subscribed source ids in order", () => {
    const vs = { subs: [
      { source: "sim:A", scale: 1, fps: 30, bitrateBps: 1 },
      { source: "win:B", scale: 1, fps: 30, bitrateBps: 1 },
    ], focused: "sim:A" };
    expect(subscribedSources(vs)).toEqual(["sim:A", "win:B"]);
  });
  it("empty for no subs", () => expect(subscribedSources({ subs: [] })).toEqual([]));
});

describe("sourceRows marks the subscribed SET", () => {
  it("current is true for every subscribed id", () => {
    const sources = [
      { id: "sim:A", kind: "sim", name: "A", inputCapable: true, running: true },
      { id: "win:B", kind: "win", name: "B", inputCapable: false, running: true },
      { id: "sim:C", kind: "sim", name: "C", inputCapable: true, running: false },
    ];
    const rows = sourceRows(sources, ["sim:A", "win:B"]);
    expect(rows.map((r) => r.current)).toEqual([true, true, false]);
  });
});

describe("parseSourceStatus", () => {
  it("accepts a well-formed source-status", () => {
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: "win:1", live: false }] }))
      .toEqual({ statuses: [{ id: "win:1", live: false }] });
    expect(parseSourceStatus({ t: "source-status", statuses: [] })).toEqual({ statuses: [] });
  });
  it("rejects wrong t / non-array / bad element", () => {
    expect(parseSourceStatus({ t: "view-set", statuses: [] })).toBeNull();
    expect(parseSourceStatus({ t: "source-status", statuses: "nope" })).toBeNull();
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: "win:1" }] })).toBeNull();
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: 1, live: false }] })).toBeNull();
    expect(parseSourceStatus(null)).toBeNull();
  });
  it("keeps optional native pixel size and rejects junk", () => {
    expect(parseSourceStatus({ t: "source-status", statuses: [
      { id: "win:7", live: true, w: 900, h: 600, pxW: 1800, pxH: 1200 },
    ] })).toEqual({ statuses: [{ id: "win:7", live: true, w: 900, h: 600, pxW: 1800, pxH: 1200 }] });

    // Absent is legal and means UNKNOWN — the liveness monitor has no backing scale to report.
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: "win:7", live: false }] }))
      .toEqual({ statuses: [{ id: "win:7", live: false }] });

    // A zero or non-numeric pixel size is not "unknown", it is corrupt: reject the whole message rather
    // than let a 0 reach autoScale.
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: "win:7", live: true, pxW: 0, pxH: 1200 }] })).toBeNull();
    expect(parseSourceStatus({ t: "source-status", statuses: [{ id: "win:7", live: true, pxW: "1800" }] })).toBeNull();
  });
});

describe("source size parsing", () => {
  it("keeps w/h when present and tolerates their absence", () => {
    const msg = { t: "source-list", sources: [
      { id: "win:7", kind: "window", name: "Safari", inputCapable: true, running: true, w: 892, h: 655 },
      { id: "sim:U1", kind: "sim", name: "iPhone", inputCapable: true, running: true },
    ] };
    const parsed = parseSourceList(msg)!;
    expect(parsed.sources[0]!.w).toBe(892);
    expect(parsed.sources[0]!.h).toBe(655);
    expect(parsed.sources[1]!.w).toBeUndefined();
  });
  it("keeps w/h on a source-status entry", () => {
    const parsed = parseSourceStatus({ t: "source-status", statuses: [{ id: "win:7", live: true, w: 900, h: 600 }] })!;
    expect(parsed.statuses[0]!).toEqual({ id: "win:7", live: true, w: 900, h: 600 });
  });
  it("rejects a non-numeric size rather than trusting it", () => {
    expect(parseSourceList({ t: "source-list", sources: [
      { id: "win:7", kind: "window", name: "S", inputCapable: true, running: true, w: "892", h: 655 },
    ] })).toBeNull();
  });
});

describe("recovery override on view-set", () => {
  it("parses a top-level recoveryOverrideBp", () => {
    const vs = parseViewSet({ t: "view-set", subs: [], focused: null, recoveryOverrideBp: 3000 });
    expect(vs?.recoveryOverrideBp).toBe(3000);
  });

  // Absence is Auto, which is what lets an older host — or a session under adaptive control —
  // read correctly rather than as a forced zero.
  it("reads an absent recoveryOverrideBp as Auto", () => {
    const vs = parseViewSet({ t: "view-set", subs: [], focused: null });
    expect(vs?.recoveryOverrideBp).toBeNull();
  });
});

describe("display sources", () => {
  it("carries kind through to the row so CSS can key on it", () => {
    const rows = sourceRows([
      { id: "dsp:1", kind: "display", name: "Desktop", inputCapable: true, running: true },
      { id: "win:7", kind: "window", name: "Safari - GitHub", inputCapable: true, running: true },
    ], []);
    expect(rows[0]?.kind).toBe("display");
    expect(rows[1]?.kind).toBe("window");
  });

  it("never labels a display as minimized", () => {
    // `sourceStateLabel` keys on `kind === "window"`. A display is always running, so it must not pick
    // up the window state label under any circumstance — including a malformed running:false. A future
    // `!row.running` simplification would light this up on every display.
    expect(sourceStateLabel({ id: "dsp:1", kind: "display", name: "Desktop",
                              running: false, inputCapable: true, current: false })).toBeNull();
  });

  it("parses a display entry off the wire", () => {
    const r = parseSourceList({ t: "source-list", sources: [
      { id: "dsp:1", kind: "display", name: "Desktop", inputCapable: true, running: true, w: 1728, h: 1117 },
    ]});
    expect(r?.sources[0]?.kind).toBe("display");
    expect(r?.sources[0]?.w).toBe(1728);
  });
});

describe("host display availability on source-list", () => {
  const src = { id: "win:7", kind: "window", name: "Safari", inputCapable: true, running: true };

  it("reads the display block", () => {
    const m = parseSourceList({ t: "source-list", sources: [src], display: { availability: "asleep", locked: true } });
    expect(m?.display).toEqual({ availability: "asleep", locked: true });
  });

  it("leaves display undefined when the host omits it", () => {
    // Absent means UNKNOWN — it must never arrive as "ok".
    const m = parseSourceList({ t: "source-list", sources: [src] });
    expect(m?.display).toBeUndefined();
  });

  it("leaves locked undefined when the host omits it", () => {
    const m = parseSourceList({ t: "source-list", sources: [src], display: { availability: "ok" } });
    expect(m?.display).toEqual({ availability: "ok" });
    expect(m?.display?.locked).toBeUndefined();
  });

  it("rejects an unknown availability rather than passing it through", () => {
    const m = parseSourceList({ t: "source-list", sources: [src], display: { availability: "banana" } });
    expect(m?.display).toBeUndefined();
    expect(m?.sources).toHaveLength(1);   // a bad display block must not discard the sources
  });
});

describe("parseViewSet — the bar's order and the windows' names (tab menu, 2026-10-01)", () => {
  const vs = (extra: Record<string, unknown>) => ({ t: "view-set", subs: [], focused: null, ...extra });

  it("reads tabOrder, and an absent one is empty", () => {
    expect(parseViewSet(vs({ tabOrder: ["pty:2", "win:7", "pty:1"] }))?.tabOrder).toEqual(["pty:2", "win:7", "pty:1"]);
    expect(parseViewSet(vs({}))?.tabOrder).toEqual([]);
  });

  it("refuses a malformed tabOrder WHOLE, like the windows — the state is read whole or not at all", () => {
    expect(parseViewSet(vs({ tabOrder: "pty:1" }))).toBeNull();
    expect(parseViewSet(vs({ tabOrder: ["pty:1", 2] }))).toBeNull();
  });

  it("reads a window's name, and refuses one that is not a string", () => {
    const r = parseViewSet(vs({ windows: [{ source: "win:7", minimized: false, name: "logs" }, { source: "win:8", minimized: true }] }));
    expect(r?.windows).toEqual([{ source: "win:7", minimized: false, name: "logs" }, { source: "win:8", minimized: true }]);
    expect(parseViewSet(vs({ windows: [{ source: "win:7", minimized: false, name: 1 }] }))).toBeNull();
  });
});
