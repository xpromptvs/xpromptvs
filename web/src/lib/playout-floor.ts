/// Size the playout-delay FLOOR from how unevenly frames ARRIVE.
///
/// WHY A FLOOR AND NOT A CEILING. The ceiling only PERMITS a receiver to buffer, and WebKit declines
/// the invitation: raised from 10ms to 150ms on a juddering relay, `jbuf` stayed at ~6ms and nothing
/// changed. The minimum is what FORCES buffering, and it moves `jbuf` directly — 50 -> ~35ms,
/// 100 -> ~88ms, 200 -> ~185ms, measured. A forced 100ms on a relayed session that pulsed at every
/// buffer either browser chose for itself was "much smoother", and that is the effect this
/// reproduces without a human picking the number.
///
/// MEASURED AT THE INPUT, NOT THE OUTPUT — AND THAT IS THE WHOLE DESIGN. The controller this replaced
/// watched how evenly frames were PAINTED, which is downstream of its own actuator: raising the floor
/// changed the reading, so every raise needed a trial, a verdict, a refund and a ban, and after six
/// rounds of that it still could not tell a path that needed buffer from one that needed something
/// else. Arrival is upstream. `requestVideoFrameCallback` hands over each presented frame's
/// `receiveTime` — the arrival of its last packet — beside its `rtpTimestamp`, and rdev's timestamps
/// carry real capture time, so `receiveTime - rtpTimestamp` is the frame's transit plus everything
/// that made it late. Its SPREAD over a few seconds is exactly what a jitter buffer must absorb, and
/// nothing the floor does can change it. There is no loop to close, so the floor is simply that
/// spread, with headroom, in the extension's units.
///
/// BOTH ENGINES SUPPLY THE TWO FIELDS. Chromium always has; WebKit's `metadataFromVideoFrame`
/// (RealtimeIncomingVideoSource.cpp) fills `rtpTimestamp` from the frame and `receiveTime` from the
/// latest `packet_infos()` entry — read from the source, since Safari's `mediaTime` on the same
/// callback has already been found unreliable and this must not rest on a field that lies. A browser
/// reporting neither contributes no samples, which reads as UNKNOWN and moves nothing.
///
/// NOT TRANSPORT-GATED, DELIBERATELY. A relay may be fast and a LAN may be terrible; the transport
/// type is a proxy for the property, and this measures the property.
///
/// THE SAMPLE IS THE PRESENTED FRAMES, SO THE CEILING MUST BE PERMISSIVE. Under a tight playout-delay
/// ceiling WebKit DISCARDS the frames that arrive late — exactly the ones that carry the spread — and
/// the survivors of a burst are its youngest members, late by only a fraction of the stall. The host's
/// default ceiling is 500ms (rdev_playout_delay.go) for this reason: a ceiling the receiver never hits
/// keeps every arrival in the sample.
export interface ArrivalSample {
  /// `VideoFrameCallbackMetadata.receiveTime`: when the frame's last packet arrived, on the page's
  /// `performance.now()` timeline.
  receiveMs: number;
  /// `VideoFrameCallbackMetadata.rtpTimestamp`: the frame's 90kHz RTP timestamp, 32-bit.
  rtpTimestamp: number;
}

/// How far back the arrival distribution is measured. Four seconds of 60fps is 240 samples — enough
/// for a 98th percentile to mean something, short enough to follow a path that changes.
export const ARRIVAL_WINDOW_MS = 4000;
const MIN_SAMPLES = 30;
/// 0.98 rather than the maximum: the extreme is one packet having a bad day, and sizing every frame's
/// latency to it is how a jitter buffer becomes a latency buffer. Its complement is covered by the
/// headroom below, not by a more extreme percentile — p99.5 of 240 samples is the 239th, which hands a
/// single unlucky arrival the next four seconds of latency.
const SPREAD_PERCENTILE = 0.98;
const RTP_TICKS_PER_MS = 90;

/// The spread of arrival lateness across the window: how much later than the fastest frame the 98th
/// percentile frame arrived, relative to where its own timestamp put it. Null when the window is too
/// small to describe.
///
/// A CONTENT-DRIVEN SOURCE READS ZERO. A window that stops redrawing for 33ms produces a 33ms gap in
/// BOTH clocks, and the deviation between them is unchanged — the mistake that once sent a floor
/// controller to its cap closing gaps where no frame had ever existed cannot recur here.
export function arrivalSpread(samples: readonly ArrivalSample[]): number | null {
  if (samples.length < MIN_SAMPLES) return null;
  const first = samples[0]!;
  const deviations = samples.map((s) => {
    // `| 0` reads the 32-bit difference as SIGNED, which is what makes a window straddling the
    // timestamp wrap (every 13 hours at 90kHz) read as a small step rather than a 13-hour one.
    const mediaMs = ((s.rtpTimestamp - first.rtpTimestamp) | 0) / RTP_TICKS_PER_MS;
    return (s.receiveMs - first.receiveMs) - mediaMs;
  }).sort((a, b) => a - b);
  const high = deviations[Math.min(deviations.length - 1, Math.floor(SPREAD_PERCENTILE * deviations.length))]!;
  return high - deviations[0]!;
}

/// The most this will ever ask for. MATCHES THE HOST'S `maximumPlayoutDelayMinMs` — a client cap above
/// it would request a floor the host silently reduces, and the panel would then claim a number the
/// wire does not carry. Past 500ms a link is not interactive by any definition and needs a different
/// answer than patience.
export const PLAYOUT_FLOOR_CAP_MS = 500;
/// The extension's resolution: both of its fields are 12-bit counts of ten milliseconds.
const UNIT_MS = 10;
/// Headroom on top of the measured spread, as a fraction of it. A percentile leaves its complement
/// late BY CONSTRUCTION — p98 of 240 samples is five frames a window — and proportional headroom
/// covers them without charging a clean path anything: 4ms of spread gains 0.6ms.
const HEADROOM_FRACTION = 0.15;
/// A floor of ONE unit can never bind: every receiver holds 13-18ms on its own (Chromium clamps its
/// minimum there; WebKit chose 13ms on loopback when left alone), so sending 10ms changes the wire
/// and nothing else. The smallest floor worth sending is two units.
const SMALLEST_FLOOR_MS = 2 * UNIT_MS;

/// The floor a given spread requires. A pure function of the spread — NOT of the current floor —
/// which is the property that makes this loop-free: two sessions on the same path converge on the
/// same number whatever they started from.
export function floorFor(spreadMs: number): number {
  const ms = Math.round((spreadMs * (1 + HEADROOM_FRACTION)) / UNIT_MS) * UNIT_MS;
  if (ms < SMALLEST_FLOOR_MS) return 0;
  return Math.min(PLAYOUT_FLOOR_CAP_MS, ms);
}

export interface PlayoutFloorState {
  floorMs: number;
  /// Consecutive readings whose need was ABOVE the floor — the evidence required before climbing.
  aboveTicks: number;
  /// Consecutive readings whose need was at least two units BELOW it — the evidence required before
  /// descending.
  belowTicks: number;
}

export const PLAYOUT_FLOOR_START: PlayoutFloorState = { floorMs: 0, aboveTicks: 0, belowTicks: 0 };

/// A RAMP, NEVER A JUMP — ONE UNIT PER READING IN EITHER DIRECTION.
///
/// The receiver applies the minimum as an INSTANTANEOUS clamp on every frame's render time
/// (libwebrtc `VCMTiming::RenderTime`: `local_time + clamp(current_delay, min, max)`; its 100ms/s
/// smoothing governs only its own jitter estimate, which the clamp overrides). So a raise of N ms
/// holds the picture for N ms at once, and a fall of N ms squeezes N ms out of one frame interval.
/// The first version raised at once — 0 -> 60 -> 110 inside two readings on a relay — and the
/// reporter's reference bars juddered with it. One unit is the extension's own resolution and the
/// only step under a 60Hz frame period, so each step is at most one repeated frame; the price is
/// reaching an 80ms requirement over eight seconds rather than one, chosen with eyes open.
const STEP_MS = UNIT_MS;
/// Consecutive readings of demand before the first step up. A single reading is not evidence of a
/// path, and the cost of a wrong step is a hitch.
const RAISE_AFTER_TICKS = 3;
/// Consecutive readings of surplus before the first step down. Long, deliberately: the cost of a
/// wrong fall is the stall it was covering, and a path that bursts every half minute must not have
/// its buffer taken away between bursts only to buy it back at the next.
const LOWER_AFTER_TICKS = 30;
/// ...UNLESS THE SURPLUS IS LARGE. Measured 2026-09-04 on a seeded congested path whose steady need
/// was 12 ms: the connection's first four seconds (the initial keyframe, the FEC controller climbing
/// tiers, the bitrate settling) read a 54 ms spread, the floor chased it to 50 in five seconds, and
/// then sat there for the whole thirty-second hold while every later reading said 0 — 50 ms on every
/// frame for over half a minute, on the strength of a transient every connection has. A second run
/// of the same path that happened to miss the transient settled at 20. The startup transient is the
/// ordinary case, not the exception: every reconnect produces one.
///
/// Three units (30 ms) of surplus for ten consecutive seconds — two and a half turns of the
/// measurement window with no sign of the demand — is the evidence that separates a transient from a
/// path that bursts. A path that bursts every ten seconds keeps its floor exactly as before; one that
/// bursts every half minute gives back its buffer between bursts and pays one hitch at the next,
/// which is the trade made here, with eyes open, against thirty-plus seconds of a wrong floor after
/// every reconnect.
const LOWER_AFTER_TICKS_LARGE_SURPLUS = 10;
const LARGE_SURPLUS_MS = 3 * UNIT_MS;

/// Advance the floor by one reading (one per second in production). `spreadMs` null is UNKNOWN and
/// changes nothing — it neither raises, lowers, nor counts toward either.
///
/// THE QUIESCENT BAND IS THE STABILISATION. A floor sitting exactly on its need flaps on measurement
/// noise, and every flap is a hitch — so the descent stops ONE UNIT ABOVE the need (it runs only
/// while the need is at least two units below), and a raise needs the need to clear the floor by a
/// whole unit. Between those a settled floor moves for nothing. The cost is one unit of latency on
/// a path that has ever climbed: measured, deliberate, and far cheaper than the alternative.
///
/// A PASSING STALL THEREFORE LEAVES ONE UNIT BEHIND. It lifts the p98 for the four seconds it stays
/// in the window, which is long enough to climb; when it leaves, the descent returns everything but
/// the cushion. A path that stalls now and then ends up one unit above its quiet need — and STOPS.
export function nextPlayoutFloor(state: PlayoutFloorState, spreadMs: number | null): PlayoutFloorState {
  if (spreadMs === null) return state;
  const target = floorFor(spreadMs);
  const floor = state.floorMs;
  const wantsMore = target > floor;
  const wantsLess = target < floor - UNIT_MS;
  const aboveTicks = wantsMore ? state.aboveTicks + 1 : 0;
  const belowTicks = wantsLess ? state.belowTicks + 1 : 0;
  // The patience before a step down depends on how much is being held for nothing: a large surplus
  // sustained for ten seconds is a transient that has left, not a burst that will return.
  const lowerAfter = target <= floor - LARGE_SURPLUS_MS ? LOWER_AFTER_TICKS_LARGE_SURPLUS : LOWER_AFTER_TICKS;
  let floorMs = floor;
  if (wantsMore && aboveTicks >= RAISE_AFTER_TICKS) {
    floorMs = Math.min(PLAYOUT_FLOOR_CAP_MS, Math.max(SMALLEST_FLOOR_MS, floor + STEP_MS));
  } else if (wantsLess && belowTicks >= lowerAfter) {
    // ONE UNIT IS NEVER SENT: the step below the smallest binding floor goes straight to zero.
    floorMs = floor - STEP_MS;
    if (floorMs < SMALLEST_FLOOR_MS) floorMs = 0;
  }
  return { floorMs, aboveTicks, belowTicks };
}

// ─── THE WINDOW ─────────────────────────────────────────────────────────────────────────────────
//
// A receiver can be asked for a fixed WINDOW — `min = max` on the playout-delay extension — instead of
// a floor under the permissive ceiling. Measured 2026-09-04, both engines (headed Chrome and full
// Chromium headless; docs/latency-campaign/2026-09-04-report.md): under the defaults (min 0 / max
// 500) Chromium adds its own jitter estimate to whatever floor it is given and renders through a
// two-refresh compositor path — glass-to-glass 51–57 ms on loopback with a 7–9 ms judder tail on the
// headless engine. Under min = max = 10 the render time is a fixed offset from capture and the
// low-latency compositor path engages: 27 ms, every frame in phase (judder p95 0.8–0.9 ms), 60.0 fps.
// It is the WINDOW that does it, not either bound: 0/0 and 0/10 engage the fast path but the receiver
// then phase-flips or drops frames, and 20/20 lost the fast path on one engine.
//
// THE FAST PATH IS CHOSEN WHEN THE STREAM STARTS. The same window applied three seconds in moved the
// timing clamp (pipeline 16 ms) but the vsync wait stayed at two refreshes (33 ms against 27). So a
// capable client asks for the window BEFORE it subscribes (`controlOpenMessages`) and only ever
// resizes it afterwards.
//
// SIZED TO THE PATH. The window replaces the receiver's own adaptive buffer, so a frame later than it
// is late on screen (Chromium renders it late; WebKit DISCARDS it, which is why this is never asked
// of WebKit — see `playoutWindowCapable`). 10 ms fits a path whose need (p98 spread with headroom)
// is under 7 — loopback and a LAN read 2–3; the stall-free relay reads 11–14 and measured 20/20 with a
// one-refresh judder tail and 30/30 smooth (48.6 ms, judder p95 1.1) — so the window is one unit
// above the need, rounded up, and the floor design takes over past 50 ms.
//
// HYSTERESIS, LIKE THE FLOOR: three consecutive readings before any change, because every change is
// a hitch — a resize shifts every render time by the difference at once.
export const PLAYOUT_WINDOW_MS = 10;
/// The need at or under which the smallest window is used: two units of margin under it.
const WINDOW_SMALL_NEED_MS = 7;
/// Past this need the window is left for the floor design (the AirDrop-stalled relay reads 70–80).
export const PLAYOUT_WINDOW_MAX_MS = 50;
const WINDOW_CHANGE_AFTER_TICKS = 3;

export interface PlayoutWindowState {
  active: boolean;
  /// The window currently asked for, in ms (a multiple of 10, 10..50); meaningful while active.
  sizeMs: number;
  /// Consecutive readings that disagreed with `sizeMs`/`active` in the same direction.
  pendingSizeMs: number | null;
  pendingTicks: number;
}

/// The window a need calls for: 10 under 7 ms, else one unit above the need rounded up; null past
/// the cap, meaning "the floor design".
export function playoutWindowFor(needMs: number): number | null {
  if (needMs <= WINDOW_SMALL_NEED_MS) return PLAYOUT_WINDOW_MS;
  const size = Math.ceil(needMs / UNIT_MS) * UNIT_MS + UNIT_MS;
  return size > PLAYOUT_WINDOW_MAX_MS ? null : size;
}

/// Where a session starts: a window on a capable engine (asked for before the first frame, so the
/// fast path engages), nothing on an incapable one.
///
/// THE STARTING SIZE IS THE ONE THAT COUNTS, AND A PRIOR BEATS A GUESS. The compositor regime is
/// fixed when the stream starts: on the stall-free relay a session started at 10 and resized to 30
/// three seconds in measured 60 ms, the same window from the start 48.6 — and the defaults 62–65.
/// So the client remembers the window a path settled on (per pairing code, in localStorage) and
/// starts the next session there; a first visit starts at the smallest. An invalid prior — not a
/// multiple of ten, out of range, garbage from storage — is ignored, never clamped into a guess.
export function playoutWindowStart(capable: boolean, priorMs: number | null = null): PlayoutWindowState {
  const valid = priorMs !== null && Number.isInteger(priorMs) && priorMs % UNIT_MS === 0
    && priorMs >= PLAYOUT_WINDOW_MS && priorMs <= PLAYOUT_WINDOW_MAX_MS;
  return { active: capable, sizeMs: valid ? priorMs : PLAYOUT_WINDOW_MS, pendingSizeMs: null, pendingTicks: 0 };
}

/// Advance the window decision by one reading. `capable` false (WebKit, or a pinned control) keeps
/// it inactive whatever the path reads; null is UNKNOWN and changes nothing. A change — a resize, a
/// leave (target null) or a re-entry — happens after three consecutive readings agreeing on it.
export function nextPlayoutWindow(state: PlayoutWindowState, spreadMs: number | null, capable: boolean): PlayoutWindowState {
  if (!capable) return playoutWindowStart(false);
  if (spreadMs === null) return state;
  const need = spreadMs * (1 + HEADROOM_FRACTION);
  const target = playoutWindowFor(need);   // null = leave for the floor design
  const current = state.active ? state.sizeMs : null;
  if (target === current) return { ...state, pendingSizeMs: null, pendingTicks: 0 };
  // Inside a window's own band nothing moves: a need that calls for the SAME size as before but
  // crosses a rounding edge by noise must not flap. The band is the target itself, so only a
  // different target counts.
  const pendingTicks = state.pendingSizeMs === target ? state.pendingTicks + 1 : 1;
  if (pendingTicks < WINDOW_CHANGE_AFTER_TICKS) return { ...state, pendingSizeMs: target, pendingTicks };
  return target === null
    ? { active: false, sizeMs: state.sizeMs, pendingSizeMs: null, pendingTicks: 0 }
    : { active: true, sizeMs: target, pendingSizeMs: null, pendingTicks: 0 };
}

/// What to ask the host for: the window when it is active, else the floor under the configured
/// ceiling (`maxMs` null). Pure, so the two controllers compose without either knowing the other.
export function playoutRequest(floor: PlayoutFloorState, window: PlayoutWindowState): { minMs: number; maxMs: number | null } {
  if (window.active) return { minMs: window.sizeMs, maxMs: window.sizeMs };
  return { minMs: floor.floorMs, maxMs: null };
}

/// Whether this engine may be asked for a window. WebKit takes the ceiling LITERALLY and discards
/// what arrives past it, and its presented-frame sample then hides exactly the lateness the window
/// would need to see — so it stays on the floor design. Everything Chromium-based (Chrome, Edge) is
/// capable. The native app's own client window is a WKWebView — WebKit — so it is NOT, which is the
/// accepted Safari-parity trade-off of replacing Electron (`docs/desktop-app.md`). Feature-detected
/// from the UA by exclusion: WebKit is the engine that says AppleWebKit and does NOT say
/// Chrome/Chromium/Edg.
export function playoutWindowCapable(userAgent: string): boolean {
  return !(/AppleWebKit/.test(userAgent) && !/Chrome|Chromium|CriOS|Edg/.test(userAgent));
}
