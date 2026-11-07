interface Deps {
  stop(): void;
  show(message: string, reconnect: () => void): void;
  reconnect(): void;
}

export function parseTermStreamError(message: unknown): { reason: 'overloaded' | 'codec'; epoch: bigint } | null {
  if (!message || typeof message !== 'object') return null;
  const m = message as { t?: unknown; reason?: unknown; epoch?: unknown };
  if (m.t !== 'term-stream-error' || (m.reason !== 'overloaded' && m.reason !== 'codec') || typeof m.epoch !== 'string' ||
      !/^[1-9][0-9]{0,19}$/.test(m.epoch)) return null;
  const epoch = BigInt(m.epoch);
  return epoch <= 0xffffffffffffffffn ? { reason: m.reason, epoch } : null;
}

/** A resource limit needs a deliberate reconnect, never automatic wire retries. */
export class TermOverload {
  blocked = false;
  constructor(private readonly d: Deps) {}

  receive(message: unknown, current: bigint | null): boolean {
    const fault = parseTermStreamError(message);
    if (!fault || fault.reason !== 'overloaded') return false;
    const epoch = fault.epoch;
    if (current !== null && epoch < current) return true;
    // The host can retire a new wire before transport capacity allows START.
    this.stop();
    return true;
  }

  private stop(): void {
    if (this.blocked) return;
    this.blocked = true;
    this.d.stop();
    this.d.show('Terminal output stopped: queue limit reached.', () => this.d.reconnect());
  }
}
