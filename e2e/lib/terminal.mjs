// The xterm.js instance ON SCREEN: one instance per open tab exists (web/src/client/term-deck.ts); the
// visible tab's slot is not `.is-hidden`, and an instance still being written by a snapshot is
// `.is-pending`. Every check that reads or clicks "the terminal" goes through this.
export const VISIBLE_TERM = "#xterm > .xterm-tab:not(.is-hidden) > .xterm-inst:not(.is-pending)";

// Since 2026-09-25 no shell opens by itself — a check that needs one ASKS, exactly as a person does:
// the driver with no tabs sees `#term-empty`, and pressing its "New terminal" is the request. A host
// that has been driven before may already have tabs, in which case there is nothing to open.
//
// The page must already be the DRIVER (claim first): a passive client never sees `#term-empty`.
export async function openPlainTerminal(page, { timeout = 15000 } = {}) {
  const state = await page.waitForFunction(() => {
    const empty = document.getElementById("term-empty");
    if (empty && !empty.classList.contains("hidden")) return "empty";
    return document.querySelectorAll("#term-tabs .rl-tab .rl-tab-close").length > 0 ? "tabs" : false;
  }, undefined, { timeout });
  if ((await state.jsonValue()) === "empty") await page.locator("#term-empty-new").click();
  await page.waitForFunction(() => (document.querySelector("#xterm > .xterm-tab:not(.is-hidden) > .xterm-inst:not(.is-pending) .xterm-rows")?.textContent ?? "").trim().length > 0,
    undefined, { timeout });
}
