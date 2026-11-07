#!/usr/bin/env python3
"""Regenerate protocol/fixtures/lane-vectors.json — the lane's wire format and its FEC, from a THIRD implementation.

    python3 scripts/gen_lane_vectors.py > protocol/fixtures/lane-vectors.json

The Go bridge (host/streaming-engine/PionBridge) and the page (web/src/lib) each assert what this produces
(docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2, §5). A disagreement about the field, the coefficient
generator or a byte order DECODES TO PLAUSIBLE GARBAGE rather than to an error, which is why neither language's own
literals are trusted — only this file's.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import json
import struct

# ---- GF(256): primitive polynomial 0x11d, generator 2 ------------------------------------------------------------
EXP = [0] * 512
LOG = [0] * 256
_x = 1
for _i in range(255):
    EXP[_i] = _x
    LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    EXP[_i] = EXP[_i - 255]


def gf_mul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


def xorshift_step(state):
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= state >> 17
    state ^= (state << 5) & 0xFFFFFFFF
    return state


def next_seed(seed):
    return xorshift_step(seed & 0xFFFFFFFF or 0x9E3779B9)


def coefficients(seed, count):
    state, out = seed & 0xFFFFFFFF or 0x9E3779B9, []
    for _ in range(count):
        state = xorshift_step(state)
        out.append(state % 255 + 1)
    return out


def repair(symbols, seed):
    cs = coefficients(seed, len(symbols))
    out = [0] * max(len(s) for s in symbols)
    for c, s in zip(cs, symbols):
        for i, b in enumerate(s):
            out[i] ^= gf_mul(c, b)
    return bytes(out)


# ---- the lane's packets, symbols and counters (spec §2) ------------------------------------------------------------
def header(kind, pkt, ts):
    return struct.pack(">BII", kind, pkt, ts)


def source(pkt, ts, esi, symbol_bytes):
    return header(1, pkt, ts) + struct.pack(">I", esi) + symbol_bytes


def repair_packet(pkt, ts, first, count, seed, payload):
    return header(2, pkt, ts) + struct.pack(">IHI", first, count, seed) + payload


def feedback(pkt, ts, cum, ranges, loss, echo, held):
    out = header(3, pkt, ts) + struct.pack(">IB", cum, len(ranges))
    for start, length in ranges:
        out += struct.pack(">IH", start, length)
    return out + struct.pack(">HIH", loss, echo, held)


def symbol(chunks):
    body = b"".join(struct.pack(">BIH", stream, offset, len(data)) + data for stream, offset, data in chunks)
    return struct.pack(">H", len(body)) + body


def unwrap(reference, wire):
    candidate = (reference & ~0xFFFFFFFF) | wire
    if candidate > reference and candidate - reference > 1 << 31 and candidate >= 1 << 32:
        return candidate - (1 << 32)
    if candidate < reference and reference - candidate > 1 << 31:
        return candidate + (1 << 32)
    return candidate


def patterned(esi, length):
    return bytes((esi * 31 + i * 7 + 11) & 0xFF for i in range(length))


# The video path's pinned literal: if this moves, the field or the generator did.
assert coefficients(0x12345678, 8) == [33, 57, 35, 123, 59, 3, 193, 118]

KEY = symbol([(1, 0, struct.pack(">I", 38) + b'{"t":"key","data":"a","term":"pty:1"}')])
TWO = [symbol([(0, 7, b"terminal bytes")]), symbol([(2, 3, b"ctl")])]
RLC = [
    ("one symbol: its own scaled copy", [KEY], 1),
    ("three symbols of different lengths", [patterned(0, 3), patterned(1, 9), patterned(2, 5)], 0x12345678),
    ("a seed with the high bit set", [patterned(i, 16) for i in range(4)], 0xFFFFFFFF),
    ("seed zero", [patterned(i, 8) for i in range(3)], 0),
    ("a full window of 64", [patterned(i, 32) for i in range(64)], 0xDEADBEEF),
]
PACKETS = [
    ("a keystroke's SOURCE", "source", dict(pkt=7, ts=123456, esi=42, symbol=KEY)),
    ("a SOURCE with every counter's high bit set", "source", dict(pkt=0xFFFFFFFF, ts=0xFFFFFFFE, esi=0x80000001, symbol=TWO[0])),
    ("a REPAIR over three", "repair", dict(pkt=9, ts=99, firstEsi=40, count=3, seed=0xC0FFEE,
                                            payload=repair([KEY] + TWO, 0xC0FFEE))),
    ("a FEEDBACK with nothing above cumESI", "feedback", dict(pkt=1, ts=2, cumEsi=100, ranges=[], lossPermille=0, echoTs=5, held=0)),
    ("a FEEDBACK with two ranges", "feedback", dict(pkt=3, ts=4, cumEsi=7, ranges=[(9, 2), (14, 1)], lossPermille=37, echoTs=1234, held=18)),
    ("a FEEDBACK with sixteen ranges", "feedback", dict(pkt=5, ts=6, cumEsi=0x10, ranges=[(0x11 + 3 * i, 1) for i in range(16)],
                                                      lossPermille=1000, echoTs=0xFFFFFFFF, held=65535)),
]


def encode(kind, f):
    if kind == "source":
        return source(f["pkt"], f["ts"], f["esi"], f["symbol"])
    if kind == "repair":
        return repair_packet(f["pkt"], f["ts"], f["firstEsi"], f["count"], f["seed"], f["payload"])
    return feedback(f["pkt"], f["ts"], f["cumEsi"], f["ranges"], f["lossPermille"], f["echoTs"], f["held"])


def as_json(kind, f):
    out = {}
    for k, v in f.items():
        out[k] = v.hex() if isinstance(v, bytes) else ([list(r) for r in v] if k == "ranges" else v)
    return out


MALFORMED_PACKETS = [
    ("empty", b""),
    ("shorter than a header", b"\x01" * 8),
    ("an unknown type", header(9, 0, 0) + b"\x00" * 6),
    ("a SOURCE without a whole symbol length", header(1, 0, 0) + struct.pack(">I", 1) + b"\x00"),
    ("a SOURCE whose symbol is longer than 1080", header(1, 0, 0) + struct.pack(">I", 1) + b"\x00" * 1081),
    ("a REPAIR covering no symbols", header(2, 0, 0) + struct.pack(">IHI", 0, 0, 1) + b"\x00\x00"),
    ("a FEEDBACK claiming 17 ranges", header(3, 0, 0) + struct.pack(">IB", 0, 17) + b"\x00" * (17 * 6 + 8)),
    ("a FEEDBACK one byte short", feedback(1, 2, 3, [(4, 1)], 0, 0, 0)[:-1]),
    ("a FEEDBACK one byte long", feedback(1, 2, 3, [(4, 1)], 0, 0, 0) + b"\x00"),
    ("longer than 1100 bytes", header(2, 0, 0) + struct.pack(">IHI", 0, 1, 1) + b"\x00" * 1082),
]
SYMBOLS = [
    ("one chunk", [(2, 0, b"x")]),
    ("three streams in priority order", [(2, 5, b"ab"), (1, 0, b"c"), (0, 1000, b"defg")]),
    ("no chunks", []),
    ("a chunk at a wrapped offset", [(0, 0xFFFFFFF0, b"zz")]),
]
PADDED = ("zero-padded, as rebuilt from repair", [(1, 3, b"k")])
MALFORMED_SYMBOLS = [
    ("one byte", b"\x00"),
    ("a length past the end", b"\x00\x09abc"),
    ("a chunk on stream 3", struct.pack(">H", 8) + struct.pack(">BIH", 3, 0, 1) + b"x"),
    ("a chunk running past the symbol", struct.pack(">H", 8) + struct.pack(">BIH", 0, 0, 5) + b"x"),
    ("a truncated chunk header", struct.pack(">H", 3) + b"\x00\x00\x00"),
]
UNWRAP = [(0, 0), (5, 3), (5, 0xFFFFFFFF), ((1 << 32) - 5, 3), ((1 << 32) + 2, 0xFFFFFFFE), ((1 << 33) + 10, 20),
          (1 << 32, (1 << 31) + 1), (1 << 32, 1 << 31)]

print(json.dumps({
    "coefficients": [{"seed": s, "values": coefficients(s, 8)} for s in (0x12345678, 0, 0xFFFFFFFF)],
    "nextSeed": [{"seed": s, "next": next_seed(s)} for s in (0, 1, 0x12345678, 0x80000000, 0xFFFFFFFF)],
    "rlc": [{"name": n, "seed": seed, "symbols": [s.hex() for s in syms], "repair": repair(syms, seed).hex()}
            for n, syms, seed in RLC],
    "packets": [dict(name=n, kind=k, bytes=encode(k, f).hex(), **as_json(k, f)) for n, k, f in PACKETS],
    "malformedPackets": [{"name": n, "bytes": b.hex()} for n, b in MALFORMED_PACKETS],
    "symbols": [{"name": n, "chunks": [{"stream": s, "offset": o, "bytes": d.hex()} for s, o, d in c],
                 "bytes": symbol(c).hex()} for n, c in SYMBOLS]
               + [{"name": PADDED[0], "chunks": [{"stream": s, "offset": o, "bytes": d.hex()} for s, o, d in PADDED[1]],
                   "bytes": (symbol(PADDED[1]) + b"\x00" * 20).hex()}],
    "malformedSymbols": [{"name": n, "bytes": b.hex()} for n, b in MALFORMED_SYMBOLS],
    "unwrap": [{"reference": r, "wire": w, "full": unwrap(r, w)} for r, w in UNWRAP],
}, indent=2))
