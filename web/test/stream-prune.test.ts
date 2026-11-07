import { expect, test } from "vitest";
import { UNLISTED_GRACE_MS, UnlistedStreams, staleStreams } from "../src/lib/stream-prune";

// THE RACE THIS PINS, observed 2026-09-04 on the real Cloudflare relay (three runs out of three, UDP
// and TCP alike): the host answers a subscribe with a renegotiation AND a view-set. The offer rides
// signalling (a WebSocket to the control plane) and the view-set rides the control DataChannel, and
// on a relayed path the DataChannel is the slower of the two — so `ontrack` fires while the last
// view-set the client holds is still the one from BEFORE the subscribe. A prune keyed on that
// view-set forgot the stream the moment it arrived, nothing ever re-added it, and the window stayed
// black while every counter (frames decoded, `active=rtp`, the subscription itself) read healthy.
//
// A stream may be forgotten only on the evidence of a view-set that ARRIVED AFTER it — i.e. in the
// sync a view-set triggers, never in the sync a track arrival triggers.

test("a sync triggered by a track arrival forgets nothing, whatever the last view-set said", () => {
  expect(staleStreams({ kind: "track" }, ["win:1", "win:2"])).toEqual([]);
});

test("a sync triggered by a view-set forgets exactly the streams it does not subscribe", () => {
  expect(staleStreams({ kind: "view-set", subscribed: ["win:2"] }, ["win:1", "win:2", "win:3"]))
    .toEqual(["win:1", "win:3"]);
});

test("an empty view-set forgets every stream — the unsubscribe-all case", () => {
  expect(staleStreams({ kind: "view-set", subscribed: [] }, ["win:1"])).toEqual(["win:1"]);
});

test("a sync with no fresh evidence (rebuild, late channel open) forgets nothing", () => {
  expect(staleStreams({ kind: "other" }, ["win:1"])).toEqual([]);
});

test("the relay ordering: track, stale view-set already held, then the subscribing view-set", () => {
  // Before the fix the second step pruned win:9 because the sync ran on the track's arrival against
  // a view-set that predated the subscribe. Modelled as the sequence of triggers main.ts sees.
  const held = new Set(["win:9"]);
  for (const id of staleStreams({ kind: "track" }, [...held])) held.delete(id);           // ontrack
  expect([...held]).toEqual(["win:9"]);
  for (const id of staleStreams({ kind: "view-set", subscribed: ["win:9"] }, [...held])) held.delete(id);
  expect([...held]).toEqual(["win:9"]);
  for (const id of staleStreams({ kind: "view-set", subscribed: [] }, [...held])) held.delete(id);  // unsubscribe
  expect([...held]).toEqual([]);
});

// 2026-10-08, the case the rule above still lost: a palette pick sends `set-view` THEN `subscribe`, so the host's
// view-set WITHOUT the source travels just ahead of the one with it — and while previews fill the control channel the
// offer outruns both. The earlier view-set arrived AFTER the track and pruned it; the window came with no stream.
test("a view-set that predates the subscribe, arriving after the track, does not forget it", () => {
  let t = 0;
  const unlisted = new UnlistedStreams(() => t);
  const held = new Set<string>();
  const sync = (trigger: Parameters<typeof staleStreams>[0]) => {
    if (trigger.kind === "view-set") unlisted.listed(trigger.subscribed);
    for (const id of staleStreams(trigger, [...held], unlisted.protectedIds())) held.delete(id);
  };
  held.add("dsp:3"); unlisted.arrived("dsp:3", false); sync({ kind: "track" });   // ontrack: no view-set lists it yet
  t += 2000;
  sync({ kind: "view-set", subscribed: [] });                                       // the set-view's, older
  expect([...held]).toEqual(["dsp:3"]);
  sync({ kind: "view-set", subscribed: ["dsp:3"] });                                // the subscribe's
  expect([...held]).toEqual(["dsp:3"]);
  sync({ kind: "view-set", subscribed: [] });                                       // a real unsubscribe, later
  expect([...held]).toEqual([]);
});

test("a stream no view-set ever lists is forgotten after the grace", () => {
  let t = 0;
  const unlisted = new UnlistedStreams(() => t);
  unlisted.arrived("win:4", false);
  expect(staleStreams({ kind: "view-set", subscribed: [] }, ["win:4"], unlisted.protectedIds())).toEqual([]);
  t += UNLISTED_GRACE_MS;
  expect(staleStreams({ kind: "view-set", subscribed: [] }, ["win:4"], unlisted.protectedIds())).toEqual(["win:4"]);
});

test("a stream whose source the newest view-set already lists has no protection to lose", () => {
  const unlisted = new UnlistedStreams(() => 0);
  unlisted.arrived("win:5", true);
  expect(staleStreams({ kind: "view-set", subscribed: [] }, ["win:5"], unlisted.protectedIds())).toEqual(["win:5"]);
});
