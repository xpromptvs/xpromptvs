// WHICH OF AN xterm.js INSTANCE'S OUTGOING DATA IS A DEVICE-QUERY REPLY, NOT TYPING (docs/terminal.md,
// "Who answers a device query").
//
// Every open tab has a live instance, and the host leaves every query whose bytes reached this client
// to the instance that parsed it — hidden or shown — because it cannot know which tab the client shows
// (a switch in flight, a host-opened tab before its term-list). So a hidden instance must answer, and
// its answer must name ITS tab; the host accepts it for that tab while it owes one. Typing is
// different: it names the tab the user SEES and is dropped when that disagrees with the host. The two
// therefore travel as different messages (`term-reply` vs `key`), and have to be told apart here.
//
// xterm.js's `onData` carries both. It emits a reply SYNCHRONOUSLY while parsing the query, from the
// sequence's own handler; nothing a user does can fire in the middle of a parse. So a hook registered
// for every sequence xterm.js answers (DA1, DA2, DSR, DECDSR, DECRQM, OSC 4/10/11/12, DECRQSS — the set
// measured in `protocol/fixtures/term-client-queries.json`, which the host counts credits from) marks
// the parse and returns false so xterm.js's own handler still runs and answers, and the `onData` that
// follows is a reply. The mark lasts until the parse batch ends (`onWriteParsed`), so a query xterm.js
// chose not to answer cannot turn later typing into a "reply". (`onWriteParsed` is skipped while a
// handler returns a Promise; none is registered.) Inside that batch the only other thing xterm.js can
// emit is a FOCUS REPORT (`ESC[I`/`ESC[O`: `CSI ? 1004 h` reports the current focus at once) — input,
// never a reply, so it is excluded by its exact bytes. Window ops (`CSI t`) are not hooked: this
// product enables no `windowOptions`, so xterm.js answers none.
//
// Public API only (`term.parser`), so an xterm.js upgrade that changed it would fail to compile.
import type { IDisposable, Terminal } from "@xterm/xterm";

export interface ReplySink {
  /// Typing, paste, mouse and focus reports — anything not produced by parsing a query.
  data(d: string): void;
  /// A device-query reply this instance produced while parsing its tab's bytes.
  reply(d: string): void;
}

type Parsing = Pick<Terminal, "parser" | "onData" | "onWriteParsed">;

const FOCUS_REPORTS = new Set(["\x1b[I", "\x1b[O"]);

export function splitReplies(term: Parsing, sink: ReplySink): IDisposable {
  let answering = false;
  const mark = () => { answering = true; return false; };
  const p = term.parser;
  const subs: IDisposable[] = [
    // CSI c — DA1, DA2 (`>`); CSI n — DSR (and `?` DECDSR); CSI … $ p — DECRQM (ANSI and `?`). A form
    // xterm.js does not answer (`CSI 1 c`) marks and replies nothing; the mark ends with the batch.
    p.registerCsiHandler({ final: "c" }, mark),
    p.registerCsiHandler({ prefix: ">", final: "c" }, mark),
    p.registerCsiHandler({ final: "n" }, mark),
    p.registerCsiHandler({ prefix: "?", final: "n" }, mark),
    p.registerCsiHandler({ intermediates: "$", final: "p" }, mark),
    p.registerCsiHandler({ prefix: "?", intermediates: "$", final: "p" }, mark),
    // OSC 4 / 10 / 11 / 12 colour queries; DCS $ q — DECRQSS.
    ...[4, 10, 11, 12].map((code) => p.registerOscHandler(code, mark)),
    p.registerDcsHandler({ intermediates: "$", final: "q" }, mark),
    term.onWriteParsed(() => { answering = false; }),
    term.onData((d) => { if (answering && !FOCUS_REPORTS.has(d)) sink.reply(d); else sink.data(d); }),
  ];
  return { dispose: () => { for (const s of subs) s.dispose(); } };
}
