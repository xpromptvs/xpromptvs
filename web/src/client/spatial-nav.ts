/// What the wearer can reach on Meta Ray-Ban Display glasses, in the order the D-pad walks it.
///
/// PURE on purpose: the glasses' whole interaction model is "which control is focused" — there is no
/// cursor, the D-pad moves focus and a pinch activates whatever holds it — so the ORDER is the
/// feature. The DOM glue in `glasses-nav.ts` does nothing but map these ids onto elements through
/// `[data-nav-id]` and move `document.activeElement`.
import { visibleSettingsRows } from "./window-settings";

export type GlassesScreen = "sources" | "window" | "terminal";

export interface NavState {
  screen: GlassesScreen;
  sources: { id: string; minimized: boolean }[];
  terminals: { id: string }[];
  /// The tab bar's keys in BAR order (`tabBarOrder`) — terminal and window tabs interleave once the
  /// driver drags them, and the D-pad must walk them as they are drawn. Absent: terminals, then windows.
  tabOrder?: readonly string[];
  /// The palette is MODAL: while it is open nothing behind it is reachable. Without this the D-pad
  /// walks straight out of the sheet into controls the wearer cannot see, and a pinch then activates
  /// one of them.
  paletteOpen: boolean;
  /// A passive client can do exactly one thing — the same rule the claim overlay already encodes.
  active: boolean;
  /// The palette's CURRENT entries, in visual order — action rows then grid tiles. Supplied by the
  /// caller rather than derived here because the contents are asynchronous: sources and snapshots
  /// arrive after the sheet opens, and `CommandPalette.refresh` re-renders in place.
  paletteEntries: readonly string[];
  /// The per-window settings panel is MODAL for the same reason the palette is: it covers the screen
  /// on this layout, so anything behind it is invisible and must not be reachable.
  settingsOpen: boolean;
  /// The empty terminal's buttons (`#term-empty`), when it is showing — nothing opens a shell by
  /// itself, so on glasses these are the only way to get one. Empty when there are tabs.
  termEmpty: readonly string[];
  /// An open confirmation `<dialog>`'s buttons, or null. A TRAP like the palette: it is modal, so
  /// nothing behind it may be reachable.
  dialog: readonly string[] | null;
}

/// The terminal strip, in screen order. Exported so the chip byte tables and the gate cannot drift
/// from it — a chip present here with no bytes focuses, activates, and silently does nothing.
///
/// Pinned in both directions against `chipBytes` (glasses-compose), NOT against `CHIP_BYTES`: the
/// four cursor keys resolve through `CHIP_CSI` because their sequence depends on the terminal's
/// live cursor-key mode.
export const TERMINAL_CHIPS: readonly string[] = [
  "compose",
  "chip:enter", "chip:backspace", "chip:tab", "chip:esc", "chip:ctrlc",
  "chip:up", "chip:down", "chip:left", "chip:right",
];

export function navOrder(s: NavState): string[] {
  // Checked BEFORE the palette: a passive client that opened the palette must still get only the
  // claim button, since every palette action is a host-gated mutation it cannot perform.
  if (!s.active) return ["claim"];
  if (s.dialog) return [...s.dialog];
  // Visual order, so the sweep matches what the wearer sees: query field, the action rows and the
  // window grid, then the ✕. Still a TRAP — nothing behind the sheet is reachable.
  if (s.paletteOpen) return ["palette:input", ...s.paletteEntries, "palette:close"];
  // Checked after the palette (which covers this too) and before the screens: the settings panel is
  // its own modal surface, and its close is LAST so a sweep ends at the way out.
  if (s.settingsOpen) {
    return [
      // GLASSES, always — `navOrder` IS the glasses D-pad order, so it asks for the rows that
      // render there and never for the full table.
      ...visibleSettingsRows("glasses").filter((r) => r.focusable).map((r) => `win:settings:${r.key}`),
      "win:settings:close",
    ];
  }

  const tabs = [
    ...s.terminals.map((t) => ({ key: t.id, nav: `tab:term:${t.id}` })),
    ...s.sources.map((x) => ({ key: x.id, nav: `tab:win:${x.id}` })),
  ];
  if (s.tabOrder) {
    // A stable sort by bar position; a tab the order does not name keeps its place after the named ones.
    const at = (k: string) => { const i = s.tabOrder!.indexOf(k); return i < 0 ? Number.MAX_SAFE_INTEGER : i; };
    tabs.sort((a, b) => at(a.key) - at(b.key));
  }
  const strip = [...tabs.map((t) => t.nav), "add", "palette"];

  switch (s.screen) {
    case "sources":
      // Minimized sources are listed: minimize UNSUBSCRIBES, and the tab is the live way back.
      return [...strip, ...s.sources.map((x) => `src:${x.id}`)];
    case "window":
      return [...strip, "win:settings", "win:back", "win:minimize", "win:close"];
    case "terminal":
      // No tab: the ways to get one, and no chips — there is nothing for them to type into.
      if (s.termEmpty.length > 0) return [...strip, ...s.termEmpty];
      // The physical D-pad is spoken for — it moves focus — so the shell's OWN arrow keys have to be
      // chips, or a TUI and shell history are unreachable from the glasses.
      return [...strip, ...TERMINAL_CHIPS];
  }
}

/// The DASHBOARD (`#welcome`, no session): what a wearer who has not connected yet can reach.
///
/// The ids are read from the DOM by the caller, for the palette's reason — the list is asynchronous
/// (a directory poll, a stream, a sign-in) and the rendered rows ARE the answer. Only the visible,
/// enabled controls of the page on screen are passed; the hidden page is not reachable.
export interface HomeNavState {
  /// A session frame covers the dashboard. Its document runs its OWN nav; nothing here is reachable.
  session: boolean;
  /// An open modal's controls (`<dialog open>`, the scanner sheet), or null. A TRAP.
  modal: readonly string[] | null;
  /// The header's controls, in visual order (Devices, Settings, the profile button).
  header: readonly string[];
  /// The shown page's controls, in DOM order — which on this single-column page IS visual order.
  page: readonly string[];
}

/// **VISUAL ORDER, ENTERED AT THE FIRST MAC.** The order is the page top to bottom, header first, as
/// the session's is ("the sweep matches what the wearer sees"). But `navStep` enters a cold focus at
/// `order[0]`, and the header's Devices tab is the one control on this page that does nothing — the
/// wearer is already on it. The first Mac is the one-pinch path to what the page is for; the pairing
/// field beside it needs the composer (handwriting or voice) and a code read off another screen.
/// So the visual CYCLE is ROTATED to start there: the D-pad still walks the page in the order it is
/// drawn and wraps at the same seam, only the entry point moves. With no Mac listed it enters at the
/// page's first control — the pairing field, the one path that needs nothing.
export function homeNavOrder(s: HomeNavState): string[] {
  if (s.session) return [];
  if (s.modal) return [...s.modal];
  const visual = [...s.header, ...s.page];
  const firstMac = visual.findIndex((id) => id.startsWith("device:"));
  const at = firstMac >= 0 ? firstMac : Math.min(s.header.length, visual.length);
  if (at === 0 || at >= visual.length) return visual;
  return [...visual.slice(at), ...visual.slice(0, at)];
}

/// Move one step through `order`, wrapping at both ends.
///
/// Wrapping rather than clamping: at this list length a dead end costs the wearer a full reverse
/// sweep, and there is no pointer to shortcut it. An unknown or absent `current` re-enters at the
/// first control — focus can vanish under us when a source unsubscribes or the palette closes.
export function navStep(order: string[], current: string | null, delta: 1 | -1): string | null {
  if (order.length === 0) return null;
  const at = current === null ? -1 : order.indexOf(current);
  // `?? null` satisfies noUncheckedIndexedAccess; both indices are in range by construction.
  if (at < 0) return order[0] ?? null;
  return order[(at + delta + order.length) % order.length] ?? null;
}
