// scripts/make-app-icon.mjs — render desktop/build/icon.svg into desktop/build/icon.png (1024 px),
// desktop/build/icon.icns (every size macOS asks for, rendered at its own size), and the 64 px
// web/public/favicon.png. scripts/assemble-app.sh copies the native icon into the bundle.
//
//   node scripts/make-app-icon.mjs        (needs e2e's Playwright: `npm ci` in e2e/, or its node_modules linked)
//
// Headless Chromium draws the SVG — its gradients, clip and drop-shadow filter exactly as a browser does — on a
// TRANSPARENT page. The native rounded-square mask also handles supplied SVGs with an opaque square
// background: NSApp's direct Dock image does not apply the Finder/Launch Services mask for us.
// Match Finder/Terminal/Chrome's measured 824×824 artwork in a 1024×1024 canvas: 100 px clear on
// each edge. Full-canvas artwork is oversized in the Dock and can overlap its running-app dot.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "../e2e/node_modules/playwright/index.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const build = join(root, "desktop/build");
const svg = readFileSync(join(build, "icon.svg"), "utf8");
writeFileSync(join(root, "web/public/favicon.svg"), svg);
const set = join(mkdtempSync(join(tmpdir(), "app-icon-")), "icon.iconset");
execFileSync("mkdir", ["-p", set]);

// iconutil's names: `icon_<n>x<n>[@2x].png`, n in 16…512.
const sizes = [];
for (const n of [16, 32, 128, 256, 512]) sizes.push([`icon_${n}x${n}.png`, n], [`icon_${n}x${n}@2x.png`, n * 2]);

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  const render = async (px, native = true) => {
    const inset = native ? px * 100 / 1024 : 0;
    const artwork = px - 2 * inset;
    await page.setViewportSize({ width: px, height: px });
    await page.setContent(`<!doctype html><html><head><style>
      html, body { margin: 0; background: transparent; }
      .app-icon { position: absolute; left: ${inset}px; top: ${inset}px; width: ${artwork}px; height: ${artwork}px; border-radius: 22.5%; overflow: hidden; }
      svg { display: block; width: 100%; height: 100%; }
    </style></head><body><div class="app-icon">${svg}</div></body></html>`);
    return page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: px, height: px } });
  };
  for (const [name, px] of sizes) writeFileSync(join(set, name), await render(px));
  // Browser favicons use their full tiny canvas; Dock spacing belongs only to native renditions.
  writeFileSync(join(root, "web/public/favicon.png"), await render(64, false));
} finally {
  await browser.close();
}
copyFileSync(join(set, "icon_512x512@2x.png"), join(build, "icon.png"));
execFileSync("iconutil", ["-c", "icns", set, "-o", join(build, "icon.icns")]);
rmSync(dirname(set), { recursive: true, force: true });
console.log(`wrote app icon renditions and ${join(root, "web/public/favicon.png")} (64 px)`);
