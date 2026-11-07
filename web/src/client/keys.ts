import type { ChannelLike } from "../lib/channel";
import { encodeJson } from "../lib/codec";
import { modsBitmask } from "./input";
import { contextFor, presentationRoot } from "./instance/context";

export interface WinKeyWire {
  t: "win-key"; down: boolean; code: string; key: string; repeat: boolean; mods: number;
}

/** Build the `win-key` message for one key transition, or null when there is nothing to forward.
 *
 * The client stays DUMB on purpose: it reports the physical key (`code`), the character its own
 * layout produced (`key`), the repeat flag and the modifier snapshot, and the host decides what any
 * of that means (see `planKeyInjection` — dead keys, unmapped codes and the unicode-override rule
 * all live there, once, in a tested pure function).
 *
 * Two things ARE decided here because only the client can see them: a key produced mid-composition
 * (the composed character arrives on its own event, so forwarding the intermediate types twice), and
 * an event with no physical identity at all. */
export function keyEventToWire(e: KeyboardEvent, down: boolean): WinKeyWire | null {
  if (e.isComposing) return null;
  if (!e.code && !e.key) return null;
  return {
    t: "win-key", down, code: e.code, key: e.key, repeat: Boolean(e.repeat), mods: modsBitmask(e),
  };
}

/** Wire keyboard on a window's body to the input channel.
 *
 * FOCUS DOES THE ARBITRATION. The listeners are on the BODY, so a keydown only reaches them while
 * `document.activeElement` is inside it — clicking the tab bar, the terminal, the stage or opening
 * the palette takes DOM focus away and rdev's own shortcuts work again. `isActive` adds the other
 * half of the rule: the source must also be the FOCUSED source (that is which injector the host
 * routes to) and this client must be the driver. BOTH are required — one pointerdown sets both, so
 * a disagreement means dropping the keystroke rather than typing into a window nobody is looking at.
 *
 * Every forwarded key is preventDefault'ed, which stops Tab moving focus, Space scrolling the page
 * and ⌘S opening Save. ⌘W/⌘T/⌘N/⌘Q stay browser-owned and cannot be captured in a normal tab.
 *
 * Release-all is sent on every transition after which the browser stops delivering keyups: blur,
 * window blur, a hidden tab, and pagehide. The host releases too (on client leave and injector swap),
 * because ⌘W kills the tab mid-chord and no client-side handler can run then. */
export function attachWindowKeys(
  body: HTMLElement, inputChannel: ChannelLike, isActive: () => boolean,
  /// The on-screen key strip's latched modifiers, OR'd into every forwarded key. An iPad with BOTH a
  /// hardware keyboard and the strip can then arm Ctrl with a finger and press the letter
  /// physically. OR rather than assignment: the event's own modifiers must survive, or holding a
  /// real Shift while the strip holds Ctrl would drop one of them. Optional, so every existing
  /// caller is unchanged.
  extraMods?: () => number,
): void {
  // LOAD-BEARING — on glasses the client NEVER forwards keys to the host.
  //
  // The D-pad IS the keyboard there: arrows and Enter arrive as key events at the focused element,
  // and everything below preventDefaults and forwards every key a focused `.win-body` sees. On
  // desktop the way out is the mouse ("the way back to rdev's UI is the mouse"); on glasses there is
  // no mouse, and no long-press to reserve as an escape — the device fires keydown and keyup back to
  // back. So a single pinch into a projected window would hand the wearer's only input device to the
  // remote Mac, permanently and irrecoverably.
  //
  // The glasses window screen is therefore view-only with respect to the HOST. Its own controls stay
  // focusable and stay ours. Note the test for the exact string: an UNSET data-layout means floating
  // (the default mode), and must keep forwarding.
  if (presentationRoot(body).dataset.layout === "glasses") return;

  const send = (obj: unknown) => inputChannel.send(encodeJson(obj) as Uint8Array<ArrayBuffer>);
  const releaseAll = () => { if (isActive()) send({ t: "win-keys-release" }); };
  const context = contextFor(body);

  const forward = (e: Event, down: boolean) => {
    if (!isActive() || context?.scope.disposed) return;
    const ke = e as KeyboardEvent;
    const msg = keyEventToWire(ke, down);
    if (!msg) return;
    if (down) context?.input.claimKeyboard(releaseAll);
    if (extraMods) msg.mods |= extraMods();
    ke.preventDefault();
    send(msg);
  };
  body.addEventListener("keydown", (e) => forward(e, true));
  body.addEventListener("keyup", (e) => forward(e, false));

  // Element-scoped listeners die with the element. The window/document ones do NOT, which is why
  // they are installed ONCE for the whole client and routed through `keyboardOwner` — binding them
  // per window would leak three global listeners for every window ever opened, and minimize→restore
  // builds a fresh element each time.
  if (context) {
    body.addEventListener("focus", () => context.input.claimKeyboard(releaseAll), {signal:context.scope.signal});
    body.addEventListener("blur", () => context.input.releaseKeyboard(releaseAll), {signal:context.scope.signal});
    return;
  }
  body.addEventListener("focus", () => { keyboardOwner = releaseAll; });
  body.addEventListener("blur", () => {
    if (keyboardOwner === releaseAll) keyboardOwner = null;
    releaseAll();
  });
  installGlobalRelease();
}

/// The release callback of the window that currently holds the keyboard, or null. O(1) — exactly one
/// window can have DOM focus, so no registry is needed and nothing accumulates.
let keyboardOwner: (() => void) | null = null;
let globalReleaseInstalled = false;

/// The session is over (`session.ts`): nothing it built may be released by the page's blur/pagehide
/// listeners any more. Those listeners are PAGE-LIFETIME (`installGlobalRelease`) and stay; only the
/// owner they call goes.
export function releaseKeyboardOwner(): void { keyboardOwner = null; }

/// Window blur (⌘-Tab to another app), a hidden tab and pagehide all stop the browser delivering
/// keyups — the host would keep holding whatever was down, and a stuck ⌘ turns every later keystroke
/// into a chord. DOM focus is deliberately left ALONE: the user coming back should be able to keep
/// typing rather than having to click the window again, and the next keydown re-establishes the
/// modifier flags anyway since every `win-key` carries its own snapshot.
function installGlobalRelease(): void {
  if (globalReleaseInstalled) return;
  globalReleaseInstalled = true;
  const release = () => keyboardOwner?.();
  window.addEventListener("blur", release);
  window.addEventListener("pagehide", release);
  document.addEventListener("visibilitychange", () => { if (document.hidden) release(); });
}
