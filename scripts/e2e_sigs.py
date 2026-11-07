#!/usr/bin/env python3
"""Ed25519 (RFC 8032), ECDSA P-256 (FIPS 186-4, RFC 6979 nonces) and X25519 (RFC 7748) in
stdlib Python.

Exists so `gen_e2e_certificate_fixture.py` can produce REAL SIGNATURES for the §10.4 evidence
vectors. Swift verifies with CryptoKit and TypeScript with @noble; without this they would only
ever check each other, and two implementations that agree only with each other can be wrong
together.

**THIS FILE IS NOT A SECURITY COMPONENT AND MUST NEVER BE IMPORTED BY ONE.** It is straight-line
textbook arithmetic with no constant-time discipline whatsoever — every scalar multiply here
branches on secret bits. It signs fixture keys that are published in a JSON file. That is its
entire purpose.

It is also not trusted on its own: `self_test()` reproduces the published RFC 8032 §7.1, RFC 6979
A.2.5 and RFC 7748 §6.1 answers, and the generator refuses to emit anything until it passes. So the
vectors rest on an external answer rather than on this code being right.
"""
import hashlib
import hmac

# --------------------------------------------------------------------------- Ed25519 (RFC 8032)

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _recover_x(y: int, sign: int):
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * pow(5, _P - 2, _P) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _ed_add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % _P
    b = (p[1] + p[0]) * (q[1] + q[0]) % _P
    c = 2 * p[3] * q[3] * _D % _P
    d = 2 * p[2] * q[2] % _P
    e, f, g, hh = b - a, d - c, d + c, b + a
    return (e * f % _P, g * hh % _P, f * g % _P, e * hh % _P)


def _ed_mul(s: int, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _ed_add(q, p)
        p = _ed_add(p, p)
        s >>= 1
    return q


def _compress(p) -> bytes:
    zinv = pow(p[2], _P - 2, _P)
    x = p[0] * zinv % _P
    y = p[1] * zinv % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _clamp(h: bytes) -> int:
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a


def ed25519_public_key(secret: bytes) -> bytes:
    assert len(secret) == 32
    return _compress(_ed_mul(_clamp(hashlib.sha512(secret).digest()), _G))


def ed25519_sign(secret: bytes, message: bytes) -> bytes:
    assert len(secret) == 32
    h = hashlib.sha512(secret).digest()
    a = _clamp(h)
    pub = _compress(_ed_mul(a, _G))
    r = int.from_bytes(hashlib.sha512(h[32:] + message).digest(), "little") % _L
    rr = _compress(_ed_mul(r, _G))
    k = int.from_bytes(hashlib.sha512(rr + pub + message).digest(), "little") % _L
    return rr + int.to_bytes((r + k * a) % _L, 32, "little")


# ------------------------------------------------------------------- ECDSA P-256 (FIPS 186-4)

_N256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_N256_A = _N256_P - 3
_N256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_N256_GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
_N256_GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
_N256_G = (_N256_GX, _N256_GY)


def _pt_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % _N256_P == 0:
        return None
    if p == q:
        lam = (3 * p[0] * p[0] + _N256_A) * pow(2 * p[1], _N256_P - 2, _N256_P) % _N256_P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], _N256_P - 2, _N256_P) % _N256_P
    x = (lam * lam - p[0] - q[0]) % _N256_P
    return (x, (lam * (p[0] - x) - p[1]) % _N256_P)


def _pt_mul(k: int, p):
    r = None
    while k:
        if k & 1:
            r = _pt_add(r, p)
        p = _pt_add(p, p)
        k >>= 1
    return r


def p256_public_key(d: int) -> bytes:
    """Uncompressed SEC1: 0x04 || X || Y — the 65 bytes §10.1 puts in the root descriptor."""
    q = _pt_mul(d, _N256_G)
    return b"\x04" + q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big")


def _rfc6979_k(d: int, msg_hash: bytes) -> int:
    def mac(key, *data):
        m = hmac.new(key, digestmod=hashlib.sha256)
        for chunk in data:
            m.update(chunk)
        return m.digest()

    # bits2octets: qlen == hlen == 256 here, so there is no truncation shift, only the reduction.
    z = int.from_bytes(msg_hash, "big")
    if z >= _N256_N:
        z -= _N256_N
    x_oct = d.to_bytes(32, "big")
    h_oct = z.to_bytes(32, "big")
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = mac(k, v, b"\x00", x_oct, h_oct)
    v = mac(k, v)
    k = mac(k, v, b"\x01", x_oct, h_oct)
    v = mac(k, v)
    while True:
        v = mac(k, v)
        t = int.from_bytes(v, "big")
        if 1 <= t < _N256_N:
            return t
        k = mac(k, v, b"\x00")
        v = mac(k, v)


def p256_sign(d: int, msg_hash: bytes, low_s: bool = True, force_high_s: bool = False):
    """Deterministic (r, s) over a 32-byte SHA-256 digest.

    `low_s` defaults to True because that is what a well-behaved signer emits. WebAuthn
    authenticators are NOT required to normalise, so the fixture also needs an assertion that is
    definitely high-S — and `low_s=False` ALONE DOES NOT GIVE ONE: it merely declines to normalise,
    and RFC 6979 lands below N/2 about half the time. That is not a hypothetical. The first version
    of the high-S vector was built that way, came out low-S for its key, and a verifier mutated to
    enforce low-S passed the whole suite. `force_high_s` reflects s when it needs reflecting, so the
    case tests what its name says.

    (r, s) and (r, N - s) are both valid ECDSA signatures for the same message and key, so this
    changes nothing except which half of the curve order s falls in.
    """
    z = int.from_bytes(msg_hash, "big")
    k = _rfc6979_k(d, msg_hash)
    r = _pt_mul(k, _N256_G)[0] % _N256_N
    s = pow(k, _N256_N - 2, _N256_N) * (z + r * d) % _N256_N
    if force_high_s:
        assert not low_s, "force_high_s and low_s are contradictory"
        if s <= _N256_N // 2:
            s = _N256_N - s
        assert s > _N256_N // 2
    elif low_s and s > _N256_N // 2:
        s = _N256_N - s
    return r, s


def _der_int(v: int) -> bytes:
    # Minimal two's-complement DER INTEGER: one leading zero byte exactly when the high bit is set.
    width = (v.bit_length() + 8) // 8 or 1
    return b"\x02" + bytes([width]) + v.to_bytes(width, "big")


def der_signature(r: int, s: int) -> bytes:
    body = _der_int(r) + _der_int(s)
    return b"\x30" + bytes([len(body)]) + body


# ------------------------------------------------------------------- X25519 (RFC 7748)

_X_P = 2 ** 255 - 19
_X_A24 = 121665


def _x_decode_scalar(k: bytes) -> int:
    b = bytearray(k)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")


def x25519(k: bytes, u: bytes) -> bytes:
    """The RFC 7748 Montgomery ladder. Not constant-time; see this module's header."""
    x1 = int.from_bytes(bytes(u[:31]) + bytes([u[31] & 127]), "little")
    scalar = _x_decode_scalar(k)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        kt = (scalar >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        a = (x2 + z2) % _X_P
        aa = a * a % _X_P
        b = (x2 - z2) % _X_P
        bb = b * b % _X_P
        e = (aa - bb) % _X_P
        c = (x3 + z3) % _X_P
        d = (x3 - z3) % _X_P
        da = d * a % _X_P
        cb = c * b % _X_P
        x3 = pow(da + cb, 2, _X_P)
        z3 = x1 * pow(da - cb, 2, _X_P) % _X_P
        x2 = aa * bb % _X_P
        z2 = e * (aa + _X_A24 * e) % _X_P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, _X_P - 2, _X_P) % _X_P).to_bytes(32, "little")


def x25519_public_key(private: bytes) -> bytes:
    """The Noise static a device publishes in its §10.2 descriptor."""
    assert len(private) == 32
    return x25519(private, (9).to_bytes(32, "little"))


# ----------------------------------------------------------------------------------- self test

def self_test() -> None:
    """Reproduce published answers. The generator calls this before emitting anything."""
    # RFC 8032 §7.1 TEST 1 and TEST 2.
    sk1 = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc4"
                        "4449c5697b326919703bac031cae7f60")
    pk1 = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a"
                        "0ee172f3daa62325af021a68f707511a")
    sig1 = bytes.fromhex("e5564300c360ac729086e2cc806e828a"
                         "84877f1eb8e5d974d873e06522490155"
                         "5fb8821590a33bacc61e39701cf9b46b"
                         "d25bf5f0595bbe24655141438e7a100b")
    assert ed25519_public_key(sk1) == pk1, "RFC 8032 TEST 1 public key"
    assert ed25519_sign(sk1, b"") == sig1, "RFC 8032 TEST 1 signature"

    sk2 = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f"
                        "5b8a319f35aba624da8cf6ed4fb8a6fb")
    sig2 = bytes.fromhex("92a009a9f0d4cab8720e820b5f642540"
                         "a2b27b5416503f8fb3762223ebdb69da"
                         "085ac1e43e15996e458f3613d0f11d8c"
                         "387b2eaeb4302aeeb00d291612bb0c00")
    assert ed25519_sign(sk2, bytes([0x72])) == sig2, "RFC 8032 TEST 2 signature"

    # RFC 6979 A.2.5 — P-256, SHA-256. Note these published s values are NOT low-S normalised,
    # which is exactly why p256_sign takes the flag.
    d = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
    ux = 0x60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6
    uy = 0x7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299
    assert p256_public_key(d) == b"\x04" + ux.to_bytes(32, "big") + uy.to_bytes(32, "big"), \
        "RFC 6979 A.2.5 public key"
    for message, want_r, want_s in [
        (b"sample",
         0xEFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716,
         0xF7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8),
        (b"test",
         0xF1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367,
         0x019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083),
    ]:
        r, s = p256_sign(d, hashlib.sha256(message).digest(), low_s=False)
        assert (r, s) == (want_r, want_s), f"RFC 6979 A.2.5 {message!r}"

    # RFC 7748 §6.1 — the X25519 Diffie-Hellman worked example.
    a_priv = bytes.fromhex("77076d0a7318a57d3c16c17251b26645"
                           "df4c2f87ebc0992ab177fba51db92c2a")
    a_pub = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a"
                          "0dbf3a0d26381af4eba4a98eaa9b4e6a")
    b_priv = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee6"
                           "6f3bb1292618b6fd1c2f8b27ff88e0eb")
    b_pub = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece43537"
                          "3f8343c85b78674dadfc7e146f882b4f")
    shared = bytes.fromhex("4a5d9d5ba4ce2de1728e3bf480350f25"
                           "e07e21c947d19e3376f09b3c1e161742")
    assert x25519_public_key(a_priv) == a_pub, "RFC 7748 §6.1 alice public"
    assert x25519_public_key(b_priv) == b_pub, "RFC 7748 §6.1 bob public"
    assert x25519(a_priv, b_pub) == shared, "RFC 7748 §6.1 shared (a)"
    assert x25519(b_priv, a_pub) == shared, "RFC 7748 §6.1 shared (b)"


if __name__ == "__main__":
    self_test()
    print("ok: RFC 8032 §7.1, RFC 6979 A.2.5 and RFC 7748 §6.1 reproduced")
