import metrics from "./native-chrome.json";

/** One geometry for AppKit, the production web tabs, and the workbench's native frame.
 * assemble-app.sh bundles this exact JSON for ClientChrome.swift on every app rebuild. */
export function installNativeChromeMetrics(root: HTMLElement): void {
  for (const [name, value] of Object.entries(metrics)) {
    const cssName = name.replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`);
    root.style.setProperty(`--native-${cssName}`, `${value}px`);
  }
}
