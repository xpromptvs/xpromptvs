import { isRequestedTab, type OpenRequest } from "./term-view-policy";
import type { TermListMsg } from "./terminal-tabs";

/// **THE TERMINAL THE DRIVER JUST PICKED, SHOWN AT ONCE** (2026-10-04; docs/client-web.md, "A picked terminal's
/// tab shows at once"). A pick in the palette (or the empty terminal's buttons) closed the palette onto the OLD
/// tab, and the new one appeared a round trip later with the host's `term-list` — two steps. Now the tab is in
/// the strip, selected, and the deck shows it, in the same tick as the palette closes; its content follows as
/// the host's snapshot commits (and fades in, `TermDeck.watchFirstContent`).
///
/// `key`: the tab's id when it is known — `open-tmux` names its session — else a PLACEHOLDER (`placeholderKey`)
/// until the host's list names the tab it made (`resolveOpening`), whose element the strip then RE-KEYS in place
/// (`TerminalTabs.rekey`). `req`: what the deck's focus expectation and the resolution both match on.
export interface OpeningTab { key: string; label: string; req: OpenRequest }

/// How long an opening tab waits for the host to list it before it is taken away again — a refusal comes as
/// `term-error`/`tmux-error` and takes it at once; this is for an answer that never comes.
export const OPENING_MS = 5000;

/// A key no host id can be: no `pty:` or `tmux:` prefix.
export function placeholderKey(seq: number): string { return `opening:${seq}`; }

/// The host's tab the opening one turned out to be, once a `term-list` names it — for `open-tmux`, its own id;
/// for a new tab, the first listed tab of that kind this client did not know when it asked (`isRequestedTab`).
/// Null while none is.
export function resolveOpening(o: OpeningTab, tl: TermListMsg): string | null {
  const req = o.req;
  if ("id" in req) return tl.tabs.some((t) => t.id === req.id) ? req.id : null;
  return tl.tabs.find((t) => isRequestedTab(req, t.id, true))?.id ?? null;
}

/// The strip's list: the host's, with the opening tab after its tabs while the host has not listed it.
/// `activeId` is the tab the strip selects — the deck's shown one, which is the opening tab right after a pick.
export function withOpening(tl: TermListMsg, o: OpeningTab | null, activeId: string | null): TermListMsg {
  if (!o || tl.tabs.some((t) => t.id === o.key)) return { tabs: tl.tabs, activeId };
  return { tabs: [...tl.tabs, { id: o.key, n: 0, title: o.label }], activeId };
}

/// What a new shell's tab will most likely be called until its title says otherwise: "Terminal N", one past the
/// highest ordinal the host has listed (ordinals are never reused, so a closed higher one makes it a guess the
/// host's label corrects).
export function predictedShellLabel(tl: TermListMsg): string {
  return `Terminal ${tl.tabs.reduce((m, t) => Math.max(m, t.n), 0) + 1}`;
}
