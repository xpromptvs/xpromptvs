import { windowControlIcon } from "./window-control-icons";
const icon = (body: string, size = 22) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const touchTap = '<path transform="translate(0 -1)" d="M6 8a4 4 0 0 1 8 0M9 13V8a1 1 0 0 1 2 0v4l5 1.5a2 2 0 0 1 1.4 2.4l-.8 3.6A2 2 0 0 1 14.7 21h-3.5a2 2 0 0 1-1.6-.8L6 15.5a1.2 1.2 0 0 1 1.7-1.7L9 15"/>';
const expand = '<path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5"/>';
const collapse = '<path d="M4 9h5V4m11 5h-5V4M9 20v-5H4m11 5v-5h5"/>';

/** Status-bar actions forward to the focused window's existing controls, preserving its state machine. */
export function installMobileWindowControls(windows: HTMLElement, footer: HTMLElement, togglePointer: () => void = () => {}): () => void {
  const group = document.createElement("div");
  group.className = "mobile-window-controls";
  group.setAttribute("role", "group"); group.setAttribute("aria-label", "Window controls");
  const touch = document.createElement("button"); touch.type = "button";
  touch.className = "mobile-pointer-toggle";
  touch.setAttribute("aria-label", "Trackpad mode");

  touch.addEventListener("pointerdown", e => e.stopPropagation());
  touch.addEventListener("mousedown", e => e.preventDefault());
  touch.addEventListener("click", togglePointer);
  group.append(touch);
  const specs = [
    { label: "Home", icon: windowControlIcon("home", 22), selector: ".win-sim-home", state: "aria-pressed" },
    { label: "Keyboard", icon: windowControlIcon("keyboard", 22), selector: ".win-sim-keyboard", state: "aria-pressed" },
    { label: "Zoom", icon: icon('<circle cx="10.5" cy="10.5" r="7"/><path d="m16 16 4.5 4.5M8 10.5h5m-2.5-2.5v5"/>'), selector: ".win-zoom", state: "aria-pressed" },
    { label: "Settings", icon: windowControlIcon("settings", 22), selector: ".win-gear", state: "aria-expanded" },
    { label: "Full screen", icon: windowControlIcon("fullscreen", 22), selector: ".win-fullscreen", state: "aria-pressed" },
  ];
  const current = () => windows.querySelector<HTMLElement>(".source-window.fullscreen, .source-window.focused");
  const buttons = specs.map(spec => {
    const button = document.createElement("button"); button.type = "button"; button.innerHTML = spec.icon; button.setAttribute("aria-label", spec.label); button.title = spec.label;
    button.addEventListener("pointerdown", e => e.stopPropagation()); // Don't dismiss Settings before its toggle reads it.
    button.addEventListener("mousedown", e => e.preventDefault());
    button.addEventListener("click", () => current()?.querySelector<HTMLButtonElement>(spec.selector)?.click());
    group.append(button); return button;
  });
  footer.insertBefore(group, footer.querySelector("#keyboard-open"));
  const sync = () => {
    const win = current(); group.hidden = !win;
    const simulator = win?.dataset.source?.startsWith("sim:") === true;
    footer.dataset.simulatorControls = String(simulator);
    const trackpad = !simulator && win?.dataset.pointerMode === "trackpad";
    const mode = trackpad ? "trackpad" : "direct";
    if (touch.dataset.mode !== mode) {
      touch.dataset.mode = mode;
      touch.innerHTML = trackpad ? icon(touchTap, 24) : windowControlIcon("cursor", 22);
    }
    touch.hidden = simulator;
    touch.disabled = !win || simulator;
    touch.setAttribute("aria-pressed", String(trackpad));
    touch.title = trackpad ? "Trackpad mode · switch to direct touch" : "Direct touch · switch to trackpad";
    specs.forEach((spec, i) => {
      const source = win?.querySelector<HTMLButtonElement>(spec.selector);
      buttons[i]!.hidden = spec.selector.startsWith(".win-sim-") && !simulator;
      buttons[i]!.disabled = !source || source.disabled;
      buttons[i]!.setAttribute(spec.state, source?.getAttribute(spec.state) ?? "false");
      const exiting = spec.label === "Full screen" && source?.getAttribute("aria-pressed") === "true";
      const label = exiting ? "Exit full screen" : spec.label;
      buttons[i]!.setAttribute("aria-label", label); buttons[i]!.title = label;
      if (spec.label === "Full screen") buttons[i]!.innerHTML = icon(exiting ? collapse : expand);
    });
  };
  const observer = new MutationObserver(sync);
  observer.observe(windows, { subtree: true, childList: true, attributes: true, attributeFilter: ["class", "aria-pressed", "aria-expanded", "disabled", "data-pointer-mode", "data-source"] });
  sync();
  return () => { observer.disconnect(); group.remove(); delete footer.dataset.simulatorControls; };
}
