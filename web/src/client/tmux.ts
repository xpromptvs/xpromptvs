
/// A tmux session on the host, as `tmux-list` reports it. `id` is tmux's own session id (`$3`).
export interface TmuxSession { id: string; name: string; windows: number; attached: number }
/// `available: false` means the host found no tmux binary.
export interface TmuxListMsg { available: boolean; sessions: TmuxSession[] }

const isSession = (v: unknown): v is TmuxSession => {
  if (typeof v !== "object" || v === null) return false;
  const s = v as Record<string, unknown>;
  return typeof s.id === "string" && typeof s.name === "string"
    && typeof s.windows === "number" && typeof s.attached === "number";
};

export function parseTmuxList(msg: unknown): TmuxListMsg | null {
  const m = msg as { t?: unknown; available?: unknown; sessions?: unknown } | null;
  if (!m || m.t !== "tmux-list" || typeof m.available !== "boolean"
      || !Array.isArray(m.sessions) || !m.sessions.every(isSession)) return null;
  return { available: m.available, sessions: m.sessions as TmuxSession[] };
}

/// The HOST removed a tmux tab — its session ended or was killed.
export function parseTmuxClosed(msg: unknown): { session: string; reason: string } | null {
  const m = msg as { t?: unknown; session?: unknown; reason?: unknown } | null;
  if (!m || m.t !== "tmux-closed" || typeof m.session !== "string" || typeof m.reason !== "string") return null;
  return { session: m.session, reason: m.reason };
}

/// A tmux request was refused: `unavailable`, `session-gone`, `too-many-tabs`, `failed`.
export function parseTmuxError(msg: unknown): { session: string | null; reason: string } | null {
  const m = msg as { t?: unknown; session?: unknown; reason?: unknown } | null;
  if (!m || m.t !== "tmux-error" || typeof m.reason !== "string") return null;
  if (m.session !== null && typeof m.session !== "string") return null;
  return { session: m.session as string | null, reason: m.reason };
}
