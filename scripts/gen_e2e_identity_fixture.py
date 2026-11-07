#!/usr/bin/env python3
"""Regenerate protocol/fixtures/e2e-identity.json — the §10 identity encodings (root, device, grant,
grant id, revocation) of the E2E protocol specification.

    python3 scripts/gen_e2e_identity_fixture.py > protocol/fixtures/e2e-identity.json

A THIRD IMPLEMENTATION, like the pairing-seed and wire fixtures beside it: the Swift and TypeScript
encoders assert against what this produces, so each agrees with something neither wrote. These bytes
are what signatures are computed over, so a layout disagreement is a signature that verifies against
the wrong statement — the quietest failure in the whole protocol.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import hashlib
import json

def lp(b: bytes) -> bytes:
    assert len(b) <= 0xFFFF
    return len(b).to_bytes(2, "big") + b

def u8(n: int) -> bytes:
    return bytes([n])

def h(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()

def utf8(s: str) -> bytes:
    return s.encode("utf-8")

# §10.1
def root(rp_id: str, credential_id: bytes, root_public_key: bytes) -> bytes:
    assert len(root_public_key) == 65, "an uncompressed SEC1 P-256 point is 65 bytes (§7)"
    return lp(utf8("rdev-e2e/root/v1")) + lp(utf8(rp_id)) + lp(credential_id) + root_public_key

# §10.2
def device(root_id: bytes, signing_public_key: bytes, noise_public_key: bytes) -> bytes:
    return lp(utf8("rdev-e2e/device/v1")) + root_id + signing_public_key + noise_public_key

# §10.3
def binding_local(randomness: bytes) -> bytes:
    return u8(0) + randomness

def binding_remote(handshake_hash: bytes, responder_device_id: bytes) -> bytes:
    return u8(1) + handshake_hash + responder_device_id

def grant(root_id: bytes, operation_id: bytes, issuer_kind: int, issuer_id: bytes,
          device_bytes: bytes, capabilities: int, binding: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/grant/v2")) + root_id + operation_id
            + u8(issuer_kind) + issuer_id + lp(device_bytes) + u8(capabilities) + lp(binding))

def grant_id(grant_bytes: bytes) -> bytes:
    return h(lp(utf8("rdev-e2e/grant-id/v1")) + grant_bytes)

# §10.4's grant commitment — the bytes a ROOT PASSKEY signs. It names NO root: a browser signing in
# has not yet learned which credential will answer, so a challenge containing root_id could not exist
# until a first ceremony had produced it. The field order mirrors grant()'s with the root-dependent
# fields elided; LP(device) is deliberately not used, because a device descriptor names its root.
def grant_commitment(operation_id: bytes, issuer_kind: int, signing_public_key: bytes,
                     noise_public_key: bytes, capabilities: int, binding: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/grant-commit/v1")) + operation_id + u8(issuer_kind)
            + signing_public_key + noise_public_key + u8(capabilities) + lp(binding))

# §10.5
def revocation(root_id: bytes, operation_id: bytes, target_device_id: bytes) -> bytes:
    return lp(utf8("rdev-e2e/revoke/v1")) + root_id + operation_id + target_device_id

def fill(byte: int, n: int = 32) -> bytes:
    return bytes([byte]) * n

RP = "rdev.example"
CRED = bytes(range(16))
ROOT_PUB = b"\x04" + bytes(range(64))          # uncompressed SEC1 P-256
SIGNING = fill(0xA1)
NOISE = fill(0xA2)
OPERATION = fill(0xB0)
RANDOM = fill(0xC0)
HASH = fill(0xD0)
RESPONDER = fill(0xE0)

root_bytes = root(RP, CRED, ROOT_PUB)
root_id = h(root_bytes)
device_bytes = device(root_id, SIGNING, NOISE)
device_id = h(device_bytes)

cases = [
    {"name": "root", "kind": "root", "rp_id": RP, "credential_id": CRED.hex(),
     "root_public_key": ROOT_PUB.hex(), "encoded": root_bytes.hex(), "id": root_id.hex()},
    {"name": "device", "kind": "device", "root_id": root_id.hex(),
     "signing_public_key": SIGNING.hex(), "noise_public_key": NOISE.hex(),
     "encoded": device_bytes.hex(), "id": device_id.hex()},
]

# A direct grant (root-issued, capabilities 7) bound to a LOCAL passkey ceremony, and a code grant
# (device-issued, capabilities 3 and 1) bound to a REMOTE enrollment. Both binding shapes and all
# four accepted capability values appear.
#
# The fourth is ADOPT-BY-CODE's own shape: root-issued at capability 2 with a REMOTE binding. That
# combination exists nowhere else — §12.1's direct grant is local because a passkey ceremony has no
# transcript to name, and a code grant is device-issued — so without this case the one grant the
# product now mints inside a live handshake would have no vector at all.
direct = grant(root_id, OPERATION, 0, root_id, device_bytes, 7, binding_local(RANDOM))
cases.append({"name": "grant/direct-root-7", "kind": "grant", "root_id": root_id.hex(),
              "operation_id": OPERATION.hex(), "issuer_kind": 0, "issuer_id": root_id.hex(),
              "device": device_bytes.hex(), "capabilities": 7,
              "binding": binding_local(RANDOM).hex(), "encoded": direct.hex(),
              "id": grant_id(direct).hex()})

adopt = grant(root_id, OPERATION, 0, root_id, device_bytes, 2, binding_remote(HASH, RESPONDER))
cases.append({"name": "grant/direct-root-2-remote", "kind": "grant", "root_id": root_id.hex(),
              "operation_id": OPERATION.hex(), "issuer_kind": 0, "issuer_id": root_id.hex(),
              "device": device_bytes.hex(), "capabilities": 2,
              "binding": binding_remote(HASH, RESPONDER).hex(), "encoded": adopt.hex(),
              "id": grant_id(adopt).hex()})

parent = grant_id(direct)
for caps in (3, 1):
    leaf = grant(root_id, OPERATION, 1, parent, device_bytes, caps,
                 binding_remote(HASH, RESPONDER))
    cases.append({"name": f"grant/leaf-device-{caps}", "kind": "grant", "root_id": root_id.hex(),
                  "operation_id": OPERATION.hex(), "issuer_kind": 1, "issuer_id": parent.hex(),
                  "device": device_bytes.hex(), "capabilities": caps,
                  "binding": binding_remote(HASH, RESPONDER).hex(), "encoded": leaf.hex(),
                  "id": grant_id(leaf).hex()})

# §10.4 grant commitments. Three shapes, because the LP() around the binding is the only thing
# keeping the encoding unambiguous and a fixture that only used the 33-byte local form would not
# show that.
for name, op, kind, sign, noise, caps, bind in [
    ("commitment-enroll", OPERATION, 0, SIGNING, NOISE, 7, binding_local(RANDOM)),
    ("commitment-connect-only", fill(0xB1), 0, fill(0xA3), fill(0xA4), 1, binding_local(fill(0xC1))),
    ("commitment-remote-binding", fill(0xB2), 0, fill(0xA5), fill(0xA6), 3,
     binding_remote(HASH, RESPONDER)),
    # What the root passkey actually signs when a Mac is adopted by code.
    ("commitment-host-only", fill(0xB3), 0, fill(0xA7), fill(0xA8), 2,
     binding_remote(HASH, RESPONDER)),
]:
    cases.append({"name": name, "kind": "grant-commitment",
                  "operation_id": op.hex(), "issuer_kind": kind,
                  "signing_public_key": sign.hex(), "noise_public_key": noise.hex(),
                  "capabilities": caps, "binding": bind.hex(),
                  "encoded": grant_commitment(op, kind, sign, noise, caps, bind).hex()})

rev = revocation(root_id, OPERATION, device_id)
cases.append({"name": "revocation", "kind": "revocation", "root_id": root_id.hex(),
              "operation_id": OPERATION.hex(), "target_device_id": device_id.hex(),
              "encoded": rev.hex()})

doc = {
    "_comment": [
        "Cross-implementation vectors for the §10 identity encodings of the E2E protocol spec.",
        "GENERATED BY A THIRD IMPLEMENTATION (stdlib Python) so Swift and TypeScript each agree with",
        "something neither wrote. THESE BYTES ARE WHAT SIGNATURES COVER: a layout disagreement is a",
        "signature that verifies against the wrong statement, which is the quietest failure in the",
        "whole protocol.",
        "",
        "LP(x) = uint16be(len(x)) || x; H = SHA-256. The root public key is a 65-byte uncompressed",
        "SEC1 P-256 point; every other fixed field is 32 bytes. capabilities: 1 connect, 2 host,",
        "4 enroll — only {1, 2, 3, 7} are accepted. issuer_kind: 0 root, 1 device.",
        "",
        "Regenerate with scripts/gen_e2e_identity_fixture.py; never edit a value by hand."
    ],
    "cases": cases,
}
print(json.dumps(doc, indent=1))
