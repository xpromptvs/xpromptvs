import { describe, expect, it } from "vitest";
import { termWriter, WriteCoalescer } from "../src/client/write-coalescer";

/// A serial task queue like main.ts's `enqueue`: each task runs after the previous one resolves.
function serialQueue() {
  let tail: Promise<void> = Promise.resolve();
  return (task: () => Promise<void>) => { tail = tail.then(task); };
}

describe("WriteCoalescer", () => {
  it("text that arrives while a write is in flight goes out as ONE later write, in order", async () => {
    const writes: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const c = new WriteCoalescer(serialQueue(), async (t) => { writes.push(t); if (writes.length === 1) await gate; });
    c.push("a");
    await Promise.resolve(); await Promise.resolve();          // the first write starts and blocks
    c.push("b"); c.push("c"); c.push("d");
    release();
    await new Promise((r) => setTimeout(r, 0));
    expect(writes).toEqual(["a", "bcd"]);
  });

  it("a burst pushed before anything runs is one write", async () => {
    const writes: string[] = [];
    const c = new WriteCoalescer(serialQueue(), async (t) => { writes.push(t); });
    for (const ch of "hello") c.push(ch);
    await new Promise((r) => setTimeout(r, 0));
    expect(writes).toEqual(["hello"]);
  });

  it("an empty push writes nothing", async () => {
    const writes: string[] = [];
    const c = new WriteCoalescer(serialQueue(), async (t) => { writes.push(t); });
    c.push("");
    await new Promise((r) => setTimeout(r, 0));
    expect(writes).toEqual([]);
  });
});

describe("termWriter", () => {
  it("a ?2026 frame arriving in pieces is applied as ONE write, and only once it is whole", async () => {
    const writes: string[] = [];
    const w = termWriter(serialQueue(), async (t) => { writes.push(t); }, { set: () => 0, clear: () => {} });
    const frame = "\x1b[?2026h" + "row\r\n".repeat(50) + "\x1b[?2026l";
    for (let i = 0; i < frame.length; i += 16) {
      w.push(frame.slice(i, i + 16));
      await new Promise((r) => setTimeout(r, 0));             // each piece is its own message
      if (i + 16 < frame.length) expect(writes).toEqual([]);
    }
    expect(writes).toEqual([frame]);
  });

  it("dispose drops a held frame", async () => {
    const writes: string[] = [];
    const w = termWriter(serialQueue(), async (t) => { writes.push(t); }, { set: () => 0, clear: () => {} });
    w.push("a\x1b[?2026hb");
    w.dispose();
    w.push("\x1b[?2026l");
    await new Promise((r) => setTimeout(r, 0));
    expect(writes).toEqual(["a"]);
  });
});
