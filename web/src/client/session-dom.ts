import { shellstormMotion } from "./shellstorm-motion";

/// The session's markup — `#session`'s children in `index.html` — owned per CONNECTION.
///
/// **SNAPSHOT ONCE, MOUNT FRESH.** The markup is taken out of the document at boot, before anything
/// can bind to it, and every session gets a new copy: a listener, an inline style or a child that one
/// session added cannot survive into the next, which is what removing an iframe used to guarantee.
/// One session at a time, so the ids stay unique.
///
/// `#session` ITSELF stays: `session-motion.js` and `motion.js` hold it from load, and its classes
/// (`ss-session-pending`, `ss-session-moving`) are the slide's. Unmount resets those, plus the two
/// root attributes a session writes (`data-tab`, `data-keystrip`). Body-level dialogs are closed by
/// the session (`session.ts`, `closeSessionDialogs`), not recreated.
export interface SessionDom {
  mount(): void;
  unmount(): void;
  readonly mounted: boolean;
}

export function captureSessionDom(root: HTMLElement): SessionDom {
  return createSessionDom(root, root.ownerDocument.documentElement, () => shellstormMotion()?.resync?.());
}

/** Embedded sessions reset only their own presentation root. Motion is an explicit adapter. */
export function createSessionDom(root: HTMLElement, stateRoot: HTMLElement, resync: () => void = () => {}): SessionDom {
  const doc = root.ownerDocument;
  const pristine = root.cloneNode(true) as HTMLElement;
  root.replaceChildren();
  let mounted = false;
  // `data-tab` MUST exist before `data-layout` matters, or a pinned layout renders both surfaces
  // (main.ts); the session starts on the window surface, as the page always did.
  const resetRoot = (): void => {
    stateRoot.dataset.tab = "sim";
    delete stateRoot.dataset.keystrip;
  };
  return {
    get mounted() { return mounted; },
    mount() {
      // **A SECOND MOUNT WITHOUT AN UNMOUNT THROWS.** Unmounting first, or replacing the children,
      // would pull the DOM out from under a session still running on it — hiding a controller that
      // lost track of its session behind a session that silently stopped painting. Every caller
      // pairs mount with unmount; this makes the day one does not loud.
      if (mounted) throw new Error("session DOM is already mounted — unmount it first");
      const fresh = pristine.cloneNode(true) as HTMLElement;
      root.replaceChildren(...Array.from(fresh.childNodes));
      resetRoot();
      mounted = true;
      // `motion.js` observes `.ss-home` only — the "binds once to static markup" trap — so the
      // status bar's Slow 10x button in a NEW copy would keep whatever `hidden` it was cloned with.
      resync();
    },
    unmount() {
      root.replaceChildren();
      root.inert = false;
      root.classList.remove("ss-session-pending", "ss-session-moving");
      delete root.dataset.ready;
      resetRoot();
      mounted = false;
    },
  };
}
