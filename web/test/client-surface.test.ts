import { afterEach, expect, it } from "vitest";
import { createClientSurface } from "../src/client/instance/surface";
import { createSessionDom } from "../src/client/session-dom";

afterEach(() => document.body.replaceChildren());
it("duplicate internal IDs resolve locally and unmount does not reset sibling attributes", () => {
  const a = createClientSurface(document.body), b = createClientSurface(document.body);
  b.ui.dataset.tab = "terminal";
  const aStage = a.root.getElementById("stage"), bStage = b.root.getElementById("stage");
  expect(aStage).not.toBeNull(); expect(bStage).not.toBe(aStage);
  expect(document.getElementById("stage")).toBeNull();
  const dom = createSessionDom(a.root.getElementById("session")!, a.ui);
  dom.mount(); dom.unmount();
  expect(b.root.getElementById("stage")).toBe(bStage);
  expect(b.ui.dataset.tab).toBe("terminal");
  a.destroy(); expect(b.root.getElementById("stage")).toBe(bStage);
  b.destroy();
});
it("surface owns every session dialog without adding scripts or document styles", () => {
  const before = document.head.innerHTML;
  const a = createClientSurface(document.body);
  for (const id of ["e2e-setup", "tmux-kill-dialog", "paste-lines-dialog", "paste-folder-dialog", "identity-mismatch"])
    expect(a.root.getElementById(id)).not.toBeNull();
  expect(a.root.querySelector("script")).toBeNull();
  expect(document.head.innerHTML).toBe(before);
  a.destroy();
});
