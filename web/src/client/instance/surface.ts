import { installNativeChromeMetrics } from "../../shared/native-chrome";
import { acquireClientFonts } from "./fonts";
import markup from "./session.html?raw";
import { clientStyles } from "./styles";

export function createClientSurface(container: HTMLElement) {
  const document = container.ownerDocument;
  const host = document.createElement("div");
  host.dataset.clientHost = "";
  const root = host.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = clientStyles;
  root.appendChild(style);
  const ui = root.appendChild(document.createElement("div"));
  ui.className = "client-root";
  installNativeChromeMetrics(ui);
  ui.dataset.theme = "dark"; ui.dataset.tab = "sim"; ui.dataset.layout = "floating";
  const body = ui.appendChild(document.createElement("div"));
  body.className = "client-body";
  body.innerHTML = markup;
  container.appendChild(host);
  const fonts = acquireClientFonts(document);
  return { host, root, ui, body, ready: fonts.ready, destroy() { fonts.release(); host.remove(); } };
}
