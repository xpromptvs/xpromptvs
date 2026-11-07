#!/usr/bin/env python3
"""Regenerate protocol/fixtures/e2e-wire.json — the §11 wire encodings of the E2E protocol
specification (prologue, device proof body, client-confirm, session-start).

    python3 scripts/gen_e2e_wire_fixture.py > protocol/fixtures/e2e-wire.json

A THIRD IMPLEMENTATION, like scripts/gen_pairing_fixture.py, and for the same reason: the Swift and
TypeScript encoders each assert against what this produces, so each agrees with something neither of
them wrote. Byte layouts are exactly where two implementations drift while both look correct.

Stdlib only. NEVER edit a vector by hand to make a suite pass — if a vector is wrong, the spec is.
"""
import json

def lp(b: bytes) -> bytes:
    """LP(x) = uint16be(len(x)) || x  (spec §7)."""
    assert len(b) <= 0xFFFF, "LP cannot carry more than 65535 bytes"
    return len(b).to_bytes(2, "big") + b

def u8(n: int) -> bytes:
    return bytes([n])

def utf8(s: str) -> bytes:
    return s.encode("utf-8")

# §11.1
def prologue(mode: str, room_code: str) -> bytes:
    return lp(utf8("rdev-e2e/v3")) + lp(utf8(mode)) + lp(utf8(room_code))

# §11.1 handshake payloads. NO LABEL on either: position in the transcript fixes the meaning,
# and the prologue has already bound the mode and the room.
def responder_hello(bundle: bytes, rcode: str, rtoken: str) -> bytes:
    return lp(bundle) + lp(utf8(rcode)) + lp(utf8(rtoken))

def initiator_hello(device: bytes, operation_id: bytes, bundle: bytes) -> bytes:
    return lp(device) + operation_id + lp(bundle)

# §11.2
def proof_body(mode: str, h: bytes, device_id: bytes, responder_device_id: bytes,
               operation_id: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/device-proof/v1")) + lp(utf8(mode)) + h
            + device_id + responder_device_id + operation_id)

# v3 (2026-10-05) adds `app_hello`: the application's first words — the client's terminal grid — opaque
# here, inside the session's first transport message, at most APP_HELLO_MAX bytes (§11.2: bounded).
APP_HELLO_MAX = 1024

def client_confirm(body: bytes, proof: bytes, new_bundle: bytes, app_hello: bytes) -> bytes:
    assert len(app_hello) <= APP_HELLO_MAX
    return lp(utf8("rdev-e2e/confirm/v3")) + lp(body) + proof + lp(new_bundle) + lp(app_hello)

def session_start(h: bytes, operation_id: bytes, status: int, accepted_bundle: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/session-start/v3")) + h + operation_id
            + u8(status) + lp(accepted_bundle))

def fill(byte: int, n: int = 32) -> bytes:
    return bytes([byte]) * n

H          = fill(0x11)
DEVICE     = fill(0x22)
RESPONDER  = fill(0x33)
OPERATION  = fill(0x44)
PROOF      = fill(0x55, 64)          # Ed25519 signatures are 64 bytes (§7)
BUNDLE     = bytes(range(40))

cases = []
for mode in ("pair", "enroll", "auth", "resume"):
    cases.append({
        "name": f"prologue/{mode}",
        "kind": "prologue",
        "mode": mode,
        "room_code": "SUT_8ORm",
        "encoded": prologue(mode, "SUT_8ORm").hex(),
    })

# §9.2's rcode is 8 characters from the 64-character alphabet and rtoken is a lowercase UUID.
RCODE = "x0WuwKuk"
RTOKEN = "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d"

cases.append({
    "name": "responder_hello/with-route", "kind": "responder_hello",
    "bundle": BUNDLE.hex(), "rcode": RCODE, "rtoken": RTOKEN,
    "encoded": responder_hello(BUNDLE, RCODE, RTOKEN).hex(),
})

# §11.1: message 3's bundle "is empty for `pair` and `enroll`", and an ordinary `auth` uses an
# ALL-ZERO operation id — a meaning, not a missing value, so both shapes are pinned.
cases.append({
    "name": "initiator_hello/auth-ordinary", "kind": "initiator_hello",
    "device": DEVICE.hex(), "operation_id": fill(0x00).hex(), "bundle": BUNDLE.hex(),
    "is_ordinary_auth": True,
    "encoded": initiator_hello(DEVICE, fill(0x00), BUNDLE).hex(),
})
cases.append({
    "name": "initiator_hello/pair-empty-bundle", "kind": "initiator_hello",
    "device": DEVICE.hex(), "operation_id": OPERATION.hex(), "bundle": "",
    "is_ordinary_auth": False,
    "encoded": initiator_hello(DEVICE, OPERATION, b"").hex(),
})

cases.append({
    "name": "proof_body/auth",
    "kind": "proof_body",
    "mode": "auth",
    "h": H.hex(), "device_id": DEVICE.hex(),
    "responder_device_id": RESPONDER.hex(), "operation_id": OPERATION.hex(),
    "encoded": proof_body("auth", H, DEVICE, RESPONDER, OPERATION).hex(),
})

body = proof_body("enroll", H, DEVICE, RESPONDER, OPERATION)
APP_HELLO = utf8('{"grid":{"cols":120,"rows":40}}')
for name, bundle, app_hello in (("client_confirm/enroll-with-bundle", BUNDLE, b""),
                                ("client_confirm/empty-bundle", b"", b""),
                                ("client_confirm/auth-with-app-hello", b"", APP_HELLO),
                                ("client_confirm/app-hello-at-the-cap", b"", fill(0x7B, APP_HELLO_MAX))):
    cases.append({
        "name": name, "kind": "client_confirm",
        "proof_body": body.hex(), "proof": PROOF.hex(), "new_bundle": bundle.hex(),
        "app_hello": app_hello.hex(),
        "encoded": client_confirm(body, PROOF, bundle, app_hello).hex(),
    })

for status, label in ((0, "confirmed"), (1, "unconfirmed"), (2, "rejected")):
    cases.append({
        "name": f"session_start/{label}", "kind": "session_start",
        "h": H.hex(), "operation_id": OPERATION.hex(),
        "publication_status": status, "accepted_bundle": BUNDLE.hex(),
        "encoded": session_start(H, OPERATION, status, BUNDLE).hex(),
    })

doc = {
    "_comment": [
        "Cross-implementation vectors for the §11 wire encodings of the E2E protocol specification.",
        "GENERATED BY A THIRD IMPLEMENTATION (stdlib Python) so the Swift and TypeScript encoders each",
        "agree with something neither of them wrote. Byte layouts are exactly where two",
        "implementations drift while both look correct.",
        "",
        "LP(x) = uint16be(len(x)) || x. Fixed-width fields are 32 bytes except Ed25519 signatures,",
        "which are 64 (§7). publication_status is U8: 0 confirmed, 1 unconfirmed, 2 rejected.",
        "client-confirm's app_hello is at most 1024 bytes; a longer one is a rejection, as trailing bytes are.",
        "",
        "Regenerate with scripts/gen_e2e_wire_fixture.py; never edit a value by hand."
    ],
    "cases": cases,
}
print(json.dumps(doc, indent=1))
