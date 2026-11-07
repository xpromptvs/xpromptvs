import type { LayoutMode } from "./layout-mode";
import { ContextMenu } from "./context-menu";

/// A settings value opens the same top-layer menu as a tab. The underlying select remains the
/// source of truth and continues to serve the glasses layout.
export function mountSettingsChoice(select: HTMLSelectElement, signal: AbortSignal): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "win-settings-choice";
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-label", select.getAttribute("aria-label") ?? select.title);
  const menu = new ContextMenu(signal, (value) => {
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
    sync();
  }, () => button.setAttribute("aria-expanded", "false"), "win-settings-choice-menu", select);
  const sync = () => syncSettingsChoice(select);
  button.addEventListener("click", () => {
    sync();
    if (menu.isOpen) { menu.close(); return; }
    const options = [...select.options].map((option) => ({
      action: option.value, label: option.textContent ?? "", selected: option.selected,
    }));
    if (menu.open(options, button.getBoundingClientRect(), undefined, { parent: button.closest("dialog") ?? undefined })) button.setAttribute("aria-expanded", "true");
  }, { signal });
  select.addEventListener("change", sync, { signal });
  sync();
  return button;
}

export function syncSettingsChoice(select: HTMLSelectElement): void {
  const button = select.nextElementSibling;
  if (button?.classList.contains("win-settings-choice")) {
    button.textContent = select.selectedOptions[0]?.textContent ?? "—";
  }
}

/// The per-window settings popover: what goes in it, and where it lands.
///
/// WHY IT EXISTS. Every control used to live in the titlebar strip, which stopped fitting once there
/// were six of them — and a window is often only 280px wide. `pinControls` slid the whole cluster
/// back into view when a window overflowed, which kept the buttons reachable but did nothing about a
/// strip wider than its own titlebar.
///
/// THE PURE PARTS LIVE HERE so they can be tested without layout. jsdom has no layout engine, so
/// `getBoundingClientRect` is 0x0 there and positioning cannot be tested against the real stylesheet
/// — but the DECISION, given rectangles, is arithmetic and belongs in a function.

/// How far a control reaches. `device` sits between `session` and `host`: it outlives the connection
/// like `host` does, but it changes THIS phone rather than the Mac.
export type SettingsScope = "window" | "session" | "device" | "host";

/// One row of the panel. DATA, NOT CLOSURES — the same rule the command palette follows, and what
/// makes the panel's contents assertable without constructing a WindowManager.
export interface SettingsRow {
  key: "fps" | "scale" | "bitrate" | "codec" | "audio" | "recovery" | "referenceRecovery" | "delay" | "rate" | "curtain" | "pointer";
  label: string;
  /// HOW FAR THIS CONTROL REACHES, and it is written into the label rather than left to a tooltip.
  /// A control that changes more than the window you opened it from, rendered identically to one
  /// that does not, is how someone comes to believe their FEC percentage applies to one source.
  ///
  /// `host` is broader than `session`: it outlives this connection and changes the physical Mac.
  scope: SettingsScope;
  /// Whether the D-pad can land on it. The incoming-rate readout is a `<span>`, so a nav order that
  /// included it would leave the wearer on a control a pinch cannot activate — a dead stop with no
  /// pointer to escape it.
  focusable: boolean;
  /// Layouts this row may appear on. Absent means every layout.
  ///
  /// NOT THE WHOLE VISIBILITY RULE — the stylesheet ANDs this with `(any-pointer: coarse)`, so a
  /// touch-only control stays hidden on a mouse-only machine whatever its layout.
  ///
  /// LOAD-BEARING — `visibleSettingsRows` is consumed by BOTH the panel renderer and the glasses
  /// D-pad order. A row hidden by CSS alone still emits its nav id, and the D-pad then walks onto an
  /// element `querySelector` cannot find and stops with no way back.
  layouts?: readonly LayoutMode[];
}

const SCOPE_SUFFIX: Record<SettingsScope, string> = {
  window: "",
  session: " (all windows)",
  device: " (this device)",
  host: " (this Mac)",
};

/// The label as rendered, scope included. ONE function, so the select and any other surface cannot
/// disagree about how far a control reaches.
export function settingsRowLabel(row: SettingsRow): string {
  return `${row.label}${SCOPE_SUFFIX[row.scope]}`;
}

export const SETTINGS_ROWS: readonly SettingsRow[] = [
  { focusable: true, key: "bitrate", label: "Bitrate", scope: "device" },
  { focusable: true, key: "recovery", label: "Forced FEC overhead", scope: "session" },
  { focusable: true, key: "referenceRecovery", label: "AV1 reference recovery (experimental)", scope: "device" },
  { focusable: true, key: "delay", label: "Prefer smooth video over latency", scope: "session" },
  { focusable: true, key: "audio", label: "Audio", scope: "window" },
  { focusable: true, key: "curtain", label: "Curtain", scope: "host" },
  { focusable: false, key: "rate", label: "Incoming", scope: "window" },
  { focusable: false, key: "codec", label: "Codec", scope: "window" },
];

/// Pinned layouts cover their own window. Desktop settings use a top-layer dialog, centred on the
/// owner by settings-overlay.ts, so neither its overflow clip nor its stacking context can hide controls.

/// The rows that RENDER on a layout. One helper, two consumers, so the panel and the D-pad order
/// cannot disagree about what exists.
export function visibleSettingsRows(mode: LayoutMode): readonly SettingsRow[] {
  return SETTINGS_ROWS.filter((r) => r.layouts === undefined || r.layouts.includes(mode));
}
