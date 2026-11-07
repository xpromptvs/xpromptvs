import { decodeSocketFrame, encodeSocketFrame, SOCKET_MALFORMED_CLOSE_CODE } from "@rdev/protocol";
import type { ChannelLike, Channels } from "./channel";

/**
 * **THE `WebSocket` SUBSET A MESSAGE SOCKET NEEDS** — ordered, reliable, framed, binary. A browser
 * `WebSocket` satisfies it as is; so does the app's bridge socket (docs/desktop-app.md).
 */
export interface MessageSocket {
  binaryType: BinaryType;
  readonly readyState: number;
  /** WebSocket's own: bytes queued, not yet on the wire. A socket without it reports 0 to the uploader. */
  readonly bufferedAmount?: number;
  send(data: ArrayBufferLike | ArrayBufferView): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: string, listener: (e: Event) => void): void;
  removeEventListener(type: string, listener: (e: Event) => void): void;
}

type Label = "terminal" | "input" | "control" | "bulk";

/**
 * **ONE LOGICAL CHANNEL MULTIPLEXED OVER A MESSAGE SOCKET** (protocol/datachannels.md, "Over a message
 * socket"). It behaves as the session expects an `RTCDataChannel` to: CONNECTING until opened, `send`
 * throws while not open, and a message's `data` is an `ArrayBuffer` whatever `binaryType` says.
 */
export class MultiplexedChannel extends EventTarget implements ChannelLike {
  private state: RTCDataChannelState = "connecting";
  binaryType: BinaryType = "arraybuffer";
  constructor(readonly label: Label, private readonly socket: MessageSocket) { super(); }
  get readyState(): RTCDataChannelState { return this.state; }
  get bufferedAmount(): number { return this.socket.bufferedAmount ?? 0; }

  send(data: string | ArrayBuffer | ArrayBufferView): void {
    if (this.state !== "open") throw new DOMException(`the ${this.label} channel is not open`, "InvalidStateError");
    const bytes = typeof data === "string" ? new TextEncoder().encode(data)
      : data instanceof ArrayBuffer ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    this.socket.send(encodeSocketFrame(this.label, bytes));
  }

  /** @internal SocketChannels only. */
  open(): void {
    if (this.state !== "connecting") return;
    this.state = "open";
    this.dispatchEvent(new Event("open"));
  }
  /** @internal SocketChannels only: `payload` is `decodeSocketFrame`'s own copy. */
  deliver(payload: Uint8Array): void {
    if (this.state !== "open") return;
    // Its `buffer` IS the message, with no second copy: `decodeSocketFrame` returns `frame.slice(1)`, a
    // FRESH ArrayBuffer at offset 0 of exactly the payload's length, which nothing else holds.
    this.dispatchEvent(new MessageEvent("message", { data: payload.buffer }));
  }
  /** @internal SocketChannels only. */
  close(): void {
    if (this.state === "closed") return;
    this.state = "closed";
    this.dispatchEvent(new Event("close"));
  }
}

/**
 * **THE THREE CHANNELS OVER ONE SOCKET.** Routes every frame from the host to the channel its first
 * byte names; a frame naming none — or the meta channel, which the host never sends on — breaks the
 * protocol, and the socket is closed as malformed.
 */
export class SocketChannels {
  readonly terminal: MultiplexedChannel;
  readonly input: MultiplexedChannel;
  readonly control: MultiplexedChannel;
  readonly bulk: MultiplexedChannel;

  constructor(private readonly socket: MessageSocket) {
    this.terminal = new MultiplexedChannel("terminal", socket);
    this.input = new MultiplexedChannel("input", socket);
    this.control = new MultiplexedChannel("control", socket);
    this.bulk = new MultiplexedChannel("bulk", socket);
    socket.addEventListener("message", (e) => this.receive((e as MessageEvent).data));
  }

  all(): Channels { return { terminal: this.terminal, input: this.input, control: this.control, bulk: this.bulk }; }

  /** Open all four, in the order WebRTC opens them. */
  markOpen(): void { this.terminal.open(); this.input.open(); this.control.open(); this.bulk.open(); }
  markClosed(): void { this.terminal.close(); this.input.close(); this.control.close(); this.bulk.close(); }

  private receive(data: unknown): void {
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
      : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
    const frame = bytes ? decodeSocketFrame(bytes) : null;
    if (!frame || frame.channel === "meta") {
      this.socket.close(SOCKET_MALFORMED_CLOSE_CODE, "malformed frame");
      return;
    }
    this[frame.channel].deliver(frame.payload);
  }
}
