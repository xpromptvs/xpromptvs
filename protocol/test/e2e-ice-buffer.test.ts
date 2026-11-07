import { describe, expect, test } from "vitest";
import {
  ICE_BUFFER_DEADLINE_MS, ICE_BUFFER_MAX, IceBuffer,
} from "../src/e2e-ice-buffer";

// §11.3: "Buffer early ICE candidates until their remote description is installed, with a bounded
// size and deadline. Discard the buffer with its attempt."
//
// The clock is a PARAMETER, never `Date.now()`, so the deadline is testable without waiting ten
// seconds and without a fake-timer harness that would be the thing under test.

describe("the ordinary path", () => {
  test("drains in arrival order and empties itself", () => {
    const b = new IceBuffer<string>();
    expect(b.push("a", 0)).toBe("buffered");
    expect(b.push("b", 1)).toBe("buffered");
    expect(b.size).toBe(2);

    expect(b.drain(2)).toEqual(["a", "b"]);
    expect(b.size).toBe(0);
    // PAIRED: a buffer that never drained would satisfy the first assertion, and one that kept its
    // contents would satisfy neither this nor a second drain.
    expect(b.drain(3)).toEqual([]);
  });

  test("nothing is counted as dropped on a healthy negotiation", () => {
    const b = new IceBuffer<number>();
    for (let i = 0; i < 12; i++) b.push(i, i);   // a dual-stack host with TURN, roughly
    expect(b.drain(20)).toHaveLength(12);
    expect(b.counters).toEqual({ droppedFull: 0, droppedExpired: 0, discarded: 0 });
  });
});

describe("the size bound", () => {
  test("refuses past the cap and says so", () => {
    const b = new IceBuffer<number>(4);
    for (let i = 0; i < 4; i++) expect(b.push(i, 0)).toBe("buffered");
    expect(b.push(99, 0)).toBe("dropped-full");
    expect(b.size).toBe(4);
    expect(b.counters.droppedFull).toBe(1);
  });

  // The EARLIEST are kept: candidates arrive roughly in usefulness order for latency — host first,
  // then server-reflexive, then relay — and losing the early ones is what produces the peer-reflexive
  // delay the queue exists to avoid.
  test("the newest are dropped, not the oldest", () => {
    const b = new IceBuffer<string>(3);
    for (const c of ["host-1", "host-2", "srflx", "relay", "flood"]) b.push(c, 0);
    expect(b.drain(1)).toEqual(["host-1", "host-2", "srflx"]);
    expect(b.counters.droppedFull).toBe(2);
  });

  test("the default cap is far above any real negotiation", () => {
    expect(ICE_BUFFER_MAX).toBeGreaterThan(32);
    const b = new IceBuffer<number>();
    for (let i = 0; i < ICE_BUFFER_MAX; i++) expect(b.push(i, 0)).toBe("buffered");
    expect(b.push(-1, 0)).toBe("dropped-full");
  });
});

describe("the deadline", () => {
  test("a candidate that waited past it is not delivered", () => {
    const b = new IceBuffer<string>(ICE_BUFFER_MAX, 1000);
    b.push("stale", 0);
    b.push("fresh", 900);
    expect(b.drain(1500)).toEqual(["fresh"]);
    expect(b.counters.droppedExpired).toBe(1);
  });

  test("exactly at the deadline is still fresh; one past it is not", () => {
    const b = new IceBuffer<string>(ICE_BUFFER_MAX, 1000);
    b.push("edge", 0);
    expect(b.drain(1000)).toEqual(["edge"]);

    const c = new IceBuffer<string>(ICE_BUFFER_MAX, 1000);
    c.push("edge", 0);
    expect(c.drain(1001)).toEqual([]);
  });

  test("the default deadline is generous — a slow round trip is not an attack", () => {
    expect(ICE_BUFFER_DEADLINE_MS).toBeGreaterThanOrEqual(5000);
  });
});

describe("§11.3: discard the buffer with its attempt", () => {
  test("discard empties it and counts what it threw away", () => {
    const b = new IceBuffer<string>();
    b.push("a", 0);
    b.push("b", 0);
    b.discard();
    expect(b.size).toBe(0);
    expect(b.drain(1)).toEqual([]);
    expect(b.counters.discarded).toBe(2);
  });

  test("a discarded buffer is reusable, because a new attempt starts from empty", () => {
    const b = new IceBuffer<string>();
    b.push("old", 0);
    b.discard();
    expect(b.push("new", 1)).toBe("buffered");
    expect(b.drain(2)).toEqual(["new"]);
  });
});

test("the counters are a copy, not the live object", () => {
  // A caller that mutated them would be rewriting the record of what was dropped.
  const b = new IceBuffer<string>(1);
  b.push("a", 0);
  b.push("b", 0);
  const snapshot = b.counters;
  snapshot.droppedFull = 999;
  expect(b.counters.droppedFull).toBe(1);
});
