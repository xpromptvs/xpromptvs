import type { MenuItem } from "./context-menu";
import type { SimStateWire } from "./source-picker";

/// A simulator tab's own items (docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "The client"). Each
/// item's action is `sim-` + the `sim-action` it sends, so nothing else in the menu can be mistaken for one. While the
/// device is changing state the menu offers nothing of its own: a press would land on a device that is not there.
const BOOTED: ReadonlyArray<[label: string, action: string]> = [
  ["Home", "home"], ["App Switcher", "app-switcher"], ["Lock", "lock"], ["Rotate Left", "rotate-left"],
  ["Rotate Right", "rotate-right"], ["Shake", "shake"], ["Volume Up", "volume-up"], ["Volume Down", "volume-down"],
  ["Siri", "siri"], ["Shut Down", "shutdown"],
];
const ACTIONS = new Set([...BOOTED.map(([, a]) => a), "boot"]);

export function simMenuItems(state?: SimStateWire): MenuItem[] {
  if (state === "booting" || state === "shutting-down") return [];
  if (state === "booted") return BOOTED.map(([label, action]) => ({ action: `sim-${action}`, label }));
  return [{ action: "sim-boot", label: "Boot" }];
}

export function simActionOf(item: string): string | null {
  if (!item.startsWith("sim-")) return null;
  const a = item.slice("sim-".length);
  return ACTIONS.has(a) ? a : null;
}

/// The not-live overlay's words for a simulator window. A BOOTED device still shows nothing for ~20 s after its state
/// says booted (spec, "Measured"), so anything but off is "Booting…".
export function simOfflineText(state?: SimStateWire): string {
  if (state === "shutdown") return "Shut down";
  if (state === "shutting-down") return "Shutting down…";
  return "Booting…";
}
