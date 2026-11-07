#!/usr/bin/env python3
"""Regenerate protocol/fixtures/webauthn.json — §10.1's registration ceremony, as bytes.

    python3 scripts/gen_webauthn_fixture.py > protocol/fixtures/webauthn.json

A THIRD IMPLEMENTATION of the CBOR and COSE encodings an authenticator produces, so the TypeScript
parser is checked against something that is not itself. **These are SYNTHETIC, not captured from a
real authenticator** — that is stated here rather than implied, because it is the one thing these
vectors cannot establish. They pin the parsing; they do not prove any particular device produces
bytes of this shape.

The registration key is the SAME P-256 key the certificate fixture's root uses, so the public key
extracted from this attestation object is byte-for-byte the one that verifies those assertions —
which closes the loop from "a credential was created" to "an assertion by it verifies".

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import hashlib
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_sigs import p256_public_key, self_test  # noqa: E402


# ------------------------------------------------------------------------------ CBOR encode

def cbor_head(major: int, arg: int) -> bytes:
    if arg < 24:
        return bytes([(major << 5) | arg])
    if arg < 0x100:
        return bytes([(major << 5) | 24, arg])
    if arg < 0x10000:
        return bytes([(major << 5) | 25]) + arg.to_bytes(2, "big")
    return bytes([(major << 5) | 26]) + arg.to_bytes(4, "big")


def cbor(value) -> bytes:
    if isinstance(value, bool):
        raise TypeError("no simple values in this subset")
    if isinstance(value, int):
        return cbor_head(0, value) if value >= 0 else cbor_head(1, -1 - value)
    if isinstance(value, bytes):
        return cbor_head(2, len(value)) + value
    if isinstance(value, str):
        b = value.encode("utf-8")
        return cbor_head(3, len(b)) + b
    if isinstance(value, list):
        return cbor_head(4, len(value)) + b"".join(cbor(v) for v in value)
    if isinstance(value, dict):
        # Insertion order, as an authenticator emits it; this subset does not canonicalise.
        return cbor_head(5, len(value)) + b"".join(cbor(k) + cbor(v) for k, v in value.items())
    raise TypeError(type(value))


# ------------------------------------------------------------------- the ceremony's bytes

RP = "rdev.example"
CRED = bytes.fromhex("a10f7c2b9d4e6081a3c5e7f90b1d2f43")
AAGUID = bytes(16)
ROOT_D = 0x51EC4D6B4C81A9F0A7B32D6E1F5C8093A4B7D2E61C9F30584A6B8C7D2E1F0345
ROOT_PUB = p256_public_key(ROOT_D)          # 0x04 || X || Y
X, Y = ROOT_PUB[1:33], ROOT_PUB[33:65]

UP, UV, BE, BS, AT = 0x01, 0x04, 0x08, 0x10, 0x40


def cose_key(kty=2, alg=-7, crv=1, x=X, y=Y) -> bytes:
    return cbor({1: kty, 3: alg, -1: crv, -2: x, -3: y})


def auth_data(flags: int, cred_id: bytes = CRED, cose: bytes = None, sign_count: int = 0) -> bytes:
    head = hashlib.sha256(RP.encode()).digest() + bytes([flags]) + sign_count.to_bytes(4, "big")
    if not flags & AT:
        return head
    return head + AAGUID + len(cred_id).to_bytes(2, "big") + cred_id + (cose or cose_key())


def attestation(authdata: bytes) -> bytes:
    # fmt "none" with an empty statement: §10.1 asks for a credential, not a claim about the
    # hardware holding it, so nothing here ever inspects attStmt.
    return cbor({"fmt": "none", "attStmt": {}, "authData": authdata})


GOOD = attestation(auth_data(UP | UV | BE | BS | AT))

cases = [
    {"name": "registration/synced-passkey", "expect": "ok",
     "attestation_object": GOOD.hex(), "credential_id": CRED.hex(),
     "public_key": ROOT_PUB.hex(), "flags": UP | UV | BE | BS | AT},
    {"name": "registration/platform-no-backup", "expect": "ok",
     "attestation_object": attestation(auth_data(UP | UV | AT)).hex(),
     "credential_id": CRED.hex(), "public_key": ROOT_PUB.hex(), "flags": UP | UV | AT},
    # UV CLEAR but otherwise well formed: the PARSER accepts it (nothing about it is malformed) and
    # the CEREMONY must refuse it. §10.4 requires user verification, and `required` at request time
    # is only a request — an authenticator is free to ignore it, and the flag is the part that can
    # be checked afterwards.
    {"name": "registration/no-user-verification", "expect": "ok",
     "attestation_object": attestation(auth_data(UP | AT)).hex(),
     "credential_id": CRED.hex(), "public_key": ROOT_PUB.hex(), "flags": UP | AT},
    # A long credential id crosses CBOR's one-byte length boundary and the two-byte credIdLen field.
    {"name": "registration/long-credential-id", "expect": "ok",
     "attestation_object": attestation(auth_data(UP | UV | AT, cred_id=bytes(range(200)))).hex(),
     "credential_id": bytes(range(200)).hex(), "public_key": ROOT_PUB.hex(),
     "flags": UP | UV | AT},
]

# --- refusals. Each is a well-formed CBOR document that must not yield a key. ------------------
refusals = [
    ("no-attested-credential-data", attestation(auth_data(UP | UV))),
    # AT CLEAR BUT LONG ENOUGH TO LOOK PARSEABLE. The short case above is caught by a length check
    # whatever the flags say, so it cannot tell whether the flag is read at all — and a mutation
    # deleting the AT check passed the whole suite until this existed. Real authenticator data can
    # carry extension CBOR after the 37-byte header; a parser ignoring AT would read that as an
    # aaguid, a credential-id length, and then a key.
    ("attested-flag-clear-with-trailing-data",
     attestation(auth_data(UP | UV) + AAGUID + (16).to_bytes(2, "big") + bytes(16) + cose_key())),
    ("cose-wrong-kty", attestation(auth_data(UP | UV | AT, cose=cose_key(kty=1)))),
    ("cose-wrong-alg", attestation(auth_data(UP | UV | AT, cose=cose_key(alg=-257)))),
    ("cose-wrong-curve", attestation(auth_data(UP | UV | AT, cose=cose_key(crv=2)))),
    ("cose-short-x", attestation(auth_data(UP | UV | AT, cose=cose_key(x=X[:31])))),
    ("cose-short-y", attestation(auth_data(UP | UV | AT, cose=cose_key(y=Y[:31])))),
    ("truncated-authdata", attestation(auth_data(UP | UV | AT)[:50])),
    ("truncated-document", GOOD[:-5]),
    ("not-a-map", cbor([1, 2, 3])),
    ("missing-authdata", cbor({"fmt": "none", "attStmt": {}})),
    # A CBOR TAG (major 6). Nothing in WebAuthn uses one, and a decoder that skipped it would be
    # interpreting a structure it was never asked to understand.
    ("cbor-tag", bytes([0xC0]) + GOOD),
    # An indefinite-length map, which this subset refuses rather than stream.
    ("cbor-indefinite", bytes([0xBF]) + cbor("fmt") + cbor("none") + bytes([0xFF])),
]
for name, blob in refusals:
    cases.append({"name": f"refuse/{name}", "expect": "refuse",
                  "attestation_object": blob.hex()})

# A duplicate CBOR map key: two decoders can disagree about which copy wins, so the bytes are
# ambiguous and refused — the same rule §10.4 applies to clientDataJSON.
dup = cbor_head(5, 4) + cbor("fmt") + cbor("none") + cbor("attStmt") + cbor({}) \
    + cbor("authData") + cbor(auth_data(UP | UV | AT)) \
    + cbor("authData") + cbor(auth_data(UP | UV | AT, cred_id=b"\xff" * 16))
cases.append({"name": "refuse/duplicate-map-key", "expect": "refuse",
              "attestation_object": dup.hex()})

# §10.1's bootstrap challenge: H(LP("rdev-e2e/root-check/v1") || root_id || random(32)).
ROOT_CHECK = []
for name, root_id, random in (
    ("zeros", bytes(32), bytes(32)),
    ("counting", bytes(range(32)), bytes(range(32, 64))),
):
    label = b"rdev-e2e/root-check/v1"
    body = len(label).to_bytes(2, "big") + label + root_id + random
    ROOT_CHECK.append({"name": name, "root_id": root_id.hex(), "random": random.hex(),
                       "challenge": hashlib.sha256(body).digest().hex()})

doc = {
    "_comment": [
        "§10.1's registration ceremony, as bytes: CBOR attestation objects carrying COSE ES256 keys.",
        "GENERATED BY A THIRD IMPLEMENTATION (stdlib Python; scripts/gen_webauthn_fixture.py).",
        "",
        "**THESE ARE SYNTHETIC, NOT CAPTURED FROM A REAL AUTHENTICATOR.** They pin the PARSING; they",
        "do not establish that any particular device emits bytes of this shape. Verifying that needs",
        "a passkey and a person, and no fixture can stand in for it.",
        "",
        "The registration key is the SAME P-256 key the certificate fixture's root uses, so the",
        "public key extracted here is byte-for-byte the one that verifies those assertions — which",
        "closes the loop from 'a credential was created' to 'an assertion by it verifies'.",
        "",
        "flags: 0x01 UP, 0x04 UV, 0x08 BE, 0x10 BS, 0x40 AT (attested credential data present).",
        "",
        "Regenerate with scripts/gen_webauthn_fixture.py; never edit a value by hand."
    ],
    "rp_id": RP,
    "cases": cases,
    "root_check": ROOT_CHECK,
}

if __name__ == "__main__":
    self_test()
    print(json.dumps(doc, indent=1))
