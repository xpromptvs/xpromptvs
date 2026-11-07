import chrome from "../../public/window-chrome.json";
export { chrome };
export function installWindowChrome(): void {
  const style = document.createElement("style");
  style.textContent = `:root { --window-header-h: ${chrome.headerHeight}px; --window-radius: ${chrome.cornerRadius}px; --window-title-size: ${chrome.titleSize}px; }` +
    (["dark", "light"] as const).map(theme => {
      const p = chrome[theme];
      return `:root[data-theme="${theme}"] { --window-header: ${p.header}; --window-body: ${p.body}; --window-text: ${p.text}; --window-muted: ${p.muted}; }`;
    }).join("");
  document.head.append(style);
}
