// window-stacking-check.mjs — desktop windows must paint ABOVE the tab bar and status bar, so a window
// dragged over either one keeps a grabbable titlebar.
//
// NO HOST NEEDED. The window is synthetic DOM against the real stylesheet (same technique as
// rail-check-desktop.mjs), so this runs any time the web dev server is up:
//   node e2e/window-stacking-check.mjs
//
// What it guards: #windows used to be z-index 3 against bars at 6, so the bars won the hit test. A window
// dragged into the bottom 38px had its titlebar BEHIND the status bar and could never be grabbed again —
// measured, elementFromPoint returned #statusbar at every y in that band. Unit tests cannot see this:
// jsdom has no layout engine, so getBoundingClientRect is 0x0 and there is no stylesheet to read.
import { chromium } from "playwright";
import { checkDistFreshness } from "./dist-freshness.mjs";
import { mountSessionShell } from "./lib/session-shell.mjs";
const base = process.env.RDEV_BASE ?? "http://localhost:5173";
// Refuse to measure code that is not the code under test: an origin serving a stale `web/dist` produces
// confident, meaningless results. No-op against the vite dev server, which compiles source per request.
const __fresh = await checkDistFreshness(base);
if (!__fresh.ok) { console.error(__fresh.message); process.exit(3); }
console.log(`freshness: ${__fresh.note ?? __fresh.reason}`);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
await page.goto(base, { waitUntil: "load" });
await mountSessionShell(page);

let failures = 0;
const ok = (label, cond, detail) => {
  if (!cond) failures++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail ? "  " + detail : ""}`);
};

// Build one floating window with the real classes, then move it around and hit-test its titlebar.
const setup = await page.evaluate(() => {
  window.__rdevClientRoot.querySelector(".client-root").dataset.layout = "floating";
  window.__rdevClientRoot.getElementById("welcome")?.remove();
  const el = document.createElement("section");
  el.className = "source-window"; el.id = "probe-win";
  const tb = document.createElement("div"); tb.className = "win-titlebar";
  const dot = document.createElement("span"); dot.className = "win-dot";
  const t = document.createElement("span"); t.className = "win-title"; t.textContent = "probe";
  const fit = document.createElement("button"); fit.className = "win-fit"; fit.textContent = "Fit";
  const min = document.createElement("button"); min.className = "win-minimize"; min.textContent = "−";
  const cl = document.createElement("button"); cl.className = "win-close"; cl.textContent = "×";
  const ctl = document.createElement("div"); ctl.className = "win-controls"; ctl.append(fit, min, cl);
  tb.append(dot, t, ctl);
  const body = document.createElement("div"); body.className = "win-body";
  el.append(tb, body);
  window.__rdevClientRoot.getElementById("windows").append(el);
  const z = (id) => getComputedStyle(window.__rdevClientRoot.getElementById(id)).zIndex;
  const cs = getComputedStyle(window.__rdevClientRoot.querySelector(".client-root"));
  return {
    windows: z("windows"), tabbar: z("tabbar"), statusbar: z("statusbar"),
    tabbarH: parseFloat(cs.getPropertyValue("--tabbar-h")) || 0,
    statusbarH: parseFloat(cs.getPropertyValue("--statusbar-h")) || 0,
    vh: window.innerHeight, vw: window.innerWidth,
  };
});
console.log(`z-index: #windows=${setup.windows}  #tabbar=${setup.tabbar}  #statusbar=${setup.statusbar}`);
console.log(`bars: tabbar=${setup.tabbarH}px  statusbar=${setup.statusbarH}px  viewport=${setup.vw}x${setup.vh}`);

ok("#windows paints above both bars",
   Number(setup.windows) > Number(setup.tabbar) && Number(setup.windows) > Number(setup.statusbar),
   `${setup.windows} vs ${setup.tabbar}/${setup.statusbar}`);

/// Place the window at `top` and report what is hit at the centre of its titlebar.
const probe = (top) => page.evaluate((y) => {
  const el = window.__rdevClientRoot.getElementById("probe-win");
  el.style.left = "300px"; el.style.top = `${y}px`; el.style.width = "400px"; el.style.height = "300px";
  const tb = el.querySelector(".win-titlebar");
  const r = tb.getBoundingClientRect();
  const hit = window.__rdevClientRoot.elementFromPoint(r.left + 40, r.top + r.height / 2);
  return { titlebarTop: Math.round(r.top), reachable: !!hit && tb.contains(hit),
           hit: hit ? (hit.id || hit.className) : null };
}, top);

// Over the STATUS BAR: every y through the bottom band. All four of these failed before the z-index fix.
for (const y of [setup.vh - 24, setup.vh - 30, setup.vh - setup.statusbarH, setup.vh - 50]) {
  const r = await probe(y);
  ok(`titlebar at y=${y} (over the status bar) is grabbable`, r.reachable, `hit .${r.hit}`);
}

// Over the TAB BAR: dragging up there is newly allowed, and must be equally recoverable.
for (const y of [0, 10, setup.tabbarH - 20]) {
  const r = await probe(y);
  ok(`titlebar at y=${y} (over the tab bar) is grabbable`, r.reachable, `hit .${r.hit}`);
}

// A window must not cover the command palette — that is the way back to everything else.
await probe(200);
const paletteWins = await page.evaluate(() => {
  const ov = window.__rdevClientRoot.querySelector(".palette-overlay");
  if (!ov) return { skipped: true };
  ov.classList.remove("hidden"); ov.style.display = "";
  const el = window.__rdevClientRoot.getElementById("probe-win");
  const r = el.getBoundingClientRect();
  const hit = window.__rdevClientRoot.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  const inWin = !!hit && el.contains(hit);
  ov.classList.add("hidden");
  return { skipped: false, inWin, hit: hit ? (hit.id || hit.className) : null };
});
ok("the command palette still opens ABOVE a window",
   paletteWins.skipped || !paletteWins.inWin,
   paletteWins.skipped ? "no .palette-overlay in the DOM — skipped" : `hit .${paletteWins.hit}`);

// NOTE the `.settling` / `.fitting` re-pin is NOT checked here. This file has no WindowManager, so any
// check would have to replicate `afterGeometryTransition` itself and would pass regardless of the code.
// It is exercised for real by `e2e/fit-check.mjs`, which drives a grip drag through settle on a live host.

await page.evaluate(() => { window.__rdevClientRoot.getElementById("probe-win").style.top = "500px"; });
await page.screenshot({ path: "shot-stacking.png" });
console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
await browser.close();
process.exit(failures === 0 ? 0 : 1);
