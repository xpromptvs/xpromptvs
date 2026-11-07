// EVERY SEQUENCE xterm.js 6 CAN ANSWER, FOUND BY WALKING ITS OWN REGISTERED HANDLERS (docs/terminal.md,
// "The send buffer": device queries are never held).
//
// The host's send buffer holds a tab's output up to 8 ms, and a query held there can lose its answer
// to a pause or a new wire (a snapshot carries no query). The measured client set
// (`term-client-queries.test.ts`) covers the CANDIDATES someone thought of; this covers the rest: it
// walks every CSI, ESC, DCS and OSC handler xterm.js 6 registers, drives each with a battery of
// parameters on an instance that permits EVERYTHING (all `windowOptions` on — the product enables
// none, but an option change must not reopen the hole), and records which ones ever answered. The
// committed `protocol/fixtures/term-reply-handlers.json` must say exactly that; the Swift suite
// (`TermReplyHandlersFixtureTests`) asserts the host's "never hold" rule covers every handler here
// that answers — for every parameter — and that it is not simply "every sequence".
//
// Regenerate with `RDEV_WRITE_TERM_QUERIES=1 npx vitest run test/term-reply-handlers.test.ts`, then
// read the diff. An xterm.js upgrade that adds a reply fails here first.
import { beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readFileSync, writeFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";
import { Terminal } from "@xterm/xterm";

declare const process: { env: Record<string, string | undefined> };

const FIXTURE = resolve(dirname(fileURLToPath(import.meta.url)), "../../protocol/fixtures/term-reply-handlers.json");
const E = "\x1b", ST = "\x1b\\", BEL = "\x07";
// A focus report is not an answer: xterm.js emits one from inside `CSI ? 1004 h` (`term-replies.ts`).
const FOCUS_REPORTS = new Set([`${E}[I`, `${E}[O`]);

/// Parameters every CSI handler is driven with: none, 0-30 (every DSR, DA, window op, mode number
/// under 31), the modes and window ops above that, and the two-parameter forms that gate answers.
export const CSI_PARAMS = ["", ...Array.from({ length: 31 }, (_, i) => String(i)),
  "47", "66", "67", "1000", "1004", "1006", "1047", "1048", "1049", "2004", "2026", "9999",
  "14;2", "22;0", "23;0", "6;1", "0;0"];

interface Internals {
  _core: { _inputHandler: { _parser: {
    _csiHandlers: Record<string, unknown[]>;
    _escHandlers: Record<string, unknown[]>;
    _dcsParser: { _handlers: Record<string, unknown[]> };
    _oscParser: { _handlers: Record<string, unknown[]> };
    identToString(ident: number): string;
  } } };
}

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

const ALL_WINDOW_OPTIONS = Object.fromEntries([
  "restoreWin", "minimizeWin", "setWinPosition", "setWinSizePixels", "raiseWin", "lowerWin", "refreshWin",
  "setWinSizeChars", "maximizeWin", "fullscreenWin", "getWinState", "getWinPosition", "getWinSizePixels",
  "getScreenSizePixels", "getCellSizePixels", "getWinSizeChars", "getScreenSizeChars", "getIconTitle",
  "getWinTitle", "pushTitle", "popTitle", "setWinLines",
].map((k) => [k, true]));

function openTerminal(): { term: Terminal; replies: string[]; dispose(): void } {
  const el = document.createElement("div");
  document.body.append(el);
  const term = new Terminal({ allowProposedApi: true, windowOptions: ALL_WINDOW_OPTIONS });
  term.open(el);
  const replies: string[] = [];
  term.onData((d) => { if (!FOCUS_REPORTS.has(d)) replies.push(d); });
  return { term, replies, dispose: () => { term.dispose(); el.remove(); } };
}

const write = (t: Terminal, s: string) => new Promise<void>((r) => t.write(s, r));
const settle = () => new Promise((r) => setTimeout(r, 0));

/// `prefix`/`intermediates`/`final` of a handler identifier (xterm.js packs them a byte each).
function split(ident: string): { prefix: string; intermediates: string; final: string } {
  const final = ident.slice(-1);
  let head = ident.slice(0, -1);
  let prefix = "";
  if (head && head.charCodeAt(0) >= 0x3c && head.charCodeAt(0) <= 0x3f) { prefix = head.slice(0, 1); head = head.slice(1); }
  return { prefix, intermediates: head, final };
}

async function answers(build: (p: string) => string, params: string[]): Promise<boolean> {
  for (const p of params) {
    const t = openTerminal();
    await write(t.term, `a${build(p)}b${E}[m`);
    await settle();
    const answered = t.replies.length > 0;
    t.dispose();
    if (answered) return true;
  }
  return false;
}

describe("the sequences xterm.js 6 can answer, walked from its registered handlers", () => {
  it("match the committed fixture the host's never-hold rule is tested against", async () => {
    const probe = openTerminal();
    const parser = (probe.term as unknown as Internals)._core._inputHandler._parser;
    const idents = (table: Record<string, unknown[]>) =>
      Object.keys(table).filter((k) => (table[k]?.length ?? 0) > 0).map((k) => parser.identToString(Number(k))).sort();
    const csi = idents(parser._csiHandlers);
    const esc = idents(parser._escHandlers);
    const dcs = idents(parser._dcsParser._handlers);
    const osc = Object.keys(parser._oscParser._handlers).filter((k) => (parser._oscParser._handlers[k]?.length ?? 0) > 0)
      .map(Number).sort((a, b) => a - b);
    probe.dispose();
    // Not vacuous: the walk reached the tables (xterm.js 6 registers ~50 CSI handlers).
    expect(csi.length).toBeGreaterThan(40);
    expect(osc).toContain(11);
    expect(dcs).toContain("$q");

    const result = { csi: { answer: [] as string[], silent: [] as string[] }, esc: { answer: [] as string[], silent: [] as string[] },
      dcs: { answer: [] as string[], silent: [] as string[] }, osc: { answer: [] as number[], silent: [] as number[] } };
    for (const id of csi) {
      const { prefix, intermediates, final } = split(id);
      (await answers((p) => `${E}[${prefix}${p}${intermediates}${final}`, CSI_PARAMS) ? result.csi.answer : result.csi.silent).push(id);
    }
    for (const id of esc) {
      (await answers(() => `${E}${id}`, [""]) ? result.esc.answer : result.esc.silent).push(id);
    }
    for (const id of dcs) {
      const { prefix, intermediates, final } = split(id);
      (await answers((d) => `${E}P${prefix}${intermediates}${final}${d}${ST}`, ["", "m", "r", " q", "xyz"]) ? result.dcs.answer : result.dcs.silent).push(id);
    }
    for (const id of osc) {
      (await answers((d) => `${E}]${id}${d}${BEL}`, ["", ";?", ";1;?", ";?;?", ";1"]) ? result.osc.answer : result.osc.silent).push(id);
    }

    const measured = { "xterm.js": "6.0.0, every windowOptions on", generated: "web/test/term-reply-handlers.test.ts",
      csiParams: CSI_PARAMS, ...result };
    if (process.env.RDEV_WRITE_TERM_QUERIES === "1") writeFileSync(FIXTURE, JSON.stringify(measured, null, 2) + "\n");
    expect(JSON.parse(readFileSync(FIXTURE, "utf8"))).toEqual(measured);
  }, 120_000);
});
