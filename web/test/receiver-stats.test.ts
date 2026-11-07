import { describe, it, expect } from "vitest";
import { fecBandwidthFraction, formatDiagnostics, inboundVideoDiagnostics } from "../src/lib/receiver-stats";

function statsMap(entries: Record<string, unknown>[]): RTCStatsReport {
  const m = new Map<string, unknown>();
  for (const e of entries) m.set(e.id as string, e);
  return m as unknown as RTCStatsReport;
}

describe("inboundVideoDiagnostics", () => {
  it("reads the counters that separate loss from decoder discard", () => {
    const ds = inboundVideoDiagnostics(statsMap([
      {
        id: "in", type: "inbound-rtp", kind: "video", ssrc: 42, codecId: "c",
        packetsReceived: 9000, packetsLost: 3, nackCount: 1, pliCount: 70, firCount: 0,
        framesReceived: 900, framesDecoded: 830, framesDropped: 70, keyFramesDecoded: 70,
        freezeCount: 12, totalFreezesDuration: 1.5, jitter: 0.004,
        jitterBufferDelay: 18, jitterBufferEmittedCount: 900,
      },
      { id: "c", type: "codec", mimeType: "video/H265" },
    ]));
    expect(ds).toHaveLength(1);
    const d = ds[0]!;
    expect(d).toMatchObject({
      ssrc: 42, codec: "video/H265",
      packetsReceived: 9000, packetsLost: 3, nackCount: 1, pliCount: 70, firCount: 0,
      framesReceived: 900, framesDecoded: 830, framesDropped: 70, keyFramesDecoded: 70,
      freezeCount: 12, totalFreezesSeconds: 1.5, jitterSeconds: 0.004,
    });
  });

  // The raw pair is meaningless alone — jitterBufferDelay is seconds ACCUMULATED over every frame
  // emitted, so only the quotient is a delay.
  it("derives the jitter buffer delay per frame, in milliseconds", () => {
    const ds = inboundVideoDiagnostics(statsMap([
      { id: "in", type: "inbound-rtp", kind: "video", jitterBufferDelay: 18, jitterBufferEmittedCount: 900 },
    ]));
    expect(ds).toHaveLength(1);
    expect(ds[0]!.jitterBufferMs).toBeCloseTo(20);
  });

  // A ZERO DENOMINATOR IS NOT A ZERO DELAY. Reporting 0 ms would say "frames are arriving instantly"
  // about a receiver that has emitted no frames at all.
  it("reports no jitter buffer delay rather than zero before any frame is emitted", () => {
    const ds = inboundVideoDiagnostics(statsMap([
      { id: "in", type: "inbound-rtp", kind: "video", jitterBufferDelay: 0, jitterBufferEmittedCount: 0 },
    ]));
    expect(ds).toHaveLength(1);
    expect(ds[0]!.jitterBufferMs).toBeNull();
  });

  // LOAD-BEARING FOR THE QUESTION THIS EXISTS TO ANSWER. Not every browser implements every counter,
  // and Safari is the receiver being diagnosed. Defaulting a MISSING counter to 0 would report "no
  // frames dropped, no freezes" about a browser that simply never said — the strongest possible
  // reading of the evidence, invented.
  it("distinguishes a counter the browser did not report from a zero", () => {
    const ds = inboundVideoDiagnostics(statsMap([
      { id: "in", type: "inbound-rtp", kind: "video", framesDropped: 0 },
    ]));
    expect(ds).toHaveLength(1);
    const d = ds[0]!;
    expect(d.framesDropped).toBe(0);
    expect(d.freezeCount).toBeNull();
    expect(d.packetsLost).toBeNull();
  });

  it("ignores audio and outbound entries", () => {
    expect(inboundVideoDiagnostics(statsMap([
      { id: "a", type: "inbound-rtp", kind: "audio", packetsReceived: 5 },
      { id: "o", type: "outbound-rtp", kind: "video", packetsSent: 5 },
      { id: "r", type: "remote-inbound-rtp", kind: "video", packetsLost: 99 },
    ]))).toEqual([]);
  });

  // One entry per subscribed source: rdev streams a track per window, and a fault in one window is
  // exactly what a summed total would hide.
  it("reports every inbound video track separately", () => {
    const ds = inboundVideoDiagnostics(statsMap([
      { id: "1", type: "inbound-rtp", kind: "video", ssrc: 1, pliCount: 2 },
      { id: "2", type: "inbound-rtp", kind: "video", ssrc: 2, pliCount: 40 },
    ]));
    expect(ds.map((d) => [d.ssrc, d.pliCount])).toEqual([[1, 2], [2, 40]]);
  });
});

describe("formatDiagnostics", () => {
  const full = {
    ssrc: 42, codec: "video/H265", packetsReceived: 9000, packetsLost: 3, nackCount: 1,
    pliCount: 70, firCount: 5, framesReceived: 900, framesDecoded: 830, framesDropped: 70,
    keyFramesDecoded: 70, freezeCount: 12, totalFreezesSeconds: 1.5, jitterSeconds: 0.004,
    jitterBufferMs: 20, jitterBufferDelaySeconds: 18, jitterBufferEmittedCount: 900,
    bytesReceived: null, fecPacketsReceived: null, fecBytesReceived: null,
  };

  it("renders one source as a single line", () => {
    expect(formatDiagnostics([full])).toBe(
      "ssrc=42 H265 rx=9000 lost=3 nack=1 pli=70 fir=5 frames=830/900 dropped=70 kf=70 " +
      "freeze=12/1.5s jbuf=20.0ms jitter=4.0ms (since start)",
    );
  });

  // LOAD-BEARING: absence and zero must not look alike. A `0` where Safari reported nothing would
  // read as "no frames dropped, no freezes" — the strongest reading of the evidence, invented.
  it("prints a missing counter as ? rather than 0", () => {
    const line = formatDiagnostics([{ ...full, framesDropped: null, freezeCount: null }]);
    expect(line).toContain("dropped=?");
    expect(line).toContain("freeze=?/1.5s");
    expect(line).not.toContain("dropped=0");
  });

  it("joins several sources and renders nothing for none", () => {
    expect(formatDiagnostics([full, { ...full, ssrc: 7 }])).toContain(" · ssrc=7 ");
    expect(formatDiagnostics([])).toBe("");
  });
});

describe("windowed reporting", () => {
  const at = (over: Record<string, unknown>) => inboundVideoDiagnostics(statsMap([
    { id: "in", type: "inbound-rtp", kind: "video", ssrc: 7, ...over },
  ]))[0]!;

  // THE FIX THIS EXISTS FOR. jitterBufferDelay and jitterBufferEmittedCount are CUMULATIVE, so their
  // ratio is the average over the whole session — and a pathological opening drags it up long after
  // the stream recovers. Read live it reports history as if it were now.
  //
  // Here the session average is ~500ms while the last window's frames waited ~10ms. The window is
  // the truth about the present; the average is the truth about a minute ago.
  it("windows the jitter buffer instead of reporting the session average", () => {
    const prev = at({ jitterBufferDelay: 50, jitterBufferEmittedCount: 100 });
    const cur = at({ jitterBufferDelay: 51, jitterBufferEmittedCount: 200 });
    expect(cur.jitterBufferMs).toBeCloseTo(255);          // the misleading session average
    expect(formatDiagnostics([cur], [prev])).toContain("jbuf=10.0ms");
  });

  // Counters are cumulative too, so a window is what says whether anything is happening NOW.
  it("differences the counters against the previous sample", () => {
    const prev = at({ packetsReceived: 1000, pliCount: 60, firCount: 0, framesDecoded: 500, framesReceived: 900, framesDropped: 400 });
    const cur = at({ packetsReceived: 1300, pliCount: 60, firCount: 0, framesDecoded: 600, framesReceived: 1190, framesDropped: 590 });
    const line = formatDiagnostics([cur], [prev]);
    expect(line).toContain("rx=300");
    expect(line).toContain("pli=0");
    expect(line).toContain("frames=100/290");
    expect(line).toContain("dropped=190");
  });

  // THE FIRST SAMPLE HAS NOTHING TO SUBTRACT, and pretending otherwise would report a session's
  // opening burst as a steady state. It is labelled rather than silently shown as a window.
  it("marks the first sample as cumulative rather than faking a window", () => {
    expect(formatDiagnostics([at({ packetsReceived: 300 })], [])).toContain("(since start)");
  });

  // A NUMBER FROM A TCP RELAY AND ONE FROM A LAN ARE NOT COMPARABLE, and a log that does not say
  // which is unreadable after the fact. This cost a long detour: hours of reasoning about Wi-Fi
  // jitter on a session that may never have had a direct path.
  it("names the transport", () => {
    expect(formatDiagnostics([at({})], [], { transport: "relay" })).toContain("via=relay");
  });
});

describe("fecBandwidthFraction", () => {
  const at = (over: Record<string, unknown>) => inboundVideoDiagnostics(statsMap([
    { id: "in", type: "inbound-rtp", kind: "video", ssrc: 7, ...over },
  ]))[0]!;

  // BYTES ANSWER THE QUESTION DIRECTLY — it is a share of bandwidth.
  it("is the byte share of the window when the browser reports bytes", () => {
    const prev = at({ bytesReceived: 1000, fecBytesReceived: 0 });
    const cur = at({ bytesReceived: 4000, fecBytesReceived: 1000 });
    expect(fecBandwidthFraction(cur, prev)).toBeCloseTo(1000 / 4000);
  });

  // Packets are the stand-in when bytes are absent, and they are what the host's `[bridge] fec:`
  // line counts — so the two readings are comparable.
  it("falls back to packets when the browser reports no FEC bytes", () => {
    const prev = at({ packetsReceived: 100, fecPacketsReceived: 10 });
    const cur = at({ packetsReceived: 300, fecPacketsReceived: 60 });
    expect(fecBandwidthFraction(cur, prev)).toBeCloseTo(50 / 250);
  });

  // WINDOWED, NEVER CUMULATIVE. A burst a minute ago must not read as the current state — the
  // footer shows a live value. This is the mistake the [rx] jitter buffer made.
  it("reports the window, not the session average", () => {
    const prev = at({ bytesReceived: 1000, fecBytesReceived: 900 });   // a heavy FEC burst, earlier
    const cur = at({ bytesReceived: 11000, fecBytesReceived: 900 });   // and none since
    expect(fecBandwidthFraction(cur, prev)).toBe(0);
  });

  // AN ABSENT MEASUREMENT MUST NOT RENDER AS 0%, which would claim FEC is off when the browser
  // simply never said.
  it("reports nothing when the counters are absent or the window is empty", () => {
    expect(fecBandwidthFraction(at({}))).toBeNull();
    const still = at({ bytesReceived: 500, fecBytesReceived: 100 });
    expect(fecBandwidthFraction(still, still)).toBeNull();
  });
});

describe("the element's own playback state", () => {
  // WHY THIS EXISTS. A report came in of "video delivery broken" whose host log was flawless:
  // frames=300/300, dropped=0, freeze=0, lost=0, pli=0, encoder at 59.8fps, jbuf recovered to 0.9ms.
  // Every counter in the system described a healthy stream. None of them answers the question the
  // user was actually asking — IS THE PICTURE MOVING — because they all describe the DECODER, and a
  // <video> element can decode without presenting. This adds the missing half.
  const base = {
    ssrc: 1, codec: "video/AV1", packetsReceived: 10, packetsLost: 0, nackCount: 0, pliCount: 0, firCount: 0,
    framesDecoded: 300, framesReceived: 300, framesDropped: 0, keyFramesDecoded: 0,
    freezeCount: 0, totalFreezesSeconds: 0, jitterBufferDelaySeconds: 0.3,
    jitterBufferEmittedCount: 300, jitterSeconds: 0.001,
    jitterBufferMs: 1, bytesReceived: 1000, fecPacketsReceived: 0, fecBytesReceived: 0,
  };

  it("reports PRESENTED frames per second, which is the only measure of the picture", () => {
    const line = formatDiagnostics([base], [], { element: { presented: 299, elapsedMs: 5000, readyState: 4, paused: false } });
    expect(line).toContain("el=playing");
    expect(line).toContain("59.8fps");
  });

  it("SAYS FROZEN WHEN FRAMES DECODE BUT NONE ARE PRESENTED", () => {
    // THE CASE THE CLOCK COULD NEVER SEE. For srcObject = MediaStream, video.currentTime is a WALL
    // CLOCK: it advances whether or not a single new frame is painted. An earlier version of this
    // field measured exactly that and reported "playing 100%" over a picture the user said was
    // frozen — an instrument confidently answering a question nobody asked.
    const line = formatDiagnostics([base], [], { element: { presented: 0, elapsedMs: 5000, readyState: 4, paused: false } });
    expect(line).toContain("el=FROZEN");
    expect(line).toContain("0.0fps");
  });

  it("a decoding-but-not-presenting element reads FROZEN", () => {
    // The exact shape that was invisible: the decoder is fine and the picture is frozen.
    const line = formatDiagnostics([base], [], { element: { presented: 0, elapsedMs: 5000, readyState: 4, paused: false } });
    expect(line).toContain("el=FROZEN");
    expect(line).toContain("rs=4");
  });

  it("distinguishes a paused element from a stalled one — they need different fixes", () => {
    const line = formatDiagnostics([base], [], { element: { presented: 0, elapsedMs: 5000, readyState: 4, paused: true } });
    expect(line).toContain("el=paused");
  });

  it("reports the recovery count, so the host log shows whether the self-heal FIRED", () => {
    // Without this, a report of "did not help" cannot be told apart from "the fix never ran" or
    // "that build predates it" — the rebind happens in the client and leaves no trace anywhere the
    // reporter can see. Absent when zero, so a healthy session carries no noise.
    const line = formatDiagnostics([base], [], { element: { presented: 0, elapsedMs: 5000, readyState: 4, paused: false, rebinds: 2 } });
    expect(line).toContain("rebinds=2");
    expect(formatDiagnostics([base], [], { element: { presented: 60, elapsedMs: 5000, readyState: 4, paused: false, rebinds: 0 } }))
      .not.toContain("rebinds=");
  });

  it("omits the field entirely when the element could not be read", () => {
    // ABSENT MEANS UNKNOWN, never "fine" — the same rule every other optional field here follows.
    expect(formatDiagnostics([base])).not.toContain("el=");
    expect(formatDiagnostics([base], [], { element: null })).not.toContain("el=");
  });
});

describe("FIR is reported beside PLI", () => {
  it("prints fir= so `N requested` can be reconciled against BOTH request types", () => {
    // THE HOST ESCALATES ON EITHER. `readFrameTrackRTCP` turns a PictureLossIndication OR a
    // FullIntraRequest into a keyframe request, and the FIR arm is unconditional. Reporting only
    // `pli` made `pli=0` alongside `5 requested` read as "the receiver asked for nothing", when the
    // honest reading is "the receiver sent no PLI, and nothing here measures the other half".
    const base = {
      ssrc: 7, codec: "AV1", packetsReceived: 100, packetsLost: 0, nackCount: 0,
      pliCount: 0, firCount: 3, framesReceived: 60, framesDecoded: 60, framesDropped: 0,
      keyFramesDecoded: 3, freezeCount: 0, totalFreezesSeconds: 0, jitterSeconds: 0,
      jitterBufferMs: 1, jitterBufferDelaySeconds: 0.06, jitterBufferEmittedCount: 60,
      bytesReceived: null, fecPacketsReceived: null, fecBytesReceived: null,
    };
    expect(formatDiagnostics([base])).toContain("pli=0 fir=3");
  });

  it("reports an absent firCount as unknown, never as zero", () => {
    // ABSENT MEANS THE BROWSER DID NOT SAY. Defaulting to 0 would claim the receiver sent no FIRs
    // about a browser that never reported the counter — the same rule every other field here follows.
    const base = {
      ssrc: 7, codec: "AV1", packetsReceived: 100, packetsLost: 0, nackCount: 0,
      pliCount: 0, firCount: null, framesReceived: 60, framesDecoded: 60, framesDropped: 0,
      keyFramesDecoded: 0, freezeCount: 0, totalFreezesSeconds: 0, jitterSeconds: 0,
      jitterBufferMs: 1, jitterBufferDelaySeconds: 0.06, jitterBufferEmittedCount: 60,
      bytesReceived: null, fecPacketsReceived: null, fecBytesReceived: null,
    };
    expect(formatDiagnostics([base])).toContain("fir=?");
  });
});

describe("arrival spread beside the floor it produced", () => {
  const base = {
    ssrc: 1, codec: "video/AV1", packetsReceived: 10, packetsLost: 0, nackCount: 0, pliCount: 0, firCount: 0,
    framesDecoded: 300, framesReceived: 300, framesDropped: 0, keyFramesDecoded: 0,
    freezeCount: 0, totalFreezesSeconds: 0, jitterBufferDelaySeconds: 0.3,
    jitterBufferEmittedCount: 300, jitterSeconds: 0.001,
    jitterBufferMs: 1, bytesReceived: 1000, fecPacketsReceived: 0, fecBytesReceived: 0,
  };
  const el = { presented: 299, elapsedMs: 5000, readyState: 4, paused: false };

  // THE PAIR IS THE POINT. `jbuf` says what the receiver held; `arr` says what the path demanded;
  // `floor` says what rdev asked for. Any one alone cannot tell "the floor is doing its job" from
  // "the floor is too small" from "nobody set one".
  it("prints the measured spread and the floor on one line", () => {
    const line = formatDiagnostics([base], [], { element: { ...el, arrivalSpreadMs: 82.4, floor: { ms: 90, auto: true } } });
    expect(line).toContain("arr=82.4ms floor=auto:90ms");
  });

  // ABSENT MEANS UNKNOWN, NEVER ZERO. A browser that reports no receiveTime has not said the path is
  // clean; and a floor the user pinned is not the controller's doing and must not read as if it were.
  it("an unmeasured spread reads ? and a pinned floor says so", () => {
    const line = formatDiagnostics([base], [], { element: { ...el, arrivalSpreadMs: null, floor: { ms: 100, auto: false } } });
    expect(line).toContain("arr=? floor=pinned:100ms");
  });

  it("says nothing about either when the client did not measure", () => {
    const line = formatDiagnostics([base], [], { element: el });
    expect(line).not.toContain("arr=");
    expect(line).not.toContain("floor=");
  });
});
