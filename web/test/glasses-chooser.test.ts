import { afterEach, describe, expect, it, vi } from "vitest";
import { chooserBackPending, chooserOpen, openSelectChooser, pushScreenEntry, resetChooser } from "../src/client/glasses-chooser";

const select = (): HTMLSelectElement => {
  const s = document.createElement("select");
  for (const v of ["a", "b"]) {
    const o = document.createElement("option");
    o.value = v; o.textContent = v;
    s.append(o);
  }
  document.body.append(s);
  return s;
};

afterEach(() => { resetChooser(); document.body.replaceChildren(); vi.restoreAllMocks(); });

describe("resetChooser — a session going away under the sheet", () => {
  it("closes it with NO history traffic and no change event", () => {
    const s = select();
    const change = vi.fn();
    s.addEventListener("change", change);
    openSelectChooser(s);
    expect(chooserOpen()).toBe(true);
    const back = vi.spyOn(history, "back");
    resetChooser();
    expect(chooserOpen()).toBe(false);
    expect(document.getElementById("glasses-chooser")).toBeNull();
    expect(back).not.toHaveBeenCalled();
    expect(change).not.toHaveBeenCalled();
  });

  it("forgets a pending back() and the pushes waiting on it: the next session pushes at once", () => {
    const s = select();
    openSelectChooser(s);
    vi.spyOn(history, "back").mockImplementation(() => {});          // the landing never comes
    document.querySelector<HTMLButtonElement>("#glasses-chooser .glasses-chooser-cancel")!.click();
    const push = vi.spyOn(history, "pushState");
    pushScreenEntry({ rdevScreen: "terminal" });
    expect(push).not.toHaveBeenCalled();                              // deferred behind that back()
    resetChooser();
    pushScreenEntry({ rdevScreen: "window" });
    expect(push).toHaveBeenCalledTimes(1);                            // the leaving session's push was dropped
  });
});

describe("resetChooser leaves pendingGen alone — only its own landing may clear it", () => {
  it("a back() in flight at reset still lands as the chooser's, and chooserBackPending() stays true until it does", () => {
    const s = select();
    openSelectChooser(s);
    vi.spyOn(history, "back").mockImplementation(() => {});          // the landing never comes synchronously
    document.querySelector<HTMLButtonElement>("#glasses-chooser .glasses-chooser-cancel")!.click();
    expect(chooserBackPending()).toBe(true);
    resetChooser();
    expect(chooserBackPending()).toBe(true);                        // pendingGen survives the reset
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(chooserBackPending()).toBe(false);                       // only its own landing clears it
  });
});
