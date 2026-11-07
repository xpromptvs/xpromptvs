import { Decompress } from 'fzstd';
import { parseTermFrame, TERM_WIRE_START, type TermFrame } from './term-frame';

interface Sink {
  start(epoch: bigint): void;
  record(frame: TermFrame): void;
  failed(error: Error): void;
}
const MAX_MESSAGE = 60 * 1024;
const MAX_QUEUED_BYTES = 64 * 1024 * 1024;
const MAX_QUEUED_RECORDS = 65_536;

/// The only codec context in a mounted connection. Every DATA record is decoded,
/// even if the tab router will discard its obsolete generation afterward.
export class TermWireDecoder {
  private epoch: bigint | null = null;
  private sequence = 0n;
  private decoder: Decompress | null = null;
  private failed = false;
  private receiving = false;
  private pending: Uint8Array[] = [];
  private queuedBytes = 0;
  private inFlightBytes = 0;
  private chunks: Uint8Array[] = [];
  private outputBytes = 0;
  private outputLimit = 0;

  constructor(private readonly sink: Sink) {}
  get currentEpoch(): bigint | null { return this.epoch; }

  reset(): void {
    this.epoch = null;
    this.failed = false;
    this.decoder = null;
    this.pending = []; this.queuedBytes = 0;
    this.chunks = [];
  }

  invalidate(): void {
    this.failed = true;
    this.decoder = null;
    this.pending = []; this.queuedBytes = 0;
    this.chunks = [];
  }

  receive(bytes: Uint8Array): void {
    if (bytes.length > MAX_MESSAGE || this.queuedBytes + this.inFlightBytes + bytes.length > MAX_QUEUED_BYTES ||
        this.pending.length + (this.receiving ? 1 : 0) >= MAX_QUEUED_RECORDS) {
      this.fail(new Error('Terminal stream receive limit exceeded')); return;
    }
    // A callback may receive again. Own those bytes until the previous push and callbacks finish.
    this.pending.push(bytes.slice()); this.queuedBytes += bytes.length;
    if (this.receiving) return;
    this.receiving = true;
    try {
      while (this.pending.length) {
        const next = this.pending.shift()!;
        this.queuedBytes -= next.length; this.inFlightBytes = next.length;
        try { this.accept(next); } catch (e) { this.fail(e instanceof Error ? e : new Error(String(e))); }
        finally { this.inFlightBytes = 0; }
      }
    } finally { this.receiving = false; }
  }

  private accept(b: Uint8Array): void {
    if (b.length < 14 || b[0] !== 82 || b[1] !== 90 || b[2] !== 84 || b[3] !== 49 || b[4]! > 1) {
      throw new Error('Unsupported terminal wire; reload the client');
    }
    const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const epoch = view.getBigUint64(5);
    if (epoch === 0n) throw new Error('Invalid terminal epoch');
    if (this.epoch !== null && epoch < this.epoch) return;
    if (b[4] === 0) {
      if (this.epoch !== null && epoch === this.epoch) return;
      this.epoch = epoch;
      this.decoder = null;
      // A failed START must remain recoverable by a later epoch, and report once.
      this.failed = false;
      const compressed = b.subarray(13);
      validateBlocks(compressed, true);
      this.decoder = new Decompress(chunk => {
        if (this.outputBytes + chunk.length > this.outputLimit) throw new Error('Terminal decoded length exceeded');
        this.outputBytes += chunk.length;
        this.chunks.push(chunk.slice());
      });
      const raw = this.decode(compressed, 32);
      if (raw.some((v, i) => v !== i)) throw new Error('Invalid terminal initialization');
      this.sequence = 0n;
        this.sink.start(epoch);
      return;
    }
    if (this.failed) return;
    if (epoch !== this.epoch || !this.decoder || b.length <= 25) throw new Error('Terminal DATA without START');
    if (view.getBigUint64(13) !== this.sequence) throw new Error('Terminal sequence mismatch');
    const length = view.getUint32(21);
    if (length < 2 || length > MAX_MESSAGE - 128) throw new Error('Invalid terminal raw length');
    const compressed = b.subarray(25);
    validateBlocks(compressed, false);
    const raw = this.decode(compressed, length);
    const frame = parseTermFrame(raw);
    if (!frame || frame.kind === TERM_WIRE_START) throw new Error('Invalid terminal record');
    // TextDecoder's replacement mode must not turn a malformed id into another tab's id.
    new TextDecoder('utf-8', { fatal: true }).decode(raw.subarray(2, 2 + raw[1]!));
    this.sequence++;
    this.sink.record(frame);
  }

  private decode(bytes: Uint8Array, length: number): Uint8Array {
    this.chunks = []; this.outputBytes = 0; this.outputLimit = length;
    this.decoder!.push(bytes);
    if (this.outputBytes !== length) throw new Error('Terminal record did not decode synchronously');
    const out = new Uint8Array(length);
    let offset = 0;
    for (const chunk of this.chunks) { out.set(chunk, offset); offset += chunk.length; }
    this.chunks = [];
    return out;
  }

  private fail(error: Error): void {
    if (this.failed) return;
    this.invalidate();
    this.sink.failed(error);
  }
}

/// The writer uses an unknown-length, dictionary-free streaming frame. Validate its
/// header BEFORE fzstd allocates a window, and every complete flushed block BEFORE
/// decoding. Last blocks, concatenated frames and partial blocks are never valid here.
function validateBlocks(b: Uint8Array, first: boolean): void {
  let pos = 0;
  if (first) {
    if (b.length < 9 || b[0] !== 0x28 || b[1] !== 0xb5 || b[2] !== 0x2f || b[3] !== 0xfd || b[4] !== 0 || b[5]! > 56) {
      throw new Error('Unsupported terminal zstd frame/window');
    }
    pos = 6;
  }
  let blocks = 0;
  while (pos < b.length) {
    if (pos + 3 > b.length) throw new Error('Truncated terminal zstd block');
    const head = b[pos]! | (b[pos+1]! << 8) | (b[pos+2]! << 16);
    const type = (head >>> 1) & 3, size = head >>> 3;
    if ((head & 1) || type === 3 || size > 131072) throw new Error('Invalid terminal zstd block');
    pos += 3 + (type === 1 ? 1 : size); blocks++;
    if (pos > b.length) throw new Error('Truncated terminal zstd payload');
  }
  if (!blocks) throw new Error('Empty terminal zstd message');
}
