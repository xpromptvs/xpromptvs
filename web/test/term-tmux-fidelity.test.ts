// A TMUX TAB'S RESTORE (docs/terminal.md, "tmux tabs count as tmux does"): for each glyph case, the client's
// tmux-tab xterm.js fed the ORIGINAL stream (what the live tab draws from `%output`) equals one fed tmux's
// own snapshot of it, emitted (protocol/fixtures/tmux-snapshot/, written from a real tmux by
// `bazelisk run //tools/TmuxSnapshotFixtures -- "$PWD/protocol/fixtures"`; HostKit's
// `TmuxSnapshotAgreementTests.testATmuxTabCountsAsTmuxDoes` checks them fresh) —
// and its cursor is tmux's own.
import { beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
import type { Terminal as XTerm } from "@xterm/xterm";
import { captureState, diffStates } from "./lib/xterm-state";
import { loadRdevUnicode, loadTmuxUnicode } from "../src/client/term-unicode";

const FIX = resolve(dirname(fileURLToPath(import.meta.url)), "../../protocol/fixtures");
const manifest = JSON.parse(readFileSync(resolve(FIX, "term-corpus/manifest.json"), "utf8")) as { name: string; cols: number; rows: number }[];
const CASES = ["emoji-widths", "emoji-split", "emoji-margin", "emoji-margin-skin-tone", "grapheme-joins"];

let Terminal: typeof XTerm;
beforeAll(async () => {
  HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;
  ({ Terminal } = await import("@xterm/xterm"));
});

async function stateOf(cols: number, rows: number, bytes: Uint8Array, flavour: "tmux" | "pty") {
  const t = new Terminal({ cols, rows, scrollback: 5000, allowProposedApi: true });
  if (flavour === "tmux") loadTmuxUnicode(t); else loadRdevUnicode(t);
  await new Promise<void>((r) => t.write(bytes, r));
  const s = captureState(t);
  t.dispose();
  // tmux keeps no wrap flag on a SCREEN row (docs/terminal.md, tmux Known limits): not a glyph question.
  // Nor tab stops (restated from tmux's own set; a Known limit of their own, not a glyph question).
  for (const b of [s.normal, s.alt]) if (b) { for (const l of b.lines) l.wrapped = false; b.tabs = []; }
  return s;
}

/// What xterm.js cannot do as tmux does (docs/terminal.md, Known limits). Each must SHOW in its case,
/// and no other difference may:
/// - WIDENED AFTER A SEQUENCE: a VS16 or a flag's second indicator after an SGR gets tmux's columns but
///   a one-column cell and an empty one (the empty one carrying the pen), where tmux's snapshot
///   restores one wide cell;
/// - JAMO: a conjoining vowel or final (U+1160–U+11FF) after a precomposed syllable or a non-Hangul
///   glyph is not in tmux's capture (measured: 가 ᆨ, 가 ᅡ, 각 ᆨ, Y ᅡ); xterm.js keeps every scalar it was
///   sent. EXACTLY that: the restored cell is the live one minus its trailing jamo, same width.
const cellDiff = /^\$\.normal\.lines\.\d+\.cells\.\d+: "\\"(.*)\\":(\d):([^"]*)" ≠ "\\"(.*)\\":(\d):([^"]*)"$/u;
const trailingJamo = /[\u1160-\u11FF]+$/u;
function limitOf(d: string): "widened" | "jamo" | null {
  const m = cellDiff.exec(d);
  if (!m) return null;
  const [, live, lw, , restored, rw] = m;
  if (live === restored && lw === "1" && rw === "2") return "widened";
  if (live === "" && restored === "" && lw === "0" && rw === "0") return "widened";      // its empty cell
  if (lw === rw && trailingJamo.test(live!) && live!.replace(trailingJamo, "") === restored) return "jamo";
  return null;
}
const LIMITS: Record<string, ("widened" | "jamo")[]> = {
  "emoji-split": ["widened", "jamo"],
  "grapheme-joins": ["jamo"],
};

describe("a tmux tab restored from tmux's snapshot equals the live one", () => {
  for (const name of CASES) {
    it(name, async () => {
      const c = manifest.find((m) => m.name === name)!;
      const original = new Uint8Array(readFileSync(resolve(FIX, `term-corpus/${name}.bin`)));
      const emitted = new Uint8Array(readFileSync(resolve(FIX, `tmux-snapshot/${name}.emitted.bin`)));
      const cursor = JSON.parse(readFileSync(resolve(FIX, `tmux-snapshot/${name}.cursor.json`), "utf8")) as { x: number; y: number };
      const live = await stateOf(c.cols, c.rows, original, "tmux");
      expect([live.cursor.x, live.cursor.y], "the live cursor is tmux's").toEqual([cursor.x, cursor.y]);
      const diff = diffStates(live, await stateOf(c.cols, c.rows, emitted, "tmux"), "$", [], 200);
      const limits = LIMITS[name];
      if (limits) {
        const kinds = diff.map(limitOf);
        expect(diff.filter((_, i) => !limits.includes(kinds[i]!))).toEqual([]);
        for (const k of limits) expect(kinds, `${name}: the ${k} limit shows`).toContain(k);
      } else {
        expect(diff).toEqual([]);
      }
    });
  }

  it("negative control: the pty model's client misses tmux's cursor on the tmux-only cases", async () => {
    const off: string[] = [];
    for (const name of CASES) {
      const c = manifest.find((m) => m.name === name)!;
      const original = new Uint8Array(readFileSync(resolve(FIX, `term-corpus/${name}.bin`)));
      const cursor = JSON.parse(readFileSync(resolve(FIX, `tmux-snapshot/${name}.cursor.json`), "utf8")) as { x: number; y: number };
      const s = await stateOf(c.cols, c.rows, original, "pty");
      if (s.cursor.x !== cursor.x || s.cursor.y !== cursor.y) off.push(name);
    }
    expect(off).toEqual(expect.arrayContaining(["emoji-split", "emoji-margin-skin-tone", "grapheme-joins"]));
  });
});
