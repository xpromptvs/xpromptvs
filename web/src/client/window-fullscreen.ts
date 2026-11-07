import { contextFor } from "./instance/context";
/// FULL-SCREEN WINDOW MODE — one source window's picture fills the screen, and every band of the
/// session's own chrome goes: the tab bar, that window's titlebar, the status bar. The mode itself is
/// CSS keyed off `data-fullscreen` on the root and `.fullscreen` on the window (`style.css`, "Full-screen
/// window"); `WindowManager.setFullscreen` owns the state. This file is the part that talks to the
/// BROWSER, and the pure decisions behind it.
///
/// THE PICTURE IS SCALED, THE MAC WINDOW IS NOT RESIZED (decided 2026-09-29): the body grows to the
/// screen, `object-fit: contain` fills it, and Auto resolution — a ceiling measured from the body's box
/// — asks for the pixels on its own. Nothing about the mode crosses the wire.

/// How close to the top edge a MOUSE must come to bring the Exit button back — it covers the corner of a
/// picture a mouse user is working in, so it hides once they are, and returns where a menu bar would.
/// Generous enough to include the button itself (top 8 px, 36 px tall), so resting on it keeps it.
export const EXIT_REVEAL_PX = 56;
/// How long the Exit button stays after entering, and after the mouse leaves the top band.
export const EXIT_LINGER_MS = 2500;

/// Whether a mouse at `clientY` asks for the Exit button.
export function exitRevealed(clientY: number): boolean {
  return clientY <= EXIT_REVEAL_PX;
}

/// An iPhone's or an iPad's WebKit. An iPad asks for the DESKTOP site by default and says `Macintosh`,
/// so its tell is the touch points a Mac does not have.
export function isAppleTouch(ua: string, maxTouchPoints: number): boolean {
  return /\b(iPhone|iPad|iPod)\b/.test(ua) || (/\bMacintosh\b/.test(ua) && maxTouchPoints > 1);
}

/// Whether to ask the BROWSER for full screen as well, which takes its own bars away too (a desktop
/// browser's, Android's system bars, the Mac app's window). Without it the mode is the page's alone —
/// on a phone added to the Home Screen that is already the whole screen.
///
/// NEVER ON AN iPHONE OR iPAD (measured on the iOS 27.2 simulators, `docs/client-web.md`, "Full-screen
/// window mode"). An iPhone's Safari has no Fullscreen API at all. An iPad's has, and LEAVES full screen
/// by itself the moment any text field takes focus — the hidden input the key strip's ⌨ focuses
/// included — so raising the keyboard to type into the Mac would take the whole mode down with it.
export function wantsBrowserFullscreen(env: { enabled: boolean; appleTouch: boolean }): boolean {
  return env.enabled && !env.appleTouch;
}

interface KeyboardLock { lock?(codes?: string[]): Promise<void>; unlock?(): void }
/// The Mac app's client window (`app/Sources/BridgeScripts.swift`): its WINDOW goes full screen.
interface ShellFullscreen {
  setFullscreen?(on: boolean): Promise<unknown>;
  onFullscreenLeft?(cb: () => void): () => void;
}
const keyboardLock = (): KeyboardLock | undefined =>
  (navigator as Navigator & { keyboard?: KeyboardLock }).keyboard;

export interface BrowserFullscreen {
  /// Ask the browser for full screen on the ROOT. Call it inside the click that asked — a request with
  /// no user activation is refused — and BEFORE any await.
  enter(): void;
  /// Give back a full screen this asked for. Never one it did not (F11, the app's green button).
  exit(): void;
}

/// The browser's half of the mode. `onLeft` fires when the browser leaves a full screen this asked for
/// — Esc, a held Esc, the browser's own UI — so the page's half follows it out.
///
/// THE ROOT, NEVER THE WINDOW ELEMENT. A full-screen element shows only its own subtree and the top
/// layer, so the palette, the claim overlay and every non-modal overlay would vanish behind it; with the
/// root full screen, the CSS decides what shows, exactly as it does without the API.
///
/// ESC GOES TO THE MAC where the browser lets it (asked for 2026-09-29): the Keyboard Lock API, in
/// Chromium, hands a page Esc while it is full screen and makes a HELD Esc the way out — what remote
/// desktops do. Elsewhere (Safari, Firefox) one Esc still leaves, and `onLeft` takes the page out with it.
///
/// IN THE MAC APP, THE APP'S OWN WINDOW, NEVER WebKit's (`__rdevShell.setFullscreen`, 2026-09-29): a
/// WebKit full screen spends Esc on leaving, and refused outright in a window that was not frontmost
/// ("Cannot request fullscreen in a hidden document", measured). The window's macOS full screen keeps
/// Esc a key the picture forwards to the Mac, and the app decides what is the page's to give back
/// (`app/Core/FullScreenOwnership.swift`): a full screen the person made stays theirs.
export function attachBrowserFullscreen(opts: { onLeft(): void; signal: AbortSignal; element?: HTMLElement }): BrowserFullscreen {
  const context = opts.element ? contextFor(opts.element) : undefined;
  if (context) {
    const off=context.platform.onFullscreenLeft?.(opts.onLeft);
    if(off)opts.signal.addEventListener("abort",off,{once:true});
    return {
    enter() { void context.platform.requestFullscreen?.(context.ui).catch(() => {}); },
    exit() { context.platform.exitFullscreen?.(); },
  };
  }
  const shell = (globalThis as { __rdevShell?: ShellFullscreen }).__rdevShell;
  if (shell?.setFullscreen && shell.onFullscreenLeft) return attachShellFullscreen(shell as Required<ShellFullscreen>, opts);
  // True from the request until we give it back or the browser takes it: "the full screen is ours".
  let wanted = false;
  const unlock = () => { try { keyboardLock()?.unlock?.(); } catch { /* nothing to undo */ } };
  document.addEventListener("fullscreenchange", () => {
    if (!wanted || document.fullscreenElement) return;
    wanted = false;
    unlock();
    opts.onLeft();
  }, { signal: opts.signal });
  return {
    enter() {
      const root = document.documentElement;
      const enabled = document.fullscreenEnabled === true && typeof root.requestFullscreen === "function";
      if (!wantsBrowserFullscreen({ enabled, appleTouch: isAppleTouch(navigator.userAgent, navigator.maxTouchPoints) })) return;
      if (document.fullscreenElement) return;          // already full screen, and not by us
      let request: Promise<void>;
      try { request = root.requestFullscreen({ navigationUI: "hide" }); } catch { return; }
      wanted = true;
      void request.then(
        () => {
          // Given back while the request was in flight: the browser has only now arrived, so leave again.
          if (!wanted) { void document.exitFullscreen().catch(() => {}); return; }
          void keyboardLock()?.lock?.(["Escape"])?.catch(() => {});
        },
        // Refused (no activation, a policy): the page's own full screen carries on without it.
        () => { wanted = false; },
      );
    },
    exit() {
      const ours = wanted;
      wanted = false;
      unlock();
      if (ours && document.fullscreenElement) void document.exitFullscreen().catch(() => {});
    },
  };
}

/// The Mac app's half: ask for the window's full screen and give it back; the app says when the person
/// took it (the green button) and the page's mode follows. Whether a request changes the window —
/// it may already be full screen by the person's hand — is the APP's decision, not this one's.
function attachShellFullscreen(shell: Required<ShellFullscreen>,
                               opts: { onLeft(): void; signal: AbortSignal }): BrowserFullscreen {
  let asked = false;
  const off = shell.onFullscreenLeft(() => {
    if (!asked) return;
    asked = false;
    opts.onLeft();
  });
  opts.signal.addEventListener("abort", off, { once: true });
  return {
    enter() { asked = true; void shell.setFullscreen(true).catch(() => {}); },
    exit() {
      if (!asked) return;
      asked = false;
      void shell.setFullscreen(false).catch(() => {});
    },
  };
}
