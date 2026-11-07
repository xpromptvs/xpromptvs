import { contextFor } from "./instance/context";
import { navStep, type HomeNavState } from "./spatial-nav";
import { chooserNavOrder, closeSelectChooser, openSelectChooser } from "./glasses-chooser";

/// Move DOM focus with the glasses' D-pad, and activate on pinch.
///
/// LOAD-BEARING — the pinch (`Enter`) is activated EXPLICITLY, not left to native behaviour.
/// A synthetic KeyboardEvent is `isTrusted: false`, and browsers run no default activation for an
/// untrusted event — so under the simulator a focused <button> is never clicked by a pinch, and an
/// app relying on native activation is dead on arrival there. (The platform's own QA guidance says
/// to implement "Enter activation" for exactly this reason.) `preventDefault()` before the explicit
/// click is what keeps it correct in BOTH worlds: if the real device delivers a trusted Enter, the
/// native activation is suppressed and the explicit click is the only one, so nothing double-fires.
/// Verified by `e2e/glasses-nav-check.mjs`, which caught the original no-handler version.
///
/// The listener is on `window` in the CAPTURE phase. Events arrive AT `document.activeElement` and
/// bubble, so a bubble-phase listener would reach us only after the focused element had its say —
/// and a focused <input> would already have consumed the arrow to move its caret.
/// Take the terminal out of the BROWSER's own focus order on glasses, and put it back otherwise.
///
/// LOAD-BEARING, and not the same thing as suppressing autofocus. xterm's `.xterm-helper-textarea`
/// gets a tabindex when `term.open()` runs — natively focusable, with no `data-nav-id`, so it sits
/// in a focus order this nav layer does not own. Anything that walks native focus (the WebView's own
/// directional focus, a stray Tab) lands on the terminal, where the wearer has no focus ring, no
/// recognised control and no pointer to escape with. Gating the programmatic `.focus()` calls was
/// necessary and not sufficient.
///
/// Called after every xterm mount, because the helper textarea does not exist until then.
///
/// `#theme-toggle` is here for the same reason rather than a different one: it is a real control the
/// D-pad order deliberately does not carry (the status bar is not a navigation surface on a 600px
/// display), so on glasses it must leave the focus order too — a focusable control the nav cannot
/// reach is exactly the dead end this function exists to prevent.
///
/// Controls rendered by rdev itself are NOT listed here; they carry `data-nav-id` at their render
/// site (index.html, terminal-tabs.ts, window-tabs.ts). This list is for elements whose markup we do
/// not own: xterm's helper textarea, and the two deliberate exclusions.
///
/// The dashboard adds two: its brand link (it duplicates Devices, and an `<a href>` is natively
/// focusable) and the `#debug`-only Slow 10x button.
const NOT_NAVIGABLE_ON_GLASSES = ".terminal-scrollbar, .xterm-helper-textarea, #theme-toggle, #welcome .ss-brand, #welcome [data-motion-slow]";

/// Subtrees made INERT on glasses. `tabindex="-1"` is not enough and measuring says so: with the
/// helper textarea at tabindex -1, a programmatic `.focus()` still focused it AND a `mousedown` on
/// `.xterm-screen` still focused it, because xterm focuses its own textarea from that handler.
/// tabindex governs the SEQUENTIAL tab order only — never programmatic or click focus.
///
/// `inert` is the property actually wanted: nothing inside can take focus by any route, and the
/// subtree stops being a hit-test target. The terminal is a VIEW on glasses; every byte it receives
/// comes from the compose strip.
const INERT_ON_GLASSES = "#xterm";

export function syncGlassesFocusOrder(mode: string, root: ParentNode = document): void {
  const inNavOrder = mode !== "glasses";
  for (const el of root.querySelectorAll<HTMLElement>(NOT_NAVIGABLE_ON_GLASSES)) {
    el.tabIndex = inNavOrder ? 0 : -1;
  }
  for (const el of root.querySelectorAll<HTMLElement>(INERT_ON_GLASSES)) {
    el.inert = !inNavOrder;
  }
}

/// Give xterm its focused RENDERING state on glasses, without giving it focus.
///
/// xterm's DOM renderer draws a cursor only while the terminal is focused — `cursorInactiveStyle` is
/// not honoured by that renderer, measured across all four of its values — and on glasses the
/// terminal is deliberately `inert`, so it can never be focused and never drew a cursor at all. The
/// wearer then cannot see where the text they dictate is going to land.
///
/// xterm derives that state from a `focus` event on its helper textarea, so dispatching one gives us
/// exactly the rendering and nothing else. Verified: real `document.activeElement` stays put, the
/// subtree stays inert, and the cursor renders and blinks. It is rendering-only BECAUSE of inert —
/// xterm's key handling hangs off the textarea's own keydown, which cannot fire without real focus,
/// and its selection needs hit-testing, which inert refuses.
///
/// Must run after the terminal is mounted: the helper textarea does not exist until `term.open()`.
///
/// `root` is the VISIBLE tab's instance (term-deck.ts mounts one per tab, so the first helper textarea
/// in the document is whichever tab happened to mount first).
export function keepTerminalCursorVisible(mode: string, root: ParentNode = document): void {
  if (mode !== "glasses") return;
  root.querySelector<HTMLTextAreaElement>(".xterm-helper-textarea")
    ?.dispatchEvent(new FocusEvent("focus"));
}

/// The nearest ancestor of `el` that actually scrolls, or null.
function scrollParent(el: HTMLElement): HTMLElement | null {
  for (let p = el.parentElement; p; p = p.parentElement) {
    const oy = getComputedStyle(p).overflowY;
    if ((oy === "auto" || oy === "scroll") && p.scrollHeight > p.clientHeight) return p;
  }
  return null;
}

/// Room left around a revealed control: the focus state SCALES its container, so an element flush
/// against the edge has its ring clipped and reads as half-focused.
const REVEAL_MARGIN_PX = 12;

/// Scroll `el`'s container so `el` is fully visible — computed here rather than delegated to
/// `scrollIntoView`.
///
/// LOAD-BEARING on the device. `scrollIntoView({ block: "nearest" })` works in Chromium (measured:
/// scrollTop 0 → 434 with a 12-window grid) but did NOT scroll the window picker on the glasses,
/// where the wearer could reach only the tiles already on screen. `scrollTop` is a far more
/// primitive operation than the UA's interpretation of "nearest", so this asks for the scroll
/// directly instead of describing the outcome and hoping.
///
/// Paired with `focus({ preventScroll: true })` at the callsite: while the UA was also scrolling on
/// focus, removing this function changed nothing in Chromium and the gate could not falsify it.
function revealInScrollParent(el: HTMLElement): void {
  const sc = scrollParent(el);
  if (!sc) return;
  const e = el.getBoundingClientRect();
  const c = sc.getBoundingClientRect();
  if (e.top < c.top + REVEAL_MARGIN_PX) {
    sc.scrollTop -= c.top + REVEAL_MARGIN_PX - e.top;
  } else if (e.bottom > c.bottom - REVEAL_MARGIN_PX) {
    sc.scrollTop += e.bottom - (c.bottom - REVEAL_MARGIN_PX);
  }
}

/// A control that takes TEXT: a textarea, or an <input> that is not a checkbox or radio. It owns Enter
/// (the composer's commit) and Left/Right (its caret); a checkbox or radio has neither.
function isTextField(el: Element | null): boolean {
  if (el instanceof HTMLTextAreaElement) return true;
  return el instanceof HTMLInputElement && el.type !== "checkbox" && el.type !== "radio";
}

/// A control the D-pad may land on: rendered (its page shown, not `hidden`) and not disabled.
/// `focus()` on either is a silent no-op, which a sweep would read as a dead end.
function navigable(el: HTMLElement): boolean {
  if ((el as HTMLButtonElement).disabled) return false;
  const vis = (el as HTMLElement & { checkVisibility?: () => boolean }).checkVisibility;
  return typeof vis === "function" ? vis.call(el) : el.closest("[hidden], .hidden") === null;
}

function navIds(els: Iterable<HTMLElement>): string[] {
  return [...els].filter(navigable).map((el) => el.dataset.navId ?? "").filter(Boolean);
}

/// The dashboard's D-pad state, read from the DOM (`homeNavOrder`). The rendered controls ARE the
/// answer — the list arrives asynchronously and re-renders in place, as the palette's does.
export function readHomeNavState(doc: Document = document): HomeNavState {
  const welcome = doc.getElementById("welcome");
  // The scanner sheet is a body-level overlay, not a <dialog>; checked first because it opens from
  // the page and nothing opens over it. A <dialog> opened with showModal() is in the top layer.
  const modal = doc.getElementById("qr-sheet")
    ?? [...doc.querySelectorAll<HTMLDialogElement>("dialog[open]")].at(-1) ?? null;
  // A session covers the dashboard once `motion.js` REVEALS it (`#session` stops being inert). While
  // it is PENDING the dashboard stays live on purpose: the busy Connect button is the way to cancel.
  const session = doc.getElementById("session");
  return {
    session: session !== null && !session.inert && session.querySelector("iframe") !== null,
    modal: modal ? navIds(modal.querySelectorAll<HTMLElement>("[data-nav-id]")) : null,
    header: welcome ? navIds(welcome.querySelectorAll<HTMLElement>(".ss-header [data-nav-id]")) : [],
    page: welcome ? navIds(welcome.querySelectorAll<HTMLElement>(
      "#home-devices [data-nav-id], #home-settings [data-nav-id]")) : [],
  };
}

/// Install the D-pad. `getOrder` is read fresh on every press — `navOrder` over the session's state,
/// or `homeNavOrder` over the dashboard's — so nothing here knows which page it is on.
export function installGlassesNav(getOrder: () => string[], targetRoot: Document | ShadowRoot | (() => Document | ShadowRoot) = document): () => void {
  const resolveRoot = () => typeof targetRoot === "function" ? targetRoot() : targetRoot;
  const DELTA: Record<string, 1 | -1> = {
    ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1,
  };

  const onKeyDown = (e: KeyboardEvent) => {
    const root=resolveRoot(), context=contextFor(root);
    // A function is the standalone page adapter explicitly routing its cold D-pad focus.
    if(typeof targetRoot !== "function" && context && !context.input.owns(e)) return;
    const el = (context ? context.activeElement() : root.activeElement) as HTMLElement | null;

    if (e.key === "Enter") {
      // A TEXT field owns Enter — it commits the composer line, and clicking it would do nothing
      // useful. A checkbox or radio is an <input> with no text to commit, so it is activated like a
      // button: `.click()` toggles it (the dashboard's Reduced motion was dead to a pinch before).
      // Everything else is a button or a link, and gets exactly one activation.
      if (isTextField(el)) return;
      if (!el?.dataset?.navId) return;
      e.preventDefault();
      // A HELD pinch (key auto-repeat) is ONE pinch for a select and for the chooser: otherwise the
      // repeats open it, commit the focused option, re-focus the select and open it again, round and
      // round — and each cycle races its own history entry.
      if (e.repeat && (el instanceof HTMLSelectElement || el.closest("#glasses-chooser"))) return;
      // A <select> is NOT activated by `.click()` — no picker opens, from script or from an untrusted
      // event — so a pinch on a DASHBOARD select STEPS it to the next option and says so with
      // `change`, as a picker would (Appearance was unreachable otherwise). ONLY the dashboard's:
      // those are local preferences where a step costs nothing, while a session select (the gear
      // panel's codec, resolution, frame rate) is a HOST setting — a codec step renegotiates the
      // track — so stepping through them on the way to the one wanted would apply every one in
      // between. A pinch on one of those OPENS the chooser (`glasses-chooser.ts`) instead: the
      // wearer walks the options and a pinch commits exactly one `change`.
      if (el instanceof HTMLSelectElement) {
        if (el.closest("#welcome")) {
          if (el.options.length > 0) {
            el.selectedIndex = (el.selectedIndex + 1) % el.options.length;
            el.dispatchEvent(new Event("change", { bubbles: true }));
          }
        } else {
          openSelectChooser(el, revealInScrollParent);
        }
        return;
      }
      el.click();
      return;
    }

    const delta = DELTA[e.key];
    if (delta === undefined) return;
    // A focused text field owns Left/Right for its caret — the wearer leaves it with Up/Down. Without
    // this you cannot position the caret in a composed command at all.
    if (isTextField(el) && (e.key === "ArrowLeft" || e.key === "ArrowRight")) return;

    // An open chooser is a TRAP: its options and its cancel are the whole order.
    const order = chooserNavOrder(root) ?? getOrder();
    const next = navStep(order, el?.dataset?.navId ?? null, delta);
    if (next === null) return;
    const target = root.querySelector<HTMLElement>(`[data-nav-id="${CSS.escape(next)}"]`);
    if (!target) return;

    e.preventDefault();
    e.stopPropagation();
    // `preventScroll` matters twice. It stops the UA scrolling to its own taste and then us
    // correcting it — a visible double jump — and it makes `revealInScrollParent` the ONLY thing
    // that scrolls, so behaviour is identical on a WebView whose focus() does not scroll (which is
    // what the glasses do) and on one whose focus() does (Chromium). It is also what lets the gate
    // falsify this at all: with the UA scrolling too, removing the reveal changed nothing.
    target.focus({ preventScroll: true });
    revealInScrollParent(target);
  };

  window.addEventListener("keydown", onKeyDown, true);
  return () => {
    window.removeEventListener("keydown", onKeyDown, true);
    closeSelectChooser(resolveRoot());            // leaving the glasses layout leaves no sheet behind
  };
}
