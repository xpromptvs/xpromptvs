import type { Terminal } from "@xterm/xterm";
import { WebLinksAddon } from "@xterm/addon-web-links";

/// **A LINK IN THE TERMINAL OPENS** (2026-10-05, reported: "In desktop app, pressing on links in the terminal doesn't
/// seem to do anything"; docs/client-web.md, "Links in the terminal"). Two things were missing:
///
///   - An OSC 8 hyperlink ran xterm.js's default activation — `confirm("Do you want to navigate to …")`, then a
///     `window.open()` it navigates itself. The app's web views answer no `confirm`, which WebKit then treats as
///     Cancel, so a click did nothing at all; a browser asked that alarming question first.
///   - A URL printed as plain text was no link: nothing detected it. The host strips `TERM_PROGRAM` from a
///     shell's environment (TermEnvironment), so programs that look for a hyperlink-capable terminal — Claude
///     Code's `supports-hyperlinks` — print plain URLs.
///
/// Both now go to ONE opener: xterm.js's `linkHandler` for OSC 8, the official web-links addon's provider for plain
/// URLs. It opens an http or https URL with `window.open(…, "_blank", "noopener,noreferrer")` and nothing else: a
/// browser opens a tab; the app's client window hands it to the default browser (`ClientWindow`'s
/// `createWebViewWith`, `ExternalLink`). The hover underline (both renderers) and the pointer are xterm.js's own.

/// The URL a link may open: http or https only — never `javascript:`, a `file:` path (on a remote Mac it names
/// that Mac's file; one naming an image is an image path, term-paths.ts's), or a scheme some app on this device would
/// claim. Null for anything else.
export function openableLink(uri: string): string | null {
  let url: URL;
  try { url = new URL(uri); } catch { return null; }
  return (url.protocol === "http:" || url.protocol === "https:") && url.hostname !== "" ? url.href : null;
}

/// Open `uri` if it may be opened (`openableLink`); whether it was.
export function openLink(uri: string, open: (url: string, target: string, features: string) => unknown = (u, t, f) => window.open(u, t, f)): boolean {
  const url = openableLink(uri);
  if (url === null) return false;
  open(url, "_blank", "noopener,noreferrer");
  return true;
}

/// Wire a terminal's links to `openLink`: OSC 8 hyperlinks (xterm.js keeps non-http ones unlinked by default) and
/// URLs in its text.
export function attachTermLinks(term: Terminal, open?: Parameters<typeof openLink>[1]): void {
  term.options.linkHandler = { activate: (_e, uri) => { openLink(uri, open); } };
  term.loadAddon(new WebLinksAddon((_e, uri) => { openLink(uri, open); }));
}
