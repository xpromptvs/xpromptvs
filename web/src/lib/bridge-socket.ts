import type { MessageSocket } from "./socket-channels";

/**
 * **WHAT `__rdevShell` GIVES THE PAGE FOR ITS SOCKET** (`app/Sources/BridgeScripts.swift`): the local
 * window's end of the app's bridge socket (docs/desktop-app.md, "The bridge socket"). Frames cross as
 * STANDARD base64, the alphabet Swift's `Data(base64Encoded:)` reads.
 */
export interface ShellSocketApi {
  socketOpen(id: string, handlers: { frames(frames: string[]): void; closed(): void }): void;
  socketSend(id: string, frame: string): void;
  socketClose(id: string): void;
}

const CONNECTING = 0, OPEN = 1, CLOSED = 3;

/**
 * **A MESSAGE SOCKET OVER THE APP'S BRIDGE** — shaped like the browser's `WebSocket`, which is what
 * `SocketConnection` expects, so a real one drops in later unchanged.
 * - It OPENS at once, but never synchronously: the caller attaches its listeners after the constructor
 *   returns. The bridge needs no handshake: the app creates the host's end as the `open` message
 *   arrives, and the handler is ORDERED, so a frame sent after it reaches the host after its socket
 *   exists.
 * - A refusal comes back as `closed`.
 */
export class BridgeMessageSocket extends EventTarget implements MessageSocket {
  binaryType: BinaryType = "blob";
  private state = CONNECTING;

  constructor(private readonly shell: ShellSocketApi, private readonly id: string = randomId()) {
    super();
    shell.socketOpen(id, { frames: (f) => this.receive(f), closed: () => this.ended() });
    queueMicrotask(() => {
      if (this.state !== CONNECTING) return;
      this.state = OPEN;
      this.dispatchEvent(new Event("open"));
    });
  }

  get readyState(): number { return this.state; }

  send(data: ArrayBufferLike | ArrayBufferView): void {
    if (this.state === CONNECTING) throw new DOMException("the bridge socket is not open", "InvalidStateError");
    if (this.state !== OPEN) return;            // a closed WebSocket discards, as here
    const bytes = ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      : new Uint8Array(data);
    this.shell.socketSend(this.id, bytesToBase64(bytes));
  }

  close(_code?: number, _reason?: string): void {
    if (this.state === CLOSED) return;
    this.state = CLOSED;
    this.shell.socketClose(this.id);
    queueMicrotask(() => this.dispatchEvent(new Event("close")));
  }

  private receive(frames: string[]): void {
    for (const frame of frames) {
      if (this.state !== OPEN) return;
      const bytes = base64ToBytes(frame);
      if (!bytes) { this.close(); return; }
      // A FRESH buffer at offset 0 of exactly the frame's length, which nothing else holds.
      this.dispatchEvent(new MessageEvent("message", { data: bytes.buffer }));
    }
  }

  /** The app closed it (a refusal, the session ending, the host replacing it). */
  private ended(): void {
    if (this.state === CLOSED) return;
    this.state = CLOSED;
    this.dispatchEvent(new Event("close"));
  }
}

function randomId(): string {
  const b = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** Bytes → standard base64 (`+`, `/`, `=` padding), in chunks: one `fromCharCode` per byte of a big frame is slow. */
export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/** Standard base64 → bytes, or null. The engine's own decoder where it has one (WebKit does). */
export function base64ToBytes(text: string): Uint8Array | null {
  const native = (Uint8Array as unknown as { fromBase64?: (s: string) => Uint8Array }).fromBase64;
  try {
    if (native) return native.call(Uint8Array, text);
    const binary = atob(text);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}
