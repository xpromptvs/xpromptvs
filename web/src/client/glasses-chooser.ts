import { contextFor } from "./instance/context";
/// The glasses' option CHOOSER for a SESSION `<select>` — the gear panel's codec, resolution, frame
/// rate, bitrate, FEC and playout delay.
///
/// WHY IT EXISTS. A pinch is a synthetic `Enter`, and `.click()` on a `<select>` opens no picker —
/// from script or from an untrusted event — so on the glasses those selects were reachable and inert.
/// The dashboard's answer (step to the next option per pinch) is WRONG here: these are HOST settings,
/// and a codec step renegotiates the track, so stepping on the way to the wanted value would apply
/// every value in between. The chooser is the picker the platform does not give us: a pinch OPENS a
/// list of the select's options, the D-pad walks it, a pinch on an option COMMITS it once (one
/// `change`, the same event the product already handles — exactly one renegotiation), and back
/// closes it with nothing changed.
///
/// - A TRAP, like the palette and the dialogs: while it is open `chooserNavOrder` is the whole D-pad
///   order (`installGlassesNav` asks it first), so nothing behind the sheet is reachable.
/// - Every option carries `data-nav-id` AT THIS RENDER SITE (`chooser:opt:<index>`), plus
///   `chooser:cancel` LAST — the door a trap needs even though back also leaves.
/// - A REAL HISTORY ENTRY, because back is literally `history.back()`: without one, back would walk
///   the session's own screens while the sheet stayed up. The entry is consumed on commit/cancel,
///   carries the chooser's GENERATION, and an open inside a pending back() waits for it (below).
/// - Picking the value already selected closes it and fires NOTHING, as a native picker does.
/// - Body-level and `position: fixed`, above the palette — on the glasses the focused window, and so
///   its settings panel, already fills the screen.

export function createSelectChooser(options?: {root: ShadowRoot; container: HTMLElement; history: boolean}) {
const ROOT_ID = "glasses-chooser";

/// The history entry's marker; its value is the pushing chooser's GENERATION.
const HISTORY_KEY = "rdevChooser";

interface Open {
  root: HTMLElement;
  select: HTMLSelectElement;
  onKey: (e: KeyboardEvent) => void;
  gen: number;
  /// Whether our history entry is still on the stack (false once back consumed it).
  entry: boolean;
}

let current: Open | null = null;

/// Is the chooser up?
function chooserOpen(): boolean {
  return current !== null && current.root.isConnected;
}

/// The chooser's D-pad order, or null when it is closed. Its options in list order, then cancel.
function chooserNavOrder(doc: ParentNode = options?.root ?? document): string[] | null {
  if (!chooserOpen()) return null;
  return [...doc.querySelectorAll<HTMLElement>(`#${ROOT_ID} [data-nav-id]`)]
    .map((el) => el.dataset.navId ?? "")
    .filter(Boolean);
}

/// The label a wearer reads as the sheet's title: the row's own label (scope included) when the
/// select sits in a settings row, else its tooltip.
function titleFor(select: HTMLSelectElement): string {
  const row = select.closest(".win-settings-row");
  const label = row?.querySelector(".win-settings-label")?.textContent?.trim();
  return label || select.title || "Choose";
}

/// Open the chooser for `select`. Focus lands on the CURRENT option, moved with `preventScroll` and
/// revealed by `reveal` — the nav layer's own container scroll, since `scrollIntoView` did not scroll
/// on the device (`docs/glasses.md`). A second open replaces the first without committing it.
function openSelectChooser(select: HTMLSelectElement, reveal: (el: HTMLElement) => void = () => {}): void {
  const shouldFocus = !options || !!options.root.activeElement;
  if (current) close(false);
  // A previous close's `history.back()` has not landed yet. Pushing now would put this chooser's
  // entry where that back() then lands on it — closing a sheet the wearer just opened and orphaning
  // its entry. So the open WAITS for that popstate (bounded), and only then pushes.
  if (pendingBack) {
    // Run only if its select is still in the document when the landing comes: one whose window went
    // meanwhile must not open a sheet (and push an entry) for nothing.
    deferredOpen = () => { if (select.isConnected) openSelectChooser(select, reveal); };
    return;
  }
  const doc = select.ownerDocument;
  const root = doc.createElement("div");
  root.id = ROOT_ID;
  root.className = "glasses-chooser";
  root.setAttribute("role", "dialog");
  root.setAttribute("aria-modal", "true");

  const head = doc.createElement("div");
  head.className = "glasses-chooser-head";
  const title = doc.createElement("span");
  title.className = "glasses-chooser-title";
  title.textContent = titleFor(select);
  root.setAttribute("aria-label", title.textContent);
  head.append(title);

  const list = doc.createElement("div");
  list.className = "glasses-chooser-list";
  list.setAttribute("role", "listbox");
  let focusTarget: HTMLElement | null = null;
  const opts = [...select.options];
  opts.forEach((o, i) => {
    if (o.disabled || o.hidden) return;
    const b = doc.createElement("button");
    b.type = "button";
    b.className = "glasses-chooser-option";
    b.setAttribute("role", "option");
    b.dataset.navId = `chooser:opt:${i}`;
    b.dataset.value = o.value;
    b.textContent = o.textContent ?? o.value;
    const isCurrent = i === select.selectedIndex;
    b.setAttribute("aria-selected", String(isCurrent));
    if (isCurrent) { b.dataset.current = "true"; focusTarget = b; }
    b.addEventListener("click", () => commit(o.value));
    list.append(b);
  });

  const cancel = doc.createElement("button");
  cancel.type = "button";
  cancel.className = "glasses-chooser-cancel";
  cancel.dataset.navId = "chooser:cancel";
  cancel.textContent = "Cancel";
  cancel.addEventListener("click", () => close(true));

  root.append(head, list, cancel);
  (options?.container ?? doc.body).append(root);

  // A REAL pointer inside the sheet (a mouse or finger driving `?layout=glasses`) must not reach
  // WindowManager's document-level pointerdown, which closes every settings panel — the one this
  // sheet's select lives in, so focus could not go back to it. The same guard the panel carries.
  root.addEventListener("pointerdown", (e) => e.stopPropagation());

  const win = doc.defaultView ?? window;
  if (options?.history !== false) installPopstate(win);
  // Escape is not a glasses key, but a keyboard driving the glasses layout on a desktop has one.
  const onKey = (e: KeyboardEvent) => {
    if (options && !e.composedPath().includes(options.root)) return;
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
    close(true);
  };
  win.addEventListener("keydown", onKey, true);
  const gen = ++generation;
  if (options?.history !== false) { try { win.history.pushState({ [HISTORY_KEY]: gen }, "", win.location.href); } catch { /* sandboxed */ } }
  current = { root, select, onKey, gen, entry: options?.history !== false };

  const first = focusTarget ?? list.querySelector<HTMLElement>("[data-nav-id]") ?? cancel;
  if (shouldFocus) first.focus({ preventScroll: true });
  reveal(first);                     // the current value of a long list may sit below the fold
}

/// Set the select to `value` and say so ONCE with `change` — the event its owner already handles.
/// The same value, or a select that left the document while the sheet was up, fires nothing.
function commit(value: string): void {
  const o = current;
  if (!o) return;
  const { select } = o;
  close(true);
  if (!select.isConnected || select.value === value) return;
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

/// Tear the sheet down and hand focus back to the select it came from. `refocus` is false only when
/// a second open is replacing this one.
function close(refocus: boolean): void {
  const o = current;
  if (!o) return;
  const ownedFocus = !options || !!options.root.activeElement && o.root.contains(options.root.activeElement);
  current = null;
  const win = o.root.ownerDocument.defaultView ?? window;
  win.removeEventListener("keydown", o.onKey, true);
  o.root.remove();
  // Consume our OWN entry — only while it is the current one — so the NEXT back leaves the screen
  // rather than doing nothing visible. `back()` is ASYNC: until its popstate lands, `pendingBack`
  // holds any new open (see `openSelectChooser`), and that popstate closes nothing. `pendingGen`
  // names WHICH landing we are waiting for — see its declaration for why it outlives the bound below.
  if (o.entry && historyGen(win) === o.gen) {
    pendingGen = o.gen;
    pendingBack = true;
    clearTimeout(pendingTimer);
    // Bounded: if the popstate never comes (a sandboxed or stubbed history), do not strand an open —
    // this only releases deferred work; `pendingGen` stays set so a landing that arrives after it
    // still lands correctly (see `installPopstate`).
    pendingTimer = setTimeout(settlePendingBack, PENDING_BACK_MS);
    // A synchronous throw is a DEFINITE "never coming" — unlike the bound, which is a guess — so it
    // is the one place `pendingGen` is cleared without a matching landing.
    try { win.history.back(); } catch { pendingGen = null; settlePendingBack(); }
  }
  if (refocus && ownedFocus && o.select.isConnected) o.select.focus({ preventScroll: true });
}

/// Close without committing. For a caller that tears the session down under an open sheet.
function closeSelectChooser(): void {
  deferredOpen = null;
  close(false);
}

/// The SESSION is going away under the chooser (`session.ts`). Close without committing and WITHOUT
/// history traffic — a `back()` now would land after the session is gone, on whatever replaced it —
/// and drop every deferred open and push, which all belonged to the leaving session. Our entry stays
/// behind as an inert one: its generation matches no open chooser. Page-lifetime state (`generation`,
/// the one popstate listener per window) survives on purpose.
///
/// DOES NOT CLEAR `pendingGen`. A close's `history.back()` already in flight still has to land as
/// ITS OWN popstate — cleared ONLY by that landing, never by a bound (see `pendingGen`'s own
/// declaration) — so clearing it here would let the eventual popstate fall through to "is this a
/// back press on the open chooser" and reopen exactly the defect that variable exists to close.
function resetChooser(): void {
  const o = current;
  if (o) { o.entry = false; close(false); }
  clearTimeout(pendingTimer);
  pendingBack = false;
  deferredOpen = null;
  deferredPushes = [];
}

/// A glasses SCREEN change's history entry (`main.ts`'s `noteGlassesScreen`) — which has to know about
/// the chooser's, or the two stack wrong:
/// - a sheet OPEN when the screen changes (a `view-set` removed the last source: its window, and the
///   select, went, and `showTerminalSurface` moved to the terminal) belonged to the screen that is
///   leaving. It closes, and the screen's entry REPLACES the chooser's rather than stacking above it —
///   stacked, Cancel issued no back() (its entry was not current) and the wearer's next back landed on
///   the stale chooser entry and did nothing visible.
/// - a closed chooser's back() still IN FLIGHT would pop an entry pushed now: the push waits for it
///   (`settlePendingBack`), and the screen layer ignores that landing (`chooserBackPending`).
function pushScreenEntry(state: object, win: Window = window): void {
  if (options?.history === false) { close(false); return; }
  const o = current;
  if (o) {
    const ours = o.entry && historyGen(win) === o.gen;
    o.entry = false;                                   // reused (or buried): close must not back() over it
    close(false);
    if (ours) {
      try { win.history.replaceState(state, "", win.location.href); } catch { /* sandboxed */ }
      return;
    }
  }
  if (pendingBack) {
    // QUEUED, in order: every screen change inside the wait gets its own entry (one slot kept only the
    // last, and back from it skipped the screen between). An open that waited too was the LEAVING
    // screen's: dropped.
    deferredPushes.push(() => { try { win.history.pushState(state, "", win.location.href); } catch { /* sandboxed */ } });
    deferredOpen = null;
    return;
  }
  try { win.history.pushState(state, "", win.location.href); } catch { /* sandboxed */ }
}

/// Whether a closed chooser's `history.back()` is still in flight — its popstate is the chooser's own.
function chooserBackPending(): boolean {
  return pendingGen !== null;
}

/// Each open's history entry carries its own generation, so a popstate is tied to the chooser that
/// pushed it: a chooser closes only when the history has LEFT its own entry.
let generation = 0;
/// A close's `history.back()` is in flight, and new opens/screen pushes DEFER while it is — pushing
/// underneath an unconfirmed traversal is what corrupts the stack (MEASURED: Chromium and WebKit both
/// point a delayed `back()` at whatever is now BELOW the newest push, not at the entry it was called
/// for, once something has been pushed on top of it first). Cleared by the confirming popstate (the
/// common case, well under a millisecond) or, if it never lands, by the bound below.
let pendingBack = false;
/// The GENERATION `pendingBack` is waiting to leave. Unlike `pendingBack`, this is cleared ONLY by
/// that landing — NEVER by the bound below — so a popstate that arrives after the bound has already
/// let deferred work through is still recognized as belonging to that stale close, REGARDLESS OF
/// TIMING, rather than being checked against whatever chooser is open by then and closed by mistake.
/// This is the fix for "an open requested inside the gap … or the stale back() lands on the new
/// chooser's entry, closes it, and orphans it": a 500 ms bound guessed at "landed" and a popstate that
/// arrived later was misread as a fresh press. See `installPopstate`.
let pendingGen: number | null = null;
let pendingTimer: ReturnType<typeof setTimeout> | undefined;
/// An open requested while `pendingBack` — run when that popstate lands.
let deferredOpen: (() => void) | null = null;
/// The screen entries pushed while `pendingBack`, in order — pushed when that popstate lands, before
/// any open.
let deferredPushes: (() => void)[] = [];
const PENDING_BACK_MS = 500;
const popWindows = new Map<Window, () => void>();

function historyGen(win: Window): unknown {
  return (win.history.state as Record<string, unknown> | null)?.[HISTORY_KEY];
}

/// Stop waiting and run whatever was deferred — idempotent, since both the confirming popstate and
/// the bound can call it. Touches only `pendingBack`; `pendingGen` is a separate clock the popstate
/// listener alone advances, so a late confirmation is still recognized after this has already run.
function settlePendingBack(): void {
  if (!pendingBack) return;
  clearTimeout(pendingTimer);
  pendingBack = false;
  const pushes = deferredPushes, run = deferredOpen;
  deferredPushes = []; deferredOpen = null;
  for (const push of pushes) push();
  run?.();
}

/// ONE popstate listener per window, for every chooser it will ever show.
function installPopstate(win: Window): void {
  if (popWindows.has(win)) return;
  const onPop = () => {
    // A pending close's own back() landing — belongs to it regardless of what it reveals (the screen
    // beneath, ordinarily, or that close's OWN entry again if something was pushed on top of it before
    // the browser got to it) and regardless of how long it took. This ALWAYS returns rather than
    // falling through to the check below, so a landing this late can never be misread as a fresh press
    // on whatever opened meanwhile.
    if (pendingGen !== null) { pendingGen = null; settlePendingBack(); return; }
    const o = current;
    if (!o || !o.root.isConnected) return;
    if (historyGen(win) === o.gen) return;          // still on our own entry: not a back past it
    o.entry = false;                                // the wearer's back consumed it
    close(true);
  };
  popWindows.set(win,onPop);
  win.addEventListener("popstate",onPop);
}
function dispose() {
  resetChooser();
  for(const [win,listener] of popWindows)win.removeEventListener("popstate",listener);
  popWindows.clear();
}

return {dispose,chooserOpen,chooserNavOrder,openSelectChooser,closeSelectChooser,resetChooser,pushScreenEntry,chooserBackPending};
}

// The page adapter keeps the historical navigation behavior. Embedded roots each own a factory.
const pageChooser = createSelectChooser();
function owner(root: Document | ShadowRoot) { return contextFor(root)?.chooser ?? pageChooser; }
export function chooserOpen(root: Document | ShadowRoot = document) { return owner(root).chooserOpen(); }
export function chooserNavOrder(root: Document | ShadowRoot = document) { return owner(root).chooserNavOrder(root); }
export function openSelectChooser(select: HTMLSelectElement, reveal?: (el: HTMLElement) => void) { return (contextFor(select)?.chooser ?? pageChooser).openSelectChooser(select,reveal); }
export function closeSelectChooser(root: Document | ShadowRoot = document) { owner(root).closeSelectChooser(); }
export function resetChooser(root: Document | ShadowRoot = document) { owner(root).resetChooser(); }
export const pushScreenEntry = pageChooser.pushScreenEntry;
export const chooserBackPending = pageChooser.chooserBackPending;
