import { expect, test } from "vitest";
import { DirectTouch, DOUBLE_TAP_SNAP_MS, TWO_FINGER_WINDOW_MS } from "../src/client/direct-touch";
import type { TrackpadOutput } from "../src/client/trackpad";

const BOX = { w: 400, h: 200 };
/// A gesture driver: every call is one pointer event, and the outputs accumulate.
function driver() {
  const dt = new DirectTouch();
  const out: TrackpadOutput[] = [];
  const at = (kind: "down" | "move" | "up" | "cancel", id: number, x: number, y: number, t: number) =>
    out.push(...dt.handle({ kind, id, x, y, t }, BOX));
  const flush = (t: number) => out.push(...dt.flush(t, BOX));
  return { dt, out, at, flush };
}
const kinds = (out: TrackpadOutput[]) => out.map((o) => o.t);
const phases = (out: TrackpadOutput[]) =>
  out.filter((o): o is Extract<TrackpadOutput, { t: "touch" }> => o.t === "touch")
     .map((o) => `${o.phase}:${o.button}`);

// ── one finger: unchanged semantics, just deferred ────────────────────────────────────────────

test("a single finger's press is NOT sent inside the two-finger window", () => {
  // THE WHOLE POINT OF THE DEFERRAL. Two fingers land milliseconds apart, and if the first one's
  // press has already gone to the host, withdrawing it injects a real click on the remote Mac —
  // potentially on a button. Nothing may cross the wire until the gesture's arity is known.
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  expect(out).toEqual([]);
});

test("the deferred press flushes once the window expires", () => {
  const { out, at, flush } = driver();
  at("down", 1, 100, 100, 0);
  flush(TWO_FINGER_WINDOW_MS);
  expect(phases(out)).toEqual(["down:left"]);
  expect(out[0]).toMatchObject({ x: 0.25, y: 0.5 });
});

test("flushing early does nothing, and flushing twice does not double the press", () => {
  const { out, at, flush } = driver();
  at("down", 1, 100, 100, 0);
  flush(TWO_FINGER_WINDOW_MS - 1);
  expect(out).toEqual([]);
  flush(TWO_FINGER_WINDOW_MS);
  flush(TWO_FINGER_WINDOW_MS + 500);
  expect(phases(out)).toEqual(["down:left"]);
});

test("movement past the slop resolves the press EARLY, at the origin", () => {
  // Spending the slop at the origin rather than discarding it is what stops every drag beginning
  // with a dead zone — the same rule Trackpad's `pressing → moving` transition follows.
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("move", 1, 140, 100, 10);
  expect(phases(out)).toEqual(["down:left", "move:left"]);
  expect(out[0]).toMatchObject({ x: 0.25, y: 0.5 });   // the ORIGIN, not where the finger now is
  expect(out[1]).toMatchObject({ x: 0.35, y: 0.5 });
});

test("a quick tap inside the window still sends a down and an up", () => {
  // A tap must never be swallowed by the deferral, and must never send a bare down.
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("up", 1, 100, 100, 20);
  expect(phases(out)).toEqual(["down:left", "up:left"]);
});

// ── double tap: the host counts, the client removes the finger's jitter ──────────────────────

const touches = (out: TrackpadOutput[]) =>
  out.filter((o): o is Extract<TrackpadOutput, { t: "touch" }> => o.t === "touch");

test("a second tap near the first is SENT at the first's point, down and up", () => {
  // The host's `ClickCounter` needs the two presses within a few POINTS; a finger lands a few CSS
  // pixels off, which on a phone showing a large window is tens of points. Snapping is what lets a
  // double tap be a double-click at all.
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("up", 1, 100, 100, 20);
  at("down", 1, 106, 104, 200);
  at("up", 1, 106, 104, 220);
  expect(phases(out)).toEqual(["down:left", "up:left", "down:left", "up:left"]);
  for (const o of touches(out)) expect(o).toMatchObject({ x: 0.25, y: 0.5 });
});

test("a held second press snaps too, and releases where it was sent", () => {
  const { out, at, flush } = driver();
  at("down", 1, 100, 100, 0);
  at("up", 1, 100, 100, 20);
  at("down", 1, 104, 100, 200);
  flush(200 + TWO_FINGER_WINDOW_MS);
  at("up", 1, 104, 100, 400);
  expect(touches(out).slice(2).map((o) => o.x)).toEqual([0.25, 0.25]);
});

test("double-tap-and-drag: the press snaps, the drag follows the finger", () => {
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("up", 1, 100, 100, 20);
  at("down", 1, 105, 100, 200);
  at("move", 1, 140, 100, 220);
  expect(phases(out).slice(2)).toEqual(["down:left", "move:left"]);
  expect(touches(out)[2]).toMatchObject({ x: 0.25 });
  expect(touches(out)[3]).toMatchObject({ x: 0.35 });
});

test("NO snap: too far, too late, or after a drag", () => {
  const far = driver();
  far.at("down", 1, 100, 100, 0); far.at("up", 1, 100, 100, 20);
  far.at("down", 1, 130, 100, 200); far.at("up", 1, 130, 100, 220);
  expect(touches(far.out)[2]).toMatchObject({ x: 130 / 400 });

  const late = driver();
  late.at("down", 1, 100, 100, 0); late.at("up", 1, 100, 100, 20);
  late.at("down", 1, 104, 100, 21 + DOUBLE_TAP_SNAP_MS); late.at("up", 1, 104, 100, 40 + DOUBLE_TAP_SNAP_MS);
  expect(touches(late.out)[2]).toMatchObject({ x: 104 / 400 });

  const dragged = driver();
  dragged.at("down", 1, 100, 100, 0); dragged.at("move", 1, 104, 160, 10); dragged.at("up", 1, 104, 160, 30);
  dragged.at("down", 1, 104, 158, 100); dragged.at("up", 1, 104, 158, 120);
  expect(touches(dragged.out).at(-2)).toMatchObject({ x: 104 / 400, y: 158 / 200 });
});

test("a live press is always released, cancel included", () => {
  const { out, at, flush } = driver();
  at("down", 1, 100, 100, 0);
  flush(TWO_FINGER_WINDOW_MS);
  at("cancel", 1, 100, 100, 200);
  expect(phases(out)).toEqual(["down:left", "up:left"]);
});

// ── the bug this exists to fix ────────────────────────────────────────────────────────────────

test("two fingers NEVER leave an unbalanced press on the host", () => {
  // THE DEFECT, from a probe of the shipped direct path: two fingers produced `down id=1`,
  // `down id=2`, moves, and ONE `up` — two leftMouseDowns against one leftMouseUp, i.e. a stuck
  // button, with nothing on either side reporting it.
  const { out, at, flush } = driver();
  at("down", 1, 100, 100, 0);
  flush(TWO_FINGER_WINDOW_MS);          // the worst case: the press already went out
  at("down", 2, 140, 100, 60);
  at("move", 1, 100, 60, 80);
  at("move", 2, 140, 60, 80);
  at("up", 1, 100, 60, 100);
  at("up", 2, 140, 60, 110);
  const downs = phases(out).filter((p) => p.startsWith("down")).length;
  const ups = phases(out).filter((p) => p.startsWith("up")).length;
  expect(downs).toBe(ups);
  expect(downs).toBeGreaterThan(0);     // and it did not simply stop sending anything at all
});

test("a second finger inside the window sends NO press at all", () => {
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("down", 2, 140, 100, 20);          // both fingers land together, as they really do
  expect(phases(out)).toEqual([]);
});

// ── two-finger pan and fling ──────────────────────────────────────────────────────────────────

test("two fingers past the slop scroll, at the CENTROID, with natural sign", () => {
  // The centroid is where the user is actually pointing, and the host's `scroll` x/y is what
  // decides which element under the pointer scrolls — a virtual cursor would aim it somewhere else.
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("down", 2, 140, 100, 10);
  at("move", 1, 100, 60, 30);           // centroid moves up 40px once both have moved
  at("move", 2, 140, 60, 30);
  const scrolls = out.filter((o) => o.t === "scroll");
  expect(scrolls.length).toBeGreaterThan(0);
  const total = scrolls.reduce((s, o) => s + (o as { dy: number }).dy, 0);
  expect(total).toBeGreaterThan(0);     // fingers up ⇒ content scrolls down (natural)
  expect((scrolls[0] as { x: number }).x).toBeCloseTo(0.3, 1);   // centroid x = 120/400
});

test("a flick emits exactly ONE fling, on the first lift", () => {
  // One message; the HOST runs the glide. The second lift must not throw the view again.
  const { out, at } = driver();
  at("down", 1, 100, 180, 0);
  at("down", 2, 140, 180, 5);
  for (let i = 1; i <= 6; i++) { at("move", 1, 100, 180 - i * 20, i * 10); at("move", 2, 140, 180 - i * 20, i * 10); }
  at("up", 1, 100, 60, 65);
  at("up", 2, 140, 60, 75);
  expect(kinds(out).filter((k) => k === "fling")).toEqual(["fling"]);
  const fling = out.find((o) => o.t === "fling") as { vy: number };
  expect(fling.vy).toBeGreaterThan(0);
});

test("a two-finger gesture that scrolled cannot also click", () => {
  const { out, at } = driver();
  at("down", 1, 100, 180, 0);
  at("down", 2, 140, 180, 5);
  at("move", 1, 100, 100, 20); at("move", 2, 140, 100, 20);
  at("up", 1, 100, 100, 200); at("up", 2, 140, 100, 210);   // slow lift: no flick
  expect(phases(out)).toEqual([]);
});

test("the finger left behind after a two-finger gesture does NOT become a new press", () => {
  // Lifting one of two fingers must not hand the survivor a press the user never made.
  const { out, at, flush } = driver();
  at("down", 1, 100, 180, 0);
  at("down", 2, 140, 180, 5);
  at("move", 1, 100, 100, 20); at("move", 2, 140, 100, 20);
  at("up", 1, 100, 100, 200);
  flush(400);
  at("move", 2, 140, 40, 420);
  at("up", 2, 140, 40, 430);
  expect(phases(out)).toEqual([]);
});

// ── two-finger tap = right click ──────────────────────────────────────────────────────────────

test("two fingers down and up, going nowhere, is a RIGHT click at the centroid", () => {
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("down", 2, 140, 100, 10);
  at("up", 1, 100, 100, 60);
  at("up", 2, 140, 100, 70);
  expect(phases(out)).toEqual(["down:right", "up:right"]);
  expect(out[0]).toMatchObject({ x: 0.3, y: 0.5 });   // centroid of 100 and 140 over a 400px box
});

test("a two-finger press held too long is not a click", () => {
  const { out, at } = driver();
  at("down", 1, 100, 100, 0);
  at("down", 2, 140, 100, 10);
  at("up", 1, 100, 100, 900);
  at("up", 2, 140, 100, 910);
  expect(phases(out)).toEqual([]);
});

test("a THIRD finger stops the pan, and ending it throws nothing", () => {
  // `onMove` requires EXACTLY two pointers: with three the centroid is a different quantity and
  // would jump the moment the third lands, scrolling for a gesture nobody made. The lift that
  // follows must not flick either — that glide would come from a gesture already over.
  const { out, at } = driver();
  at("down", 1, 100, 180, 0);
  at("down", 2, 140, 180, 5);
  for (let i = 1; i <= 4; i++) { at("move", 1, 100, 180 - i * 20, i * 10); at("move", 2, 140, 180 - i * 20, i * 10); }
  const panned = out.filter((o) => o.t === "scroll").length;
  expect(panned).toBeGreaterThan(0);

  at("down", 3, 180, 100, 45);
  at("move", 1, 100, 60, 50); at("move", 2, 140, 60, 50); at("move", 3, 180, 60, 50);
  expect(out.filter((o) => o.t === "scroll").length).toBe(panned);   // silent while three are down

  at("up", 3, 180, 60, 55);
  expect(out.filter((o) => o.t === "fling")).toHaveLength(0);        // and no spurious throw
  at("move", 1, 100, 20, 65); at("move", 2, 140, 20, 65);
  expect(out.filter((o) => o.t === "scroll").length).toBe(panned);   // the gesture stays over
});
