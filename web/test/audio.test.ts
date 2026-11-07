import { describe, expect, it } from "vitest";
import { sourceIdFromAudioStream } from "../src/client/audio";

describe("sourceIdFromAudioStream", () => {
  it("strips the audio: prefix", () => {
    expect(sourceIdFromAudioStream("audio:win:1234")).toBe("win:1234");
  });

  // A SOURCE ID CONTAINS COLONS OF ITS OWN ("win:1234", "dsp:1"), so only the FIRST segment may be
  // stripped. Splitting on every colon would resolve "audio:win:1234" to "win".
  it("keeps every colon after the first", () => {
    expect(sourceIdFromAudioStream("audio:dsp:1")).toBe("dsp:1");
    expect(sourceIdFromAudioStream("audio:win:1234")).not.toBe("win");
  });

  // A VIDEO STREAM MUST NOT RESOLVE. main.ts routes on track.kind, and this is the second guard: a
  // video stream reaching here would be filed as audio for a source that has none.
  it("refuses a stream id that is not an audio stream", () => {
    expect(sourceIdFromAudioStream("win:1234")).toBeNull();
    expect(sourceIdFromAudioStream("")).toBeNull();
    expect(sourceIdFromAudioStream("audio:")).toBeNull();
  });
});

import { parseViewSet, type ViewSetMsg } from "../src/client/source-picker";
import { audioBadge } from "../src/client/audio";

const sub = (extra: Record<string, unknown>) => ({
  source: "win:1", scale: 1, fps: 60, bitrateBps: 1, codec: "auto", ...extra,
});
const viewSet = (extra: Record<string, unknown>): ViewSetMsg | null =>
  parseViewSet({ t: "view-set", subs: [sub(extra)], focused: "win:1" });

describe("view-set audio fields", () => {
  // parseViewSet MUST SURFACE EVERY FIELD ViewSub DECLARES. `activeRecovery` was declared and never
  // read, so the footer's `no FEC` cell could not render on any build — and tsc could not catch it,
  // because every field is optional.
  it("carries audio and audioOwner through", () => {
    const first = viewSet({ audio: false, audioOwner: "win:9" })?.subs[0];
    expect(first?.audio).toBe(false);
    expect(first?.audioOwner).toBe("win:9");
  });

  // ABSENT MEANS UNKNOWN, and `undefined` is how the client must see it — `false` would render a
  // muted badge on every window served by a host that predates the field.
  it("leaves both undefined when the host says nothing", () => {
    const first = viewSet({})?.subs[0];
    expect(first).toBeDefined();
    expect(first?.audio).toBeUndefined();
    expect(first?.audioOwner).toBeUndefined();
  });

  it("still rejects a malformed sub", () => {
    expect(parseViewSet({ t: "view-set", subs: [{ source: "win:1" }], focused: null })).toBeNull();
  });
});

describe("audioBadge", () => {
  // THE TWO FALSE STATES MUST NOT RENDER THE SAME. Muted is a setting the user chose; yielded is a
  // fact about the host they did not, and it names the window that has the audio. A correct outcome
  // indistinguishable from a broken one becomes a bug report — the `data-unmet` reasoning.
  it("distinguishes muted from yielded", () => {
    expect(audioBadge({ audio: false })).toEqual({ state: "muted", title: "Audio muted" });
    expect(audioBadge({ audio: false, audioOwner: "win:9" }))
      .toEqual({ state: "yielded", title: "Audio comes from another window of the same app (win:9)" });
  });

  // AUDIBLE IS THE DEFAULT AND NEEDS NO ORNAMENT, and UNKNOWN is not a state to render.
  it("renders nothing when audible or unknown", () => {
    expect(audioBadge({ audio: true })).toBeNull();
    expect(audioBadge({})).toBeNull();
  });

  // A yielded source that the user ALSO muted reads as muted: the setting they chose is the one
  // they can act on, and it is the reason the sound is off for them specifically.
  it("prefers muted over yielded when both apply", () => {
    expect(audioBadge({ audio: false, audioOwner: "win:9" }, true)?.state).toBe("muted");
  });
});

import { formatAudioDiagnostics } from "../src/lib/receiver-stats";

const statsReport = (entries: Record<string, unknown>[]): RTCStatsReport =>
  ({ forEach: (fn: (v: unknown) => void) => entries.forEach(fn) }) as unknown as RTCStatsReport;

describe("formatAudioDiagnostics", () => {
  // THE ONE FIELD THAT SEPARATES SOUND FROM SILENCE. Every other counter is satisfied by a perfectly
  // delivered stream of zeroes, which is what a broken framer or a mis-scoped interceptor produces.
  it("reports the decoded audio energy", () => {
    const line = formatAudioDiagnostics(statsReport([
      { type: "inbound-rtp", kind: "audio", packetsReceived: 882, totalAudioEnergy: 2.3016 },
    ]));
    expect(line).toContain("aenergy=2.302");
  });

  // NO REPORT AND A SILENT STREAM ARE DIFFERENT FACTS. `aud=0` would claim the browser told us it
  // received nothing; `aud=?` says it told us nothing at all — the same distinction `arr=?` carries.
  it("says ? when the browser reported no inbound audio", () => {
    expect(formatAudioDiagnostics(statsReport([]))).toBe("aud=?");
    expect(formatAudioDiagnostics(statsReport([{ type: "inbound-rtp", kind: "video", packetsReceived: 9 }])))
      .toBe("aud=?");
  });

  it("summarises an inbound audio report", () => {
    const line = formatAudioDiagnostics(statsReport([{
      type: "inbound-rtp", kind: "audio", packetsReceived: 500, packetsLost: 2,
      concealedSamples: 480, totalSamplesReceived: 240000,
      jitterBufferDelay: 2.4, jitterBufferEmittedCount: 120,
    }]));
    expect(line).toBe("aud=500 alost=2 aconceal=0.20% ajbuf=20.0ms aenergy=?");
  });

  // A FIELD THE BROWSER OMITTED READS `?`, NOT 0 — per field, not all-or-nothing.
  it("reports ? per missing field rather than defaulting to zero", () => {
    const line = formatAudioDiagnostics(statsReport([
      { type: "inbound-rtp", kind: "audio", packetsReceived: 12 },
    ]));
    expect(line).toBe("aud=12 alost=? aconceal=? ajbuf=? aenergy=?");
  });
});
