#!/usr/bin/env python3
"""Regenerate protocol/fixtures/socket-frames.json — the message-socket transport's frames and hello.

    python3 scripts/gen_socket_frame_fixture.py > protocol/fixtures/socket-frames.json

A THIRD IMPLEMENTATION, like the fixtures beside it: RdevCore's `SocketFrame`/`SocketHello` and
protocol/'s `socket-frame.ts` each assert what this produces, so each agrees with something neither
wrote (docs/superpowers/specs/2026-09-30-transport-generic-protocol-local-window-design.md).

A frame is ONE BYTE naming the logical channel, then exactly the bytes a WebRTC data channel of that
name would carry. The client's first frame is a `hello` on the meta channel: its stable id and its
join intent.

Stdlib only. NEVER edit a vector by hand to make a suite pass.
"""
import json

CHANNELS = {"meta": 0, "control": 1, "input": 2, "terminal": 3, "bulk": 4}
HELLO_VERSION = 1
ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
ID_MAX = 64


def frame(channel, payload):
    return bytes([CHANNELS[channel]]) + payload


def hello_bytes(obj):
    # Compact, and in the key order given: the client's encoder must produce EXACTLY these bytes.
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


def hello(client, intent):
    return hello_bytes({"t": "hello", "v": HELLO_VERSION, "client": client, "intent": intent})


def is_client_id(s):
    return isinstance(s, str) and 1 <= len(s) <= ID_MAX and all(c in ID_ALPHABET for c in s)


def parse_hello(payload):
    """The reference parser: what both implementations must agree with."""
    try:
        o = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(o, dict) or o.get("t") != "hello":
        return None
    v = o.get("v")
    # The NUMBER 1 — not "1", and not true (a bool is an int in Python, and an NSNumber in Swift).
    if isinstance(v, bool) or not isinstance(v, int) or v != HELLO_VERSION:
        return None
    if not is_client_id(o.get("client")) or o.get("intent") not in ("connect", "reconnect"):
        return None
    return {"client": o["client"], "intent": o["intent"]}


FRAMES = [
    ("control", "a control message in its codec envelope", b"\x00" + b'{"t":"list-terminals"}'),
    ("input", "an input message in its codec envelope", b"\x00" + b'{"t":"key","data":"a","term":"pty:1"}'),
    ("terminal", "a terminal wire start", b"\x04\x00"),
    ("terminal", "every byte value", bytes(range(256))),
    ("bulk", "a paste piece in its codec envelope", b"\x00" + b'{"t":"paste-data","id":"p1","item":0,"seq":0,"data":"YWJj"}'),
    ("control", "an empty payload", b""),
    ("meta", "a hello", hello("tab-1", "connect")),
]
MALFORMED_FRAMES = [
    ("empty", b""),
    ("channel 5 does not exist", b"\x05\x00{}"),
    ("channel 255 does not exist", b"\xff"),
]
HELLOS = [
    ("connect", hello("Ab0_-", "connect")),
    ("reconnect", hello("tab-1", "reconnect")),
    ("a 64-character id", hello("x" * 64, "connect")),
    ("keys in another order", hello_bytes({"intent": "connect", "client": "tab-2", "v": 1, "t": "hello"})),
    ("an unknown extra field is ignored",
     hello_bytes({"t": "hello", "v": 1, "client": "tab-3", "intent": "reconnect", "later": True})),
]
MALFORMED_HELLOS = [
    ("not JSON", b"hello"),
    ("not UTF-8", b"\xff\xfe"),
    ("a JSON array", b"[]"),
    ("a JSON string", b'"hello"'),
    ("another message type", hello_bytes({"t": "bye", "v": 1, "client": "tab", "intent": "connect"})),
    ("version 2", hello_bytes({"t": "hello", "v": 2, "client": "tab", "intent": "connect"})),
    ("the version as a string", hello_bytes({"t": "hello", "v": "1", "client": "tab", "intent": "connect"})),
    ("the version as true", hello_bytes({"t": "hello", "v": True, "client": "tab", "intent": "connect"})),
    ("no version", hello_bytes({"t": "hello", "client": "tab", "intent": "connect"})),
    ("an empty id", hello("", "connect")),
    ("a 65-character id", hello("x" * 65, "connect")),
    ("an id with a space", hello("tab 1", "connect")),
    ("an id with a slash", hello("tab/1", "connect")),
    ("an id with a non-ASCII letter", hello("tabé", "connect")),
    ("a numeric id", hello_bytes({"t": "hello", "v": 1, "client": 7, "intent": "connect"})),
    ("an unknown intent", hello("tab", "resume")),
    ("no intent", hello_bytes({"t": "hello", "v": 1, "client": "tab"})),
]
ENCODED = [("tab-1", "connect"), ("Ab0_-", "reconnect")]

assert all(parse_hello(p) for _, p in HELLOS)
assert not any(parse_hello(p) for _, p in MALFORMED_HELLOS)
assert all(f and f[0] not in CHANNELS.values() for n, f in MALFORMED_FRAMES if f)

print(json.dumps({
    "channels": CHANNELS,
    "helloVersion": HELLO_VERSION,
    "frames": [{"name": n, "channel": c, "payload": p.hex(), "frame": frame(c, p).hex()} for c, n, p in FRAMES],
    "malformedFrames": [{"name": n, "frame": f.hex()} for n, f in MALFORMED_FRAMES],
    "hellos": [dict(name=n, payload=p.hex(), **parse_hello(p)) for n, p in HELLOS],
    "encodedHellos": [{"client": c, "intent": i, "payload": hello(c, i).hex()} for c, i in ENCODED],
    "malformedHellos": [{"name": n, "payload": p.hex()} for n, p in MALFORMED_HELLOS],
}, indent=2))
