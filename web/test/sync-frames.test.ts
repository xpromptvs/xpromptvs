import { describe, expect, it } from "vitest";
import { SYNC_FRAME_HOLD_MS, SyncFrameGate } from "../src/client/sync-frames";

const BSU = "\x1b[?2026h", ESU = "\x1b[?2026l";

/// A gate whose releases are recorded and whose one timer is fired by hand.
function rig() {
  const out: string[] = [];
  let timer: { f: () => void; ms: number } | null = null;
  let armed = 0;
  const gate = new SyncFrameGate((t) => out.push(t), {
    set: (f, ms) => { timer = { f, ms }; armed++; return armed; },
    clear: () => { timer = null; },
  });
  return {
    gate, out,
    text: () => out.join(""),
    timer: () => timer,
    armed: () => armed,
    fire: () => { const t = timer; timer = null; t?.f(); },
  };
}

describe("SyncFrameGate", () => {
  it("text outside a synchronized frame passes at once", () => {
    const r = rig();
    r.gate.push("hello ");
    r.gate.push("world");
    expect(r.out).toEqual(["hello ", "world"]);
    expect(r.timer()).toBeNull();
  });

  it("a whole frame passes in one release", () => {
    const r = rig();
    r.gate.push(`a${BSU}frame${ESU}b`);
    expect(r.out).toEqual([`a${BSU}frame${ESU}b`]);
    expect(r.timer()).toBeNull();
  });

  it("a frame split across pushes is held until its end, then released WHOLE", () => {
    const r = rig();
    r.gate.push(`before${BSU}fr`);
    expect(r.text()).toBe("before");
    r.gate.push("am");
    expect(r.text()).toBe("before");
    r.gate.push(`e${ESU}after`);
    expect(r.out).toEqual(["before", `${BSU}frame${ESU}after`]);
    expect(r.timer()).toBeNull();
  });

  it("back-to-back frames: a push never ends a release inside a frame", () => {
    const r = rig();
    const frames = Array.from({ length: 5 }, (_, i) => `${BSU}F${i}:${"x".repeat(40)}${ESU}`).join("");
    for (let i = 0; i < frames.length; i += 7) r.gate.push(frames.slice(i, i + 7));
    expect(r.text()).toBe(frames);
    for (const t of r.out) {
      // Every release ends outside a frame: the last marker in it (if any) is an end.
      const last = Math.max(t.lastIndexOf(BSU), t.lastIndexOf(ESU));
      if (last >= 0) expect(t.startsWith(ESU, last)).toBe(true);
    }
  });

  it("the marker itself split across pushes still opens and closes the frame", () => {
    const r = rig();
    r.gate.push("x\x1b[?20");
    expect(r.text()).toBe("x");
    r.gate.push("26hbody\x1b[?202");
    expect(r.text()).toBe("x");
    r.gate.push("6ly");
    expect(r.text()).toBe(`x${BSU}body${ESU}y`);
  });

  it("a lone trailing ESC or CSI prefix is held only until the next push", () => {
    const r = rig();
    r.gate.push("a\x1b");
    expect(r.text()).toBe("a");
    r.gate.push("[1mb");
    expect(r.text()).toBe("a\x1b[1mb");
  });

  it("the C1 introducer opens a frame as xterm.js reads it", () => {
    const r = rig();
    r.gate.push("a\u009b?2026hb");
    expect(r.text()).toBe("a");
    r.gate.push("\u009b?2026lc");
    expect(r.text()).toBe("a\u009b?2026hb\u009b?2026lc");
  });

  it("2026 among other modes in one DECSET counts", () => {
    const r = rig();
    r.gate.push("a\x1b[?25;2026hb");
    expect(r.text()).toBe("a");
    r.gate.push("\x1b[?2026;25l");
    expect(r.text()).toBe("a\x1b[?25;2026hb\x1b[?2026;25l");
  });

  it("other modes and the DECRQM query do not open a frame", () => {
    const r = rig();
    r.gate.push("\x1b[?1049h\x1b[?20260h\x1b[?2026$p\x1b[2026h");
    expect(r.text()).toBe("\x1b[?1049h\x1b[?20260h\x1b[?2026$p\x1b[2026h");
    expect(r.timer()).toBeNull();
  });

  it("a soft reset or a full reset ends the frame, as it does in xterm.js", () => {
    for (const reset of ["\x1b[!p", "\x1bc"]) {
      const r = rig();
      r.gate.push(`${BSU}a`);
      expect(r.text()).toBe("");
      r.gate.push(`${reset}b`);
      expect(r.text()).toBe(`${BSU}a${reset}b`);
      expect(r.timer()).toBeNull();
    }
  });

  it("an end with no frame open is plain text", () => {
    const r = rig();
    r.gate.push(`${ESU}a`);
    expect(r.text()).toBe(`${ESU}a`);
  });

  it("a frame that never ends is released at the cap, and what follows passes", () => {
    const r = rig();
    r.gate.push(`a${BSU}b`);
    expect(r.timer()?.ms).toBe(SYNC_FRAME_HOLD_MS);
    r.gate.push("c");
    expect(r.armed()).toBe(1);                         // the cap runs from when the hold STARTED
    r.fire();
    expect(r.text()).toBe(`a${BSU}bc`);
    r.gate.push(`d${ESU}e`);
    expect(r.text()).toBe(`a${BSU}bcd${ESU}e`);
    expect(r.timer()).toBeNull();
  });

  it("each new frame gets its own cap", () => {
    const r = rig();
    r.gate.push(`${BSU}a`);
    r.gate.push(`${ESU}${BSU}b`);
    expect(r.text()).toBe(`${BSU}a${ESU}`);
    expect(r.armed()).toBe(2);
  });

  it("dispose drops what is held and its timer", () => {
    const r = rig();
    r.gate.push(`a${BSU}b`);
    r.gate.dispose();
    expect(r.timer()).toBeNull();
    r.gate.push("c");
    expect(r.text()).toBe("a");
  });

  it("a device query inside a frame ends the hold at once — its answer is never delayed", () => {
    for (const q of ["\x1b[6n", "\x1b[c", "\x1b[>c", "\x1b[?2026$p", "\x1b[18t", "\x1bP$qm\x1b\\",
                     "\x1b]11;?\x07", "\u009b6n", "\u0090$qm\u009c", "\u009d10;?\u009c"]) {
      const r = rig();
      r.gate.push(`a${BSU}b`);
      expect(r.text()).toBe("a");
      r.gate.push(`c${q}d`);
      expect(r.text(), JSON.stringify(q)).toBe(`a${BSU}bc${q}d`);
      expect(r.timer()).toBeNull();
      r.gate.push(`e${ESU}f`);                       // the rest of that frame passes
      expect(r.text()).toBe(`a${BSU}bc${q}de${ESU}f`);
      r.gate.push(`${BSU}g`);                        // and the NEXT frame is held again
      expect(r.text()).toBe(`a${BSU}bc${q}de${ESU}f`);
    }
  });

  it("a query split across pushes inside a frame still ends the hold", () => {
    const r = rig();
    r.gate.push(`${BSU}x\x1b]11`);
    r.gate.push(";?\x07y");
    expect(r.text()).toBe(`${BSU}x\x1b]11;?\x07y`);
  });

  // `CSI ? u` is not here: the HOST answers it for every tab (docs/terminal.md), so holding it on the
  // client delays nothing.
  it("text that only looks like a query does not end the hold", () => {
    const r = rig();
    r.gate.push(`${BSU}\x1b[1m\x1b[2J\x1b]0;title\x07\x1b[?25h`);
    expect(r.text()).toBe("");
  });

  it("holding a long frame copies linearly, not per piece", () => {
    const r = rig();
    const f = `${BSU}${"z".repeat(2_000_000)}${ESU}`;
    const t0 = performance.now();
    for (let i = 0; i < f.length; i += 48) r.gate.push(f.slice(i, i + 48));
    expect(r.out).toEqual([f]);
    expect(performance.now() - t0).toBeLessThan(1000);
  });

  it("a long frame in tiny pieces is released whole and exactly once", () => {
    const r = rig();
    const body = "y".repeat(50_000);
    const f = `${BSU}${body}${ESU}`;
    for (let i = 0; i < f.length; i += 3) r.gate.push(f.slice(i, i + 3));
    expect(r.out).toEqual([f]);
  });
});
