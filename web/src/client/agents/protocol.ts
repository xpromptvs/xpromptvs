export type AgentObject = Record<string, any>;
const MAX = 64 * 1024 * 1024;
type Transfer = { epoch: string; count: number; total: number; next: number; size: number; parts: Uint8Array[]; at: number };

/** The surrounding Xpromptvs connection authenticates the peer; epochs fence a driver handoff. */
export class AgentProtocol {
  epoch: string | null = null;
  private pending = new Map<string, { resolve: (v: AgentObject) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout>; op: string }>();
  private transfers = new Map<string, Transfer>();
  private nonce = 0;
  private prefix = crypto.randomUUID();
  constructor(private send: (m: AgentObject) => void, private event: (m: AgentObject) => void) {}
  call(op: string, thread?: string, args: AgentObject = {}): Promise<AgentObject> {
    if (this.pending.size >= 32) return Promise.reject(Error("Too many pending agent requests"));
    const id = `${this.prefix}:${++this.nonce}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id);const error=Error(op==="hello"?"The host did not answer Agents. Reconnect, or update Xpromptvs on the host if it uses an older version.":"Agent request timed out; check its state before retrying");error.name=op==="hello"?"AgentHelloTimeout":"AgentRequestTimeout";reject(error); }, 25_000);
      this.pending.set(id, { resolve, reject, timer, op });
      this.send({ t: "agent-request", v: 1, id, op, ...(thread ? { thread } : {}), ...(this.epoch ? { epoch: this.epoch } : {}), args });
    });
  }
  receive(m: AgentObject): boolean {
    if (m.t === "agent-chunk") {
      this.chunk(m); return true;
    }
    if (m.t === "agent-response") {
      const waiting = this.pending.get(m.id);
      if (!waiting) return true;
      if (waiting.op !== "hello" && m.epoch !== this.epoch) return true;
      this.pending.delete(m.id); clearTimeout(waiting.timer);
      if (waiting.op === "hello" && typeof m.epoch === "string") this.epoch = m.epoch;
      if (m.error) waiting.reject(Error(String(m.error)));
      else waiting.resolve(m.result ?? {});
      return true;
    }
    if (m.t === "agent-event") {
      if (this.epoch && m.epoch === this.epoch && m.event && typeof m.event === "object") this.event(m.event);
      return true;
    }
    return false;
  }
  private chunk(m: AgentObject): void {
    for (const [id, transfer] of this.transfers) if (Date.now() - transfer.at > 20_000) this.transfers.delete(id);
    if (typeof m.transfer !== "string" || m.transfer.length > 128 || typeof m.epoch !== "string" ||
        !Number.isInteger(m.seq) || !Number.isInteger(m.count) || !Number.isInteger(m.total) ||
        m.total < 0 || m.total > MAX || m.count < 1 || m.count > 5500 || m.seq < 0 || m.seq >= m.count ||
        typeof m.data !== "string" || m.data.length > 22000) return;
    let transfer = this.transfers.get(m.transfer);
    if (!transfer) {
      if (m.seq !== 0 || this.transfers.size >= 2 || [...this.transfers.values()].reduce((n, t) => n + t.total, 0) + m.total > MAX) return;
      transfer = { epoch: m.epoch, count: m.count, total: m.total, next: 0, size: 0, parts: [], at: Date.now() };
      this.transfers.set(m.transfer, transfer);
    }
    try {
      if (transfer.epoch !== m.epoch || transfer.next !== m.seq || transfer.count !== m.count || transfer.total !== m.total) throw Error("Invalid agent transfer sequence");
      const part = Uint8Array.from(atob(m.data), c => c.charCodeAt(0));
      if (part.length > 16384 || transfer.size + part.length > transfer.total) throw Error("Invalid agent transfer size");
      transfer.parts.push(part); transfer.size += part.length; transfer.next++;
      if (transfer.next === transfer.count) {
        this.transfers.delete(m.transfer);
        if (transfer.size !== transfer.total) throw Error("Incomplete agent transfer");
        const bytes = new Uint8Array(transfer.size); let offset = 0;
        for (const p of transfer.parts) { bytes.set(p, offset); offset += p.length; }
        const object = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
        if (object.t === "agent-response" || object.t === "agent-event") this.receive(object);
      }
    } catch { this.transfers.delete(m.transfer); this.event({ method: "xpromptvs/resnapshot", params: { error: "Agent transfer was interrupted" } }); }
  }
  reset(): void {
    this.epoch = null; this.transfers.clear(); this.prefix = crypto.randomUUID();
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(Error("Agent connection or control changed")); }
    this.pending.clear();
  }
}
