import type { Cursor } from "./predictive-echo";

export interface PredictionField {
  kind: "claude" | "codex";
  anchor: Cursor;
  text: string;
  cursor: number;
  capacity: number;
  coverWidth: number;
}

/// Measured against Claude Code 2.1.308 and Codex 0.163.0. These are visual-row
/// adapters, not a parser for either CLI's UI. Process identity alone is insufficient:
/// permission dialogs, completions and quoted prompts must not become editable fields.
/// Both agents WORD-WRAP; a multirow field is ambiguous without logical-line metadata,
/// so only a complete single row is predicted, stopping before a wrap would occur.
export function recognizePredictionField(s: {
  kind: string | undefined; rows: readonly string[]; cursor: Cursor; cols: number;
  dimAt: (row: number, col: number) => boolean;
}): PredictionField | null {
  const { row, col } = s.cursor;
  if (s.kind !== "claude" && s.kind !== "codex") return null;
  if (col < 2 || col >= s.cols || row < 1) return null;
  const line = s.rows[row] ?? "";
  const rule = (v: string | undefined) => v?.trim() === "─".repeat(s.cols);
  if (s.kind === "claude") {
    if (!/^❯[ \u00a0]/.test(line) || !rule(s.rows[row - 1]) || !rule(s.rows[row + 1])) return null;
    // Claude omits the mode shortcut while background shells/agents are active.
    // Its mode label remains; require that known footer or the idle shortcut help,
    // in addition to the foreground process, prompt, cursor and both borders.
    if (!/shift\+tab to cycle|\? for shortcuts|^\s*(?:⏵⏵ (?:auto mode|accept edits|bypass permissions) on|⏸ plan mode on)(?:\s|$)/.test(s.rows[row + 2] ?? "")) return null;
  } else {
    if (!/^› /.test(line) || (s.rows[row + 1] ?? "").trim() !== "") return null;
    if (!/^  (?:GPT-|gpt-|o[134](?: |-|$)).* · /.test(s.rows[row + 2] ?? "")) return null;
    // A visible menu below the composer replaces its normal footer/shortcut rows.
    if (s.rows.slice(row + 3).some(v => v.trim() && !/^\s*(?:← for agents · )?\? for shortcuts\s*$/.test(v))) return null;
  }
  let text = line.slice(2).trimEnd();
  const coverWidth = text.length;
  const cursor = col - 2;
  if (/^[\/@!]/.test(text) || /[^\x20-\x7e]/.test(text)) return null;
  if (cursor === 0 && text) {
    // Never guess a placeholder from its words. A real field positioned with Home is
    // indistinguishable if styling is unavailable; refuse it rather than erase its text.
    if (![...text].every((_, i) => s.dimAt(row, i + 2))) return null;
    text = "";
  }
  text = text.padEnd(cursor, " ");
  if (text.length >= s.cols - 2) return null;
  return { kind: s.kind, anchor: { row, col: 2 }, text, cursor, capacity: s.cols - 3, coverWidth };
}
