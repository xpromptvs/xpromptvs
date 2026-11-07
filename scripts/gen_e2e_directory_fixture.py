#!/usr/bin/env python3
"""Regenerate protocol/fixtures/e2e-directory.json — the §12.2 body a device signs to mutate the
directory.

    python3 scripts/gen_e2e_directory_fixture.py > protocol/fixtures/e2e-directory.json

A THIRD IMPLEMENTATION, like the fixtures beside it. Kept SEPARATE from the §11 wire fixture rather
than added as another kind there: that fixture asserts every kind it contains is exercised, and one
file per specification section is what keeps that assertion meaningful instead of a place to append.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import hashlib
import json


def lp(b: bytes) -> bytes:
    assert len(b) <= 0xFFFF
    return len(b).to_bytes(2, "big") + b


def utf8(s: str) -> bytes:
    return s.encode("utf-8")


def fill(byte: int, n: int = 32) -> bytes:
    return bytes([byte]) * n


# §12.2: LP("rdev-e2e/directory/v1") || LP(action) || challenge || root_id || operation_id
#        || H(payload)
#
# The payload is HASHED, not carried, so the signed statement is a FIXED SIZE whatever the bundle
# weighs — 161 bytes for `register`. The two cases below differ only in their payload and must
# encode to the same length; the fixture would be pointless if they did not.
def directory_request(action: str, challenge: bytes, root_id: bytes, operation_id: bytes,
                      payload: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/directory/v1")) + lp(utf8(action)) + challenge + root_id
            + operation_id + hashlib.sha256(payload).digest())


# `LP("rdev-e2e/directory-session/v1") || LP(code) || LP(token) || LP(label) || LP(device_id)`
#
# A CANONICAL ENCODING, because a JSON encoder's key order is not a contract and two
# implementations that disagree about it produce a signature neither can check.
def session_payload(code: str, token: str, label: str, device_id: str) -> bytes:
    return (lp(utf8("rdev-e2e/directory-session/v1"))
            + lp(utf8(code)) + lp(utf8(token)) + lp(utf8(label)) + lp(utf8(device_id)))


CHALLENGE = fill(0x66)
ROOT_ID = fill(0x77)
OPERATION = fill(0x44)
BUNDLE = bytes(range(40))

# **`device_id` IS EMPTY IN EVERY SIGNED PAYLOAD**, and that is not a placeholder. The Worker derives
# it from the verified chain rather than reading it from the request, so a publisher that filled it
# in would be signing over a field nobody consults — and the two would then be free to disagree.
SESSION = ("AbCd1234", "fa9c2f01-7a5b-4c33-9f6d-0b1e2d3c4a5b", "studio mac", "")
SESSION_EMPTY_LABEL = ("AbCd1234", "fa9c2f01-7a5b-4c33-9f6d-0b1e2d3c4a5b", "", "")

session_cases = []
for name, fields in (("session/labelled", SESSION), ("session/no-label", SESSION_EMPTY_LABEL)):
    payload = session_payload(*fields)
    session_cases.append({
        "name": name, "kind": "directory_session",
        "code": fields[0], "token": fields[1], "label": fields[2], "device_id": fields[3],
        "encoded": payload.hex(),
    })

cases = []
# Every action that uses this body, so neither implementation can quietly support a subset.
# `register` is §12.2's; the other three are rdev's session discovery, which replaced OAuth accounts
# (docs/superpowers/specs/2026-09-13-passkey-only-identity.md) and is authorised exactly the same
# way. A ROOT REVOCATION IS STILL NOT HERE: §12.2 says its WebAuthn signature authorises its own
# idempotent submission and needs no device authority, so it never uses this body.
for action, name, payload in (
    ("register", "register/with-bundle", BUNDLE),
    ("register", "register/empty-payload", b""),
    ("publish", "publish/session", session_payload(*SESSION)),
    ("unpublish", "unpublish/by-code", utf8(SESSION[0])),
    # `list` signs an EMPTY payload: there is nothing to describe, and the one-use challenge is what
    # makes the request fresh.
    ("list", "list/empty-payload", b""),
    # `subscribe` is `list`'s authorisation for a STREAM (docs/superpowers/specs/
    # 2026-09-24-live-device-list-design.md). Same empty payload, different action — the action is
    # the only thing that stops a `list` signature being replayed as a subscription.
    ("subscribe", "subscribe/empty-payload", b""),
):
    encoded = directory_request(action, CHALLENGE, ROOT_ID, OPERATION, payload)
    cases.append({
        "name": name, "kind": "directory_request", "action": action,
        "challenge": CHALLENGE.hex(), "root_id": ROOT_ID.hex(),
        "operation_id": OPERATION.hex(), "payload": payload.hex(),
        "payload_hash": hashlib.sha256(payload).digest().hex(),
        "encoded": encoded.hex(),
    })

# The body is a fixed size FOR ONE ACTION whatever the payload weighs — 161 bytes for `register` —
# which is the whole reason it carries a hash. Across actions it varies only by the action's own
# name, so the two `register` cases are what this assertion is about.
registers = [c for c in cases if c["action"] == "register"]
assert len({len(bytes.fromhex(c["encoded"])) for c in registers}) == 1, \
    "the body must not vary with the payload; that is the whole reason it carries a hash"
assert len(bytes.fromhex(registers[0]["encoded"])) == 161
assert {c["action"] for c in cases} == {"register", "publish", "unpublish", "list", "subscribe"}
# **THE NEGATIVE THIS VECTOR EXISTS FOR:** identical inputs, different action, different bytes —
# so a signature made for `list` can never verify as `subscribe`.
_list = next(c for c in cases if c["action"] == "list")
_sub = next(c for c in cases if c["action"] == "subscribe")
assert _list["encoded"] != _sub["encoded"]
cases += session_cases

doc = {
    "_comment": [
        "Cross-implementation vectors for the §12.2 directory request body.",
        "GENERATED BY A THIRD IMPLEMENTATION (stdlib Python) so Swift and TypeScript each agree with",
        "something neither wrote.",
        "",
        "body = LP('rdev-e2e/directory/v1') || LP(action) || challenge || root_id || operation_id",
        "       || H(payload)",
        "",
        "FIVE actions use it: §12.2's `register`, plus `publish`/`unpublish`/`list`/`subscribe` — rdev's signed",
        "session discovery, which replaced OAuth accounts. A ROOT REVOCATION IS NOT AMONG THEM:",
        "§12.2 says its WebAuthn signature authorizes its own idempotent submission and needs no",
        "device authority, so it never uses this body.",
        "The challenge is 32 bytes, one-use, and valid for at most 120 seconds.",
        "",
        "`directory_session` cases are the payload `publish` signs over:",
        "  LP('rdev-e2e/directory-session/v1') || LP(code) || LP(token) || LP(label) || LP(device_id)",
        "",
        "Regenerate with scripts/gen_e2e_directory_fixture.py; never edit a value by hand."
    ],
    "challenge_length": 32,
    "challenge_max_age_seconds": 120,
    "publish_deadline_seconds": 5,
    "revoke_deadline_seconds": 5,
    "rejected_wording": "Publication rejected; listing not confirmed. Action required.",
    "cases": cases,
}
print(json.dumps(doc, indent=1))
