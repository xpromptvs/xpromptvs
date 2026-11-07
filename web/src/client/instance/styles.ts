import chrome from "../../../public/window-chrome.json";
import shell from "../../../public/shellstorm/shell.css?raw";
import motion from "../../../public/shellstorm/motion.css?raw";
import base from "../style.css?raw";
import workingTabTitle from "../../shared/working-tab-title.css?raw";
import native from "../native-chrome.css?raw";
import keyboard from "../keyboard-drawer.css?raw";
import windowSettings from "../window-settings.css?raw";
import terminalSettings from "../terminal-settings.css?raw";
import windowChrome from "../window-chrome.css?raw";
import palette from "../command-palette.css?raw";
import xterm from "@xterm/xterm/css/xterm.css?raw";
import scrollbar from "../terminal-scrollbar.css?raw";
import agents from "../agents/agents.css?raw";

// The single-client styles remain canonical during migration. Only their document boundary is
// translated here: roots become our state-bearing element, body becomes its child, viewport units
// become this host's query-container dimensions, and hardware safe areas are supplied explicitly.
// No selector prefixing is needed inside a shadow root. Keep the existing cascade order.
function localStyles(css: string): string {
  return css.replace(/:root\b/g, ".client-root")
    .replace(/(?<![\w-])html(?![\w-])/g, ".client-root")
    .replace(/(?<![\w-])body(?![\w-])/g, ".client-body")
    .replace(/(\d)(?:d|s|l)?vw\b/g, "$1cqw").replace(/(\d)(?:d|s|l)?vh\b/g, "$1cqh")
    .replace(/env\(safe-area-inset-(top|right|bottom|left)\)/g, "var(--client-safe-$1, 0px)");
}
const fonts: Record<string, string> = {
  "dm-sans.ttf": new URL("../../../public/shellstorm/dm-sans.ttf", import.meta.url).href,
  "bricolage-grotesque-latin.woff2": new URL("../../../public/fonts/bricolage-grotesque-latin.woff2", import.meta.url).href,
  "bricolage-grotesque-latin-ext.woff2": new URL("../../../public/fonts/bricolage-grotesque-latin-ext.woff2", import.meta.url).href,
  "jetbrains-mono-latin.woff2": new URL("../../../public/fonts/jetbrains-mono-latin.woff2", import.meta.url).href,
  "jetbrains-mono-latin-ext.woff2": new URL("../../../public/fonts/jetbrains-mono-latin-ext.woff2", import.meta.url).href,
};
const stylesheet = localStyles([shell, motion, base, workingTabTitle, native, keyboard, windowSettings, terminalSettings, windowChrome, palette, xterm, scrollbar, agents].join("\n"))
  .replace(/url\(["']?(?:\/fonts\/|\.\/)([^"')]+)["']?\)/g, (original, file: string) => fonts[file] ? `url("${fonts[file]}")` : original)
  + `
:host { all: initial !important; display: block !important; position: relative !important;
  width: 100% !important; height: 100% !important; contain: layout style size !important;
  container-type: size !important; isolation: isolate !important; visibility: inherit !important; }
.client-root { all: initial; display: block; position: relative; width: 100%; height: 100%;
  contain: layout style; overflow: hidden; isolation: isolate; direction: ltr;
  font-family: var(--font-ui); color: var(--text); background: var(--app-bg); }
.client-body { position: relative; width: 100%; height: 100%; }
.client-overlays { position: absolute; inset: 0; z-index: 200; pointer-events: none; }
.client-overlay { position: absolute; inset: 0; pointer-events: auto; background: var(--scrim, #0007); }
.client-overlay > dialog { z-index: 1; }
/* Alerts center in their own client window, including embedded demos. */
.client-overlay > dialog.ss-dialog {
  position: absolute; inset: 0; margin: auto; height: fit-content;
  max-height: calc(100% - 32px);
}
`;

// FontFace rules inside a shadow tree are not loaded consistently by browser engines. Register
// immutable, privately named faces with the document FontFaceSet only while a surface needs them.
export const fontNames = { ui: "Xpromptvs DM Sans", mono: "Xpromptvs JetBrains Mono", heading: "Xpromptvs Bricolage Grotesque" };
const namedStyles = stylesheet.replaceAll("DM Sans", fontNames.ui).replaceAll("JetBrains Mono", fontNames.mono).replaceAll("Bricolage Grotesque", fontNames.heading);
export const clientFontFaces = [...namedStyles.matchAll(/@font-face\s*\{([^}]+)\}/g)].map(([,rule]) => {
  const read = (key: string) => rule!.match(new RegExp(`${key}:\\s*([^;]+)`))?.[1]?.trim() ?? "";
  return { family: read("font-family").replace(/["']/g,""), source: read("src"),
    descriptors: {weight: read("font-weight"),style:read("font-style"),display: "swap" as FontDisplay,
      ...(read("unicode-range") ? {unicodeRange:read("unicode-range")} : {})} };
});
export const clientStyles = namedStyles.replace(/@font-face\s*\{[^}]+\}/g, "") + `
.client-root { --window-header-h: ${chrome.headerHeight}px; --window-radius: ${chrome.cornerRadius}px;
 --window-title-size: ${chrome.titleSize}px; --window-header: ${chrome.dark.header}; --window-body: ${chrome.dark.body};
 --window-text: ${chrome.dark.text}; --window-muted: ${chrome.dark.muted}; }
`;
