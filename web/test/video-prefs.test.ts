import { expect, test } from "vitest";
import {
  nearestStep, scaleLabel, bitrateLabel, fpsLabel,
  FPS_STEPS, SCALE_STEPS, BITRATE_STEPS_BPS,
  autoScale, autoScaleWorthSending, ceil16, AUTO_SCALE,
  codecLabel, CODEC_STEPS, codecUnmet,
} from "../src/client/video-prefs";

test("nearestStep snaps an off-grid value to the closest step", () => {
  expect(nearestStep(SCALE_STEPS, 0.6)).toBe(0.5);
  expect(nearestStep(SCALE_STEPS, 0.8)).toBe(0.75);
  expect(nearestStep(FPS_STEPS, 30)).toBe(30);
  expect(nearestStep(BITRATE_STEPS_BPS, 1_400_000)).toBe(1_000_000);
});

test("labels render human values", () => {
  expect(fpsLabel(60)).toBe("60");
  expect(scaleLabel(0.5)).toBe("50%");
  expect(bitrateLabel(100_000)).toBe("100k");
  expect(bitrateLabel(250_000)).toBe("250k");
  expect(bitrateLabel(500_000)).toBe("500k");
  expect(bitrateLabel(2_000_000)).toBe("2M");
  expect(bitrateLabel(10_000_000)).toBe("10M");
  expect(bitrateLabel(20_000_000)).toBe("20M");
});

// TEST-ONLY rungs. They exceed the host's DEFAULT 2 Mbps cap, so picking one does nothing unless the
// host was started with RDEV_VIDEO_BITRATE_CAP_BPS raised — the host clamps and echoes back its own
// effective value, and the select snaps to it. That is the honest behaviour, not a bug.
test("bitrate steps include the high test rungs, in ascending order", () => {
  expect(BITRATE_STEPS_BPS).toContain(10_000_000);
  expect(BITRATE_STEPS_BPS).toContain(20_000_000);
  const asc = [...BITRATE_STEPS_BPS].sort((a, b) => a - b);
  expect([...BITRATE_STEPS_BPS]).toEqual(asc);
});

test("nearestStep can reach the high rungs", () => {
  expect(nearestStep(BITRATE_STEPS_BPS, 9_000_000)).toBe(10_000_000);
  expect(nearestStep(BITRATE_STEPS_BPS, 18_000_000)).toBe(20_000_000);
});

test("ceil16 rounds UP to a multiple of 16", () => {
  expect(ceil16(1565)).toBe(1568);
  expect(ceil16(1568)).toBe(1568);   // already aligned — unchanged
  expect(ceil16(1569)).toBe(1584);
  expect(ceil16(1)).toBe(16);
  expect(ceil16(0)).toBe(0);
});

// A 1400x950pt window on a 2x host: 2800x1900 native pixels.
const HOST = { w: 1400, h: 950, pxW: 2800, pxH: 1900 };

test("autoScale: unfitted desktop window on a 2x client asks for full native", () => {
  // The body is drawn at 1pt -> 1 CSS px, so the box IS the point size.
  expect(autoScale({ ...HOST, boxW: 1400, boxH: 950, dpr: 2 })).toBe(1);
});

test("autoScale: unfitted window on a 1x client asks for half — it cannot paint more", () => {
  // 1400 device px -> ceil16 -> 1408; 1408/2800.
  expect(autoScale({ ...HOST, boxW: 1400, boxH: 950, dpr: 1 })).toBeCloseTo(0.5029, 4);
});

test("autoScale: a fitted window asks only for what it draws", () => {
  // fit factor 0.559 -> body 782.6 x 531.05; 0.559*1400*2 = 1565.2 -> 1568; 1568/2800.
  expect(autoScale({ ...HOST, boxW: 782.6, boxH: 531.05, dpr: 2 })).toBeCloseTo(0.56, 4);
});

test("autoScale: mobile full-bleed uses the object-fit CONTAIN factor, not the box", () => {
  // A 390x804 box around a 1400x950 window contains at 390/1400 = 0.2786 (NOT 804/950).
  // 0.2786*1400*3 = 1170 -> 1184; 1184/2800. Using the box height instead would over-ask by ~3x.
  expect(autoScale({ ...HOST, boxW: 390, boxH: 804, dpr: 3 })).toBeCloseTo(0.4229, 4);
});

test("autoScale: never exceeds native, even when the alignment step would", () => {
  // A native width that is not a multiple of 16: ceil16(2802) = 2816 > 2802, so min() pins it to 1.0.
  expect(autoScale({ w: 1401, h: 950, pxW: 2802, pxH: 1900, boxW: 1401, boxH: 950, dpr: 2 })).toBe(1);
});

test("autoScale: unknown native size returns null (simulators, pre-capture windows)", () => {
  expect(autoScale({ ...HOST, pxW: 0, pxH: 0, boxW: 1400, boxH: 950, dpr: 2 })).toBeNull();
});

test("autoScale: a degenerate box returns null rather than flooring the scale", () => {
  // Every unfocused window on mobile is hidden and measures 0x0. Computing from that would pin the
  // scale at 0.05 and the window would come back from a tab switch unreadable.
  expect(autoScale({ ...HOST, boxW: 0, boxH: 0, dpr: 2 })).toBeNull();
  expect(autoScale({ ...HOST, boxW: 390, boxH: 0, dpr: 2 })).toBeNull();
});

test("AUTO_SCALE is not parseable as a number, so it can never be mistaken for a step", () => {
  expect(Number.isNaN(Number(AUTO_SCALE))).toBe(true);
});

// Auto shows what it resolved to, so the mode stays visible AND you can see what you are getting —
// the per-window codec readout the footer lost when it was cut to three cells.
test("codecLabel: Auto names its resolved codec", () => {
  expect(codecLabel("auto", "av1")).toBe("Auto (AV1)");
  expect(codecLabel("auto", undefined)).toBe("Auto");
});

// A pinned codec is labelled by its OWN name. Labelling it with the negotiated one would misreport the
// pin — and since the removal of the H.265/H.264 entries there is nothing left to misreport WITH, which
// is exactly why the disagreement machinery went too.
test("codecLabel: a pin is labelled by its own name", () => {
  expect(codecLabel("av1", "av1")).toBe("AV1");
  expect(codecLabel("h265", "av1")).toBe("H.265");
  // An unknown pref falls back to its own key rather than rendering blank. Nothing produces one today;
  // a host that echoed a codec this build does not know would.
  expect(codecLabel("vp9", "av1")).toBe("vp9");
});

// THE DEFAULT PATH ON AN AV1-LESS RECEIVER. Auto is what every window starts on, and since the codec
// wire work a connection can genuinely resolve to H.264 or H.265 — so these are the labels a real
// iPad user reads, not a hypothetical. Before the names were added this rendered `Auto (h264)`.
test("codecLabel: Auto names a non-AV1 resolution properly", () => {
  expect(codecLabel("auto", "h264")).toBe("Auto (H.264)");
  expect(codecLabel("auto", "h265")).toBe("Auto (H.265)");
});

// THE LIST NOW MATCHES WHAT THE HOST NEGOTIATES, and it got there in two steps worth remembering.
// It was cut to AV1-only on 2026-08-18 — correct then, because the engine registered AV1 alone and an
// H.265 or H.264 entry was a pin nothing could satisfy, which had shipped for months as a permanently
// amber select. The wire increment (2026-08-20) registered all three again but stopped at the wire, so
// for a few days the client could not pin what the host could deliver.
//
// GROWN TOGETHER WITH `codecUnmet` AND THE `.win-codec[data-unmet]` RULE, deliberately: a pin that can
// be refused with nothing marking it is the worse of the two failures, and it is what existed in the
// gap. Asserting the LIST rather than a label is still the point — a label test passes whatever is in
// it.
test("CODEC_STEPS offers every codec the host negotiates", () => {
  expect([...CODEC_STEPS]).toEqual(["auto", "av1", "h265", "h264"]);
});

// `auto` asks for nothing, so nothing can refuse it; and an UNRESOLVED codec is not a disagreement —
// activeCodec is deliberately absent until the answer settles, and treating absence as unmet would
// paint every window amber for the first second of its life.
test("codecUnmet fires only on a real disagreement", () => {
  expect(codecUnmet("av1", "h265")).toBe(true);
  expect(codecUnmet("av1", "av1")).toBe(false);
  expect(codecUnmet("auto", "h264")).toBe(false);
  expect(codecUnmet("av1", undefined)).toBe(false);
});

import { RECOVERY_STEPS_BP, recoveryLabel, AUTO_RECOVERY } from "../src/client/video-prefs";

test("recovery steps run 0% to 50%", () => {
  expect([...RECOVERY_STEPS_BP]).toEqual([0, 500, 1000, 2000, 3000, 4000, 5000]);
});

// The label is what the operator reads while measuring, so it must be the percentage and not the
// basis points it is carried as.
test("recovery labels render basis points as percentages", () => {
  expect(recoveryLabel(0)).toBe("0%");
  expect(recoveryLabel(500)).toBe("5%");
  expect(recoveryLabel(2000)).toBe("20%");
  expect(recoveryLabel(5000)).toBe("50%");
});

// AUTO must not collide with a real basis-point value: 0 is a forced no-FEC setting, which is a
// different thing from letting the controller decide.
test("Auto is distinct from a forced zero", () => {
  expect(AUTO_RECOVERY).toBe("auto");
  expect(RECOVERY_STEPS_BP.map(String)).not.toContain(AUTO_RECOVERY);
});


// EVERY AUTO SEND COSTS AN ENCODER RECREATE AND AN IDR. The guard these replace was exact equality on
// a float ratio, which is no hysteresis at all — measured as an IDR every ~500ms on a WAN session,
// visible as a periodic hitch.
test("autoScaleWorthSending: the first computation always sends", () => {
  expect(autoScaleWorthSending(undefined, 0.5, 1920)).toBe(true);
  expect(autoScaleWorthSending(null, 0.5, 1920)).toBe(true);
});

test("autoScaleWorthSending: a sub-step wobble is not worth a keyframe", () => {
  // 1920px source: this is the shape that produced the hitch — a ratio that moved in its fourth
  // decimal, which is 1.9px of encode width.
  expect(autoScaleWorthSending(0.5, 0.5010, 1920)).toBe(false);
  expect(autoScaleWorthSending(0.5, 0.4990, 1920)).toBe(false);
  // Exactly at the threshold, in both directions.
  expect(autoScaleWorthSending(0.5, 0.5 + 16 / 1920, 1920)).toBe(true);
  expect(autoScaleWorthSending(0.5, 0.5 - 16 / 1920, 1920)).toBe(true);
});

// THE DEADBAND IS IN NATIVE PIXELS, NOT IN RATIO. The same ratio change is a different number of
// pixels on a small source and a large one, and it is pixels the encoder is reconfigured with.
test("autoScaleWorthSending: the same ratio change decides differently by source size", () => {
  const delta = 0.02;
  expect(autoScaleWorthSending(0.5, 0.5 + delta, 640)).toBe(false);    // 12.8px — below one step
  expect(autoScaleWorthSending(0.5, 0.5 + delta, 3840)).toBe(true);    // 76.8px — well past it
});

// LOAD-BEARING: `lastSentAuto` holds what was SENT, so a run of small changes is each compared
// against the same baseline. Comparing against the last COMPUTED value would let the scale ratchet
// arbitrarily far in steps that are each individually below the threshold.
test("autoScaleWorthSending: small steps accumulate against the last SENT value", () => {
  const sent = 0.5, pxW = 1920;
  let drifting = sent;
  for (let i = 0; i < 7; i++) {
    drifting += 0.001;                                  // 1.92px per step
    if (autoScaleWorthSending(sent, drifting, pxW)) break;
  }
  // Seven steps of 1.92px is 13.4px — still inside the deadband, so nothing has been sent...
  expect(autoScaleWorthSending(sent, drifting, pxW)).toBe(false);
  // ...and the ninth crosses it, which is the drift being caught rather than accumulating silently.
  expect(autoScaleWorthSending(sent, sent + 0.009, pxW)).toBe(true);
});
