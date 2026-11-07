import { describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { holdShiftRows } from "../src/client/hold-shift";

/// WHILE A RESIZE IS HELD, THE PICTURE SITS WHERE THE HOST WILL PUT IT (docs/terminal.md, "A held resize keeps the
/// picture where the host will put it"): the prediction, and — the part that makes it a prediction rather than a
/// guess — xterm.js's OWN resize agreeing with it, row for row (SwiftTerm's is a port of it).
describe("holdShiftRows", () => {
  const base = { scrollback: 100, alt: false, tmux: false, drawnBelow: false };

  it("the keyboard comes up over a prompt at the bottom: everything moves up by the rows lost (bottom-aligned)", () => {
    expect(holdShiftRows({ ...base, rowsOld: 40, rowsNew: 22, cursorY: 39 })).toBe(-18);
  });

  it("over a fresh shell's prompt near the top: the empty rows below go, and nothing moves", () => {
    expect(holdShiftRows({ ...base, rowsOld: 40, rowsNew: 22, cursorY: 3 })).toBe(0);
    expect(holdShiftRows({ ...base, rowsOld: 40, rowsNew: 22, cursorY: 30 }), "partly: 9 rows below the cursor go").toBe(-9);
  });

  it("the keyboard goes: lines come back from the scrollback — under xterm.js/SwiftTerm only with the cursor on the last row", () => {
    expect(holdShiftRows({ ...base, rowsOld: 22, rowsNew: 40, cursorY: 21 })).toBe(18);
    expect(holdShiftRows({ ...base, rowsOld: 22, rowsNew: 40, cursorY: 21, scrollback: 5 }), "only what there is").toBe(5);
    expect(holdShiftRows({ ...base, rowsOld: 22, rowsNew: 40, cursorY: 10 })).toBe(0);
    expect(holdShiftRows({ ...base, rowsOld: 22, rowsNew: 40, cursorY: 10, tmux: true }), "tmux pulls whenever it has history").toBe(18);
  });

  it("a full-screen program is bottom-aligned both ways; an unchanged grid moves nothing", () => {
    expect(holdShiftRows({ ...base, alt: true, rowsOld: 40, rowsNew: 22, cursorY: 0 })).toBe(-18);
    expect(holdShiftRows({ ...base, alt: true, rowsOld: 22, rowsNew: 40, cursorY: 0 })).toBe(18);
    expect(holdShiftRows({ ...base, rowsOld: 40, rowsNew: 40, cursorY: 39 })).toBe(0);
  });

  it("something drawn below the cursor — an agent's rules and footer — is the agent's to draw again: bottom-aligned", () => {
    expect(holdShiftRows({ ...base, rowsOld: 18, rowsNew: 10, cursorY: 13, drawnBelow: true })).toBe(-8);
    expect(holdShiftRows({ ...base, rowsOld: 18, rowsNew: 10, cursorY: 13 }), "as blank rows: 4 fewer").toBe(-4);
  });

  /// CLAUDE CODE, as it sat on the dev Mac's 18-row pane (2026-10-06, `tmux capture-pane`): its input box above its
  /// rule, footer, update line and a blank row — the cursor 4 rows from the bottom. On a resize the emulator drops
  /// those 4 rows; on SIGWINCH Claude Code erases its interface from the rule above its input and draws it again,
  /// the cursor back in the input. Where does the conversation's last line end up?
  it("agrees with an agent's redraw after xterm.js's resize: Claude Code's layout ends bottom-aligned", async () => {
    const live = ["─".repeat(30), "❯ ", "─".repeat(30), "  ⏵⏵ auto mode on", "          ✔ Update installed", ""];
    for (const rowsNew of [10, 14, 16]) {
      const term = new Terminal({ cols: 30, rows: 18, scrollback: 1000, allowProposedApi: true });
      const write = (s: string) => new Promise<void>((r) => term.write(s, r));
      await write(Array.from({ length: 40 }, (_, i) => `talk ${i}`).join("\r\n") + "\r\n" + live.join("\r\n") + `\x1b[${live.length - 2}A\r\x1b[2C`);
      const b = term.buffer.active;
      const row = (text: string) => { const a = term.buffer.active; for (let y = 0; y < term.rows; y++) if (a.getLine(a.viewportY + y)!.translateToString(true) === text) return y; return -1; };
      const before = row("talk 39");
      let drawnBelow = false;
      for (let y = b.cursorY + 1; y < term.rows; y++) drawnBelow ||= b.getLine(b.viewportY + y)!.translateToString(true).trim() !== "";
      expect([b.cursorY, drawnBelow], "the layout as measured: the cursor 4 rows up, the footer below it").toEqual([13, true]);
      const predicted = holdShiftRows({ rowsOld: 18, rowsNew, cursorY: b.cursorY, scrollback: b.baseY, alt: false, tmux: false, drawnBelow });
      term.resize(30, rowsNew);
      await write("\x1b[1A\r\x1b[J" + live.join("\r\n") + `\x1b[${live.length - 2}A\r\x1b[2C`);   // the agent's redraw
      expect(predicted, `18→${rowsNew}`).toBe(row("talk 39") - before);
      term.dispose();
    }
  });

  /// Where row `r`'s text sits after xterm.js resizes from `rowsOld` to `rowsNew` — the emulator itself, so the
  /// prediction is checked against the thing it predicts.
  async function moved(rowsOld: number, rowsNew: number, lines: number, cursorUp: number): Promise<{ predicted: number; actual: number }> {
    const term = new Terminal({ cols: 30, rows: rowsOld, scrollback: 1000, allowProposedApi: true });
    const out = Array.from({ length: lines }, (_, i) => `L${i}`).join("\r\n");
    await new Promise<void>((r) => term.write(out + (cursorUp ? `\x1b[${cursorUp}A` : ""), r));
    const b = term.buffer.active;
    const marker = b.getLine(b.viewportY + b.cursorY)!.translateToString(true);   // the text on the cursor's row
    const before = b.cursorY;
    const predicted = holdShiftRows({ rowsOld, rowsNew, cursorY: b.cursorY, scrollback: b.baseY, alt: false, tmux: false, drawnBelow: false });
    term.resize(30, rowsNew);
    const a = term.buffer.active;
    let after = -1;
    for (let y = 0; y < rowsNew; y++) if (a.getLine(a.viewportY + y)!.translateToString(true) === marker) after = y;
    term.dispose();
    return { predicted, actual: after - before };
  }

  it("agrees with xterm.js's own resize: shrinking and growing, the cursor at the bottom, mid-screen and near the top", async () => {
    for (const [rowsOld, rowsNew, lines, up] of [
      [40, 22, 200, 0], [40, 22, 200, 25], [40, 22, 200, 35], [40, 22, 5, 0],   // shrink: bottom, mid, near the top, a fresh shell
      [22, 40, 200, 0], [22, 40, 30, 0], [22, 40, 200, 8], [22, 40, 10, 0],     // grow: bottom, little history, mid, none
    ] as const) {
      const r = await moved(rowsOld, rowsNew, lines, up);
      expect(r.predicted, `${rowsOld}→${rowsNew}, ${lines} lines, cursor up ${up}`).toBe(r.actual);
    }
  });
});
