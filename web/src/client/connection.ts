import type { Channels } from "../lib/channel";
import type { StatusInfo } from "../lib/ice-stats";
import type { RdevDebug } from "../lib/debug";
import type { SessionScope } from "./session-scope";
import type { ClientContext } from "./instance/context";

/**
 * **HOW A SESSION REACHES ITS HOST** (docs/client-web.md, "The connection"). The session renders the
 * host's state and speaks the protocol over three channels; a `Transport` is what carries them —
 * WebRTC through the relay (`rtc-connection.ts`), or one message socket (`socket-connection.ts`).
 * Only WebRTC carries MEDIA; a transport without it is WINDOW-LESS, and the session renders the
 * terminal only.
 */
export interface Transport {
  /** Whether this transport can carry video and audio. False ⇒ a window-less session. */
  readonly carriesMedia: boolean;
  readonly presentation?: "terminal-only" | "native-simulators" | "streamed-sources";
  /** Whether its host is THIS Mac — the app's own window over its bridge socket — so a path on this
   *  machine is a path there (a folder pasted is typed as its path, docs/client-web.md, "A folder"). */
  readonly sameMac: boolean;
  connect(deps: ConnectionDeps): Connection;
}

/** What a connection tells the session. */
export interface ConnectionSink {
  /** The three channels — the first time, and after every rebuild (fresh objects each time). */
  channels(ch: Channels): void;
  /** A connection state to show, with its sentence. */
  status(state: StatusInfo["state"], text: string): void;
  /** WebRTC: THE TAB BAR, before any channel opens — the host's first offer carries the messages a control open starts
   *  with (`control-state`, `term-list`, the session's windows), sealed in §11 with the offer (docs/sources-and-focus.md,
   *  "The offer carries the tab bar"). Untrusted shapes: the session parses each as it parses the control channel's. */
  earlyState?(messages: unknown[]): void;
  /** WebRTC: the terminal grid this page says as it joins — `client-confirm`'s app_hello, asked for as that message
   *  is written, inside the §11 session (offer-screen.ts). Null says nothing: the host resizes nothing, and the
   *  offer carries no screen. */
  joinGrid?(): { cols: number; rows: number } | null;
  /** WebRTC: an incoming track. */
  track?(stream: MediaStream, receiver?: RTCRtpReceiver, negotiatedTrackId?: string): void;
  /** WebRTC: a host data channel that is none of the three (`video`, `video-feedback`). */
  extraChannel?(ch: RTCDataChannel): void;
  /** WebRTC: the answer round trip completed. */
  negotiated?(): void;
  /** WebRTC: the peer connection reached `connected`. */
  mediaConnected?(): void;
  /** WebRTC media was replaced. A retained logical control admission does not reopen with it. */
  peerClosed?(state?: { controlRetained: boolean }): void;
  /** WebRTC: whether this page drives its host — read as a connection follows its Mac to another room, whose join
   *  then says `connect` so the page drives it again (`rtc-connection.ts`, "FOLLOWING THE MAC"). */
  drives?(): boolean;
  /** WebRTC: the connection followed its Mac to another room — what a restart of this session (the bfcache) and the
   *  page's address should name from now on. */
  moved?(room: { code: string; token: string }): void;
}

export interface ConnectionDeps {
  context?: ClientContext;
  /** The session's scope: every listener and timer the connection registers is released with it. */
  scope: SessionScope;
  dbg: RdevDebug;
  sink: ConnectionSink;
  /** `?jbuf=`, the receiver's jitter-buffer target (`peer.ts`). */
  jitterBufferTargetMs: number;
}

/** The receive side of a connection that carries media — what the session's media code reads. */
export interface MediaPart {
  getStats(): Promise<RTCStatsReport>;
  /** The live receivers — the per-window bitrate readout reads each window's from here. */
  getReceivers(): RTCRtpReceiver[];
  localSdp(): string;
}

export interface Connection {
  /** As `RTCPeerConnection.connectionState` reads — a socket maps onto the same words. */
  readonly connectionState: RTCPeerConnectionState;
  /** Null for a window-less connection. */
  readonly media: MediaPart | null;
  /** Close any dialog this connection opened (the identity panels) — the session's dispose, first step. */
  closeDialogs(): void;
  /** Say goodbye to the host (and the relay): `pagehide`, Disconnect. Stops all recovery. */
  leave(): void;
  /** Release what is left after `leave` (the §11 session). Idempotent. */
  close(): void;
}
