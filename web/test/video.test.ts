import { describe, expect, it, test } from "vitest";
import { bindVideo, frozenElementNeedsRebind, shouldRebindVideo } from "../src/client/video";

// THE PREDICATE TAKES PLAIN OBJECTS, WHICH IS WHY IT IS A PREDICATE.
//
// jsdom implements neither MediaStream nor HTMLMediaElement.play, so testing this decision through
// the DOM would mean faking both — a test of browser internals wearing the costume of a test of
// rdev. The decision is what can be wrong, so the decision is what is tested. These stubs carry only
// the two fields the predicate reads.
const trackWith = (id: string) => ({ id }) as unknown as MediaStreamTrack;
const streamWith = (id: string, track: MediaStreamTrack) =>
  ({ id, getVideoTracks: () => [track] }) as unknown as MediaStream;

test("rebinds when nothing is bound yet", () => {
  expect(shouldRebindVideo(null, undefined, streamWith("win:1", trackWith("t1")))).toBe(true);
});

// Chrome's replacement path: it delivers a replacement track on a FRESH MediaStream object, so the
// object comparison already fires. Preserved exactly, which is what keeps Chrome unaffected.
test("rebinds when the stream object differs", () => {
  const t1 = trackWith("t1");
  const bound = streamWith("win:1", t1);
  const next = streamWith("win:1", t1);
  expect(shouldRebindVideo(bound, t1, next)).toBe(true);
});

// THE BUG. WebKit appears to reuse the MediaStream object across a track replacement, so the object
// comparison never fires, nothing rebinds, and the element keeps rendering the old ended track:
// frozen picture, traffic still flowing, and an unrendered track asking for keyframes forever.
test("rebinds when the object is the same but the track was replaced", () => {
  const same = streamWith("win:1", trackWith("t2"));
  expect(shouldRebindVideo(same, trackWith("t1"), same)).toBe(true);
});

// THE REPORTED BUG, AND THE ONE COMPARING IDS COULD NEVER SEE. rdev names every track for a source
// DETERMINISTICALLY — `wireVideoTrack("video-"+sourceID, ...)` — so the replacement track carries the
// SAME id as the one it replaced, and the same MSID. On WebKit, which reuses the MediaStream object,
// both comparisons then say "unchanged" and the element renders a dead track forever: frozen on the
// last frame of the previous codec, while getStats keeps reporting frames decoded.
//
// Measured on Safari 26.6: `{advanced: 0, w: 1044, h: 1472, tracks: [{id: "video-wi", state: "live"}]}`
// — one LIVE track, so it is the new track object under the old name, not a stale ended one.
//
// Playwright's WebKit mints its own remote track ids, so the ids DO differ there and it rebinds. A
// browser gate on that engine passes while real Safari is frozen — which is exactly what happened.
test("rebinds when the replacement track reuses the SAME id", () => {
  const before = trackWith("video-win:29476");
  const after = trackWith("video-win:29476");   // same name, different object — what rdev emits
  const same = streamWith("win:29476", after);
  expect(shouldRebindVideo(same, before, same)).toBe(true);
});

// STEADY STATE. sync() runs on every view-set, so a predicate that rebound here would write
// srcObject continuously — visible flicker, and a way to "fix" the freeze that is worse than the
// freeze. This is the case that stops the fix being satisfied by rebinding unconditionally.
test("does NOT rebind when the object and the track are both unchanged", () => {
  const t1 = trackWith("t1");
  const same = streamWith("win:1", t1);
  expect(shouldRebindVideo(same, t1, same)).toBe(false);
});

// A stream with no video track yet cannot be compared by track, and must not churn.
test("does NOT rebind a bound stream that currently has no video track", () => {
  const bound = { id: "win:1", getVideoTracks: () => [] } as unknown as MediaStream;
  expect(shouldRebindVideo(bound, undefined, bound)).toBe(false);
});

describe("frozenElementNeedsRebind", () => {
  // A <video> can decode every frame and paint NONE. Measured on a real session: frames=298/298,
  // dropped=0, freeze=0, lost=0, pli=0, jbuf=1.1ms — and zero frames presented. The element renders a
  // dead track while getStats reports perfect health, so nothing on the receiver side can see it
  // except a presented-frame count.
  const ok = { presented: 60, decodedDelta: 300, trackLive: true, paused: false, hidden: false };

  it("does NOT rebind a healthy element", () => {
    expect(frozenElementNeedsRebind(ok, 0)).toEqual({ rebind: false, frozenWindows: 0 });
  });

  it("does NOT rebind on a single frozen window — one sample is noise", () => {
    const r = frozenElementNeedsRebind({ ...ok, presented: 0 }, 0);
    expect(r).toEqual({ rebind: false, frozenWindows: 1 });
  });

  it("REBINDS after two consecutive frozen windows while the decoder advances", () => {
    expect(frozenElementNeedsRebind({ ...ok, presented: 0 }, 1)).toEqual({ rebind: true, frozenWindows: 0 });
  });

  it("NEVER rebinds an IDLE source — no frames decoded means nothing to paint", () => {
    // THE FLICKER TRAP, and the reason `decodedDelta` is in the predicate at all. A window nobody
    // touches produces no frames; rdev's capture is content-driven. Treating that as a freeze would
    // rewrite srcObject on every quiet source, forever.
    expect(frozenElementNeedsRebind({ ...ok, presented: 0, decodedDelta: 0 }, 5))
      .toEqual({ rebind: false, frozenWindows: 0 });
  });

  it("never rebinds a paused or hidden element — the user did that", () => {
    expect(frozenElementNeedsRebind({ ...ok, presented: 0, paused: true }, 5).rebind).toBe(false);
    expect(frozenElementNeedsRebind({ ...ok, presented: 0, hidden: true }, 5).rebind).toBe(false);
  });

  it("never rebinds onto a dead track — that needs a new track, not a re-attach", () => {
    expect(frozenElementNeedsRebind({ ...ok, presented: 0, trackLive: false }, 5).rebind).toBe(false);
  });

  it("resets the streak once the picture comes back, so a later freeze needs two windows again", () => {
    expect(frozenElementNeedsRebind(ok, 1)).toEqual({ rebind: false, frozenWindows: 0 });
  });
});

test("rebinds a reused WebKit track when its negotiated identity changes", () => {
  const track = trackWith("webkit-receiver");
  const stream = streamWith("test", track);
  expect(shouldRebindVideo(stream, track, stream, "video-0-test", "video-1-test")).toBe(true);
  expect(shouldRebindVideo(stream, track, stream, "video-1-test", "video-1-test")).toBe(false);
});
test("rebinding the same stream detaches it first", () => {
  const stream = streamWith("test", trackWith("webkit-receiver"));
  const writes: (MediaStream | null)[] = [];
  let current: MediaStream | null = stream;
  const video = { get srcObject() { return current; }, set srcObject(value: MediaStream | null) { writes.push(value); current = value; }, play: () => Promise.resolve() };
  bindVideo(video as unknown as HTMLVideoElement, stream);
  expect(writes).toEqual([null, stream]);
});
