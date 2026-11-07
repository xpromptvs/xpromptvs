/**
 * **THE MESSAGE-SOCKET TRANSPORT'S WIRE** (protocol/datachannels.md, "Over a message socket").
 *
 * rdev's protocol is three logical channels — `control`, `input`, `terminal` — and WebRTC gives each
 * its own data channel. A message socket (anything with WebSocket semantics: ordered, reliable,
 * framed, binary) has ONE stream, so every message carries ONE BYTE naming its channel, followed by
 * exactly the bytes a data channel of that name would carry. Everything becomes totally ordered,
 * which is stronger than the per-stream order the protocol already copes with.
 *
 * The client's FIRST frame is a `hello` on the meta channel: its stable id (a reconnect is recognised
 * by it) and its join intent. `protocol/fixtures/socket-frames.json`, from a third implementation,
 * is what this and RdevCore's `SocketFrame` both answer to.
 */
export const SocketChannel = { meta: 0, control: 1, input: 2, terminal: 3, bulk: 4 } as const;
export type SocketChannelName = keyof typeof SocketChannel;
const NAMES: readonly SocketChannelName[] = ["meta", "control", "input", "terminal", "bulk"];

export const SOCKET_HELLO_VERSION = 1;
/** 1–64 characters of `[A-Za-z0-9_-]` — a per-tab id. The host prefixes it (`sock:`) before using it. */
export const SOCKET_CLIENT_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** The close code for a frame this protocol does not allow — the directory watch's "malformed". */
export const SOCKET_MALFORMED_CLOSE_CODE = 4400;

export interface SocketHello { client: string; intent: "connect" | "reconnect" }

export function encodeSocketFrame(channel: SocketChannelName, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(payload.length + 1);
  out[0] = SocketChannel[channel];
  out.set(payload, 1);
  return out;
}

/** Null for an empty frame or a byte that names no channel. The payload is a COPY. */
export function decodeSocketFrame(frame: Uint8Array): { channel: SocketChannelName; payload: Uint8Array } | null {
  if (frame.length === 0) return null;
  const channel = NAMES[frame[0]!];
  if (channel === undefined) return null;
  return { channel, payload: frame.slice(1) };
}

/** The hello's payload — compact, keys in this order: the bytes the fixture's `encodedHellos` pin. */
export function encodeSocketHello(h: SocketHello): Uint8Array {
  return new TextEncoder().encode(JSON.stringify({ t: "hello", v: SOCKET_HELLO_VERSION, client: h.client, intent: h.intent }));
}

/** Unknown fields are ignored; every known one must be exactly right, or the hello is refused. */
export function parseSocketHello(payload: Uint8Array): SocketHello | null {
  let m: unknown;
  try { m = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload)); } catch { return null; }
  if (typeof m !== "object" || m === null || Array.isArray(m)) return null;
  const o = m as Record<string, unknown>;
  if (o.t !== "hello" || o.v !== SOCKET_HELLO_VERSION) return null;
  if (typeof o.client !== "string" || !SOCKET_CLIENT_ID.test(o.client)) return null;
  if (o.intent !== "connect" && o.intent !== "reconnect") return null;
  return { client: o.client, intent: o.intent };
}
