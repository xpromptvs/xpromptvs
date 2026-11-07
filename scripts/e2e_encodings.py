#!/usr/bin/env python3
"""§10 encodings the fixture generators share, in stdlib Python.

`e2e_sigs.py` is strictly curves; this is strictly bytes. Both exist so the generated vectors come
from a THIRD implementation — one neither Swift nor TypeScript was written from — and so Swift and
TypeScript each agree with something external rather than with each other.

Shared between the generators rather than copied into each: three copies of a projection free to
drift is the exact failure the grant commitment exists to make impossible.
"""


def lp(b: bytes) -> bytes:
    return len(b).to_bytes(2, "big") + b


def grant_commitment(grant_bytes: bytes) -> bytes:
    """§10.4's commitment — the bytes a ROOT PASSKEY signs, derived by PARSING the grant.

    Derived rather than built from parts, exactly as the verifier derives it, so a generator cannot
    sign a different projection than the grant it just built.

    **It names NO root.** A browser signing in has not yet learned which credential will answer, so a
    challenge containing `root_id` could not exist until a first ceremony had produced it — which is
    the whole reason signing in costs one prompt rather than two. `root_id` and `issuer_id` are
    skipped here and pinned by the verifier instead.

    `LP(device)` is deliberately NOT carried: a §10.2 descriptor names its root, which would put
    `root_id` straight back in. The device's two KEYS are carried and the verifier reassembles the
    descriptor from the root it already trusts.
    """
    i = 2 + int.from_bytes(grant_bytes[0:2], "big")      # LP(label)
    i += 32                                              # root_id — skipped on purpose
    operation_id = grant_bytes[i:i + 32]; i += 32
    issuer_kind = grant_bytes[i]; i += 1
    i += 32                                              # issuer_id — skipped on purpose
    dn = int.from_bytes(grant_bytes[i:i + 2], "big"); i += 2
    device_bytes = grant_bytes[i:i + dn]; i += dn
    capabilities = grant_bytes[i]; i += 1
    bn = int.from_bytes(grant_bytes[i:i + 2], "big"); i += 2
    binding = grant_bytes[i:i + bn]; i += bn
    assert i == len(grant_bytes), "trailing bytes in a grant this generator built"

    # device = LP(label) || root_id || signing || noise
    d = 2 + int.from_bytes(device_bytes[0:2], "big") + 32
    signing = device_bytes[d:d + 32]
    noise = device_bytes[d + 32:d + 64]
    assert len(signing) == 32 and len(noise) == 32, "a device descriptor carries two 32-byte keys"

    return (lp(b"rdev-e2e/grant-commit/v1") + operation_id + bytes([issuer_kind])
            + signing + noise + bytes([capabilities]) + lp(binding))
