/// Step tables + labels for the per-window video controls (fps / resolution / bitrate), rendered by
/// WindowManager into each window's titlebar. Effective values are reflected from the host's `view-set`
/// (source-subscription protocol), not a dedicated video-prefs message.
///
/// The `VideoPrefsControls` DOM class is GONE (2026-07-28): it drove a mobile-only ⋯ popover in the tab
/// bar, and mobile now shows the window's own titlebar controls instead — so it had no reachable caller.

export interface VideoPrefs { fps: number; scale: number; bitrateBps: number }

export const FPS_STEPS = [15, 30, 60] as const;
export const SCALE_STEPS = [0.25, 0.5, 0.75, 1.0] as const;
/// The 10M and 20M rungs are reachable on a stock host: the CEILING is 20 Mbps
/// (`RDEV_VIDEO_BITRATE_CAP_BPS`) while a source STARTS at 2 Mbps, which is why 2M remains the value the
/// picker shows by default. The host is still the source of truth — it echoes its own effective value
/// back and the select follows it, so a rung a given host will not honour announces itself on pick.
export const BITRATE_STEPS_BPS = [
  100_000, 250_000, 500_000, 1_000_000, 2_000_000, 10_000_000, 20_000_000,
] as const;

/// The step whose value is closest to `v` (so an off-grid host value highlights the nearest step).
export function nearestStep(steps: readonly number[], v: number): number {
  let best = steps[0]!;
  for (const s of steps) {
    if (Math.abs(s - v) < Math.abs(best - v)) {
      best = s;
    }
  }
  return best;
}

export function fpsLabel(v: number): string { return `${v}`; }
export function scaleLabel(v: number): string { return `${Math.round(v * 100)}%`; }
export function bitrateLabel(bps: number): string {
  if (bps < 1_000_000) return `${Math.round(bps / 1000)}k`;   // sub-1M shown in kbps (precise; 250k not "0.3M")
  const m = bps / 1_000_000;
  return `${bps % 1_000_000 === 0 ? m.toFixed(0) : m.toFixed(1)}M`;
}

/// The `<option>` value that selects Auto. Deliberately not numeric, so `Number(v)` on it is NaN and it
/// can never be confused with a step.
export const AUTO_SCALE = "auto";

/// Round UP to a multiple of 16. Encoder alignment — and, more load-bearing here, HYSTERESIS: a display
/// box that shrinks by a few pixels produces no new request, so the host is not asked to recreate its
/// CVPixelBufferPool + VTCompressionSession (and emit a fresh IDR) on every pixel of a drag.
export function ceil16(px: number): number {
  return Math.ceil(px / 16) * 16;
}

export interface AutoScaleInput {
  w: number; h: number;         // host POINT size
  pxW: number; pxH: number;     // host NATIVE PIXEL size (points x the host display's backing scale)
  boxW: number; boxH: number;   // the .win-body content box, CSS px
  dpr: number;                  // the client's devicePixelRatio
}

/// The scale Auto requests for a window: enough pixels to paint the body at the size it is currently
/// drawn, and no more.
///
/// A CEILING, never a target — the host may deliver fewer pixels, and a future bandwidth controller will.
/// LOAD-BEARING: nothing here may read the RECEIVED frame size; that would close a feedback loop around
/// such a controller. The inputs are exactly the host's point size, the host's native pixel size, the
/// client's box, and the device pixel ratio.
///
/// Returns null when the answer is unknowable, and the caller must then keep whatever it last sent:
///   - unknown native size — simulators never publish one, and a window has none before its first
///     capture push;
///   - a degenerate box — on mobile every unfocused window is hidden and measures 0x0, and computing
///     from that would floor the scale at 0.05, leaving the window unreadable when it is focused again.
export function autoScale(i: AutoScaleInput): number | null {
  if (!(i.w > 0 && i.h > 0 && i.pxW > 0 && i.pxH > 0)) return null;
  if (!(i.boxW > 0 && i.boxH > 0 && i.dpr > 0)) return null;
  // The object-fit: contain factor — the body letterboxes the stream, so the SMALLER ratio is what is
  // actually painted. 1 for an unfitted desktop window, where 1pt renders as 1 CSS px.
  const displayFactor = Math.min(i.boxW / i.w, i.boxH / i.h);
  // min() against native is what guarantees an unfitted retina window comes out at exactly 1.0 whether or
  // not its native width happens to be a multiple of 16.
  const alignedPx = Math.min(i.pxW, ceil16(displayFactor * i.w * i.dpr));
  return Math.min(1, Math.max(0.05, alignedPx / i.pxW));
}

/// The smallest change in encode width worth an encoder recreate, in native pixels.
///
/// ONE `ceil16` STEP. `autoScale` already quantises to a 16px grid — but it quantises the wrong
/// quantity: it aligns `displayFactor * w * dpr`, a POINT-derived width, then divides by `pxW` to
/// return a RATIO. The host multiplies its own capture width by that ratio, and the rounding at each
/// end destroys the alignment, so two scales one grid step apart in the client's arithmetic can land
/// three pixels apart at the encoder. Measured on a WAN session: encode widths walking
/// `864 -> 840 -> 834 -> 848 -> 852 -> 864`, none of those steps a multiple of 16.
const AUTO_SCALE_DEADBAND_PX = 16;

/// Is a newly computed Auto scale worth sending, given the last one sent?
///
/// EVERY SEND COSTS AN ENCODER RECREATE AND AN IDR — libaom takes its resolution at create time — so
/// the question is not "did the number change" but "did it change enough to be worth a keyframe".
/// The guard this replaces was exact equality on a FLOAT RATIO, which is no hysteresis at all: a
/// sub-pixel layout shift moved the fourth decimal and bought a full recreate. Measured on one WAN
/// session: 23 recreates in 160s, with 5-second windows carrying 7, 8 and 11 keyframes — an IDR every
/// ~500ms, which is visible as a periodic hitch and, on a saturated path, as a damaged frame.
///
/// `null` for `last` means nothing has been sent yet, which is always worth sending.
export function autoScaleWorthSending(last: number | null | undefined, next: number, pxW: number): boolean {
  if (last === undefined || last === null) return true;
  // Compared as ROUNDED NATIVE PIXEL WIDTHS — the quantity the encoder is actually reconfigured with.
  // Comparing the ratios would make the deadband mean different things on a 640px source and a 3840px
  // one; differencing them BEFORE rounding puts the boundary a hair inside itself, because
  // `(0.5 + 16/1920 - 0.5) * 1920` is 15.999999999999943 in binary floating point.
  return Math.abs(Math.round(next * pxW) - Math.round(last * pxW)) >= AUTO_SCALE_DEADBAND_PX;
}

/// The codec choices the titlebar offers. `auto` defers to the host, which is what keeps a window that
/// is never touched on exactly today's behaviour.
///
/// **H.265 AND H.264 WERE REMOVED 2026-08-18, BECAUSE THEY WERE PINS THE HOST CAN NEVER MEET.** Since
/// the LLV engine cutover rdev is AV1-ONLY — the engine registers AV1 and nothing else, and there is no
/// negotiation left — so picking either of them produced a request the answer could not satisfy,
/// `codecUnmet` went true, and the select rendered PERMANENTLY AMBER on a connection that was working
/// exactly as designed. A control whose every use is an error is worse than an absent one.
///
/// `av1` stays beside `auto` even though the two now request the same thing: it is truthful (the pin IS
/// met), and the labelling — `Auto (AV1)` — is the per-window codec readout the footer lost when it was
/// cut to three cells. If a second codec is ever registered again, this list and the host's order are
/// the two places that have to grow together.
export const CODEC_STEPS = ["auto", "av1", "h265", "h264"] as const;

// EVERY CODEC THE HOST CAN NEGOTIATE, not every codec the select offers. `Auto` is the default and
// it renders what the connection RESOLVED to — which since the codec wire work (2026-08-20) can be
// H.264 or H.265 on a receiver with no AV1 decoder. A name missing here does not break the label
// (it falls back to the wire key) but it reads as `Auto (h264)`, which is the ugly half-truth an
// iPad user would see on the ordinary path.
const CODEC_NAMES: Record<string, string> = { av1: "AV1", h265: "H.265", h264: "H.264" };

/// The option label. `Auto` shows what it actually resolved to — the mode stays visible AND you can see
/// what you are getting, which is the per-window codec readout the footer lost when it was cut to three
/// cells. A PINNED codec is labelled by its own name: showing the negotiated one there would misreport
/// the pin. Unresolved (`activeCodec` absent, deliberately, until the answer settles) reads as a bare
/// `Auto` rather than guessing.
export function codecLabel(pref: string, active: string | undefined): string {
  if (pref !== "auto") return CODEC_NAMES[pref] ?? pref;
  return active ? `Auto (${CODEC_NAMES[active] ?? active})` : "Auto";
}

/// Is this pin NOT what the connection settled on?
///
/// RESTORED 2026-08-20, WITH the codecs it watches. It was deleted on 2026-08-18 because the engine
/// registered AV1 alone, so the only pin on offer was the only codec there was and the predicate could
/// never fire. Both halves of that stopped being true: the host negotiates AV1, H.265 and H.264, and
/// the select offers all three. Restoring it separately from `CODEC_STEPS` would have been the worst
/// of both — a pin that can go unmet with nothing marking it, which is exactly what shipped between
/// the wire increment and now.
///
/// `auto` is NEVER unmet: it asks for nothing, so nothing can refuse it. And an UNRESOLVED codec is
/// not unmet either — `activeCodec` is deliberately absent until the answer settles, and treating
/// absence as disagreement would paint every window amber for the first second of its life.
export function codecUnmet(pref: string, active: string | undefined): boolean {
  if (pref === "auto" || active === undefined) return false;
  return active !== pref;
}

/// Forced FEC overhead, in basis points of media. A TESTING control: it pins how much recovery
/// traffic the host sends so its effect can be measured against a known number instead of whatever
/// the adaptive controller happens to choose.
///
/// The steps stop at 50%. Above that the repair stream rivals the media stream and the session's
/// egress budget begins suppressing it, so the number asked for stops being the number delivered.
export const RECOVERY_STEPS_BP = [0, 500, 1000, 2000, 3000, 4000, 5000] as const;

/// The select's Auto value. A STRING, so it cannot collide with a basis-point number — `0` is a
/// forced no-FEC setting, which is a different thing from letting the controller decide, and the
/// two would be indistinguishable if Auto were 0 or -1 in the same numeric space.
export const AUTO_RECOVERY = "auto";

/// Basis points rendered as the percentage the operator set. Every step is a whole percent, so this
/// never shows a fraction.
export function recoveryLabel(bp: number): string {
  return `${bp / 100}%`;
}
