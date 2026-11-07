import type { GlassesScreen } from "./spatial-nav";

/// Screens as real history entries, because the glasses' back gesture is literally
/// `window.history.back()`.
///
/// A screen held only in local state is INVISIBLE to that gesture: back then walks out of the
/// session entirely instead of closing the palette or leaving a window. The platform's own QA
/// checker asserts this ("Replace screen changes implemented only with local state, display toggles,
/// or custom back buttons with standard browser navigation").
///
/// Deliberately NOT pushed: focus moves and selection changes. An entry per focus step would make
/// back useless — the checker calls that out too.
const SCREENS: readonly string[] = ["sources", "window", "terminal"];

/// The screen a history entry names, or null for anything else. With a `generation`, only an entry
/// that SESSION pushed counts (`rdevSession`): the page outlives every session now, and so does its
/// history, so a later session must never adopt an earlier one's screens.
export function screenFromHistory(state: unknown, generation?: number): GlassesScreen | null {
  if (typeof state !== "object" || state === null) return null;
  const s = state as { rdevScreen?: unknown; rdevSession?: unknown };
  if (generation !== undefined && s.rdevSession !== generation) return null;
  return typeof s.rdevScreen === "string" && SCREENS.includes(s.rdevScreen) ? (s.rdevScreen as GlassesScreen) : null;
}

/// Whether a transition to `screen` deserves a history entry. A repeat does not: pushing one means
/// the wearer has to press back twice before anything visibly happens.
export function pushScreen(screen: GlassesScreen, current: GlassesScreen | null): boolean {
  return screen !== current;
}
