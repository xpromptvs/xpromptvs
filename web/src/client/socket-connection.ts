import { encodeSocketFrame, encodeSocketHello, LEAVE_CLOSE_CODE } from "@rdev/protocol";
import { SocketChannels, type MessageSocket } from "../lib/socket-channels";
import type { Connection, ConnectionDeps, Transport } from "./connection";

/**
 * **THE SESSION OVER ONE MESSAGE SOCKET** (docs/client-web.md, "The connection"): no relay, no §11 —
 * the socket's own transport is what authenticates it (the app's bridge, reachable only from its own
 * page) — and NO MEDIA, so the session is window-less. The first frame is the `hello`: this tab's id
 * and its join intent, `connect` until the control channel first opens and `reconnect` after, exactly
 * as the relay's hello says it.
 */
export interface SocketTarget {
  /** A fresh socket, connecting. Called again for every reconnect. */
  open(): MessageSocket;
  /** This tab's stable id (`resume-id.ts`) — how the host tells a reconnect from a newcomer. */
  clientId: string;
  /** The socket reaches THIS Mac's own host (the app's bridge). Absent: another machine's. */
  sameMac?: boolean;
  /** Trusted app bridge capability, never derived from a socket hello. */
  nativeSimulators?: boolean;
}

export function socketTransport(target: SocketTarget): Transport {
  return { presentation: target.nativeSimulators ? "native-simulators" : "terminal-only", carriesMedia: false, sameMac: target.sameMac === true, connect: (deps) => createSocketConnection(target, deps) };
}

const RETRY_MIN_MS = 1000, RETRY_MAX_MS = 30_000;

function createSocketConnection(target: SocketTarget, deps: ConnectionDeps): Connection {
  const { scope, sink } = deps;
  let intent: "connect" | "reconnect" = "connect";
  let socket: MessageSocket | null = null;
  /// The CURRENT socket's channels, beside it.
  let channels: SocketChannels | null = null;
  let state: RTCPeerConnectionState = "connecting";
  let ended = false;
  let retryMs = RETRY_MIN_MS;

  const open = () => {
    if (ended || scope.disposed) return;
    const s = target.open();
    const ch = new SocketChannels(s);
    socket = s;
    channels = ch;
    s.binaryType = "arraybuffer";
    s.addEventListener("open", () => {
      if (socket !== s) return;
      s.send(encodeSocketFrame("meta", encodeSocketHello({ client: target.clientId, intent })));
      state = "connected";
      retryMs = RETRY_MIN_MS;
      // FIRST, before the session's: the intent flips before its control-open batch goes out.
      ch.control.addEventListener("open", () => { intent = "reconnect"; });
      sink.channels(ch.all());
      ch.markOpen();
      sink.status("connected", "connected");
    });
    s.addEventListener("close", () => {
      if (socket !== s) return;
      socket = null;
      channels = null;
      ch.markClosed();
      if (ended || scope.disposed) { state = "closed"; return; }
      state = "connecting";
      sink.status("connecting", "reconnecting…");
      const wait = retryMs;
      retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
      scope.timeout(open, wait);
    });
  };
  open();

  const leave = () => {
    if (ended) return;
    ended = true;
    state = "closed";
    const s = socket, ch = channels;
    // Cleared FIRST: the socket's own late `close` event is then fenced out (`socket !== s`).
    socket = null;
    channels = null;
    try { s?.close(LEAVE_CLOSE_CODE, "leaving"); } catch { /* already gone */ }
    // As closing a WebRTC peer closes its data channels: nothing reads this socket's as open again.
    ch?.markClosed();
  };
  return {
    get connectionState() { return state; },
    media: null,
    closeDialogs: () => {},
    leave,
    close: leave,
  };
}
