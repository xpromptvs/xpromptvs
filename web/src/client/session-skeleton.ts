/// **THE SESSION LOADS UNDER A SKELETON — IN ITS TAB BAR** (2026-10-05; docs/client-web.md, "The session's loading
/// skeleton"). Asked for: connecting to a Mac showed the EMPTY STATE ("A fresh workspace") — the host says this client
/// drives a moment before its `term-list` names the tabs, and between the two the page had nothing to show but the
/// state of a session with none. From the moment a session mounts, placeholders stand where the tabs will be
/// (`#tab-skeleton`), until the host's first `term-list`; the empty state waits for that list (session.ts
/// `termListed`). A reconnect inside the session shows none: the page already knows its session.
///
/// The TERMINAL AREA has none (asked the same day: "When opening a remote device, don't display skeleton in the
/// terminal"): its placeholder lines are gone, it stays plain while it loads, and a tab's first content fades in as
/// it always has (`TermDeck.watchFirstContent`).
export class SessionSkeleton {
  constructor(private readonly tabs: HTMLElement) {
    tabs.classList.remove("hidden");
  }

  /// The host's tabs are in: the placeholders give way to them.
  listed(): void { this.tabs.classList.add("hidden"); }
}
