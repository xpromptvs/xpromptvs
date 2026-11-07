import { chrome } from "./window-chrome";
const paths = {
  keyboard: '<rect x="2" y="4" width="20" height="16" rx="3"/><path d="M6 9h1m4 0h1m4 0h1M6 12h1m4 0h1m4 0h1M7 16h10"/>',
  home: '<path d="m3 10 9-7 9 7M5 9v12h5v-7h4v7h5V9"/>',
  cursor: '<path d="M6.9 4.78 17.1 10.22Q19.5 11.5 17.21 12.21L14.99 12.89Q12.7 13.6 11.75 15.69L10.45 18.51Q9.5 20.6 8.85 18.38L5.15 5.72Q4.5 3.5 6.9 4.78Z"/>',
  settings: '<path d="M3 6h10m4 0h4M3 18h4m4 0h10"/><circle cx="15" cy="6" r="2" fill="currentColor"/><circle cx="9" cy="18" r="2" fill="currentColor"/>',
  settingsPanel: '<rect x="2" y="4" width="20" height="16" rx="3"/><path d="M6 9h2m4 0h6M6 15h7m4 0h1"/><circle cx="10" cy="9" r="1.7" fill="currentColor" stroke="none"/><circle cx="15" cy="15" r="1.7" fill="currentColor" stroke="none"/>',
  fit: '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/><rect x="7" y="7" width="10" height="10" rx="1"/>',
  fullscreen: '<path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5"/>',
  minimize: '<path d="M5 12h14"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
} as const;

/** The floating window and touch footer use the same outlines at their respective control sizes. */
export function windowControlIcon(name: keyof typeof paths, size = 18): string {
  const shared = chrome.icons[name as keyof typeof chrome.icons];
  const content = shared ? shared.lines.map(p => `<polyline points="${p.join(" ")}"/>`).join("")
    + shared.circles.map(([cx, cy, r]) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="currentColor"/>`).join("")
    + shared.rects.map(([x, y, width, height, rx]) => `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${rx}"/>`).join("") : paths[name];
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${name === "settingsPanel" ? 1.5 : 1.7}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${content}</svg>`;
}
