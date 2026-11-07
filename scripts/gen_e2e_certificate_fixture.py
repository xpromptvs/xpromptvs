#!/usr/bin/env python3
"""Regenerate protocol/fixtures/e2e-certificate.json — the §10.4 evidence encodings of the E2E
protocol specification (assertion, certificate, bundle) AND end-to-end bundle-verification cases.

    python3 scripts/gen_e2e_certificate_fixture.py > protocol/fixtures/e2e-certificate.json

A THIRD IMPLEMENTATION, like the fixtures beside it. Signatures come from `scripts/e2e_sigs.py`,
whose own arithmetic is pinned to the published RFC 8032 §7.1 and RFC 6979 A.2.5 answers before a
byte is emitted here — so Swift's CryptoKit and TypeScript's @noble each verify something neither
produced, against a chain of reasoning that ends at an RFC rather than at this file.

**THE NEGATIVE CASES ARE THE POINT.** Each one mutates exactly ONE thing and RE-SIGNS, so it fails
for exactly one reason and names it. A negative case that also breaks the signature proves only
that the signature check works; it says nothing about the check it was written for.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import base64
import hashlib
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_encodings import grant_commitment  # noqa: E402
from e2e_sigs import (  # noqa: E402
    der_signature, ed25519_public_key, ed25519_sign, p256_public_key, p256_sign, self_test,
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
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


# ----------------------------------------------------------------- §10.1-§10.3 (as already landed)

def root(rp_id: str, credential_id: bytes, root_public_key: bytes) -> bytes:
    return lp(utf8("rdev-e2e/root/v1")) + lp(utf8(rp_id)) + lp(credential_id) + root_public_key


def device(root_id: bytes, signing_public_key: bytes, noise_public_key: bytes) -> bytes:
    return lp(utf8("rdev-e2e/device/v1")) + root_id + signing_public_key + noise_public_key


def grant(root_id: bytes, operation_id: bytes, issuer_kind: int, issuer_id: bytes,
          device_bytes: bytes, capabilities: int, binding: bytes) -> bytes:
    return (lp(utf8("rdev-e2e/grant/v2")) + root_id + operation_id
            + u8(issuer_kind) + issuer_id + lp(device_bytes) + u8(capabilities) + lp(binding))


def grant_v1(root_id: bytes, operation_id: bytes, issuer_kind: int, issuer_id: bytes,
             device_bytes: bytes, capabilities: int, binding: bytes) -> bytes:
    """A PRE-CHANGE grant, kept solely so one fixture can prove such a bundle is now refused."""
    return (lp(utf8("rdev-e2e/grant/v1")) + root_id + operation_id
            + u8(issuer_kind) + issuer_id + lp(device_bytes) + u8(capabilities) + lp(binding))



def grant_id(grant_bytes: bytes) -> bytes:
    return h(lp(utf8("rdev-e2e/grant-id/v1")) + grant_bytes)


# ------------------------------------------------------------------------------ §10.4 encodings

def assertion(credential_id: bytes, client_data_json: bytes, authenticator_data: bytes,
              signature: bytes) -> bytes:
    return lp(credential_id) + lp(client_data_json) + lp(authenticator_data) + lp(signature)


def certificate(grant_bytes: bytes, evidence: bytes) -> bytes:
    return lp(grant_bytes) + lp(evidence)


def bundle(root_bytes: bytes, certificates: list) -> bytes:
    assert 1 <= len(certificates) <= 2
    out = lp(root_bytes) + u8(len(certificates))
    for c in certificates:
        out += lp(c)
    return out


# ------------------------------------------------------------------------------ WebAuthn pieces

def client_data(challenge: bytes, origin: str, typ: str = "webauthn.get",
                cross_origin: bool = False, extra: str = "") -> bytes:
    """Built as BYTES, never json.dumps of a dict.

    §10.4: "Do not reserialize `clientDataJSON`." The signature is over these exact octets, so the
    fixture has to be able to express key order, spacing and duplicates that no serializer would
    emit — which is precisely what the duplicate-field case needs.
    """
    return utf8('{"type":"%s","challenge":"%s","origin":"%s","crossOrigin":%s%s}'
                % (typ, b64u(challenge), origin, "true" if cross_origin else "false", extra))


UP = 0x01
UV = 0x04
BE = 0x08
BS = 0x10


def authenticator_data(rp_id: str, flags: int, sign_count: int = 0) -> bytes:
    return h(utf8(rp_id)) + u8(flags) + sign_count.to_bytes(4, "big")


# --------------------------------------------------------------------------------- the identity

RP = "rdev.example"
ORIGIN = "https://rdev.example"
CRED = bytes.fromhex("a10f7c2b9d4e6081a3c5e7f90b1d2f43")

ROOT_D = 0x51EC4D6B4C81A9F0A7B32D6E1F5C8093A4B7D2E61C9F30584A6B8C7D2E1F0345
ROOT_PUB = p256_public_key(ROOT_D)

A_SIGN_SK = bytes.fromhex("11" * 32)
A_SIGN_PK = ed25519_public_key(A_SIGN_SK)
A_NOISE_PK = bytes.fromhex("2a" * 32)

B_SIGN_SK = bytes.fromhex("33" * 32)
B_SIGN_PK = ed25519_public_key(B_SIGN_SK)
B_NOISE_PK = bytes.fromhex("4b" * 32)

# A key that belongs to no device in any chain below — the "signed by the wrong key" arm.
X_SIGN_SK = bytes.fromhex("55" * 32)

ROOT = root(RP, CRED, ROOT_PUB)
ROOT_ID = h(ROOT)

DEV_A = device(ROOT_ID, A_SIGN_PK, A_NOISE_PK)
DEV_B = device(ROOT_ID, B_SIGN_PK, B_NOISE_PK)
DEV_A_ID = h(DEV_A)
DEV_B_ID = h(DEV_B)

OP_A = bytes.fromhex("b0" * 32)
OP_B = bytes.fromhex("b1" * 32)
LOCAL_RANDOM = bytes.fromhex("c0" * 32)
REMOTE_H = bytes.fromhex("d0" * 32)

GRANT_A = grant(ROOT_ID, OP_A, 0, ROOT_ID, DEV_A, 7, u8(0) + LOCAL_RANDOM)
GRANT_A_ID = grant_id(GRANT_A)
# B is code-enrolled BY A: issuer_kind 1, issuer_id is A's exact grant id, remote binding naming
# the responder (A) and the live Noise hash. Capabilities 3 — §10.3 forbids `enroll` on a leaf.
GRANT_B = grant(ROOT_ID, OP_B, 1, GRANT_A_ID, DEV_B, 3, u8(1) + REMOTE_H + DEV_A_ID)


def root_evidence(grant_bytes: bytes, *, origin: str = ORIGIN, rp_id: str = RP,
                  flags: int = UP | UV | BE | BS, typ: str = "webauthn.get",
                  cross_origin: bool = False, extra: str = "",
                  credential_id: bytes = CRED, challenge: bytes = None,
                  low_s: bool = True, force_high_s: bool = False,
                  corrupt_signature: bool = False) -> bytes:
    """A WebAuthn assertion over `challenge = H(grant_commitment)`, signed for real after every
    mutation. The commitment is DERIVED from the grant here, so every existing call site keeps
    working and none of them can accidentally sign a different projection than it built."""
    cd = client_data(challenge if challenge is not None else h(grant_commitment(grant_bytes)),
                     origin, typ, cross_origin, extra)
    ad = authenticator_data(rp_id, flags)
    r, s = p256_sign(ROOT_D, h(ad + h(cd)), low_s=low_s, force_high_s=force_high_s)
    sig = der_signature(r, s)
    if corrupt_signature:
        sig = sig[:-1] + bytes([sig[-1] ^ 0x01])
    return assertion(credential_id, cd, ad, sig)


_N_HALF = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551 // 2


def assertion_signature_s(encoded: bytes) -> int:
    """Read `s` back out of an encoded assertion's DER signature.

    Deliberately re-parses the FINISHED BYTES rather than trusting the value that went in: the
    point of the high-S vector is a property of what the fixture actually ships.
    """
    i = 0
    fields = []
    for _ in range(4):
        n = int.from_bytes(encoded[i:i + 2], "big")
        i += 2
        fields.append(encoded[i:i + n])
        i += n
    der = fields[3]
    assert der[0] == 0x30
    j = 2
    assert der[j] == 0x02
    j += 2 + der[j + 1]                      # skip r
    assert der[j] == 0x02
    return int.from_bytes(der[j + 2:j + 2 + der[j + 1]], "big")



def parse_assertion_fails(evidence: bytes) -> bool:
    """True when `evidence` cannot be read as `LP || LP || LP || LP` exactly covering its length."""
    i = 0
    for _ in range(4):
        if len(evidence) - i < 2:
            return True
        n = int.from_bytes(evidence[i:i + 2], "big")
        i += 2
        if len(evidence) - i < n:
            return True
        i += n
    return i != len(evidence)


cases = []
verify = []


def enc(name, kind, **fields):
    cases.append({"name": name, "kind": kind, **fields})


# ------------------------------------------------------------------------------ encoding cases

A_ASSERT = root_evidence(GRANT_A)
_cd = client_data(h(grant_commitment(GRANT_A)), ORIGIN)
_ad = authenticator_data(RP, UP | UV | BE | BS)
_r, _s = p256_sign(ROOT_D, h(_ad + h(_cd)))
enc("assertion", "assertion", credential_id=CRED.hex(), client_data_json=_cd.hex(),
    authenticator_data=_ad.hex(), signature=der_signature(_r, _s).hex(), encoded=A_ASSERT.hex())

CERT_A = certificate(GRANT_A, A_ASSERT)
enc("certificate/root-assertion", "certificate", grant=GRANT_A.hex(), evidence=A_ASSERT.hex(),
    encoded=CERT_A.hex())

B_SIG = ed25519_sign(A_SIGN_SK, GRANT_B)
CERT_B = certificate(GRANT_B, B_SIG)
enc("certificate/device-signature", "certificate", grant=GRANT_B.hex(), evidence=B_SIG.hex(),
    encoded=CERT_B.hex())

enc("bundle/one", "bundle", root=ROOT.hex(), certificates=[CERT_A.hex()],
    encoded=bundle(ROOT, [CERT_A]).hex())
enc("bundle/two", "bundle", root=ROOT.hex(), certificates=[CERT_A.hex(), CERT_B.hex()],
    encoded=bundle(ROOT, [CERT_A, CERT_B]).hex())

# THE TWO EVIDENCE FORMS ARE NOT DISJOINT. This is a CRAFTED 64-byte value — the width of a raw
# Ed25519 signature — that also parses cleanly as an assertion. A verifier that probes ("try an
# assertion, fall back to a signature") therefore lets the party supplying the evidence choose which
# check it faces, which is why §10.4's `issuer_kind` decides instead.
#
# The hazard is DELIBERATE CONSTRUCTION, not coincidence: a real signature colliding with the
# assertion grammar needs four length prefixes summing to exactly 56, measured at 0 of 2,000,000
# random 64-byte values and ~1e-14 analytically. Do not water this vector down to a real signature
# on the grounds that it "looks more realistic" — a real one does not parse, and the point is lost.
CRAFTED = (lp(bytes(range(16))) + lp(bytes(range(16, 32)))
           + lp(bytes(range(32, 48))) + lp(bytes(range(48, 56))))
assert len(CRAFTED) == 64
enc("evidence/crafted-64-bytes-parse-as-assertion", "ambiguity", evidence=CRAFTED.hex(),
    real_signature=B_SIG.hex(),
    note="issuer_kind decides the evidence form; never probe. real_signature does NOT parse.")


# ---------------------------------------------------------------------------- verification cases

def vcase(name, bundle_bytes, expect, **extra):
    case = {"name": name, "bundle": bundle_bytes.hex(), "trusted_root_id": ROOT_ID.hex(),
            "rp_id": RP, "allowed_origins": [ORIGIN], "expect": expect}
    case.update(extra)
    verify.append(case)


vcase("direct", bundle(ROOT, [CERT_A]), "ok",
      leaf_device_id=DEV_A_ID.hex(), leaf_capabilities=7,
      leaf_noise_public_key=A_NOISE_PK.hex())

vcase("chain", bundle(ROOT, [CERT_A, CERT_B]), "ok",
      leaf_device_id=DEV_B_ID.hex(), leaf_capabilities=3,
      leaf_noise_public_key=B_NOISE_PK.hex())

# A syncable authenticator may emit a high-S ECDSA signature; §10.4 gives no licence to reject one,
# and libraries that enforce low-S by default (@noble does) would silently refuse a real passkey.
# FORCED high-S, not merely un-normalised: see p256_sign's docstring for the mutation that caught
# the difference. The assertion below re-checks it here, so the fixture cannot regress quietly.
_hs = root_evidence(GRANT_A, low_s=False, force_high_s=True)
_hs_sig = assertion_signature_s(_hs)
assert _hs_sig > _N_HALF, "the high-S vector must actually be high-S"
vcase("high-s-assertion", bundle(ROOT, [certificate(GRANT_A, _hs)]),
      "ok", leaf_device_id=DEV_A_ID.hex(), leaf_capabilities=7,
      leaf_noise_public_key=A_NOISE_PK.hex(), s_is_high=True)

# UP|UV with neither backup bit — an unsynced platform authenticator. Still acceptable.
vcase("minimal-flags", bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, flags=UP | UV))]),
      "ok", leaf_device_id=DEV_A_ID.hex(), leaf_capabilities=7,
      leaf_noise_public_key=A_NOISE_PK.hex())

vcase("noise-static-matches", bundle(ROOT, [CERT_A, CERT_B]), "ok",
      expected_noise_static=B_NOISE_PK.hex(), leaf_device_id=DEV_B_ID.hex(),
      leaf_capabilities=3, leaf_noise_public_key=B_NOISE_PK.hex())

# --- negative: each mutates one thing and re-signs -------------------------------------------

vcase("root-mismatch", bundle(ROOT, [CERT_A]), "root-mismatch",
      trusted_root_id=h(b"a different root").hex())

vcase("count-zero", lp(ROOT) + u8(0), "count-invalid")
vcase("count-three", lp(ROOT) + u8(3) + lp(CERT_A) + lp(CERT_B) + lp(CERT_B), "count-invalid")
vcase("count-disagrees", lp(ROOT) + u8(2) + lp(CERT_A), "malformed")
vcase("trailing-bytes", bundle(ROOT, [CERT_A]) + b"\x00", "malformed")

vcase("clientdata-type",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, typ="webauthn.create"))]),
      "clientdata-type")
vcase("clientdata-challenge",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, challenge=h(b"wrong")))]),
      "clientdata-challenge")
vcase("clientdata-origin",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, origin="https://evil.example"))]),
      "clientdata-origin")
vcase("clientdata-crossorigin",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, cross_origin=True))]),
      "clientdata-crossorigin")
# A SECOND "origin" after the first. A last-wins parser reads evil.example; a first-wins parser
# reads the good one. Both are wrong: the bytes are ambiguous and must be refused outright.
vcase("clientdata-duplicate",
      bundle(ROOT, [certificate(GRANT_A,
                                root_evidence(GRANT_A, extra=',"origin":"https://evil.example"'))]),
      "clientdata-duplicate")

vcase("credential-mismatch",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, credential_id=bytes(16)))]),
      "credential-mismatch")
vcase("rpid-hash",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, rp_id="evil.example"))]),
      "rpid-hash")
vcase("user-presence",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, flags=UV))]), "user-presence")
vcase("user-verification",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, flags=UP))]), "user-verification")
vcase("assertion-signature",
      bundle(ROOT, [certificate(GRANT_A, root_evidence(GRANT_A, corrupt_signature=True))]),
      "signature")

# The leaf signed by a key no device in this chain certifies. Structurally perfect, and the only
# thing standing between it and a session is the Ed25519 check.
vcase("leaf-wrong-signer",
      bundle(ROOT, [CERT_A, certificate(GRANT_B, ed25519_sign(X_SIGN_SK, GRANT_B))]),
      "signature")
vcase("leaf-signature-corrupt",
      bundle(ROOT, [CERT_A, certificate(GRANT_B, B_SIG[:-1] + bytes([B_SIG[-1] ^ 0x01]))]),
      "signature")
vcase("leaf-evidence-wrong-width",
      bundle(ROOT, [CERT_A, certificate(GRANT_B, B_SIG[:63])]), "malformed")

# Evidence of the WRONG FORM for the grant that carries it. 64 bytes of 0xFF cannot parse as an
# assertion (its first LP reads 0xFFFF), and that is deliberate rather than lucky: a raw Ed25519
# signature is 64 arbitrary-looking bytes and MIGHT parse as one, which is exactly why the evidence
# form is decided by the grant's issuer_kind and never by trying both.
vcase("root-grant-with-raw-signature-evidence",
      bundle(ROOT, [certificate(GRANT_A, b"\xff" * 64)]), "malformed")

# THE MUTANT THIS CASE EXISTS FOR: a verifier that probes — "parse the evidence as an assertion,
# and if that fails try Ed25519 with the grant's own device key" — accepts this bundle and hands a
# self-appointed device capabilities 7, `enroll` included. No passkey was ever involved.
#
# It is the case that caught the difference. Every other negative vector carries evidence that fails
# BOTH forms, so a probing verifier refuses them for the same reason a correct one does and the
# suite goes green over a hole. Here the fallback succeeds, so only choosing the form by
# `issuer_kind` refuses it.
GRANT_SELF = grant(ROOT_ID, OP_B, 0, ROOT_ID, DEV_B, 7, u8(0) + LOCAL_RANDOM)
SELF_SIG = ed25519_sign(B_SIGN_SK, GRANT_SELF)
assert parse_assertion_fails(SELF_SIG), \
    "this vector is about the FALLBACK, so its evidence must not parse as an assertion"
vcase("self-signed-root-grant", bundle(ROOT, [certificate(GRANT_SELF, SELF_SIG)]), "malformed",
      note="a probing verifier accepts this with capabilities 7; issuer_kind is what refuses it")

# A leaf promoting itself to a direct grant: issuer_kind 0, issuer_id the root. Structurally this
# IS a legal root-issued grant (§10.3 allows a direct grant of 3), so nothing before the signature
# can refuse it — and it cannot be signed, because signing it needs the root passkey. Signed here
# by a P-256 key that is not the root's, which is the best a holder of A's keys could do.
GRANT_B_FORGED = grant(ROOT_ID, OP_B, 0, ROOT_ID, DEV_B, 3, u8(1) + REMOTE_H + DEV_A_ID)
# The COMMITMENT, so this case still fails at the SIGNATURE check — which is its entire point.
# Over `h(grant)` it would be refused one step earlier as `clientdata-challenge`, proving
# nothing about forged signatures.
_fcd = client_data(h(grant_commitment(GRANT_B_FORGED)), ORIGIN)
_fad = authenticator_data(RP, UP | UV)
_fr, _fs = p256_sign(0x2B1E8C4A6F90D3571E4C8A2B6D0F9351C7E4A2B8D6F031597B4E2C8A6D0F3159,
                     h(_fad + h(_fcd)))
vcase("forged-root-issued-leaf",
      bundle(ROOT, [certificate(GRANT_B_FORGED,
                                assertion(CRED, _fcd, _fad, der_signature(_fr, _fs)))]),
      "signature")

# --- negative: the §10.3 chain rules, reached through a fully signed bundle -------------------

_other_root_id = h(b"a root this device does not serve")
GRANT_WRONG_ROOT = grant(_other_root_id, OP_A, 0, _other_root_id, DEV_A, 7, u8(0) + LOCAL_RANDOM)
vcase("chain-root-mismatch",
      bundle(ROOT, [certificate(GRANT_WRONG_ROOT, root_evidence(GRANT_WRONG_ROOT))]),
      "chain/root-mismatch")

# **THE CASE A VERIFIER CHECKING ONLY THE GRANT WOULD MISS.** The grant's own root_id and issuer_id
# are correct; only the DEVICE descriptor inside it names another root. §10.4's commitment carries
# the device's two KEYS and not its descriptor, so nothing about this is visible in the signature —
# it is caught because grantCommitment refuses to produce a challenge for it.
DEV_A_OTHER_ROOT = device(_other_root_id, A_SIGN_PK, A_NOISE_PK)
GRANT_DEV_OTHER = grant(ROOT_ID, OP_A, 0, ROOT_ID, DEV_A_OTHER_ROOT, 7, u8(0) + LOCAL_RANDOM)
vcase("device-root-mismatch",
      bundle(ROOT, [certificate(GRANT_DEV_OTHER, root_evidence(GRANT_DEV_OTHER))]),
      "chain/root-mismatch",
      note="only the device descriptor names another root; the grant's own fields are correct")

# **THE MIGRATION'S OWN TEST.** Every device enrolled before this change hits exactly this, once, so
# the reason it prints is worth pinning: a pre-change bundle must die at the PARSER, refusing a label
# it does not recognise, rather than limping on to the challenge comparison and reporting a corrupted
# assertion. The grant's fields are unchanged; only what a signature over them means did.
GRANT_V1 = grant_v1(ROOT_ID, OP_A, 0, ROOT_ID, DEV_A, 7, u8(0) + LOCAL_RANDOM)
vcase("grant-v1-label-refused",
      bundle(ROOT, [certificate(GRANT_V1, root_evidence(GRANT_V1))]),
      "chain/malformed-grant",
      note="a bundle minted before the commitment change; the v1 label is no longer a grant")

vcase("chain-first-not-root-issued",
      bundle(ROOT, [certificate(GRANT_B, B_SIG)]), "chain/first-not-root-issued",
      note="B's device-issued grant presented alone, with its genuine signature")

GRANT_B_WRONG_PARENT = grant(ROOT_ID, OP_B, 1, h(b"some other grant id here"), DEV_B, 3,
                             u8(1) + REMOTE_H + DEV_A_ID)
vcase("chain-second-not-chained-to-first",
      bundle(ROOT, [CERT_A, certificate(GRANT_B_WRONG_PARENT,
                                        ed25519_sign(A_SIGN_SK, GRANT_B_WRONG_PARENT))]),
      "chain/second-not-chained-to-first")

# A leaf carrying `enroll`. §10.3 forbids it, and the GRANT PARSER already refuses to decode one —
# so it never reaches the chain rule that also forbids it. The expected code says `malformed-grant`
# for that reason, and if a future parser relaxation changed it to `unauthorised-capabilities` the
# authority would still be correct. Both are rejections; neither is a session.
GRANT_B_ENROLL = (lp(utf8("rdev-e2e/grant/v2")) + ROOT_ID + OP_B + u8(1) + GRANT_A_ID
                  + lp(DEV_B) + u8(7) + lp(u8(1) + REMOTE_H + DEV_A_ID))
vcase("chain-leaf-carrying-enroll",
      bundle(ROOT, [CERT_A, certificate(GRANT_B_ENROLL, ed25519_sign(A_SIGN_SK, GRANT_B_ENROLL))]),
      "chain/malformed-grant")

vcase("malformed-root-descriptor", bundle(ROOT[:-1], [CERT_A]), "malformed")

vcase("revoked-leaf", bundle(ROOT, [CERT_A, CERT_B]), "revoked",
      revoked_device_ids=[DEV_B_ID.hex()])
# §10.5: "Reject any chain containing a tombstoned device, including an Issuer."
vcase("revoked-issuer", bundle(ROOT, [CERT_A, CERT_B]), "revoked",
      revoked_device_ids=[DEV_A_ID.hex()])

vcase("noise-static-mismatch", bundle(ROOT, [CERT_A, CERT_B]), "noise-static-mismatch",
      expected_noise_static=A_NOISE_PK.hex(),
      note="A's DH key, presented for B's chain — the certified leaf must be the Noise peer")

doc = {
    "_comment": [
        "Cross-implementation vectors for the §10.4 evidence encodings of the E2E protocol spec,",
        "plus end-to-end bundle-verification cases. GENERATED BY A THIRD IMPLEMENTATION (stdlib",
        "Python; scripts/gen_e2e_certificate_fixture.py), whose signature arithmetic is itself",
        "pinned to the published RFC 8032 §7.1 and RFC 6979 A.2.5 answers before it emits a byte.",
        "",
        "assertion   = LP(credential_id) || LP(clientDataJSON) || LP(authenticatorData) || LP(sig)",
        "certificate = LP(grant) || LP(evidence)      evidence = assertion | raw Ed25519 signature",
        "bundle      = LP(root) || U8(count) || LP(certificate_1) [|| LP(certificate_2)]",
        "",
        "EVERY NEGATIVE CASE MUTATES ONE THING AND IS RE-SIGNED, so it fails for exactly one reason",
        "and names it in `expect`. A verifier that rejects everything passes none of them.",
        "",
        "Regenerate with scripts/gen_e2e_certificate_fixture.py; never edit a value by hand."
    ],
    "cases": cases,
    "verify": verify,
}

if __name__ == "__main__":
    self_test()
    print(json.dumps(doc, indent=1))
