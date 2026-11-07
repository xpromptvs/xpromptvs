// The live-tab decisions main.ts and term-deck.ts act on, kept PURE so they can be tested without a
// browser: who takes DOM focus when the visible terminal changes, and the lifetime of a client-side
// tab switch the host has not confirmed yet.

/// Why the visible instance changed. `user`: this client switched tabs (strip, palette). `commit`: a
/// snapshot replaced the visible tab's instance (resume, reconnect, re-snapshot). `host`: the host
/// moved its active tab (a new tab, a closed neighbour) or the visible tab's first snapshot landed.
/// `activate`: this client became the driver — a claim, or an AUTO-PROMOTION when another client left,
/// which is no act of this user at all.
export type VisibleChangeReason = "user" | "commit" | "host" | "activate";

/// Whether the newly visible instance takes DOM focus.
///
/// ONLY for a user switch, or to hand on focus the terminal ALREADY held. Keyboard forwarding is gated
/// on DOM focus: a remote window holding it gets every key, so a repaint that stole it — a resume
/// re-serializes every tab — sent the next keystrokes, a password included, into the shell. Never
/// for a passive client, and never on glasses (the D-pad owns focus there).
///
/// Becoming the driver (`activate`) focuses only when NOTHING ELSE holds focus (no remote window, no
/// input) and the terminal surface is what the user is looking at — an auto-promotion happens while
/// the user is doing something else entirely.
///
/// AFTER A TOUCH focusing the terminal RAISES THE SOFT KEYBOARD, so then it takes focus
/// ONLY to hand on focus it already held: a switch while typing keeps the keyboard up for the next tab,
/// and nothing else — a switch, a tab the user opened, a claim — throws it up uninvited. A tap on the
/// terminal is how it comes up (`showTerminalSurface` has never auto-focused, for the same reason). A
/// user switch always focusing made the keyboard pop on nearly every tab change on a phone.
export function terminalTakesFocus(o: {
  reason: VisibleChangeReason;
  terminalHadFocus: boolean;
  driver: boolean;
  mayAutofocus: boolean;
  /// Something outside the terminal holds DOM focus (`elementHoldsFocus`): a remote window, an input.
  /// Refuses every reason but `user`.
  otherHoldsFocus?: boolean;
  /// The newly visible tab is one THIS user asked for (`open-terminal`, `new-tmux`, `open-tmux`) and it
  /// has just landed — the host moved to it, or its first snapshot committed.
  userOpened?: boolean;
  /// `activate` only: the terminal surface is on screen (always off the pinned layouts; on them,
  /// only while `data-tab` is the terminal).
  surfaceShown?: boolean;
  /// Focusing the terminal would raise a soft keyboard: the gesture behind this change was a TOUCH
  /// (input-modality.ts — per gesture, so a hardware keyboard on a touch device still gets focus).
  softKeyboard?: boolean;
}): boolean {
  if (!o.driver || !o.mayAutofocus) return false;
  if (o.softKeyboard) return o.terminalHadFocus && (o.reason === "user" || !o.otherHoldsFocus);
  if (o.reason === "user") return true;
  if (o.otherHoldsFocus) return false;
  if (o.reason === "activate") return o.surfaceShown === true;
  return o.terminalHadFocus || o.userOpened === true;
}

/// Whether the terminal takes the keys of a WINDOW that went holding them, the host having LANDED the person
/// on a terminal tab (`SessionState.landing`). A hand-on like a tab switch's: only the driver's, never on
/// glasses — and after a TOUCH only keys that were TYPING (the window's hidden input, the soft keyboard up),
/// which then stay up for the terminal. Keys on the picture raised no keyboard and must not raise one now.
export function terminalTakesWindowKeys(o: {
  /// The window's hidden INPUT held them (a soft keyboard is up), not its picture.
  typing: boolean;
  driver: boolean;
  mayAutofocus: boolean;
  softKeyboard?: boolean;
}): boolean {
  return o.driver && o.mayAutofocus && (o.typing || !o.softKeyboard);
}

/// A tab THIS user asked for, so it takes focus when it lands (`userOpened` above). `open-tmux` names its
/// session, so its tab id is known exactly. `open-terminal` and `new-tmux` get no echo naming the tab
/// the host made, so the match is the next NEW tab of that kind that the client did not already know
/// when the user asked (`known`: a tmux restore racing a `new-tmux` brings back sessions it knew).
/// It used to be any tab created after the request — so an unrelated tab landing first took the focus,
/// and the one the user asked for arrived without it. `reopen-terminal` (⌘⇧T) brings back a tab of EITHER
/// kind, so its kind is `any`.
export type OpenRequest = { id: string } | { kind: "pty" | "tmux" | "any"; known: ReadonlySet<string> };

/// Whether `tab` is the one `req` asked for. `createdAfterRequest`: its slot appeared after the request.
export function isRequestedTab(req: OpenRequest, tab: string, createdAfterRequest: boolean): boolean {
  if ("id" in req) return tab === req.id;
  return createdAfterRequest && (req.kind === "any" || tab.startsWith(`${req.kind}:`)) && !req.known.has(tab);
}

/// Whether `el`, the document's activeElement, holds focus AGAINST the terminal. Nothing, the body, a
/// DETACHED element, one no longer RENDERED, and anything inside `#claim` hold nothing: "Move here"
/// hides `#claim` and activates synchronously, and Chromium still reports the hidden `#claim-button`
/// as activeElement until its next rendering update (measured) — which refused the claim its focus.
export function elementHoldsFocus(el: Element | null): boolean {
  if (!el || el === el.ownerDocument.body || !el.isConnected) return false;
  if (el.closest("#claim")) return false;
  const vis = (el as Element & { checkVisibility?: () => boolean }).checkVisibility;
  if (typeof vis === "function" && !vis.call(el)) return false;
  return true;
}

/// A pending switch after a `term-list`: confirmed when the host names it active, dropped when the
/// tab is gone, otherwise still pending (a list that still names the old tab predates the switch).
export function pendingAfterTermList(
  pending: string | null,
  tl: { activeId: string | null; tabs: readonly { id: string }[] },
): string | null {
  if (pending === null) return null;
  if (tl.activeId === pending || !tl.tabs.some((t) => t.id === pending)) return null;
  return pending;
}

/// The tab to show after a `term-list`, or undefined to leave the display alone. With no switch
/// pending the display follows the host's active tab; with one pending it stays where the user put it.
export function tabToShowAfterTermList(
  pending: string | null,
  visible: string | null,
  activeId: string | null,
): string | null | undefined {
  if (pending !== null) return undefined;
  return activeId !== visible ? activeId : undefined;
}

/// On a control (re)open, becoming the driver, or going passive: whatever was pending is VOID — its
/// message may have been dropped (control not open) or ignored (this client was passive). A driver
/// re-asserts the tab it shows with a FRESH `switch-terminal`, sent now on an open channel, and that
/// becomes the pending switch; a passive client has nothing to assert and nothing pending.
export function switchReset(visible: string | null, driver: boolean): { pending: string | null; reassert: string | null } {
  if (!driver || visible === null) return { pending: null, reassert: null };
  return { pending: visible, reassert: visible };
}
