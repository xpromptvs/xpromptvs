import { LEAVE_CLOSE_CODE } from "@rdev/protocol";

export type Role = "host" | "client";

export interface WebSocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: string, cb: (e: any) => void): void;
}

export interface TurnCreds { urls: string[]; username: string; credential: string; ttl: number }

export interface SignalingHandlers {
  onWelcome?(turn: TurnCreds): void;
  /** Host: called with the client's opaque UUID when a peer joins. */
  onPeerJoined?(peer: string): void;
  onPeerLeft?(peer: string): void;
  onError?(code: string, msg?: string): void;
  /**
   * §11.3's envelope. `mode` is present on the initial handshake message only, and `peer` is
   * ROUTING ONLY — it confers nothing, which is why this handler hands it on untouched rather than
   * deciding anything with it.
   */
  onE2E?(ct: string, peer?: string, mode?: string): void;
  /**
   * The host holds no §11 session for this client any more and cannot start one: the client is the
   * initiator, and a connection carries one handshake. Plaintext and empty, so a forged one forces a
   * reconnect and nothing else.
   */
  onE2EReset?(): void;
}

export class SignalingClient {
  constructor(
    private readonly socket: WebSocketLike,
    /// NO JOIN INTENT: the client says it inside its §11 session (`client-confirm`'s app_hello), where the relay can
    /// neither read nor forge it (docs/sources-and-focus.md, "The join intent").
    /// `getToken`, when given, is read at each hello instead of `token`: a connection that follows its Mac to another
    /// room (`host-follow.ts`) says that room's token on its next socket.
    private readonly opts: { role: Role; token: string; getToken?: () => string; codecs?: string[]; resumeId?: string; getResume?: () => "ice" | "rebuild" | undefined },
    private readonly handlers: SignalingHandlers,
  ) {
    // Re-sent on every (re)open (ReconnectingSocket re-emits "open"): carries the stable resumeId so the
    // host maps a reconnecting socket back to the same peer, and — only on a reconnect that a recovery
    // controller has tagged — a `resume` mode ("ice" | "rebuild").
    socket.addEventListener("open", () => {
      const resume = this.opts.getResume?.();
      this.socket.send(JSON.stringify({
        t: "hello", role: this.opts.role, token: this.opts.getToken?.() ?? this.opts.token,
        ...(this.opts.codecs ? { codecs: this.opts.codecs } : {}),
        ...(this.opts.resumeId ? { resumeId: this.opts.resumeId } : {}),
        ...(resume ? { resume } : {}),
      }));
    });
    socket.addEventListener("message", (e: { data: string }) => this.onMessage(e.data));
  }

  private readonly warnedTypes = new Set<string>();

  private onMessage(data: string): void {
    let m: any;
    try { m = JSON.parse(data); } catch { return; }
    switch (m.t) {
      case "welcome": this.handlers.onWelcome?.(m.turn); break;
      case "peer-joined": this.handlers.onPeerJoined?.(m.peer ?? m.role); break;
      case "peer-left": this.handlers.onPeerLeft?.(m.peer ?? m.role); break;
      // **SDP AND ICE HAVE NO PLAINTEXT ARM.** They travel inside §11.3's envelope and nowhere
      // else; an `offer`, `answer` or `ice` on the wire is a message the relay no longer carries
      // and this client no longer speaks, so it falls to the warning below rather than being
      // handled — which is the difference between a retired protocol and a fallback.
      case "e2e": this.handlers.onE2E?.(m.ct, m.peer, m.mode); break;
      case "e2e-reset": this.handlers.onE2EReset?.(); break;
      case "error": this.handlers.onError?.(m.code, m.msg); break;
      case "pong": break;
      // An unhandled type is REPORTED, never silently discarded. The control plane sends 13 message
      // types and this client handles 6; the leftovers are host-directed (`peer-resumed`,
      // `peer-suspended`) and reaching one means either a protocol addition landed without a client
      // change, or a host implementation is incomplete. Discarding them in silence is exactly how the
      // dev harness came to depend on never receiving `peer-resumed` — and how a permanently
      // unsatisfiable smoke step survived unnoticed.
      //
      // Warned ONCE PER TYPE: these arrive per peer-event, so a warning per message would be noise on a
      // busy session and would train people to ignore it.
      default:
        if (!this.warnedTypes.has(m.t)) {
          this.warnedTypes.add(m.t);
          console.warn(`[signaling] unhandled message type "${m.t}" — no handler; see SignalingHandlers`);
        }
        break;
    }
  }

  /**
   * One §11.3 envelope. The mode rides only the first, which is the handshake's own rule.
   *
   * **A HOST MUST NAME THE PEER.** §11.3 calls `peer` "routing only" and it confers nothing — but
   * the relay has more than one client to choose from, and a host envelope without it is DROPPED.
   * Measured: the harness peer answered every handshake into nothing, and both ends waited on each
   * other with the client still reading "waiting for host…". A client omits it; it has one peer.
   */
  sendE2E(ct: string, mode?: string, peer?: string): void {
    this.socket.send(JSON.stringify({
      t: "e2e", ct, ...(mode ? { mode } : {}), ...(peer ? { peer } : {}),
    }));
  }
  sendBye(reason?: string): void { this.socket.send(JSON.stringify({ t: "bye", ...(reason ? { reason } : {}) })); }
  ping(): void { this.socket.send(JSON.stringify({ t: "ping" })); }
  close(): void { this.socket.close(); }

  /**
   * Tell the control plane this client is LEAVING DELIBERATELY, so it reaps the identity now
   * instead of suspending it for the grace window while the host keeps capturing and encoding for
   * a page that is gone.
   *
   * Best-effort by nature: a crash, a force-quit or a lost network sends nothing. That is why the
   * host also releases media when the peer connection reaches a terminal state — measured at 32s
   * against this path's near-zero.
   */
  leave(): void { this.socket.close(LEAVE_CLOSE_CODE, "leaving"); }
}
