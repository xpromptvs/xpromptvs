import { describe, it, expect } from "vitest";
import { recognizePredictionField } from "../src/client/prediction-field";
const rule = "─".repeat(44);
const claude = ["Claude Code", rule, "❯ abc def", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"];
const codex = ["OpenAI Codex", "", "› abc def", "", "  GPT-6-Astra medium · ~/repo", "  ? for shortcuts"];
const read = (kind: string | undefined, rows: string[], col = 5, row = 2, dim = false) =>
  recognizePredictionField({ kind, rows, cursor: { row, col }, cols: 44, dimAt: () => dim });
describe("known agent composer recognition", () => {
  it("requires foreground identity and the matching layout", () => {
    expect(read(undefined, claude)).toBeNull(); expect(read("codex", claude)).toBeNull();
    expect(read("claude", codex)).toBeNull();
    for (const [kind, rows] of [["claude", claude], ["codex", codex]] as const) {
      expect(read(kind, [...rows])).toMatchObject({ anchor: { row: 2, col: 2 }, text: "abc def", cursor: 3 });
    }
  });
  it("rejects popups, cursor outside, non-ASCII, slash menus and multiline rows", () => {
    expect(read("claude", ["", rule, "❯ /help", rule, claude[4]!])).toBeNull();
    expect(read("claude", claude, 1)).toBeNull();
    expect(read("claude", ["", rule, "❯ hello", "  world", rule, claude[4]!])).toBeNull();
    expect(read("codex", ["", "", "› café", "", codex[4]!])).toBeNull();
    expect(read("codex", ["", "", "› hello", "choose an option", codex[4]!])).toBeNull();
  });
  it("ignores only styled placeholders, never real input under a Home-position cursor", () => {
    expect(read("codex", codex, 2)).toBeNull();
    expect(read("codex", codex, 2, 2, true)).toMatchObject({ text: "", cursor: 0 });
  });
  it("preserves typed spaces before the cursor", () => {
    expect(read("claude", ["", rule, "❯ a  ", rule, claude[4]!], 5)).toMatchObject({ text: "a  ", cursor: 3 });
  });
  it("recognizes Claude's busy composer without the optional mode shortcut", () => {
    for (const footer of [
      "  ⏵⏵ auto mode on · 1 shell · esc to interrupt · ← 2 agents · ↓ to manage",
      "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
      "  ⏵⏵ accept edits on · esc to interrupt",
      "  ⏸ plan mode on · esc to interrupt",
    ]) {
      expect(read("claude", ["", rule, "❯ ", rule, footer], 2)).toMatchObject({ text: "", cursor: 0 });
    }
    expect(read("claude", ["", rule, "❯ ", rule, "  Do you want to proceed?"], 2)).toBeNull();
  });
});
