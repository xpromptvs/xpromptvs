/**
 * **ONE OF THE PROTOCOL'S THREE LOGICAL CHANNELS** — `control`, `input`, `terminal` — as the session
 * uses it, whatever carries it (docs/client-web.md, "The connection"). An `RTCDataChannel` IS one; so
 * is a `MultiplexedChannel` (`socket-channels.ts`), the same channel multiplexed over one message socket.
 * Only what the session actually touches: sending, the ready state, the binary type and the
 * open/close/message events. It extends `EventTarget` deliberately, so a channel can be compared with an
 * event's `target` (the recovery check in `onControlClose`).
 */
export interface ChannelLike extends EventTarget {
  readonly label: string;
  readonly readyState: RTCDataChannelState;
  binaryType: BinaryType;
  /** Bytes queued and not yet sent — the paste uploader paces on it. Absent: nothing to wait for. */
  readonly bufferedAmount?: number;
  send(data: string | ArrayBuffer | ArrayBufferView): void;
  addEventListener<K extends keyof RTCDataChannelEventMap>(type: K, listener: (ev: RTCDataChannelEventMap[K]) => unknown,
                                                           options?: boolean | AddEventListenerOptions): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject,
                   options?: boolean | AddEventListenerOptions): void;
  removeEventListener<K extends keyof RTCDataChannelEventMap>(type: K, listener: (ev: RTCDataChannelEventMap[K]) => unknown,
                                                              options?: boolean | EventListenerOptions): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject,
                      options?: boolean | EventListenerOptions): void;
}

export interface Channels {
  terminal: ChannelLike;
  input: ChannelLike;
  control: ChannelLike;
  /** The paste/drop protocol and the image viewer's files: reliable, ordered, never the lane. */
  bulk: ChannelLike;
}

/**
 * **RUNS `fn` ONCE FOR `ch`'S OPEN — AT ONCE IF IT IS ALREADY OPEN, ELSE AT ITS `open`.** A channel can be open when it
 * is handed over: on the SCTP baseline `bulk` is created last, so `control` has opened before the set completes, and
 * the answering side gets a lane whose streams read open at the hand-over (lane-channel.ts). A listener bound only at
 * the hand-over would miss that `open`, and the session would never send its control-open batch. Per binding, not per
 * channel: two bindings on one channel each run once, in the order they were bound — as two `open` listeners would.
 */
export function whenOpen(ch: ChannelLike, fn: () => void): void {
  if (ch.readyState === "open") {
    // AT ONCE, BUT ISOLATED AS AN `open` LISTENER IS: run inline, a throw would abort whatever the caller binds after
    // this — the session's `bulk` dispatch and its terminal binding — leaving a terminal channel nobody listens to under
    // a footer that reads connected. Reported, as the browser reports a listener's throw.
    try { fn(); } catch (err) { reportListenerError(err); }
  } else {
    ch.addEventListener("open", () => fn(), { once: true });   // a closure: one binding is never another's duplicate
  }
}

/** The browser's own report for a listener that threw (`reportError`), or the console where there is none (jsdom). */
function reportListenerError(err: unknown): void {
  const report = (globalThis as { reportError?: (e: unknown) => void }).reportError;
  if (typeof report === "function") report(err);
  else console.error(err);
}
