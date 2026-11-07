import { describe, expect, test } from "vitest";
import {
  apply, emptyJournal, findJob, mayAcknowledge, pendingJobs, retriesNow, secretIsLive,
  type EnrollmentEvent, type Journal,
} from "../src/e2e-enrollment";
import { PublicationStatus } from "../src/e2e-wire";

// §12.3's commit order. `E2EEnrollmentTests.swift` asserts the same rules.
//
// THE ORDERING IS THE FEATURE: durable local commit → publication attempt → outcome →
// acknowledgement → background retries. A reducer, so a CRASH is dropping the returned journal on
// the floor and a RESTART is applying the next event to the last journal actually written — which
// is §17.2's "restart from serialized durable state only", expressed as ordinary code.
const id = (n: number): Uint8Array => new Uint8Array(32).fill(n);
const DEVICE = id(1);
const OTHER = id(2);
const OP = id(0x10);
const OTHER_OP = id(0x11);
const GRANT = id(0x20);
const BUNDLE = new Uint8Array([1, 2, 3, 4]);

const step = (journal: Journal, event: EnrollmentEvent): Journal => {
  const r = apply(journal, event);
  if (!r.ok) throw new Error(`expected ok, got ${r.failure}`);
  return r.journal;
};
const failure = (journal: Journal, event: EnrollmentEvent): string => {
  const r = apply(journal, event);
  return r.ok ? "ok" : r.failure;
};

const reserve = (j: Journal, deviceId = DEVICE, operationId = OP): Journal =>
  step(j, { event: "reserve", deviceId, operationId });
const commit = (j: Journal, deviceId = DEVICE, operationId = OP): Journal =>
  step(j, { event: "commit", deviceId, operationId, grantId: GRANT, bundle: BUNDLE });

describe("the acknowledgement is gated on the transaction, not on the Worker", () => {
  test("nothing may be acknowledged before the commit", () => {
    let j = emptyJournal();
    expect(mayAcknowledge(j, OP)).toBe(false);
    j = reserve(j);
    // RESERVED IS NOT COMMITTED. The grant may already be computed — §12.3 allows that — but it
    // must not escape, and this is what says so.
    expect(mayAcknowledge(j, OP)).toBe(false);
    j = commit(j);
    expect(mayAcknowledge(j, OP)).toBe(true);
  });

  test("acknowledgement does not wait on publication, and survives a rejection", () => {
    // §12.2: publication "is not a hard precondition" for access. A rejected job is still an
    // enrolled device — the endpoint's own verification is what authorized it.
    let j = commit(reserve(emptyJournal()));
    expect(mayAcknowledge(j, OP)).toBe(true);
    j = step(j, { event: "publication-attempt", operationId: OP,
                  response: { kind: "http", status: 422 } });
    expect(findJob(j, OP)!.status).toBe(PublicationStatus.Rejected);
    expect(mayAcknowledge(j, OP)).toBe(true);
  });

  test("only the committed operation may be acknowledged", () => {
    const j = commit(reserve(emptyJournal()));
    expect(mayAcknowledge(j, OTHER_OP)).toBe(false);
  });
});

describe("§12.3: only one request wins a window", () => {
  test("a second device is refused", () => {
    const j = reserve(emptyJournal());
    expect(failure(j, { event: "reserve", deviceId: OTHER, operationId: OTHER_OP }))
      .toBe("window-taken");
  });

  test("the same request re-reserving is idempotent", () => {
    // A retry of the same handshake must not lose the window it already holds.
    const j = reserve(emptyJournal());
    expect(reserve(j).window).toEqual(j.window);
  });

  test("a different operation from the SAME device is still a different request", () => {
    const j = reserve(emptyJournal());
    expect(failure(j, { event: "reserve", deviceId: DEVICE, operationId: OTHER_OP }))
      .toBe("window-taken");
  });

  test("a committed or closed window takes no further reservations", () => {
    const committed = commit(reserve(emptyJournal()));
    expect(failure(committed, { event: "reserve", deviceId: OTHER, operationId: OTHER_OP }))
      .toBe("window-unavailable");
    const closed = step(emptyJournal(), { event: "expire" });
    expect(failure(closed, { event: "reserve", deviceId: DEVICE, operationId: OP }))
      .toBe("window-unavailable");
  });
});

describe("§12.3: reservation, grant and job are ONE transaction", () => {
  test("a commit with no reservation behind it is refused", () => {
    expect(failure(emptyJournal(), { event: "commit", deviceId: DEVICE, operationId: OP,
                                     grantId: GRANT, bundle: BUNDLE })).toBe("not-reserved");
  });

  test("a commit for a device other than the reserved one is refused", () => {
    const j = reserve(emptyJournal());
    expect(failure(j, { event: "commit", deviceId: OTHER, operationId: OP, grantId: GRANT,
                        bundle: BUNDLE })).toBe("wrong-reservation");
    expect(failure(j, { event: "commit", deviceId: DEVICE, operationId: OTHER_OP, grantId: GRANT,
                        bundle: BUNDLE })).toBe("wrong-reservation");
  });

  test("the window, the job and the destroyed secret all move together", () => {
    const before = reserve(emptyJournal());
    expect(before.jobs).toHaveLength(0);
    expect(secretIsLive(before.window)).toBe(true);

    const after = commit(before);
    expect(after.window.state).toBe("committed");
    expect(after.jobs).toHaveLength(1);
    // §12.3: the secret is destroyed as part of the committing transaction.
    expect(secretIsLive(after.window)).toBe(false);
  });

  test("replaying the same commit is idempotent, and a different one is refused", () => {
    const j = commit(reserve(emptyJournal()));
    const replayed = commit(j);
    expect(replayed).toEqual(j);
    expect(replayed.jobs).toHaveLength(1);
    expect(failure(j, { event: "commit", deviceId: OTHER, operationId: OTHER_OP, grantId: GRANT,
                        bundle: BUNDLE })).toBe("not-reserved");
  });

  // §17.2: "restart from serialized durable state only." A crash is dropping the returned journal.
  test("a crash before the durable write leaves the window reservable", () => {
    const reserved = reserve(emptyJournal());
    const committed = commit(reserved);
    expect(committed.jobs).toHaveLength(1);

    // ...and the restart, from what was actually written — which is `reserved`, not `committed`.
    const afterRestart = reserved;
    expect(afterRestart.jobs).toHaveLength(0);
    expect(mayAcknowledge(afterRestart, OP)).toBe(false);
    // The same handshake can retry and win its own window back.
    expect(mayAcknowledge(commit(reserve(afterRestart)), OP)).toBe(true);
  });
});

describe("§12.2: the publication job", () => {
  const committed = (): Journal => commit(reserve(emptyJournal()));

  test("a fresh job retries by itself and preserves its payload", () => {
    const j = committed();
    const job = findJob(j, OP)!;
    expect(retriesNow(job)).toBe(true);
    // §12.2: "a retry obtains another challenge but preserves the operation ID and payload."
    expect(job.bundle).toEqual(BUNDLE);
    expect(job.operationId).toEqual(OP);
  });

  test("a transient outcome keeps retrying; a terminal one pauses", () => {
    let j = step(committed(), { event: "publication-attempt", operationId: OP,
                                response: { kind: "http", status: 503 } });
    expect(retriesNow(findJob(j, OP)!)).toBe(true);
    expect(findJob(j, OP)!.attempts).toBe(1);

    j = step(j, { event: "publication-attempt", operationId: OP,
                  response: { kind: "http", status: 400 } });
    // "Paused, pending corrective action" — not looped, and not abandoned either.
    expect(retriesNow(findJob(j, OP)!)).toBe(false);
    expect(findJob(j, OP)!.paused).toBe(true);
    expect(pendingJobs(j)).toHaveLength(0);
    expect(j.jobs).toHaveLength(1);
  });

  test("confirmed is terminal even for the endpoint holding the job", () => {
    let j = step(committed(), { event: "publication-attempt", operationId: OP,
                                response: { kind: "acknowledged" } });
    expect(findJob(j, OP)!.status).toBe(PublicationStatus.Confirmed);
    j = step(j, { event: "publication-attempt", operationId: OP, response: { kind: "no-reply" } });
    expect(findJob(j, OP)!.status).toBe(PublicationStatus.Confirmed);
    expect(retriesNow(findJob(j, OP)!)).toBe(false);
  });

  test("a paused job resumes only on an explicit action", () => {
    let j = step(committed(), { event: "publication-attempt", operationId: OP,
                                response: { kind: "http", status: 403 } });
    expect(retriesNow(findJob(j, OP)!)).toBe(false);
    j = step(j, { event: "resume", operationId: OP });
    expect(retriesNow(findJob(j, OP)!)).toBe(true);
    expect(findJob(j, OP)!.attempts).toBe(1);
  });

  test("an unknown operation is not silently ignored", () => {
    expect(failure(committed(), { event: "publication-attempt", operationId: OTHER_OP,
                                  response: { kind: "acknowledged" } })).toBe("unknown-operation");
    expect(failure(committed(), { event: "resume", operationId: OTHER_OP }))
      .toBe("unknown-operation");
  });
});

describe("§12.2: revocation stops jobs, and stopping is irreversible", () => {
  test("a revoked device's job stops", () => {
    let j = commit(reserve(emptyJournal()));
    expect(pendingJobs(j)).toHaveLength(1);
    j = step(j, { event: "revoked", deviceId: DEVICE });
    expect(pendingJobs(j)).toHaveLength(0);
    expect(findJob(j, OP)!.stopped).toBe(true);
  });

  test("a stopped job does NOT resume", () => {
    // §10.5 has no unrevoke operation; a resume that restarted a revoked device's publication
    // would be the one path in this system that manufactures one.
    let j = step(commit(reserve(emptyJournal())), { event: "revoked", deviceId: DEVICE });
    j = step(j, { event: "resume", operationId: OP });
    expect(retriesNow(findJob(j, OP)!)).toBe(false);
    expect(findJob(j, OP)!.stopped).toBe(true);
  });

  // AND ITS STATUS MUST NOT BE REWRITTEN EITHER, which is a separate fact from whether it runs.
  // §12.2 obliges an endpoint to surface anything other than `confirmed` to the user; a job that
  // reads `unconfirmed` says "still trying", and a stopped one never will be. Without this the
  // guard in `resume` is invisible — `retriesNow` already consults `stopped`, so a mutation
  // deleting the guard passed the whole suite.
  test("resuming a stopped job leaves its reported status alone", () => {
    let j = commit(reserve(emptyJournal()));
    j = step(j, { event: "publication-attempt", operationId: OP,
                  response: { kind: "http", status: 403 } });
    expect(findJob(j, OP)!.status).toBe(PublicationStatus.Rejected);
    expect(findJob(j, OP)!.paused).toBe(true);

    j = step(j, { event: "revoked", deviceId: DEVICE });
    const before = findJob(j, OP)!;
    j = step(j, { event: "resume", operationId: OP });
    const after = findJob(j, OP)!;
    expect(after.status).toBe(PublicationStatus.Rejected);
    expect(after.paused).toBe(true);
    expect(after).toEqual(before);
  });

  test("a device revoked BEFORE its commit gets a job that never runs", () => {
    let j = step(emptyJournal(), { event: "revoked", deviceId: DEVICE });
    j = commit(reserve(j));
    expect(findJob(j, OP)!.stopped).toBe(true);
    expect(pendingJobs(j)).toHaveLength(0);
  });

  test("an unrelated device's job is untouched", () => {
    let j = commit(reserve(emptyJournal()));
    j = step(j, { event: "revoked", deviceId: OTHER });
    expect(pendingJobs(j)).toHaveLength(1);
  });
});

describe("§14: the window expires", () => {
  test("an open or reserved window closes and its secret dies", () => {
    for (const start of [emptyJournal(), reserve(emptyJournal())]) {
      const closed = step(start, { event: "expire" });
      expect(closed.window.state).toBe("closed");
      expect(secretIsLive(closed.window)).toBe(false);
    }
  });

  // §14: "erase secret and abort unreserved handshakes; PRESERVE ESTABLISHED ROUTES."
  test("a committed window is not torn down by an expiry", () => {
    const j = commit(reserve(emptyJournal()));
    const after = step(j, { event: "expire" });
    expect(after.window.state).toBe("committed");
    expect(mayAcknowledge(after, OP)).toBe(true);
    expect(pendingJobs(after)).toHaveLength(1);
  });
});

test("the reducer never mutates the journal it was given", () => {
  // A caller writes the RETURNED journal durably; one that mutated in place would have already
  // changed the state a crash would restart from.
  const before = reserve(emptyJournal());
  const snapshot = JSON.stringify(before, (_k, v: unknown) =>
    v instanceof Uint8Array ? [...v] : v);
  commit(before);
  expect(JSON.stringify(before, (_k, v: unknown) => v instanceof Uint8Array ? [...v] : v))
    .toBe(snapshot);
});
