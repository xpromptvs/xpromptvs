import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  APP_HELLO_MAX, E2E_MODES, E2E_ID_LENGTH, E2E_SIGNATURE_LENGTH, PublicationStatus,
  clientConfirm, deviceProofBody, initiatorHello, isOrdinaryAuth, message1PayloadIsAcceptable,
  parseClientConfirm, parseInitiatorHello, parseResponderHello, parseSessionStart, prologue,
  responderHello, sessionStart,
  type E2EMode,
} from "../src/e2e-wire";

// The §11 wire encodings, against vectors a THIRD implementation produced
// (`scripts/gen_e2e_wire_fixture.py`) and which `E2EWireTests.swift` asserts too. Byte layouts are
// exactly where two implementations drift while both look correct, so neither grades its own work.
interface Case {
  name: string; kind: string; encoded: string;
  mode?: E2EMode; room_code?: string;
  h?: string; device_id?: string; responder_device_id?: string; operation_id?: string;
  proof_body?: string; proof?: string; new_bundle?: string; app_hello?: string;
  publication_status?: number; accepted_bundle?: string;
  bundle?: string; rcode?: string; rtoken?: string; device?: string; is_ordinary_auth?: boolean;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-wire.json", import.meta.url)), "utf8")) as { cases: Case[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

describe("cross-implementation vectors", () => {
  const seen = new Set<string>();
  for (const c of fx.cases) {
    test(c.name, () => {
      seen.add(c.kind);
      switch (c.kind) {
        case "prologue":
          expect(toHex(prologue(c.mode!, c.room_code!)!)).toBe(c.encoded);
          break;
        case "proof_body":
          expect(toHex(deviceProofBody(c.mode!, hex(c.h!), hex(c.device_id!),
                                       hex(c.responder_device_id!), hex(c.operation_id!))!)).toBe(c.encoded);
          break;
        case "client_confirm": {
          expect(toHex(clientConfirm(hex(c.proof_body!), hex(c.proof!), hex(c.new_bundle!), hex(c.app_hello!))!)).toBe(c.encoded);
          const p = parseClientConfirm(hex(c.encoded))!;
          expect(p, c.name).not.toBeNull();
          expect(toHex(p.proofBody)).toBe(c.proof_body);
          expect(toHex(p.proof)).toBe(c.proof);
          expect(toHex(p.newBundle)).toBe(c.new_bundle);
          expect(toHex(p.appHello)).toBe(c.app_hello);
          break;
        }
        case "session_start": {
          expect(toHex(sessionStart(hex(c.h!), hex(c.operation_id!),
                                    c.publication_status!, hex(c.accepted_bundle!))!)).toBe(c.encoded);
          const p = parseSessionStart(hex(c.encoded))!;
          expect(p).not.toBeNull();
          expect(p.publicationStatus).toBe(c.publication_status);
          expect(toHex(p.acceptedBundle)).toBe(c.accepted_bundle);
          break;
        }
        case "responder_hello": {
          expect(toHex(responderHello(hex(c.bundle!), c.rcode!, c.rtoken!)!)).toBe(c.encoded);
          const p = parseResponderHello(hex(c.encoded))!;
          expect(p).not.toBeNull();
          expect(toHex(p.bundle)).toBe(c.bundle);
          expect(p.rcode).toBe(c.rcode);
          expect(p.rtoken).toBe(c.rtoken);
          break;
        }
        case "initiator_hello": {
          expect(toHex(initiatorHello(hex(c.device!), hex(c.operation_id!), hex(c.bundle!))!))
            .toBe(c.encoded);
          const p = parseInitiatorHello(hex(c.encoded))!;
          expect(p).not.toBeNull();
          expect(toHex(p.device)).toBe(c.device);
          expect(toHex(p.operationId)).toBe(c.operation_id);
          expect(toHex(p.bundle)).toBe(c.bundle);
          expect(isOrdinaryAuth(p)).toBe(c.is_ordinary_auth);
          break;
        }
        default:
          throw new Error(`unknown fixture kind ${c.kind} — a new kind must be asserted, not skipped`);
      }
    });
  }
  test("every message kind appears", () => {
    expect([...seen].sort()).toEqual(["client_confirm", "initiator_hello", "prologue",
                                      "proof_body", "responder_hello", "session_start"]);
  });
});

// EVERY MODE AND EVERY ROOM IS A DIFFERENT PROLOGUE. Noise mixes it before anything else, so two
// peers disagreeing about either cannot complete a handshake — which is what stops a `pair`
// transcript being replayed as an `auth`, or one session's into another's.
test("the mode and the room are both bound in", () => {
  const byMode = new Set(E2E_MODES.map((m) => toHex(prologue(m, "room")!)));
  expect(byMode.size).toBe(E2E_MODES.length);
  expect(toHex(prologue("auth", "roomA")!)).not.toBe(toHex(prologue("auth", "roomB")!));
});

// §7 requires refusing wrong widths BEFORE verification — a proof over a short hash would be a
// perfectly valid signature over the wrong statement.
test("wrong widths are refused at construction", () => {
  const ok = new Uint8Array(E2E_ID_LENGTH);
  const short = new Uint8Array(E2E_ID_LENGTH - 1);
  expect(deviceProofBody("auth", short, ok, ok, ok)).toBeNull();
  expect(deviceProofBody("auth", ok, short, ok, ok)).toBeNull();
  expect(clientConfirm(new Uint8Array(0), short, new Uint8Array(0))).toBeNull();
  expect(sessionStart(short, ok, PublicationStatus.Confirmed, new Uint8Array(0))).toBeNull();
});

// THE PARSER IS THE SECURITY SURFACE. Every input here is a byte string an adversary can send.
test("the parser refuses malformed input", () => {
  const good = sessionStart(new Uint8Array(E2E_ID_LENGTH).fill(1), new Uint8Array(E2E_ID_LENGTH).fill(2),
                            PublicationStatus.Unconfirmed, new Uint8Array([9, 9, 9]))!;
  expect(parseSessionStart(good)).not.toBeNull();
  expect(parseSessionStart(new Uint8Array([...good, 0])), "extra trailing bytes").toBeNull();
  expect(parseSessionStart(good.subarray(0, good.length - 1)), "truncated").toBeNull();
  expect(parseSessionStart(new Uint8Array(0)), "empty").toBeNull();

  const future = new Uint8Array(good);
  future[2 + "rdev-e2e/session-start/v3".length + 2 * E2E_ID_LENGTH] = 3;
  expect(parseSessionStart(future), "an unknown publication status").toBeNull();

  const confirm = clientConfirm(new Uint8Array([1, 2, 3]),
                                new Uint8Array(E2E_SIGNATURE_LENGTH).fill(7), new Uint8Array(0))!;
  expect(parseSessionStart(confirm), "a confirm is not a session-start").toBeNull();
  expect(parseClientConfirm(good), "a session-start is not a confirm").toBeNull();
});

// A LENGTH PREFIX THAT OVERRUNS THE BUFFER must not be believed — the classic parser defect, and the
// one that turns a length field into a read primitive.
test("a length prefix cannot overrun the buffer", () => {
  const bytes = new Uint8Array(clientConfirm(new Uint8Array([1, 2, 3]),
                                             new Uint8Array(E2E_SIGNATURE_LENGTH).fill(7),
                                             new Uint8Array([4, 5]))!);
  const at = 2 + "rdev-e2e/confirm/v3".length;
  bytes[at] = 0xff; bytes[at + 1] = 0xff;
  expect(parseClientConfirm(bytes)).toBeNull();
});

// §11.2's "BOUNDED": `app_hello` rides the gate's own message, so it is capped — on both ends, and the cap is a
// rejection when parsing, never a truncation.
test("client-confirm's app_hello is capped at APP_HELLO_MAX", () => {
  const proof = new Uint8Array(E2E_SIGNATURE_LENGTH).fill(7);
  const atCap = clientConfirm(new Uint8Array([1]), proof, new Uint8Array(0), new Uint8Array(APP_HELLO_MAX).fill(0x7b))!;
  expect(parseClientConfirm(atCap)?.appHello.length).toBe(APP_HELLO_MAX);
  expect(clientConfirm(new Uint8Array([1]), proof, new Uint8Array(0), new Uint8Array(APP_HELLO_MAX + 1)), "encoding").toBeNull();
  // One over, written by hand: the length prefix says it, and the parser refuses it.
  const over = new Uint8Array([...atCap.subarray(0, atCap.length - APP_HELLO_MAX - 2),
                               (APP_HELLO_MAX + 1) >> 8, (APP_HELLO_MAX + 1) & 0xff, ...new Uint8Array(APP_HELLO_MAX + 1)]);
  expect(parseClientConfirm(over), "parsing").toBeNull();
  // A confirm MISSING the field is refused, never read as one with an empty app_hello.
  const missing = atCap.subarray(0, atCap.length - APP_HELLO_MAX - 2);
  expect(parseClientConfirm(missing), "no app_hello").toBeNull();
});

// §11.1: "Message 1 has an empty payload." It travels before any authentication, so anything in it
// is bytes an unauthenticated stranger chose — a build that tolerated a payload here would be
// parsing attacker input at the earliest possible point in the protocol.
test("message 1 carries nothing", () => {
  expect(message1PayloadIsAcceptable(new Uint8Array(0))).toBe(true);
  expect(message1PayloadIsAcceptable(new Uint8Array(1))).toBe(false);
  expect(message1PayloadIsAcceptable(new TextEncoder().encode("hello"))).toBe(false);
});

// Both hello payloads are UNLABELLED concatenations, so their parsers have nothing to anchor on
// except widths and the total length. That makes trailing bytes the whole defence.
describe("the hello payloads reject what §7 says they must", () => {
  const bundle = new Uint8Array([1, 2, 3, 4]);
  const device = new Uint8Array(70).fill(9);
  const op = new Uint8Array(E2E_ID_LENGTH).fill(7);

  test("a responder hello with trailing bytes", () => {
    const good = responderHello(bundle, "x0WuwKuk", "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d")!;
    expect(parseResponderHello(good)).not.toBeNull();
    expect(parseResponderHello(new Uint8Array([...good, 0]))).toBeNull();
    expect(parseResponderHello(good.slice(0, -1))).toBeNull();
  });

  test("an initiator hello with a short operation id", () => {
    const good = initiatorHello(device, op, bundle)!;
    expect(parseInitiatorHello(good)).not.toBeNull();
    expect(parseInitiatorHello(new Uint8Array([...good, 0]))).toBeNull();
    expect(initiatorHello(device, op.slice(0, 31), bundle)).toBeNull();
  });

  test("an rcode that is not UTF-8 is refused, never replaced", () => {
    // A replacement character would make two different byte strings compare equal as routes.
    const bad = new Uint8Array([0, 4, 1, 2, 3, 4, 0, 2, 0xff, 0xfe, 0, 0]);
    expect(parseResponderHello(bad)).toBeNull();
  });

  test("a signature-width value is not silently accepted as a device descriptor", () => {
    // The initiator hello has no label, so this is the shape most likely to be confused with it.
    expect(parseInitiatorHello(new Uint8Array(E2E_SIGNATURE_LENGTH))).toBeNull();
  });
});
