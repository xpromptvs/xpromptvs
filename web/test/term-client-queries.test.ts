// THE SET OF DEVICE QUERIES THE CLIENT ANSWERS, MEASURED (docs/terminal.md, "Who answers").
//
// The host leaves a query to the client only if the client's xterm.js — configured EXACTLY as the
// product configures it (`mountXterm`, a real opened instance) — answers it, and owes the client one
// accepted `term-reply` per answer it gives; every other query the host answers itself, for every tab.
// So the host's classifier (`StreamingQueryStripper.scan`, Swift) must agree with THIS xterm.js on every
// query either side recognises. This test measures each candidate against the real thing and requires
// the committed fixture `protocol/fixtures/term-client-queries.json` to say exactly that; the Swift suite
// (`TermClientQueriesFixtureTests`) asserts its classifier against the same file. An xterm.js upgrade
// or an option change that alters an answer fails here first. Regenerate with
// `RDEV_WRITE_TERM_QUERIES=1 npx vitest run test/term-client-queries.test.ts`, then read the diff.
//
// Every answer must also be CLASSED as a reply (`splitReplies`) — none may leak out as typing.
//
// The fixture also records each candidate's ANSWERS (the bytes, dark theme, cursor after the leading
// `a`) and the PALETTE xterm.js reports with no theme and with each of the product's themes: the host
// answers the queries a tmux tab leaves for the client when their bytes reach no client
// (`TermHostReplies`), and `TermClientQueriesFixtureTests` holds its bytes to these. `xtermPalette`
// — what the client sends the host (`term-palette`) — must equal the measured palette per theme.
import { beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readFileSync, writeFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";

declare const process: { env: Record<string, string | undefined> };
import { Terminal } from "@xterm/xterm";
import { mountXterm, xtermCubeColor, xtermPalette, XTERM_DEFAULT_PALETTE, type TermPalette } from "../src/client/xterm-view";

const FIXTURE = resolve(dirname(fileURLToPath(import.meta.url)), "../../protocol/fixtures/term-client-queries.json");
const E = "\x1b", ST = "\x1b\\", BEL = "\x07";

/// Every query-like sequence either side recognises: xterm.js's reply handlers (DA, DSR, DECRQM,
/// DECRQSS, OSC colour), what SwiftTerm answers (window ops, kitty keyboard, XTVERSION, DECRQCRA,
/// XTGETTCAP), the parameter forms that decide whether each is answered, and how strings END (BEL, ST,
/// the next sequence's ESC, CAN/SUB). Each is written as `a<q>b ESC[m` — the closing ESC ends a string
/// left open, so a DCS "ended" by BEL is measured as a real stream answers it.
export const CANDIDATES = [
  `${E}[c`, `${E}[0c`, `${E}[1c`, `${E}[>c`, `${E}[>0c`, `${E}[>1c`, `${E}[=c`, `${E}[?c`,
  `${E}[5n`, `${E}[6n`, `${E}[0n`, `${E}[3n`, `${E}[6;9n`, `${E}[?6n`, `${E}[?15n`, `${E}[?25n`, `${E}[?26n`, `${E}[?53n`,
  `${E}[4$p`, `${E}[20$p`, `${E}[99$p`, `${E}[?25$p`, `${E}[?1049$p`, `${E}[?2026$p`, `${E}[?9999$p`,
  `${E}P$qm${ST}`, `${E}P$qr${ST}`, `${E}P$q q${ST}`, `${E}P$qxyz${ST}`, `${E}P$qm${BEL}`, `${E}P+q544e${ST}`,
  `${E}[>q`, `${E}[>0q`, `${E}[?u`, `${E}[1;1;1;1;1;1*y`,
  `${E}[11t`, `${E}[13t`, `${E}[14t`, `${E}[14;2t`, `${E}[15t`, `${E}[16t`, `${E}[18t`, `${E}[19t`, `${E}[20t`, `${E}[21t`, `${E}[22;0t`,
  `${E}]4;1;?${BEL}`, `${E}]4;1;?;2;?${BEL}`, `${E}]4;1;?${ST}`, `${E}]4;256;?${BEL}`, `${E}]4;1;#ff0000${BEL}`,
  `${E}]10;?${BEL}`, `${E}]11;?${BEL}`, `${E}]12;?${BEL}`, `${E}]10;?;?${BEL}`, `${E}]11;?;?;?${BEL}`, `${E}]12;?;?${BEL}`,
  `${E}]10;rgb:ff/00/00${BEL}`, `${E}]104;1${BEL}`, `${E}]110${BEL}`,
  // Past the 16 themed colours: xterm.js's fixed cube and grey ramp.
  `${E}]4;0;?;15;?;16;?;231;?;232;?;255;?${BEL}`,
  // Strings ended by the NEXT sequence's ESC, or aborted by CAN/SUB; a DCS runs on past a BEL.
  `${E}]0;t${E}[6n`, `${E}]11;?${E}[m`, `${E}P$qm${BEL}xx${E}[m`, `${E}]11;?\x18`, `${E}]4;1;?\x1a`, `${E}P$qm\x18`,
  // The ESC state and bodies: an ESC restarts a sequence; a C0 byte is executed in place (never a final,
  // never a parameter); C0 is dropped from an OSC body and a DCS header; a byte >= 0x80 aborts a CSI.
  `${E}${E}[6n`, `${E}(${E}[6n`, `${E}\r[6n`, `${E}[\r6n`, `${E}[?\r6n`, `${E}P\n$qm${ST}`, `${E}]11;\n?${BEL}`,
  `${E}[é6n`, `${E}[6\x7fn`,
  // The CSI grammar of xterm.js 6's table: a private marker only first (later ones make the CSI
  // ignored), digits clamped rather than wrapped, an OSC identifier digits only, a DCS prefix part of
  // the handler's identity.
  `${E}[6?n`, `${E}[?6?n`, `${E}[99999999999999999999c`, `${E}[6:1n`, `${E}[$1p`, `${E}]+11;?${BEL}`, `${E}P?$qm${ST}`,
  `${E}P1$qm${ST}`, `${E}]4;0001;?${BEL}`,
  // OSC 4 index slots xterm.js refuses (a sign, a space, a letter, empty) and a pair whose query slot is
  // not exactly `?`: it answers NONE of them — SwiftTerm answers each from its own palette, so a host
  // answering a `pty:` tab's colour query must not pass that through.
  `${E}]4;-1;?${BEL}`, `${E}]4; 1;?${BEL}`, `${E}]4;x;?${BEL}`, `${E}]4;;?${BEL}`, `${E}]4;x;?;?${BEL}`,
  `${E}]4;1;;?;?${BEL}`, `${E}]4;1;?x;?${BEL}`,
  // 8-bit C1, as code points after UTF-8 decoding (the client decodes with TextDecoder): U+009B CSI,
  // U+009D OSC, U+0090 DCS, U+009C ST are introducers and terminators in EVERY state; any other C1
  // aborts a sequence (an OSC or DCS it interrupts is never answered) — docs/terminal.md, "8-bit C1".
  `\u009b6n`, `\u009bc`, `\u009b?25$p`, `\u009b>c`, `\u009d11;?${BEL}`, `\u009d11;?\u009c`, `${E}]11;?\u009c`,
  `\u0090$qm\u009c`, `${E}P$qm\u009c`, `\u0090$qm${ST}`, `${E}\u009b6n`, `${E}[\u009b6n`, `${E}]0;t\u009b6n`,
  `${E}]11;?\u0085`, `${E}]11;?\u009b`, `${E}]11;?\u009d11;?${BEL}`, `${E}[6\u0085n`, `\u0098x${E}[6n`,
  `\u009e\u009b6n`, `${E}P$qm\u0085${ST}`, `${E}P$qm\u009b6n`, `${E}(\u009b6n`, `\u009b\u009b6n`,
  `${E}]11;?\u0090$qm${ST}`, `${E}P$qé${ST}`, `${E}Pé$qm${ST}`,
  // COLOUR QUERIES LONGER THAN THE HOST'S 4 KB HOLD: the host answers them (when their bytes reach no
  // client) from the shape its scanner kept, never the bytes — so their answers are measured here too.
  `${E}]4;${"x;".repeat(2100)}1;?;2;?${BEL}`, `${E}]4;${Array.from({ length: 800 }, (_, i) => `${(i * 7) % 256};?`).join(";")}${BEL}`,
  `${E}]10;${"x".repeat(5000)};?${BEL}`, `${E}]12;?;${"y".repeat(5000)}${BEL}`, `${E}]4;${"x;".repeat(2100)}0001;?${E}[m`,
  `\u009d11;${"z".repeat(5000)};?\u009c`, `${E}]10;?;${"w".repeat(5000)};?${ST}`, `${E}]4;${"x;".repeat(2100)}1;?\x18`,
  // C1 DECRQM and DECRQSS after the setting they ask about: in a tmux tab tmux answers neither (it
  // reads bytes), so the host answers them when their bytes reach no client — from tmux's own state
  // (`TerminalManagerTmuxTests.testC1ModeAndSettingQueriesAreAnsweredAsXtermJsAnswersThem`).
  `\u009b?1$p`, `${E}[?1h\u009b?1$p`, `${E}[?6h\u009b?6$p`, `${E}[?7l\u009b?7$p`, `${E}[?25l\u009b?25$p`,
  `${E}=\u009b?66$p`, `${E}[?1049h\u009b?1049$p`, `${E}[?47h\u009b?1047$p`, `${E}[?2004h\u009b?2004$p`,
  `${E}[?2026h\u009b?2026$p`, `${E}[?1000h${E}[?9h\u009b?1000$p`, `${E}[?9h\u009b?9$p`, `${E}[?1003h\u009b?1003$p`,
  `${E}[?1002h${E}[?1006h\u009b?1006$p`, `${E}[?1006h${E}[?1016h\u009b?1016$p`, `${E}[?1004h\u009b?1004$p`,
  `${E}[4h\u009b4$p`, `\u009b2$p`, `\u009b12$p`, `\u009b20$p`, `\u009b9999$p`, `\u009b?9999$p`, `\u009b?3$p`,
  `\u009b?8$p`, `\u009b?67$p`, `\u009b?1005$p`, `\u009b?1015$p`, `\u009b?1048$p`, `\u009b?12$p`,
  `${E}[?12h\u009b?12$p`, `${E}[2 q\u009b?12$p`, `${E}[4 q${E}[?12h\u009b?12$p`, `${E}[?45h\u009b?45$p`,
  `${E}[3;10r\u0090$qr\u009c`, `${E}[5 q\u0090$q q\u009c`, `${E}[2 q\u0090$q q\u009c`, `${E}[?12h\u0090$q q\u009c`,
  `\u0090$q q\u009c`, `\u0090$q"p\u009c`, `${E}[1;31m\u0090$qm\u009c`, `${E}[1"q\u0090$q"q\u009c`, `\u0090$qxyz\u009c`,
  `\u0090$q\u009c`, `\u0090$qr${E}\\`,
  // …where tmux's own formats and xterm.js part ways (measured): tmux ignores DECSTR, `?66h`, `?9h` and
  // `?1016h`; xterm.js reads `?12` and `CSI 20 h` as OPTIONS that DECSCUSR, RIS and DECSTR leave alone.
  `${E}[?7l${E}[!p\u009b?7$p`, `${E}[4h${E}[!p\u009b4$p`, `${E}[?6h${E}[!p\u009b?6$p`, `${E}=${E}[!p\u009b?66$p`,
  `${E}[?66h\u009b?66$p`, `${E}[?45h${E}[!p\u009b?45$p`, `${E}[?12l\u009b?12$p`, `${E}[?12l\u0090$q q\u009c`,
  `${E}[?12l${E}c\u009b?12$p`, `${E}[?12l${E}[1 q\u009b?12$p`, `${E}[20h\u009b20$p`, `${E}[?1000h${E}[?1006h${E}c\u009b?1006$p`,
  // …and a mode changed AFTER the query in the same stream: the answer is the mode where it was asked.
  `\u009b?1$p${E}[?1h`, `${E}[4h\u009b4$p${E}[4l\u009b4$p`,
];

/// INVALID UTF-8 around queries, as HEX: the client decodes the terminal stream with a streaming
/// `TextDecoder` (`term-stream.ts`), which makes every maximal invalid subpart ONE U+FFFD — so these are
/// measured exactly that way, never by handing xterm.js the bytes (its own decoder DROPS an invalid
/// byte, and `ESC [ C2 63` is a DA1 to it: a path the product never takes).
export const BYTE_CANDIDATES = [
  "1b5bc263", "1b509c2471711b5c", "c29b9b63", "1b5d31313b3f8007", "1b5d31313b803f07", "1b5d31313b3fe207",
  "e21b5b366e", "1b5b36e26e", "1b5d343b313b3f1bf05c", "1b5024716dc21b5c", "f09f1b5b356e", "c2c29b366e",
  "eda0801b5b63", "1b5d31313b3f1b5b6e", "1b50e224716d1b5c", "1b5d343b31e23b3f07", "1b5d31303bc0af3b3f07",
  "1b5bf0909080", "c21b5b63", "1b5dc29d31313b3f07",
];

interface Case { q: string; hex?: string; replies: number; answers: string }

beforeAll(() => {
  // jsdom lacks these; the renderer only needs them to exist.
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

async function measure(q: string, hex?: string): Promise<{ replies: string[]; data: string[] }> {
  const el = document.createElement("div");
  document.body.append(el);
  const replies: string[] = [], data: string[] = [];
  const v = mountXterm(el, { onData: (d) => data.push(d), onReply: (d) => replies.push(d), onFit: () => {}, theme: "dark" });
  // The closing ESC ends a string left open, as a real stream would. Bytes go through the client's own
  // decoding: a streaming, non-fatal TextDecoder, exactly as `term-stream.ts` feeds xterm.js.
  await v.writeAsync(hex === undefined ? `a${q}b${E}[m` : decodeAsTheClientDoes(hex));
  await new Promise((r) => setTimeout(r, 0));
  v.dispose(); el.remove();
  return { replies, data };
}

/// `a` + the candidate's bytes + `b ESC [ m`, decoded as `term-stream.ts` decodes the stream.
function decodeAsTheClientDoes(hex: string): string {
  const bytes = new Uint8Array([0x61, ...(hex.match(/../g) ?? []).map((h) => parseInt(h, 16)), 0x62, 0x1b, 0x5b, 0x6d]);
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes, { stream: true });
}

/// The colours an xterm.js REPORTS (OSC 10/11/12 and OSC 4 0-255), as `#rrggbb` — 16-255 recorded only
/// where they differ from xterm.js's fixed cube and greys (`ext`), which is all the host needs to know.
async function reportedPalette(write: (s: string) => Promise<void>, replies: string[]): Promise<TermPalette> {
  const ask = `${E}]10;?${BEL}${E}]11;?${BEL}${E}]12;?${BEL}${E}]4;${Array.from({ length: 256 }, (_, i) => `${i};?`).join(";")}${BEL}`;
  await write(ask);
  await new Promise((r) => setTimeout(r, 0));
  const hex = (r: string) => {
    const m = /rgb:([0-9a-f]{4})\/([0-9a-f]{4})\/([0-9a-f]{4})/.exec(r);
    if (!m) throw new Error(`not a colour report: ${JSON.stringify(r)}`);
    return "#" + m.slice(1).map((c) => c.slice(0, 2)).join("");
  };
  expect(replies.length).toBe(3 + 256);
  const ext: Record<string, string> = {};
  replies.slice(3 + 16).forEach((r, i) => { if (hex(r) !== xtermCubeColor(16 + i)) ext[String(16 + i)] = hex(r); });
  return { fg: hex(replies[0] ?? ""), bg: hex(replies[1] ?? ""), cursor: hex(replies[2] ?? ""),
           ansi: replies.slice(3, 3 + 16).map(hex), ext };
}

async function themedPalette(theme: "dark" | "light"): Promise<TermPalette> {
  const el = document.createElement("div");
  document.body.append(el);
  const replies: string[] = [];
  const v = mountXterm(el, { onData: () => {}, onReply: (d) => replies.push(d), onFit: () => {}, theme });
  const p = await reportedPalette((s) => v.writeAsync(s), replies);
  v.dispose(); el.remove();
  return p;
}

async function defaultPalette(): Promise<TermPalette> {
  const el = document.createElement("div");
  document.body.append(el);
  const replies: string[] = [];
  const t = new Terminal();
  t.open(el);
  t.onData((d) => replies.push(d));
  const p = await reportedPalette((s) => new Promise<void>((r) => t.write(s, r)), replies);
  t.dispose(); el.remove();
  return p;
}

describe("the device queries this client's xterm.js answers", () => {
  it("match the committed fixture the host's classifier is tested against", async () => {
    const cases: Case[] = [];
    for (const q of CANDIDATES) {
      const m = await measure(q);
      // `CSI ? 1004 h` makes xterm.js report the focus at once: a focus report, never a reply.
      const typed = m.data.filter((d) => d !== `${E}[I` && d !== `${E}[O`);
      expect(typed, `an answer to ${JSON.stringify(q)} leaked out as typing`).toEqual([]);
      cases.push({ q, replies: m.replies.length, answers: m.replies.join("") });
    }
    for (const hex of BYTE_CANDIDATES) {
      const m = await measure("", hex);
      expect(m.data, `an answer to ${hex} leaked out as typing`).toEqual([]);
      const q = new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array((hex.match(/../g) ?? []).map((h) => parseInt(h, 16))));
      cases.push({ q, hex, replies: m.replies.length, answers: m.replies.join("") });
    }
    const palettes = { default: await defaultPalette(), dark: await themedPalette("dark"), light: await themedPalette("light") };
    const measured = { "xterm.js": "6.0.0 as configured by web/src/client/xterm-view.ts (no windowOptions)",
      generated: "web/test/term-client-queries.test.ts", palettes, cases };
    if (process.env.RDEV_WRITE_TERM_QUERIES === "1") writeFileSync(FIXTURE, JSON.stringify(measured, null, 2) + "\n");
    expect(JSON.parse(readFileSync(FIXTURE, "utf8"))).toEqual(measured);
  });
});

// CLAUDE CODE'S DIFF BACKGROUNDS ARE THE THEME'S (asked for 2026-09-29: "Map them to ours"). Its diff
// renderer paints with fixed 256-colour slots when it does not see truecolor — removed line 52, removed
// word 88, added line 22, added word 28 — which xterm.js draws as the cube's #5f0000 / #870000 /
// #005f00 / #008700 whatever the theme. Sonokai assigns its OWN diff backgrounds to exactly 22 and 52
// (bg_green #394634, bg_red #55393d); the word slots take the same tint twice as far from Sonokai's
// background. Dark only: Claude Code's light diffs use other slots (194/157/224/217).
describe("the 256-colour slots Claude Code paints diffs with", () => {
  it("are Sonokai's diff backgrounds on the dark theme, and untouched on the light one", () => {
    expect(xtermPalette("dark").ext).toEqual({ "22": "#394634", "28": "#386b50", "52": "#55393d", "88": "#7d484c" });
    expect(xtermPalette("light").ext).toEqual({});
    expect(XTERM_DEFAULT_PALETTE.ext).toEqual({});
  });

  it("leave every other slot on xterm.js's fixed cube and greys", () => {
    expect([16, 21, 22, 52, 196, 231, 232, 255].map(xtermCubeColor))
      .toEqual(["#000000", "#0000ff", "#005f00", "#5f0000", "#ff0000", "#ffffff", "#080808", "#eeeeee"]);
  });
});

describe("the palette the client sends the host (term-palette)", () => {
  it("is exactly what this client's xterm.js reports, per theme, and xterm.js's own until then", async () => {
    expect(xtermPalette("dark")).toEqual(await themedPalette("dark"));
    expect(xtermPalette("light")).toEqual(await themedPalette("light"));
    expect(XTERM_DEFAULT_PALETTE).toEqual(await defaultPalette());
  });
});
