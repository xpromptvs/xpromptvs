import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import { expect, test } from "vitest";

function loadSchema(name: string) {
  const ajv = new Ajv({ allErrors: true });
  const path = fileURLToPath(new URL(`../schema/${name}`, import.meta.url));
  return ajv.compile(JSON.parse(readFileSync(path, "utf8")));
}

test("signaling schema accepts valid messages", () => {
  const v = loadSchema("signaling.schema.json");
  expect(v({ t: "hello", role: "host", token: "abc", codecs: ["deflate"] })).toBe(true);
  expect(v({ t: "offer", sdp: "v=0..." })).toBe(true);
  expect(v({ t: "ice", cand: { candidate: "..." } })).toBe(true);
  expect(v({ t: "welcome", sessionId: "s1", turn: { urls: ["turn:x"], username: "u", credential: "c", ttl: 600 } })).toBe(true);
});

test("signaling schema rejects unknown type and missing fields", () => {
  const v = loadSchema("signaling.schema.json");
  expect(v({ t: "nope" })).toBe(false);
  expect(v({ t: "hello", role: "host" })).toBe(false); // missing token
  expect(v({ t: "hello", role: "spectator", token: "x" })).toBe(false); // bad role
});

test("input schema validates touch and key", () => {
  const v = loadSchema("input.schema.json");
  expect(v({ t: "touch", phase: "down", id: 0, x: 0.5, y: 0.5, ts: 1 })).toBe(true);
  expect(v({ t: "key", data: "ls\r", term: "pty:3" })).toBe(true);
  expect(v({ t: "touch", phase: "sideways", id: 0, x: 0, y: 0, ts: 1 })).toBe(false);
  expect(v({ t: "touch", phase: "down", id: 0, x: 2, y: 0, ts: 1 })).toBe(false); // x out of 0..1
});

// `term` names the tab the client believed it was typing into, and the host refuses a keystroke that
// disagrees with the active tab. An unaddressed one is malformed rather than "for whatever is active":
// keystrokes ride `input` while `switch-terminal` rides `control`, so there is no arrival order to
// infer a target from, and a default would silently restore the race the field exists to close.
test("input schema requires a keystroke to name its terminal", () => {
  const v = loadSchema("input.schema.json");
  expect(v({ t: "key", data: "ls\r" })).toBe(false);
  expect(v({ t: "key", data: "ls\r", term: "3" })).toBe(false);
  expect(v({ t: "key", data: "ls\r", term: 0 })).toBe(false);          // the retired numeric id
  expect(v({ t: "key", data: "ls\r", term: "tmux:$4" })).toBe(true);
});

// A device-query REPLY is not a keystroke: it names the tab whose xterm.js instance parsed the query
// (shown or hidden), and the host delivers it there while it owes that tab a reply — so it is its own
// message, and, like a keystroke, malformed without its tab (docs/terminal.md, "Who answers").
test("input schema carries a device-query reply naming its tab", () => {
  const v = loadSchema("input.schema.json");
  expect(v({ t: "term-reply", data: "\u001b[0n", term: "pty:3" })).toBe(true);
  expect(v({ t: "term-reply", data: "\u001b[0n", term: "tmux:$4" })).toBe(true);
  expect(v({ t: "term-reply", data: "\u001b[0n" })).toBe(false);
  expect(v({ t: "term-reply", data: "\u001b[0n", term: 3 })).toBe(false);
});

test("control schema validates resize / ping / pong, and the retired snapshot-request is gone", () => {
  const v = loadSchema("control.schema.json");
  expect(v({ t: "resize", cols: 80, rows: 24 })).toBe(true);
  expect(v({ t: "snapshot-request" })).toBe(false);
  expect(v({ t: "ping", ts: 12 })).toBe(true);
  expect(v({ t: "pong", ts: 12 })).toBe(true);
  expect(v({ t: "resize", cols: -1, rows: 24 })).toBe(false);
});

test("signaling schema rejects welcome with extra junk key in turn", () => {
  const v = loadSchema("signaling.schema.json");
  expect(v({
    t: "welcome",
    sessionId: "s1",
    turn: { urls: ["turn:x"], username: "u", credential: "c", ttl: 600, junk: "bad" },
  })).toBe(false);
});

test("control schema rejects ping with negative ts", () => {
  const v = loadSchema("control.schema.json");
  expect(v({ t: "ping", ts: -1 })).toBe(false);
});

// The DRIVER's xterm.js palette as it REPORTS it (docs/terminal.md, "tmux answers device queries
// itself"): the host answers a tmux tab's colour queries from it when their bytes reach no client.
// Exactly 16 ANSI colours, each colour a lowercase-or-uppercase `#rrggbb` and nothing else.
test("control schema carries the terminal palette", () => {
  const v = loadSchema("control.schema.json");
  const ansi = Array.from({ length: 16 }, () => "#2e3436");
  expect(v({ t: "term-palette", fg: "#ececec", bg: "#000000", cursor: "#ECECEC", ansi })).toBe(true);
  expect(v({ t: "term-palette", fg: "#ececec", bg: "#000000", cursor: "#ececec", ansi: ansi.slice(1) })).toBe(false);
  expect(v({ t: "term-palette", fg: "ececec", bg: "#000000", cursor: "#ececec", ansi })).toBe(false);
  expect(v({ t: "term-palette", fg: "#ececec", bg: "#000000", ansi })).toBe(false);
  expect(v({ t: "term-palette", fg: "#ececec", bg: "#000000", cursor: "#ececec", ansi, extra: 1 })).toBe(false);
});
