#!/usr/bin/env python3
"""Regenerate protocol/fixtures/e2e-session.json — the identities and bundles the §11 session state
machine is driven with.

    python3 scripts/gen_e2e_session_fixture.py > protocol/fixtures/e2e-session.json

Unlike the fixtures beside it this one is not a table of expected ENCODINGS: the session machine
produces messages at runtime and signs some of them, so what a third implementation can usefully
supply is the WORLD — a root, four devices with real keys, and correctly signed grant chains for
each. Both suites then drive their own machines through a complete handshake against it and against
each other's expectations.

That is still a third implementation of everything that matters here: the chains are signed by
`scripts/e2e_sigs.py`, pinned to RFC 8032 §7.1 and RFC 6979 A.2.5 before a byte is emitted, and a
suite that built its own identities would be checking its encoder against its own encoder.

**THE SIGNING PRIVATE KEYS ARE IN THIS FILE ON PURPOSE.** They are fixture keys for a test root that
authorises nothing. The machines have to SIGN a device proof, so a fixture that withheld them could
only exercise verification.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import hashlib
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_encodings import grant_commitment  # noqa: E402
from e2e_sigs import (  # noqa: E402
    der_signature, ed25519_public_key, ed25519_sign, p256_public_key, p256_sign, self_test,
    x25519_public_key,
)


def lp(b: bytes) -> bytes:
    assert len(b) <= 0xFFFF
    return len(b).to_bytes(2, "big") + b


def u8(n: int) -> bytes:
    return bytes([n])


def h(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def utf8(s: str) -> bytes:
    return s.encode("utf-8")


def b64u(b: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


RP = "rdev.example"
ORIGIN = "https://rdev.example"
CRED = bytes.fromhex("a10f7c2b9d4e6081a3c5e7f90b1d2f43")
ROOT_D = 0x51EC4D6B4C81A9F0A7B32D6E1F5C8093A4B7D2E61C9F30584A6B8C7D2E1F0345
ROOT_PUB = p256_public_key(ROOT_D)

ROOT = lp(utf8("rdev-e2e/root/v1")) + lp(utf8(RP)) + lp(CRED) + ROOT_PUB
ROOT_ID = h(ROOT)


def device(signing_pub: bytes, noise_pub: bytes) -> bytes:
    return lp(utf8("rdev-e2e/device/v1")) + ROOT_ID + signing_pub + noise_pub


def grant(operation_id: bytes, issuer_kind: int, issuer_id: bytes, device_bytes: bytes,
          capabilities: int, binding: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/grant/v2")) + ROOT_ID + operation_id
            + u8(issuer_kind) + issuer_id + lp(device_bytes) + u8(capabilities) + lp(binding))


def grant_id(g: bytes) -> bytes:
    return h(lp(utf8("rdev-e2e/grant-id/v1")) + g)


def root_certificate(g: bytes) -> bytes:
    """A WebAuthn assertion over `challenge = H(grant_commitment)`, signed with the fixture root
    key. §10.4's commitment is a projection of the grant that names no root — see
    `scripts/e2e_encodings.py` for why."""
    cd = utf8('{"type":"webauthn.get","challenge":"%s","origin":"%s","crossOrigin":false}'
              % (b64u(h(grant_commitment(g))), ORIGIN))
    ad = h(utf8(RP)) + u8(0x01 | 0x04 | 0x08 | 0x10) + (0).to_bytes(4, "big")
    r, s = p256_sign(ROOT_D, h(ad + h(cd)))
    evidence = lp(CRED) + lp(cd) + lp(ad) + lp(der_signature(r, s))
    return lp(g) + lp(evidence)


def device_certificate(g: bytes, issuer_signing_secret: bytes) -> bytes:
    return lp(g) + lp(ed25519_sign(issuer_signing_secret, g))


def bundle(certificates: list) -> bytes:
    assert 1 <= len(certificates) <= 2
    out = lp(ROOT) + u8(len(certificates))
    for c in certificates:
        out += lp(c)
    return out


def rendezvous(seed: bytes):
    import hmac
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    prk = hmac.new(b"rdev/rendezvous/v7", seed, hashlib.sha256).digest()

    def expand(info, length):
        out, block, counter = b"", b"", 1
        while len(out) < length:
            block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
            out += block
            counter += 1
        return out[:length]

    t = bytearray(expand(b"token", 16))
    t[6] = (t[6] & 0x0F) | 0x40
    t[8] = (t[8] & 0x3F) | 0x80
    hx = t.hex()
    return ("".join(alphabet[b % 64] for b in expand(b"code", 8)),
            f"{hx[:8]}-{hx[8:12]}-{hx[12:16]}-{hx[16:20]}-{hx[20:]}")


# Four devices. H is the Host and also the pairing Issuer (capabilities 7 is root-issued and carries
# `enroll`, which is exactly what §11.1 requires of a `pair` responder). C is code-enrolled BY H, so
# its chain is two grants long. X is connect-only — the arm that proves a responder without `host`
# is refused for `auth`. N has keys and NO grant at all: the newcomer in a `pair`.
#
# Y IS THE INTERESTING ONE: it reuses C's NOISE key with a DIFFERENT signing key, so it is a
# different device that nevertheless satisfies any check phrased as "the leaf's DH key equals the
# static this handshake authenticated". A device descriptor is `label || root_id || signing_key ||
# noise_key`, so nothing stops an attacker who learns a public DH key from enrolling an identity
# around it — and Y carries capabilities 7 against C's 3, which is what makes the confusion worth
# something. It exists because a mutation survived without it.
# **THE NOISE KEYS ARE REAL X25519 KEYS**, derived from the fixed private keys beside them, not
# filler bytes. §17.3 requires the signalling tests to "use real Noise on both ends", which means the
# static key a handshake authenticates has to be the one in the device descriptor — and a descriptor
# holding 32 bytes of 0x2A can never be that. The private keys ship for the same reason the signing
# ones do: the end-to-end test has to complete a handshake, not merely verify one.
DEVICES = {}
for name, sk_byte, noise_byte in (("H", 0x11, 0x2A), ("C", 0x33, 0x4B),
                                  ("X", 0x55, 0x6C), ("N", 0x77, 0x8D),
                                  ("Y", 0x55, 0x4B)):
    sk = bytes([sk_byte]) * 32
    pk = ed25519_public_key(sk)
    noise_private = bytes([noise_byte]) * 32
    noise = x25519_public_key(noise_private)
    desc = device(pk, noise)
    DEVICES[name] = {
        "name": name,
        "signing_private_key": sk.hex(),
        "signing_public_key": pk.hex(),
        "noise_private_key": noise_private.hex(),
        "noise_public_key": noise.hex(),
        "descriptor": desc.hex(),
        "device_id": h(desc).hex(),
    }

OP_H = bytes.fromhex("b0" * 32)
OP_C = bytes.fromhex("b1" * 32)
OP_X = bytes.fromhex("b2" * 32)
ZERO = bytes(32)

H_DESC = bytes.fromhex(DEVICES["H"]["descriptor"])
C_DESC = bytes.fromhex(DEVICES["C"]["descriptor"])
X_DESC = bytes.fromhex(DEVICES["X"]["descriptor"])
H_SK = bytes.fromhex(DEVICES["H"]["signing_private_key"])

GRANT_H = grant(OP_H, 0, ROOT_ID, H_DESC, 7, u8(0) + bytes.fromhex("c0" * 32))
CERT_H = root_certificate(GRANT_H)
DEVICES["H"]["bundle"] = bundle([CERT_H]).hex()

GRANT_C = grant(OP_C, 1, grant_id(GRANT_H), C_DESC, 3,
                u8(1) + bytes.fromhex("d0" * 32) + h(H_DESC))
DEVICES["C"]["bundle"] = bundle([CERT_H, device_certificate(GRANT_C, H_SK)]).hex()

GRANT_X = grant(OP_X, 0, ROOT_ID, X_DESC, 1, u8(0) + bytes.fromhex("c1" * 32))
DEVICES["X"]["bundle"] = bundle([root_certificate(GRANT_X)]).hex()

DEVICES["N"]["bundle"] = ""          # a newcomer has no chain; that is what `pair` is for

# **WHAT A `pair` RESPONDER ISSUES TO N, in adopt-by-code.** Root-issued at capability 2 with a
# REMOTE binding: the shape a browser holding the passkey mints for a Mac that showed its code, and
# one that exists nowhere else — §12.1's direct grant is LOCAL, because a passkey ceremony has no
# transcript to name, and an ordinary code grant is DEVICE-issued.
#
# The binding names H as the responder because H is the Issuer in that flow. Its `h` is filler: a
# handshake hash is only known at run time, and the side that CHECKS it against a live transcript is
# the far one (§10.4). A responder gate cannot meaningfully check its own binding.
N_DESC = bytes.fromhex(DEVICES["N"]["descriptor"])
GRANT_N_ADOPT = grant(bytes.fromhex("b4" * 32), 0, ROOT_ID, N_DESC, 2,
                      u8(1) + bytes.fromhex("d2" * 32) + h(H_DESC))
ADOPTION = {
    "comment": "root-issued capability 2 over N, remote binding — what adopt-by-code mints",
    "bundle_for_N": bundle([root_certificate(GRANT_N_ADOPT)]).hex(),
    "capabilities": 2,
}

# Y's own root-issued grant, capabilities 7, genuinely signed. Everything about this bundle verifies;
# it simply does not describe C, which is the only thing standing between it and an accepted chain.
Y_DESC = bytes.fromhex(DEVICES["Y"]["descriptor"])
GRANT_Y = grant(bytes.fromhex("b3" * 32), 0, ROOT_ID, Y_DESC, 7, u8(0) + bytes.fromhex("c2" * 32))
DEVICES["Y"]["bundle"] = bundle([root_certificate(GRANT_Y)]).hex()
assert DEVICES["Y"]["noise_public_key"] == DEVICES["C"]["noise_public_key"]
assert DEVICES["Y"]["signing_public_key"] != DEVICES["C"]["signing_public_key"]
assert DEVICES["Y"]["device_id"] != DEVICES["C"]["device_id"]

# §10.5 revocations, SIGNED BY THE ROOT PASSKEY, so a test can present one without needing a P-256
# signer of its own. `challenge = H(revocation)` — the same WebAuthn shape a grant uses, which is
# why §12.2 says the assertion "itself authorizes an idempotent submission and needs no device
# authority": nothing but the root could have produced it.
def revocation_for(target_device_id: bytes, operation_id: bytes):
    body = (lp(utf8("rdev-e2e/revoke/v1")) + ROOT_ID + operation_id + target_device_id)
    cd = utf8('{"type":"webauthn.get","challenge":"%s","origin":"%s","crossOrigin":false}'
              % (b64u(h(body)), ORIGIN))
    ad = h(utf8(RP)) + u8(0x01 | 0x04) + (0).to_bytes(4, "big")
    r, s_ = p256_sign(ROOT_D, h(ad + h(cd)))
    evidence = lp(CRED) + lp(cd) + lp(ad) + lp(der_signature(r, s_))
    return {"revocation": body.hex(), "evidence": evidence.hex(),
            "target_device_id": target_device_id.hex(), "root": ROOT.hex()}


REVOCATIONS = {
    name: revocation_for(bytes.fromhex(DEVICES[name]["device_id"]),
                         bytes.fromhex(f"{0xa0 + i:02x}" * 32))
    for i, name in enumerate(("H", "C", "X"))
}

# A SIGNED DEVICE LABEL — an addition to the specification rather than one of its sections, closing
# the gap §10.1's residual names: a directory-supplied name is one "the same adversary chose". Signed
# by a device holding `enroll`, so a compromised leaf cannot name itself after the machine a user
# trusts. H carries capabilities 7 and may sign; C carries 3 and may not.
def device_label(root_id: bytes, device_id: bytes, name: str) -> bytes:
    return (lp(utf8("rdev-e2e/device-label/v1")) + root_id + device_id + lp(utf8(name)))


LABELS = {}
for case, target, signer, name in (
    ("valid", "H", "H", "Isaac's MacBook"),
    ("signer-not-authorised", "C", "C", "Isaac's MacBook"),
):
    body = device_label(ROOT_ID, bytes.fromhex(DEVICES[target]["device_id"]), name)
    LABELS[case] = {
        "name": name,
        "target_device_id": DEVICES[target]["device_id"],
        "signer": signer,
        "body": body.hex(),
        "signature": ed25519_sign(bytes.fromhex(DEVICES[signer]["signing_private_key"]),
                                  body).hex(),
        "signer_bundle": DEVICES[signer]["bundle"],
    }

# A label naming a root this endpoint does not serve, signed correctly for the root it DOES name —
# so the only thing wrong with it is which identity it belongs to.
_other_root = h(b"a root this directory does not serve")
_body = device_label(_other_root, bytes.fromhex(DEVICES["H"]["device_id"]), "Isaac's MacBook")
LABELS["wrong-root"] = {
    "name": "Isaac's MacBook",
    "target_device_id": DEVICES["H"]["device_id"],
    "signer": "H",
    "body": _body.hex(),
    "signature": ed25519_sign(H_SK, _body).hex(),
    "signer_bundle": DEVICES["H"]["bundle"],
}

H_ROUTE = rendezvous(bytes.fromhex("e0" * 32))
X_ROUTE = rendezvous(bytes.fromhex("e1" * 32))

doc = {
    "_comment": [
        "The world the §11 session state machine is driven through: one root, four devices with real",
        "keys, and correctly signed grant chains. GENERATED BY A THIRD IMPLEMENTATION",
        "(scripts/gen_e2e_session_fixture.py), whose signature arithmetic is pinned to the published",
        "RFC 8032 §7.1 and RFC 6979 A.2.5 answers before it emits a byte.",
        "",
        "H  capabilities 7, root-issued  — the Host, and the Issuer a `pair` needs (`enroll`)",
        "C  capabilities 3, issued BY H  — a code-enrolled device; its chain is two grants long",
        "X  capabilities 1, root-issued  — connect-only, so it may NOT be an `auth` responder",
        "N  no grant at all              — the newcomer in a `pair`",
        "Y  capabilities 7, root-issued  — C's NOISE key with a DIFFERENT signing key: a distinct",
        "                                  identity that passes any 'the DH key matches' check",
        "",
        "`revocations` carries root-passkey-signed §10.5 revocations for H, C and X, so a test can",
        "present one without a P-256 signer of its own.",
        "",
        "`labels` carries SIGNED DEVICE LABELS — an addition to the specification, closing the gap",
        "§10.1's residual names: a directory-supplied name is one 'the same adversary chose'. Signed",
        "by a device holding `enroll` (H, capabilities 7); C carries 3 and its label must be refused.",
        "",
        "THE PRIVATE KEYS ARE HERE ON PURPOSE. The machines have to SIGN a device proof and the",
        "§17.3 end-to-end test has to COMPLETE a Noise handshake, so a fixture withholding them",
        "could only ever exercise verification. Noise keys are real X25519 points, not filler: the",
        "static a handshake authenticates must be the one in the device descriptor. They authorise",
        "nothing.",
        "",
        "Regenerate with scripts/gen_e2e_session_fixture.py; never edit a value by hand."
    ],
    "rp_id": RP,
    "allowed_origins": [ORIGIN],
    "root": ROOT.hex(),
    "root_id": ROOT_ID.hex(),
    "devices": DEVICES,
    "adoption": ADOPTION,
    "routes": {
        "H": {"rcode": H_ROUTE[0], "rtoken": H_ROUTE[1]},
        "X": {"rcode": X_ROUTE[0], "rtoken": X_ROUTE[1]},
    },
    "revocations": REVOCATIONS,
    "labels": LABELS,
    "operation_ids": {
        "zero": ZERO.hex(),
        "enrollment": bytes.fromhex("f0" * 32).hex(),
    },
    "handshake_hashes": {
        "a": bytes.fromhex("11" * 32).hex(),
        "b": bytes.fromhex("22" * 32).hex(),
    },
}

if __name__ == "__main__":
    self_test()
    print(json.dumps(doc, indent=1))
