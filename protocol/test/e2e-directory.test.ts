import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { sha256 } from "@noble/hashes/sha2.js";
import {
  DIRECTORY_CHALLENGE_LENGTH, DIRECTORY_CHALLENGE_MAX_AGE_SECONDS,
  PUBLICATION_REJECTED_WORDING, PUBLISH_DEADLINE_SECONDS,
  REVOKE_DEADLINE_SECONDS, classifyPublication, directoryRequestBody, mergePublicationStatus,
  DIRECTORY_ACTIONS, directorySessionPayload, isDirectoryAction,
  mustSurface, nextAction, observedOwnGrantInDirectory, parseDirectoryRequestBody,
  retriesAutomatically, type DirectoryResponse, type DurableState,
} from "../src/e2e-directory";
import { PublicationStatus } from "../src/e2e-wire";

// §12's directory contract. The encodings are held to vectors a THIRD implementation produced
// (`scripts/gen_e2e_wire_fixture.py`); the rules are §12.2's own tables, and `E2EDirectoryTests.swift`
// asserts all of it too.
interface Case {
  name: string; kind: string; encoded: string;
  action?: string; challenge?: string; root_id?: string; operation_id?: string;
  payload?: string; payload_hash?: string;
  code?: string; token?: string; label?: string; device_id?: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-directory.json", import.meta.url)), "utf8")) as {
    challenge_length: number; challenge_max_age_seconds: number;
    publish_deadline_seconds: number; revoke_deadline_seconds: number;
    rejected_wording: string; cases: Case[];
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
const cases = fx.cases.filter((c) => c.kind === "directory_request");
const sessionCases = fx.cases.filter((c) => c.kind === "directory_session");

describe("§12.2's signed request body", () => {
  test("the fixture carries directory cases at all", () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  // **EVERY action, not only `register`.** The parser used to hardcode that one while
  // `directoryRequestBody` accepted four, so a well-formed `publish` body round-tripped to null —
  // a disagreement about the vocabulary that no caller had yet exercised.
  test("the fixture exercises every action the body is defined for", () => {
    expect(new Set(cases.map((c) => c.action))).toEqual(new Set(DIRECTORY_ACTIONS));
  });

  for (const c of cases) {
    test(c.name, () => {
      expect(isDirectoryAction(c.action), c.action).toBe(true);
      const body = directoryRequestBody(c.action as "register", hex(c.challenge!), hex(c.root_id!),
                                        hex(c.operation_id!), hex(c.payload!));
      expect(toHex(body!)).toBe(c.encoded);
      const parsed = parseDirectoryRequestBody(hex(c.encoded))!;
      expect(parsed).not.toBeNull();
      expect(parsed.action).toBe(c.action);
      expect(toHex(parsed.challenge)).toBe(c.challenge);
      expect(toHex(parsed.rootId)).toBe(c.root_id);
      expect(toHex(parsed.operationId)).toBe(c.operation_id);
      // The PAYLOAD is not in the body; its hash is. That is what keeps the signed statement a
      // fixed size whatever the bundle weighs.
      expect(toHex(parsed.payloadHash)).toBe(c.payload_hash);
      expect(toHex(parsed.payloadHash)).toBe(toHex(sha256(hex(c.payload!))));
    });
  }

  // A `list` signature must never verify as a subscription: same inputs, different bytes.
  test("subscribe and list sign different bodies for the same inputs", () => {
    const list = cases.find((c) => c.action === "list")!;
    const sub = cases.find((c) => c.action === "subscribe")!;
    expect(sub).toBeDefined();
    expect(sub.encoded).not.toBe(list.encoded);
  });

  // FOR ONE ACTION. Across actions the body differs only by the action's own name, so the two
  // `register` cases — one with a 40-byte bundle, one with nothing — are what this is about.
  test("the body is the same size whatever the payload weighs", () => {
    const registers = cases.filter((c) => c.action === "register");
    expect(registers.length).toBeGreaterThan(1);
    expect(new Set(registers.map((c) => c.encoded.length)).size).toBe(1);
    expect(hex(registers[0]!.encoded).length).toBe(161);
  });

  // The payload `publish` signs over. Canonical, because a JSON encoder's key order is not a
  // contract and two implementations that disagree about it produce a signature neither can check.
  test("the session payload matches the third implementation", () => {
    expect(sessionCases.length).toBeGreaterThan(0);
    for (const c of sessionCases) {
      const encoded = directorySessionPayload({
        code: c.code!, token: c.token!, label: c.label!, device_id: c.device_id!,
      });
      expect(toHex(encoded!), c.name).toBe(c.encoded);
    }
  });

  test("a wrong-width challenge, root or operation id is refused", () => {
    const ok = { c: new Uint8Array(32), r: new Uint8Array(32), o: new Uint8Array(32) };
    expect(directoryRequestBody("register", ok.c, ok.r, ok.o, new Uint8Array(0))).not.toBeNull();
    expect(directoryRequestBody("register", new Uint8Array(31), ok.r, ok.o, new Uint8Array(0)))
      .toBeNull();
    expect(directoryRequestBody("register", ok.c, new Uint8Array(31), ok.o, new Uint8Array(0)))
      .toBeNull();
    expect(directoryRequestBody("register", ok.c, ok.r, new Uint8Array(33), new Uint8Array(0)))
      .toBeNull();
    expect(DIRECTORY_CHALLENGE_LENGTH).toBe(32);
  });

  test("trailing bytes and an unknown action are refused", () => {
    const good = directoryRequestBody("register", new Uint8Array(32), new Uint8Array(32),
                                      new Uint8Array(32), new Uint8Array(0))!;
    expect(parseDirectoryRequestBody(good)).not.toBeNull();
    expect(parseDirectoryRequestBody(new Uint8Array([...good, 0]))).toBeNull();
    expect(parseDirectoryRequestBody(good.slice(0, -1))).toBeNull();
    // "revoke" is deliberately NOT an action here: §12.2 says the WebAuthn-signed revocation
    // authorizes its own submission and needs no device authority. It is the same LENGTH as
    // "register" is not — so the substitution below keeps the framing valid and changes only the
    // name, which is the only way to test the vocabulary rather than the reader.
    const revoke = new Uint8Array(good);
    revoke.set(new TextEncoder().encode("revoke!!"), 25);
    expect(parseDirectoryRequestBody(revoke)).toBeNull();
  });
});

describe("§12.2's transient/terminal table", () => {
  const table: Array<[DirectoryResponse, PublicationStatus, string]> = [
    [{ kind: "acknowledged" }, PublicationStatus.Confirmed, "a plain acknowledgement"],
    [{ kind: "conflict-same-content" }, PublicationStatus.Confirmed, "409 with the SAME content"],
    [{ kind: "no-reply" }, PublicationStatus.Unconfirmed, "nothing came back"],
    [{ kind: "conflict-different-content" }, PublicationStatus.Rejected, "409, DIFFERENT content"],
    [{ kind: "http", status: 200 }, PublicationStatus.Confirmed, "200"],
    [{ kind: "http", status: 204 }, PublicationStatus.Confirmed, "204"],
    [{ kind: "http", status: 404 }, PublicationStatus.Unconfirmed, "404 — a deploy in progress"],
    [{ kind: "http", status: 429 }, PublicationStatus.Unconfirmed, "429"],
    [{ kind: "http", status: 500 }, PublicationStatus.Unconfirmed, "500"],
    [{ kind: "http", status: 503 }, PublicationStatus.Unconfirmed, "503"],
    [{ kind: "http", status: 400 }, PublicationStatus.Rejected, "400 malformed"],
    [{ kind: "http", status: 401 }, PublicationStatus.Rejected, "401 refused"],
    [{ kind: "http", status: 403 }, PublicationStatus.Rejected, "403 refused"],
    [{ kind: "http", status: 422 }, PublicationStatus.Rejected, "422 invalid chain"],
    [{ kind: "http", status: 409 }, PublicationStatus.Rejected, "a bare 409, content uncompared"],
  ];
  for (const [response, want, why] of table) {
    test(why, () => { expect(classifyPublication(response)).toBe(want); });
  }

  // The two rules most likely to be "tidied" into something that looks more sensible.
  test("404 is TRANSIENT, not a refusal", () => {
    expect(retriesAutomatically(classifyPublication({ kind: "http", status: 404 }))).toBe(true);
  });

  test("a matching 409 is the idempotent SUCCESS path", () => {
    expect(classifyPublication({ kind: "conflict-same-content" }))
      .toBe(PublicationStatus.Confirmed);
    expect(classifyPublication({ kind: "conflict-different-content" }))
      .not.toBe(PublicationStatus.Confirmed);
  });

  test("only unconfirmed retries by itself, and anything but confirmed is surfaced", () => {
    expect(retriesAutomatically(PublicationStatus.Unconfirmed)).toBe(true);
    expect(retriesAutomatically(PublicationStatus.Rejected)).toBe(false);
    expect(retriesAutomatically(PublicationStatus.Confirmed)).toBe(false);
    expect(mustSurface(PublicationStatus.Confirmed)).toBe(false);
    expect(mustSurface(PublicationStatus.Unconfirmed)).toBe(true);
    expect(mustSurface(PublicationStatus.Rejected)).toBe(true);
  });

  test("the required wording is quoted exactly and never asserts an absence", () => {
    expect(PUBLICATION_REJECTED_WORDING)
      .toBe("Publication rejected; listing not confirmed. Action required.");
    // "An interface that says 'not listed' asserts an absence no endpoint has established."
    expect(PUBLICATION_REJECTED_WORDING).not.toMatch(/not listed/i);
  });

  test("the deadlines and the wording match the fixture's own record of them", () => {
    // The constants ARE the contract; a suite asserting them against itself asserts nothing.
    expect(PUBLISH_DEADLINE_SECONDS).toBe(fx.publish_deadline_seconds);
    expect(REVOKE_DEADLINE_SECONDS).toBe(fx.revoke_deadline_seconds);
    expect(DIRECTORY_CHALLENGE_LENGTH).toBe(fx.challenge_length);
    expect(DIRECTORY_CHALLENGE_MAX_AGE_SECONDS).toBe(fx.challenge_max_age_seconds);
    expect(PUBLICATION_REJECTED_WORDING).toBe(fx.rejected_wording);
  });
});

describe("§12.2: status is monotonic toward confirmed", () => {
  const S = PublicationStatus;

  test("confirmed is terminal and no peer resets it", () => {
    for (const reported of [S.Unconfirmed, S.Rejected, S.Confirmed]) {
      for (const holds of [true, false]) {
        expect(mergePublicationStatus(S.Confirmed, reported, holds)).toBe(S.Confirmed);
      }
    }
  });

  // THE RULE THAT MAKES THIS NON-TRIVIAL. `publication_status` rides in EVERY session-start,
  // including an ordinary `auth` to a Host that never participated in the publication — and such a
  // Host correctly reports `unconfirmed`, because it does not know. Without the job test, every
  // connection to an unrelated Host would erase what the issuing endpoint reported.
  test("a responder holding no publication job is informational only", () => {
    expect(mergePublicationStatus(S.Rejected, S.Unconfirmed, false)).toBe(S.Rejected);
    expect(mergePublicationStatus(S.Unconfirmed, S.Rejected, false)).toBe(S.Unconfirmed);
    expect(mergePublicationStatus(null, S.Unconfirmed, false)).toBeNull();
  });

  test("the endpoint holding the job may change a non-confirmed value in either direction", () => {
    expect(mergePublicationStatus(S.Unconfirmed, S.Rejected, true)).toBe(S.Rejected);
    expect(mergePublicationStatus(S.Rejected, S.Unconfirmed, true)).toBe(S.Unconfirmed);
    expect(mergePublicationStatus(S.Unconfirmed, S.Confirmed, true)).toBe(S.Confirmed);
    expect(mergePublicationStatus(null, S.Unconfirmed, true)).toBe(S.Unconfirmed);
  });

  test("observing your own grant clears the flag, and it never comes back", () => {
    const cleared = observedOwnGrantInDirectory();
    expect(cleared).toBe(S.Confirmed);
    // M can later omit the record; re-raising the warning would hand it a nuisance channel.
    expect(mergePublicationStatus(cleared, S.Unconfirmed, true)).toBe(S.Confirmed);
  });
});

describe("§12.4's resume table", () => {
  const table: Array<[DurableState, string, boolean | undefined]> = [
    ["keys-only", "fresh-enrollment", undefined],
    ["pending-operation", "resume", undefined],
    ["committed-cleanup-pending", "auth", true],
    ["committed-clean", "auth", false],
    ["keys-lost", "generate-new-keys-and-enroll", undefined],
  ];
  for (const [state, action, repeatCleanup] of table) {
    test(`${state} → ${action}`, () => {
      const next = nextAction(state);
      expect(next.action).toBe(action);
      if (repeatCleanup !== undefined) {
        expect(next.action === "auth" && next.repeatCleanup).toBe(repeatCleanup);
      }
    });
  }

  test("a committed chain never restarts a ceremony", () => {
    // Restarting would reserve a second window for a device that already holds a grant.
    for (const state of ["committed-cleanup-pending", "committed-clean"] as DurableState[]) {
      expect(nextAction(state).action).toBe("auth");
    }
    // ...and keys with no committed chain never go straight to `auth`.
    expect(nextAction("keys-only").action).not.toBe("auth");
    expect(nextAction("pending-operation").action).not.toBe("auth");
  });
});

// ------------------------------------------------- session discovery, which replaces OAuth accounts

describe("the directory's session actions", () => {
  // A body that did not bind the ACTION would let a `list` signature be replayed as an `unpublish`:
  // same challenge, same root, same operation id, same payload. The label and the action are the
  // only things separating them.
  test("the action is bound into the signed body", () => {
    const c = new Uint8Array(32).fill(1);
    const r = new Uint8Array(32).fill(2);
    const o = new Uint8Array(32).fill(3);
    const bodies = DIRECTORY_ACTIONS.map(
      (a) => directoryRequestBody(a, c, r, o, new Uint8Array(0))!);
    const seen = new Set(bodies.map((b) => [...b].join(",")));
    expect(seen.size).toBe(DIRECTORY_ACTIONS.length);
  });

  test("an unknown action is refused rather than guessed", () => {
    for (const a of DIRECTORY_ACTIONS) expect(isDirectoryAction(a)).toBe(true);
    for (const a of ["", "REGISTER", "delete", "publish ", 7, null, undefined]) {
      expect(isDirectoryAction(a)).toBe(false);
    }
  });

  // Length-prefixed, so no field can eat the next one. Without it a label of `"x\u0000y"` and a
  // token beginning `y` would sign the same bytes as a different pair.
  test("the session payload is unambiguous across its fields", () => {
    const a = directorySessionPayload({ code: "ab", token: "c", label: "d", device_id: "e" })!;
    const b = directorySessionPayload({ code: "a", token: "bc", label: "d", device_id: "e" })!;
    expect(a).not.toBeNull();
    expect([...a].join(",")).not.toBe([...b].join(","));
  });

  test("every field is covered by the payload", () => {
    const base = { code: "c", token: "t", label: "l", device_id: "d" };
    const seen = new Set([directorySessionPayload(base)!].map((p) => [...p].join(",")));
    for (const k of ["code", "token", "label", "device_id"] as const) {
      const p = directorySessionPayload({ ...base, [k]: "CHANGED" })!;
      seen.add([...p].join(","));
    }
    expect(seen.size).toBe(5);
  });
});
