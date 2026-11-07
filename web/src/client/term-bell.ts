import type { TabKind } from "./tab-order";

/// THE BELL (docs/terminal.md, "The bell"). A BEL (xterm.js's `onBell`) rung by a TERMINAL tab the person
/// is not LOOKING AT is UNSEEN until they look at it: the tab carries a mark, the page's title and favicon
/// say so, and in the app the Dock does (`__rdevShell.setBell`). Every open tab is a live xterm.js instance
/// (term-deck.ts), so a hidden one rings as it runs — a long command finishing, a program waiting for input.
///
/// A WINDOW tab rings too (2026-10-02, docs/window-capture-and-input.md, "A window's bell"): its application
/// raised its Dock badge on the host (`window-bell`) — Terminal.app badging a bell, a chat's unread count.
/// Its mark, title and Dock count are the same as a terminal tab's.
///
/// LOOKING AT means the tab the deck SHOWS and the window the session FOCUSES, each on a surface on screen,
/// in a page that is visible AND focused — the session decides that (`looking`). Nothing looking (the page
/// hidden, another app in front) leaves even the shown tab's bell unseen, and looking at it again is what
/// clears it.
///
/// Per CLIENT, never the host's: what a person has seen is a property of the screen in front of them. The
/// HOST only RINGS — a bell in output that reached no client (`parseTermBell`), as it answers a device query
/// whose bytes reached none, and a window's Dock badge (`parseWindowBell`) — and keeps no record of what
/// anyone has seen.

export interface TabBellsOpts {
  /// The tabs the person is looking at now — a terminal tab and a window at most, none when nothing is.
  looking(): ReadonlySet<string>;
  /// The unseen set changed. `rang`: a tab became unseen (news — the app may ask for attention); false: one
  /// was seen, closed or cleared.
  changed(rang: boolean): void;
}

export class TabBells {
  /// Each unseen tab and its KIND — from what rang it, never its key's prefix (the headless test pattern's
  /// one window is not a `win:` id), so `retain` drops only the kind its list is about.
  private readonly unseen = new Map<string, TabKind>();

  constructor(private readonly o: TabBellsOpts) {}

  /// `keys` rang together — one terminal tab, or every window of the application whose badge rose. When
  /// the person is looking at ANY of them they are in it, and nothing is news; otherwise each is marked. A
  /// mark already up is not news again.
  ring(kind: TabKind, ...keys: string[]): void {
    const looking = this.o.looking();
    if (keys.some((k) => looking.has(k))) return;
    let added = false;
    for (const k of keys) if (!this.unseen.has(k)) { this.unseen.set(k, kind); added = true; }
    if (added) this.o.changed(true);
  }

  /// What the person looks at may have changed (a switch, a focus, the page shown or focused, the
  /// surface): THOSE tabs' bells are seen.
  look(): void {
    let seen = false;
    for (const k of this.o.looking()) if (this.unseen.delete(k)) seen = true;
    if (seen) this.o.changed(false);
  }

  /// Explicit activation is acknowledgement even when an embedded page's focus flag lags the click.
  acknowledge(tab: string): void {
    if (this.unseen.delete(tab)) this.o.changed(false);
  }

  /// Only `ids` of `kind` still exist (a `term-list`, a `view-set`): a closed tab takes its bell with it.
  /// The other kind's marks are not this list's to drop.
  retain(kind: TabKind, ids: ReadonlySet<string>): void {
    let dropped = false;
    for (const [k, of] of [...this.unseen]) if (of === kind && !ids.has(k)) { this.unseen.delete(k); dropped = true; }
    if (dropped) this.o.changed(false);
  }

  /// Forget every bell — this client is no longer the driver, whose tabs they were.
  clear(): void {
    if (this.unseen.size === 0) return;
    this.unseen.clear();
    this.o.changed(false);
  }

  has(tab: string): boolean { return this.unseen.has(tab); }
  get count(): number { return this.unseen.size; }
  get tabs(): string[] { return [...this.unseen.keys()]; }
}

/// THE HOST'S BELL (`{t:"term-bell", term}`): a BEL in output that reached NO client context — the page
/// hidden and its terminal paused, a resume's gap, a new wire before the tab's snapshot — rung by the host on
/// the device-query rule, since this page's xterm.js never parsed it (docs/terminal.md, "The bell"). At most
/// one per tab per such stretch; the mark is idempotent anyway.
export function parseTermBell(msg: unknown): { term: string } | null {
  const m = msg as { t?: unknown; term?: unknown } | null;
  if (!m || m.t !== "term-bell" || typeof m.term !== "string" || m.term === "") return null;
  return { term: m.term };
}

/// The tab a host bell rings, or null: only the DRIVER's (a passive client holds none of the tabs), and only
/// a tab this client has (`term-list`) — a stray id must not count toward the title or the Dock.
export function hostBellTab(bell: { term: string }, list: { tabs: readonly { id: string }[] }, driver: boolean): string | null {
  return driver && list.tabs.some((t) => t.id === bell.term) ? bell.term : null;
}

/// A WINDOW'S BELL (`{t:"window-bell", sources}`): the application owning `sources` raised its Dock badge
/// on the host (docs/window-capture-and-input.md, "A window's bell") — every window of it in the session.
export function parseWindowBell(msg: unknown): { sources: string[] } | null {
  const m = msg as { t?: unknown; sources?: unknown } | null;
  if (!m || m.t !== "window-bell" || !Array.isArray(m.sources)) return null;
  const sources = m.sources.filter((s): s is string => typeof s === "string" && s !== "");
  return sources.length > 0 ? { sources } : null;
}

/// The windows a host's window bell rings, or none: only the DRIVER's, only on a client that SHOWS windows
/// (a window-less one has no window tab to mark, and must not count them toward its title or the Dock), and
/// only windows of the session it renders (`view-set.windows`).
export function hostBellWindows(bell: { sources: readonly string[] }, windows: readonly { source: string }[],
                                driver: boolean, windowless: boolean): string[] {
  if (!driver || windowless) return [];
  return bell.sources.filter((s) => windows.some((w) => w.source === s));
}

/// The page title's prefix while a bell is unseen. The BROWSER draws a title (a tab, the app window's
/// title bar), not the page's font subsets, so the emoji renders.
export const BELL_TITLE_PREFIX = "🔔 ";

/// `title` with the prefix while `ringing`, without it otherwise — never two of them, whatever it is given.
export function bellTitle(title: string, ringing: boolean): string {
  const base = title.startsWith(BELL_TITLE_PREFIX) ? title.slice(BELL_TITLE_PREFIX.length) : title;
  return ringing ? BELL_TITLE_PREFIX + base : base;
}

/// The app's half (`__rdevShell.setBell`, BridgeScripts.swift): this window's count of tabs with an unseen
/// bell. The app sums its windows for the Dock's badge and asks for attention when one grows while it is
/// not the active app.
export interface BellShell { setBell?(count: number): void }

/// The favicon's dot: the Dock badge's red, not a theme token — the browser draws it over its own chrome.
export const FAVICON_DOT = "#ff453a";

/// WHERE AN UNSEEN BELL SHOWS OUTSIDE THE TAB BAR: the page's title (`bellTitle`), a badged favicon, and the
/// app (`BellShell`). `show` on every change of the count; `restore` when the session ends, giving the page
/// its own title and favicon back and the app a zero.
export class BellChrome {
  private readonly icon: { link: HTMLLinkElement; href: string } | null;
  private badged: Promise<string | null> | null = null;
  private ringing = false;
  private sent = 0;

  constructor(private readonly doc: Document, private readonly shell: BellShell | undefined,
              private readonly badge: (href: string, dot: string) => Promise<string | null> = badgedFavicon) {
    const link = doc.querySelector<HTMLLinkElement>('link[rel~="icon"]');
    this.icon = link ? { link, href: link.getAttribute("href") ?? "" } : null;
  }

  /// `count` tabs of this session have an unseen bell.
  show(count: number): void {
    this.ringing = count > 0;
    this.doc.title = bellTitle(this.doc.title, this.ringing);
    if (count !== this.sent) { this.sent = count; this.shell?.setBell?.(count); }
    const icon = this.icon;
    if (!icon) return;
    if (!this.ringing) { icon.link.setAttribute("href", icon.href); return; }
    this.badged ??= this.badge(icon.href, FAVICON_DOT);
    void this.badged.then((url) => { if (this.ringing && url) icon.link.setAttribute("href", url); });
  }

  restore(): void { this.show(0); }
}

/// The favicon with a dot in its top-right corner, as a PNG data URL — or null where the image cannot be
/// read or drawn. Raster on purpose, like the favicon it badges (index.html). `dot` is the dot's colour.
export async function badgedFavicon(href: string, dot: string): Promise<string | null> {
  try {
    const img = new Image();
    img.decoding = "async";
    img.src = href;
    await img.decode();
    const size = Math.max(32, img.naturalWidth || 0);
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = size;
    const g = canvas.getContext("2d");
    if (!g) return null;
    g.drawImage(img, 0, 0, size, size);
    const r = size * 0.2;
    g.beginPath();
    g.arc(size - r - 1, r + 1, r, 0, Math.PI * 2);
    g.fillStyle = dot;
    g.fill();
    return canvas.toDataURL("image/png");
  } catch {
    return null;
  }
}
