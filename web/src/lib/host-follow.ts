import type { DirectorySession } from "@rdev/protocol";

/**
 * **A CLIENT FOLLOWS ITS MAC TO THE MAC'S NEXT ROOM** (docs/client-web.md, "A Mac that shares again";
 * 2026-10-08, asked for: "reconnect without restarting the client to a host that's restarted (but kept
 * identity and began sharing)").
 *
 * Every Share opens a fresh pairing window, so a Mac that quit (or crashed) and shares again is in ANOTHER
 * room, under another code and token — and a connection retries the room it was given, forever, where
 * nothing will ever answer. What does not change is the Mac: its §10.2 device id, which the §11 handshake
 * authenticated, and which §12.2's directory names beside every room it lists (the Worker derives it from
 * the publishing chain). So while a connection is not live, this asks the directory — the live stream, and
 * a poll beside it, as the dashboard does — whether that device is listed in a room other than this one,
 * and hands that room over once.
 *
 * **THE LISTING IS ONLY A HINT.** The connection pins the next handshake to that device
 * (`expectedResponderDeviceId`): a directory that lies can send it to a room that fails the handshake,
 * never to another Mac.
 */
export interface Room { code: string; token: string }

/** The room the directory lists `deviceId` in, when it is not `current`; null while the Mac is unlisted or
 *  listed where this connection already is (a blip, which recovery handles in place). */
export function nextRoom (rows: readonly DirectorySession[], deviceId: string, current: string): Room | null {
  const row = rows.find((r) => r.device_id === deviceId);
  return row && row.code !== current ? { code: row.code, token: row.token } : null;
}

/** The poll beside the stream: soon at first (a restart takes seconds), backing off while the Mac stays away. */
export const FOLLOW_POLL_MIN_MS = 2000;
export const FOLLOW_POLL_MAX_MS = 30_000;

export interface HostFollowDeps {
  /** §12.2's `list` under this device's identity; null on any failure (or no identity). */
  list: () => Promise<readonly DirectorySession[] | null>;
  /** §12.2's `/watch`, under the same identity: each snapshot of the listing until `signal` aborts. */
  watch?: (onRows: (rows: readonly DirectorySession[]) => void, signal: AbortSignal) => void;
  schedule: (fn: () => void, ms: number) => unknown;
  clear: (t: unknown) => void;
  /** The Mac is listed in another room. Called once per arming; the follow is disarmed first. */
  found: (room: Room) => void;
}

export class HostFollow {
  private deviceId: string | null = null;
  private armed = false;
  private disposed = false;
  private timer: unknown = null;
  private delay = FOLLOW_POLL_MIN_MS;
  private watching: AbortController | null = null;
  /** Bumped by every disarm, so a lookup that was in flight when the connection came back finds nothing. */
  private epoch = 0;

  constructor (private current: string, private readonly deps: HostFollowDeps) {}

  /** The Mac this connection reached — its device id as the directory spells it (b64u of SHA-256 of its
   *  descriptor). Learned from every session that opens. */
  learn (deviceId: string): void { this.deviceId = deviceId; }

  get known (): boolean { return this.deviceId !== null; }
  get isArmed (): boolean { return this.armed; }

  /** The connection is not live: look for the Mac, the first lookup after `firstMs`. Nothing until a session
   *  has opened (no device to look for); arming again brings a later lookup forward, never back. */
  arm (firstMs: number): void {
    if (this.disposed || this.deviceId === null) return;
    if (!this.armed) {
      this.armed = true;
      this.delay = FOLLOW_POLL_MIN_MS;
      this.startWatch();
      this.lookAfter(firstMs);
      return;
    }
    if (firstMs === 0) this.lookAfter(0);
  }

  /** The connection is live again, in its room: stop looking. */
  disarm (): void {
    this.epoch += 1;
    this.armed = false;
    if (this.timer !== null) { this.deps.clear(this.timer); this.timer = null; }
    this.watching?.abort();
    this.watching = null;
  }

  /** Look now — the page was looked at again, or the network came back — if looking at all. */
  kick (): void { if (this.armed) this.lookAfter(0); }

  dispose (): void {
    this.disposed = true;
    this.disarm();
  }

  private lookAfter (ms: number): void {
    if (this.timer !== null) this.deps.clear(this.timer);
    this.timer = this.deps.schedule(() => { this.timer = null; void this.poll(); }, ms);
  }

  private async poll (): Promise<void> {
    const epoch = this.epoch;
    let rows: readonly DirectorySession[] | null = null;
    try { rows = await this.deps.list(); } catch { rows = null; }
    if (epoch !== this.epoch || !this.armed) return;
    if (rows && this.offer(rows)) return;
    this.lookAfter(this.delay);
    this.delay = Math.min(this.delay * 2, FOLLOW_POLL_MAX_MS);
  }

  private startWatch (): void {
    if (!this.deps.watch) return;
    const watching = new AbortController();
    this.watching = watching;
    try {
      this.deps.watch((rows) => { if (!watching.signal.aborted) this.offer(rows); }, watching.signal);
    } catch { /* the poll carries on */ }
  }

  /** True when the rows name the Mac in another room — handed over, and the follow disarmed. */
  private offer (rows: readonly DirectorySession[]): boolean {
    if (!this.armed || this.deviceId === null) return false;
    const room = nextRoom(rows, this.deviceId, this.current);
    if (!room) return false;
    this.current = room.code;
    this.disarm();
    this.deps.found(room);
    return true;
  }
}
