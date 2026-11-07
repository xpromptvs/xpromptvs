// A REAL xterm.js (no DOM rendering needed: the parser runs without `open()`), so the reply set is the
// one xterm.js actually answers, and a query it answers is proven to arrive as a REPLY — never as typing.
import { beforeAll, describe, expect, it } from "vitest";
import type { Terminal as XTerm } from "@xterm/xterm";
import { splitReplies } from "../src/client/term-replies";
import { mountXterm } from "../src/client/xterm-view";

let Terminal: typeof XTerm;
beforeAll(async () => { ({ Terminal } = await import("@xterm/xterm")); });

function rig() {
  const t = new Terminal({ cols: 80, rows: 24, allowProposedApi: true });
  const data: string[] = [], replies: string[] = [];
  splitReplies(t, { data: (d) => data.push(d), reply: (d) => replies.push(d) });
  const write = (s: string) => new Promise<void>((r) => t.write(s, r));
  return { t, data, replies, write };
}

describe("splitReplies", () => {
  it("every query xterm.js answers arrives as a REPLY", async () => {
    const { replies, data, write } = rig();
    // (CSI 18 t needs `windowOptions`, off by default; OSC 11 is answered by the BROWSER layer, which
    // needs `open()` — both reply from inside the same parse, so the same marks cover them.)
    for (const q of ["\x1b[5n", "\x1b[6n", "\x1b[c", "\x1b[>c", "\x1b[?25$p", "\x1b[4$p", "\x1bP$qm\x1b\\"]) {
      await write(`x${q}y`);
    }
    expect(data).toEqual([]);
    expect(replies).toEqual(["\x1b[0n", "\x1b[1;4R", "\x1b[?1;2c", "\x1b[>0;276;0c", "\x1b[?25;1$y", "\x1b[4;2$y",
      "\x1bP1$r0m\x1b\\"]);
  });

  it("typing is data, including right after a query xterm.js chose not to answer", async () => {
    const { t, replies, data, write } = rig();
    await write("\x1b[2t");                                   // a window op with no reply: marks, answers nothing
    t.input("ls\r");                                          // the user types after that parse ended
    await write("\x1b[5n");
    t.input("\x1b[1;5R");                                     // Ctrl+F3 — byte-identical to a CPR reply
    expect(data).toEqual(["ls\r", "\x1b[1;5R"]);
    expect(replies).toEqual(["\x1b[0n"]);
  });
});

// Fix round M2: a FOCUS REPORT is input, never a reply — even one xterm.js emits from inside a parse
// (`CSI ? 1004 h` reports the current focus at once) in the same batch as a marked query.
describe("splitReplies on the product's opened xterm.js", () => {
  it("a focus report in a batch with a query stays input", async () => {
    (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
    (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
    const el = document.createElement("div"); document.body.append(el);
    const data: string[] = [], replies: string[] = [];
    const v = mountXterm(el, { onData: (d) => data.push(d), onReply: (d) => replies.push(d), onFit: () => {}, theme: "dark" });
    await v.writeAsync("\x1b[c\x1b[?1004h");
    expect(replies).toEqual(["\x1b[?1;2c"]);
    expect(data).toEqual(["\x1b[O"]);
    v.dispose(); el.remove();
  });
});
