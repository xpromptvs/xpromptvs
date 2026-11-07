#!/usr/bin/env python3
"""Mint a root and two enrolled devices FOR A GIVEN ORIGIN, so a gate can bring up an E2E host and
client without a passkey ceremony.

    python3 scripts/gen_e2e_test_identities.py --rp-id localhost \
        --origin http://localhost:8787 --out /tmp/ids.json

**WHY THIS EXISTS.** Once signalling is E2E-only, every gate needs both ends enrolled — and driving
a real ceremony per gate would put a browser, a virtual authenticator and a Worker in front of
checks that are about codecs, audio or input. This installs an identity instead. **It removes no
security property from what is under test:** the §11 handshake still runs for real, against real
chains, with real signatures. What it skips is the part §12.1 covers and these gates do not.

**IT MINTS PER ORIGIN, AND THAT IS THE POINT.** `protocol/fixtures/e2e-session.json` carries devices
whose root assertions were made for `https://rdev.example`, so a host on `http://localhost:8787`
would fail `verifyBundle`'s origin check against its own policy — and the way out is NOT to let a
test override §10.1's policy, which is the one thing that must come from trusted application code.
It is to mint chains whose assertions name the origin the test actually uses.

The chains are signed by `scripts/e2e_sigs.py`, pinned to the published RFC 8032 §7.1 and RFC 6979
A.2.5 answers before a byte is emitted. Stdlib only.

**THE PRIVATE KEYS ARE IN THE OUTPUT ON PURPOSE.** They are keys for a throwaway root that
authorises nothing beyond the test that minted it, and both ends have to SIGN — a device proof, a
directory request — so withholding them would leave only verification exercised.
"""
import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_encodings import grant_commitment  # noqa: E402
from e2e_sigs import (  # noqa: E402
    der_signature, ed25519_public_key, p256_public_key, p256_sign, self_test, x25519_public_key,
)


def lp(b: bytes) -> bytes:
    assert len(b) <= 0xFFFF
    return len(b).to_bytes(2, "big") + b


def u8(n: int) -> bytes:
    return bytes([n])


def h(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def b64u(b: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rp-id", required=True, help="the relying party, e.g. localhost")
    parser.add_argument("--origin", required=True, help="e.g. http://localhost:8787")
    parser.add_argument("--out", required=True, help="where to write the JSON")
    parser.add_argument("--seed", default=None,
                        help="hex, for a REPRODUCIBLE identity; omitted means a fresh random one")
    args = parser.parse_args()

    # The RFC vectors first, exactly as every other generator here does: a signer that cannot
    # reproduce the published answers has no business emitting a chain.
    self_test()

    seed = bytes.fromhex(args.seed) if args.seed else os.urandom(32)
    # Deterministic in `seed` so a gate can mint the same identity twice — a host restarting must
    # come back as the SAME device, not a new one.
    def derive(label: str, length: int = 32) -> bytes:
        return hashlib.sha256(b"rdev/test-identity/v1|" + label.encode() + b"|" + seed).digest()[:length]

    root_d = int.from_bytes(derive("root"), "big") or 1
    cred = derive("credential", 16)
    root = lp(b"rdev-e2e/root/v1") + lp(args.rp_id.encode()) + lp(cred) + p256_public_key(root_d)
    root_id = h(root)

    def clamp(raw: bytes) -> bytes:
        b = bytearray(raw)
        b[0] &= 248
        b[31] &= 127
        b[31] |= 64
        return bytes(b)

    def make(name: str, capabilities: int) -> dict:
        signing_secret = derive(f"{name}/signing")
        noise_secret = clamp(derive(f"{name}/noise"))
        descriptor = (lp(b"rdev-e2e/device/v1") + root_id
                      + ed25519_public_key(signing_secret) + x25519_public_key(noise_secret))
        operation_id = derive(f"{name}/operation")
        grant = (lp(b"rdev-e2e/grant/v2") + root_id + operation_id
                 + u8(0) + root_id + lp(descriptor) + u8(capabilities)
                 + lp(u8(0) + derive(f"{name}/binding")))
        # The root's own WebAuthn assertion over `H(grant_commitment)`, for THIS origin. §10.4's
        # commitment is a projection of the grant that names no root.
        client_data = ('{"type":"webauthn.get","challenge":"%s","origin":"%s","crossOrigin":false}'
                       % (b64u(h(grant_commitment(grant))), args.origin)).encode()
        authenticator_data = h(args.rp_id.encode()) + u8(0x01 | 0x04 | 0x08 | 0x10) \
            + (0).to_bytes(4, "big")
        r, s = p256_sign(root_d, h(authenticator_data + h(client_data)))
        evidence = lp(cred) + lp(client_data) + lp(authenticator_data) + lp(der_signature(r, s))
        certificate = lp(grant) + lp(evidence)
        return {
            "signing_private_key": signing_secret.hex(),
            "noise_private_key": noise_secret.hex(),
            "rendezvous_seed": derive(f"{name}/rendezvous").hex(),
            "descriptor": descriptor.hex(),
            "device_id": h(descriptor).hex(),
            "operation_id": operation_id.hex(),
            "bundle": (lp(root) + u8(1) + lp(certificate)).hex(),
        }

    out = {
        "rp_id": args.rp_id,
        "origin": args.origin,
        "root": root.hex(),
        "root_id": root_id.hex(),
        # `host` carries `enroll` because §11.1 asks it of a `pair` responder and it costs nothing
        # here; `client` is a leaf with `connect | host`, which is what a browser holds.
        "host": make("host", 7),
        "client": make("client", 3),
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
