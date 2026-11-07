#!/usr/bin/env python3
"""Regenerate protocol/fixtures/identity-code.json — the human-readable form of a root id.

    python3 scripts/gen_identity_code_fixture.py > protocol/fixtures/identity-code.json

A THIRD IMPLEMENTATION, like the identity and wire fixtures beside it: the Swift and TypeScript
encoders assert against what this produces, so each agrees with something neither wrote. **The Mac
and the browser showing different strings would break the one comparison this code exists for**,
which is why agreement is asserted against an outside answer rather than between the two.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import json

# Crockford's: no I, L, O or U, so there is no pair of characters a person can confuse when holding
# two screens side by side, and nothing in it reads as a word.
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
BYTES = 10          # 80 bits -> exactly 16 characters, no padding

assert len(ALPHABET) == 32 and len(set(ALPHABET)) == 32
assert not (set("ILOU") & set(ALPHABET))


def code(root_id: bytes) -> str:
    n = int.from_bytes(root_id[:BYTES], "big")
    chars = "".join(ALPHABET[(n >> (5 * (15 - i))) & 31] for i in range(16))
    return "-".join(chars[i:i + 4] for i in range(0, 16, 4))


def root_id(prefix: bytes) -> bytes:
    # **The tail is 0xAA, not zero.** Only the first 10 bytes are encoded; padding with zeros would
    # let an implementation that read all 32 pass anyway.
    assert len(prefix) == BYTES
    return prefix + b"\xaa" * (32 - BYTES)


vectors = []

# One vector per alphabet character, each repeating that character sixteen times. Between them they
# reach ALL 32, so a transposed or truncated alphabet cannot pass on the rows that happen to agree.
for index in range(32):
    n = sum(index << (5 * k) for k in range(16))
    vectors.append(root_id(n.to_bytes(BYTES, "big")))

# The extremes, and a real root id from the session fixture beside it.
vectors.append(bytes(32))
vectors.append(b"\xff" * 32)
vectors.append(bytes.fromhex(
    "606c98d0b9335237d9ac94a0364819405df10ef29e50d623ba35c78a0515b203"))

print(json.dumps({
    "alphabet": ALPHABET,
    "bytes": BYTES,
    "vectors": [{"root_id": v.hex(), "code": code(v)} for v in vectors],
}, indent=2))
