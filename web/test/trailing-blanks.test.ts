import { describe, it, expect } from "vitest";
import { Terminal } from "@xterm/xterm";
import { TrailingBlanks, cursorViewRow, hiddenRows, lastDrawnRow } from "../src/client/trailing-blanks";

// TRAILING BLANK LINES DO NOT EXIST in an agent's tab (trailing-blanks.ts): the screen's empty rows below its last
// line of content are not scrolled to, so the view ends where the content does. Real xterm.js, unopened — its
// buffer, cursor and scrolling work headless.

// The class looks a microtask after xterm.js's event, never inside it (trailing-blanks.ts, `update`): every step
// lets it run before asserting.
const write = (t: Terminal, s: string) => new Promise<void>((r) => t.write(s, () => setTimeout(r, 0)));
const settled = () => new Promise<void>((r) => setTimeout(r, 0));

/// An agent's screen after a redraw from the top: `history` lines above, then the screen cleared and `content` lines
/// written from its first row, the cursor at the end of the last one — every row below it blank.
async function cleared(t: Terminal, history: number, content: number): Promise<void> {
  for (let i = 0; i < history; i++) await write(t, `h${i}\r\n`);
  await write(t, "\x1b[2J\x1b[H");
  for (let i = 0; i < content; i++) await write(t, `${i ? "\r\n" : ""}c${i}`);
}
const b = (t: Terminal) => t.buffer.active;
const lastVisible = (t: Terminal) => b(t).getLine(b(t).viewportY + t.rows - 1)?.translateToString(true) ?? "";

describe("hiddenRows", () => {
  it("counts the rows below both the last drawn row and the cursor's", () => {
    expect(hiddenRows({ rows: 40, cursorY: 17, lastDrawnRow: 23, baseY: 1874 })).toBe(16);   // the 2026-10-14 tab
    expect(hiddenRows({ rows: 40, cursorY: 30, lastDrawnRow: 23, baseY: 1874 })).toBe(9);    // a prompt below the text
    expect(hiddenRows({ rows: 40, cursorY: 39, lastDrawnRow: 39, baseY: 1874 })).toBe(0);
  });
  it("never more than the scrollback can make up", () => {
    expect(hiddenRows({ rows: 40, cursorY: 3, lastDrawnRow: 3, baseY: 10 })).toBe(10);
    expect(hiddenRows({ rows: 40, cursorY: 3, lastDrawnRow: 3, baseY: 0 })).toBe(0);
  });
  it("an all-blank screen keeps its cursor's row", () => {
    expect(hiddenRows({ rows: 10, cursorY: 0, lastDrawnRow: -1, baseY: 100 })).toBe(9);
  });
});

describe("lastDrawnRow", () => {
  it("is the last row with a glyph — or with a background, which is content too", async () => {
    const t = new Terminal({ cols: 20, rows: 6, allowProposedApi: true });
    await write(t, "a\r\nb\r\n");
    expect(lastDrawnRow(t)).toBe(1);
    await write(t, "\r\n\r\n\x1b[41m   \x1b[0m");          // row 4: three spaces on red
    expect(lastDrawnRow(t)).toBe(4);
    t.dispose();
  });
  it("is -1 on a blank screen", () => {
    const t = new Terminal({ cols: 20, rows: 6, allowProposedApi: true });
    expect(lastDrawnRow(t)).toBe(-1);
    t.dispose();
  });
});

describe("TrailingBlanks", () => {
  const mk = async (history = 50, content = 4) => {
    const t = new Terminal({ cols: 20, rows: 10, scrollback: 1000, allowProposedApi: true });
    const tail = new TrailingBlanks(t);
    await cleared(t, history, content);
    return { t, tail };
  };

  it("an agent's view ends at its last line: the rows below it are not there", async () => {
    const { t, tail } = await mk();
    expect(lastVisible(t)).toBe("");                     // off: the blank rows show, as today
    tail.set(true);
    expect(tail.hidden()).toBe(6);
    expect(b(t).viewportY).toBe(b(t).baseY - 6);
    expect(lastVisible(t)).toBe("c3");
    t.dispose();
  });

  it("follows the content as output fills the rows below it", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    await write(t, "\r\nc4");
    expect(lastVisible(t)).toBe("c4");
    expect(b(t).viewportY).toBe(b(t).baseY - 5);
    t.dispose();
  });

  it("follows the content back up when rows below it are erased", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    await write(t, "\x1b[2K\x1b[A\x1b[2K");              // c3 and c2 erased, the cursor on c2's row
    expect(b(t).viewportY).toBe(b(t).baseY - 7);         // the cursor's row stays: it ends the view
    expect(b(t).getLine(b(t).viewportY + t.rows - 2)?.translateToString(true)).toBe("c1");
    t.dispose();
  });

  it("is never scrolled into the rows that are not there", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    t.scrollToBottom();
    await settled();
    expect(lastVisible(t)).toBe("c3");
    t.scrollLines(3);
    await settled();
    expect(lastVisible(t)).toBe("c3");
    t.dispose();
  });

  it("leaves a view scrolled back where it is when output comes", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    t.scrollLines(-10);
    await settled();
    const at = b(t).viewportY;
    await write(t, "\r\nc4");
    expect(b(t).viewportY).toBe(at);
    t.scrollLines(100);                                  // back down to the end: following again
    await settled();
    await write(t, "\r\nc5");
    expect(lastVisible(t)).toBe("c5");
    t.dispose();
  });

  it("typing brings a scrolled-back view to the content's end, not to the blank rows", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    t.scrollLines(-10);
    t.input("x", true);                                  // xterm.js scrolls to the bottom on user input
    await settled();
    expect(lastVisible(t)).toBe("c3");
    t.dispose();
  });

  it("keeps following at the scrollback cap, where xterm.js trims as it scrolls", async () => {
    const t = new Terminal({ cols: 20, rows: 10, scrollback: 20, allowProposedApi: true });
    const tail = new TrailingBlanks(t);
    await cleared(t, 40, 4);
    tail.set(true);
    for (let i = 0; i < 30; i++) await write(t, `\r\nn${i}`);   // fills the blanks, then scrolls and trims
    expect(lastVisible(t)).toBe("n29");
    await write(t, "\x1b[2J\x1b[Hd0\r\nd1");                   // a redraw from the top again, at the cap
    expect(lastVisible(t)).toBe("d1");
    t.dispose();
  });

  it("…and while the view rests above blank rows: a redraw that scrolls through the bottom and back", async () => {
    const t = new Terminal({ cols: 20, rows: 10, scrollback: 20, allowProposedApi: true });
    const tail = new TrailingBlanks(t);
    await cleared(t, 40, 4);
    tail.set(true);
    // ONE write: twelve lines that scroll the full buffer (xterm.js trims as it goes, holding the view on its
    // content), then the cursor back up five rows and everything below it erased — blank rows again.
    let w = "";
    for (let i = 0; i < 12; i++) w += `\r\nr${i}`;
    await write(t, w + "\x1b[5A\r\x1b[J");
    expect(tail.hidden()).toBe(5);
    expect(b(t).viewportY).toBe(b(t).baseY - 5);
    expect(lastVisible(t)).toBe("");                     // the cursor's row — r6's, erased
    expect(b(t).getLine(b(t).viewportY + t.rows - 2)?.translateToString(true)).toBe("r5");
    t.dispose();
  });

  it("the alternate screen and a mouse-tracking app are left as they are", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    await write(t, "\x1b[?1049h");
    expect(tail.hidden()).toBe(0);
    await write(t, "\x1b[?1049l\x1b[?1000h");
    expect(tail.hidden()).toBe(0);
    expect(lastVisible(t)).toBe("");
    t.dispose();
  });

  it("turned off, a view at the end goes back to the bottom", async () => {
    const { t, tail } = await mk();
    tail.set(true);
    tail.set(false);
    expect(b(t).viewportY).toBe(b(t).baseY);
    expect(tail.end()).toBe(b(t).baseY);
    t.dispose();
  });

  it("a short history makes up what it can, and none changes nothing", async () => {
    const { t, tail } = await mk(12, 4);                 // 3 lines above, 6 blank rows below
    tail.set(true);
    expect(b(t).viewportY).toBe(0);
    const { t: t2, tail: tail2 } = await mk(0, 4);
    tail2.set(true);
    expect(b(t2).viewportY).toBe(0);
    expect(lastVisible(t2)).toBe("");
    t.dispose(); t2.dispose();
  });
});

describe("cursorViewRow (session.ts's cursorTop, which the soft keyboard's shift keeps on screen)", () => {
  it("at the content's end the cursor is drawn as many rows lower as the view rests into the scrollback", () => {
    expect(cursorViewRow({ cursorY: 17, baseY: 1874, viewportY: 1858, hidden: 16 })).toBe(33);
  });
  it("a view at the bottom with nothing hidden is the screen row, as before", () => {
    expect(cursorViewRow({ cursorY: 5, baseY: 100, viewportY: 100, hidden: 0 })).toBe(5);
  });
  it("scrolled back past the end there is no cursor to keep — hidden rows or none", () => {
    expect(cursorViewRow({ cursorY: 17, baseY: 1874, viewportY: 1857, hidden: 16 })).toBeNull();
    expect(cursorViewRow({ cursorY: 5, baseY: 100, viewportY: 99, hidden: 0 })).toBeNull();
  });
});
