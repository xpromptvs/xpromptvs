/** Scoped background tokens shared by the shell and the real terminal renderer. */
export interface BackgroundColors { panel?: string; terminal?: string }
export const BACKGROUND_COLORS_CHANGED = 'rdev-background-colors-changed';
const HEX = /^#[0-9a-f]{6}$/i;
export function backgroundColors(value: unknown): BackgroundColors {
  const v = value && typeof value === 'object' ? value as Record<string, unknown> : {};
  const result: BackgroundColors = {};
  for (const key of ['panel','terminal'] as const) {
    if (typeof v[key] === 'string' && HEX.test(v[key])) result[key] = v[key].toLowerCase();
  }
  return result;
}
export function applyBackgroundColors(root: HTMLElement, value: BackgroundColors): void {
  const colors = backgroundColors(value);
  for (const key of ['panel','terminal'] as const) {
    const token = `--${key}-background`;
    if (colors[key]) root.style.setProperty(token, colors[key]!);
    else root.style.removeProperty(token);
  }
  root.dispatchEvent(new Event(BACKGROUND_COLORS_CHANGED, {bubbles:true,composed:true}));
}
