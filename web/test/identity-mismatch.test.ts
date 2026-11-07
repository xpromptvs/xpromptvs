import { describe, it, expect, vi } from "vitest";
import { identityMismatch, mismatchView } from "../src/client/identity-mismatch";
import { askIdentityMismatch } from "../src/client/identity-mismatch-dialog";

const WINDOW_CODE = "C1P9-HM5S-6D93-FPDC";
const MAC_CODE = "NNYX-EFF9-2D44-1111";

describe("identityMismatch", () => {
  it("two different identities are a mismatch, and it carries BOTH codes", () => {
    const m = identityMismatch(WINDOW_CODE, MAC_CODE);
    expect(m).toEqual({ kind: "mismatch", window: WINDOW_CODE, mac: MAC_CODE });
  });

  it("the same identity is not", () => {
    expect(identityMismatch(MAC_CODE, MAC_CODE).kind).toBe("none");
  });

  // Two surfaces that grouped or cased one identity differently would read as two.
  it("compares without separators and without case", () => {
    expect(identityMismatch("nnyx-eff9-2d44-1111", MAC_CODE).kind).toBe("none");
    expect(identityMismatch("NNYXEFF92D441111", MAC_CODE).kind).toBe("none");
    expect(identityMismatch(" NNYX-EFF9-2D44-1111 ", MAC_CODE).kind).toBe("none");
  });

  // **ABSENT PROVES NOTHING.** The shell answers "" when the host has no identity to name, and a window with
  // no trust record has no code yet; swapping an identity on either would be a swap nobody asked for.
  it("an absent code on EITHER side is nothing to compare, never a mismatch", () => {
    for (const missing of [null, undefined, "", "   "]) {
      expect(identityMismatch(missing, MAC_CODE).kind).toBe("none");
      expect(identityMismatch(WINDOW_CODE, missing).kind).toBe("none");
    }
    expect(identityMismatch(null, null).kind).toBe("none");
  });
});

describe("mismatchView", () => {
  const view = mismatchView({ kind: "mismatch", window: WINDOW_CODE, mac: MAC_CODE });

  it("says the keys are kept and nothing is revoked", () => {
    expect(view.body).toMatch(/keys are kept/i);
    expect(view.body).toMatch(/nothing is revoked/i);
  });

  it("the declined reason NAMES BOTH identities — it is the one `peer-chain` never did", () => {
    expect(view.declined).toContain(WINDOW_CODE);
    expect(view.declined).toContain(MAC_CODE);
  });

  it("offers exactly Replace and Cancel", () => {
    expect(view.confirm).toBe("Replace");
    expect(view.cancel).toBe("Cancel");
  });
});

function mount(): HTMLElement {
  const host = document.createElement("div");
  host.innerHTML = `
    <dialog id="identity-mismatch">
      <h2 id="identity-mismatch-title"></h2>
      <p id="identity-mismatch-body"></p>
      <dl>
        <dt id="identity-mismatch-window-label"></dt><dd><code id="identity-mismatch-window"></code></dd>
        <dt id="identity-mismatch-mac-label"></dt><dd><code id="identity-mismatch-mac"></code></dd>
      </dl>
      <button type="button" data-identity-mismatch-cancel></button>
      <button type="button" data-identity-mismatch-confirm></button>
    </dialog>`;
  document.body.appendChild(host);
  return host;
}

describe("askIdentityMismatch", () => {
  const m = { kind: "mismatch", window: WINDOW_CODE, mac: MAC_CODE } as const;

  it("paints both codes so a person can compare them", async () => {
    const host = mount();
    const answer = askIdentityMismatch(m, host);
    expect(host.querySelector("#identity-mismatch-window")!.textContent).toBe(WINDOW_CODE);
    expect(host.querySelector("#identity-mismatch-mac")!.textContent).toBe(MAC_CODE);
    expect(host.querySelector("#identity-mismatch-title")!.textContent).toBe(mismatchView(m).title);
    host.querySelector<HTMLButtonElement>("[data-identity-mismatch-cancel]")!.click();
    await answer;
  });

  it("Replace answers replace", async () => {
    const host = mount();
    const answer = askIdentityMismatch(m, host);
    host.querySelector<HTMLButtonElement>("[data-identity-mismatch-confirm]")!.click();
    expect(await answer).toBe("replace");
  });

  it("Cancel answers cancel", async () => {
    const host = mount();
    const answer = askIdentityMismatch(m, host);
    host.querySelector<HTMLButtonElement>("[data-identity-mismatch-cancel]")!.click();
    expect(await answer).toBe("cancel");
  });

  // Escape closes a modal without pressing anything; a promise that never settled would hang the
  // session open behind it. jsdom 25 implements neither `showModal` nor `close`, so the dismissal is
  // driven by the EVENT a real one fires — the attribute below is all a unit test can observe, and
  // `e2e/` is where a real modal is seen.
  it("a dismissal is a Cancel, not a hang", async () => {
    const host = mount();
    const answer = askIdentityMismatch(m, host);
    const dialog = host.querySelector<HTMLDialogElement>("#identity-mismatch")!;
    expect(dialog.hasAttribute("open")).toBe(true);
    dialog.dispatchEvent(new Event("close"));
    expect(await answer).toBe("cancel");
    expect(dialog.hasAttribute("open")).toBe(false);
  });

  // A document without the element must not swap an identity because it could not ask.
  it("no dialog in the document is a Cancel, never a silent Replace", async () => {
    expect(await askIdentityMismatch(m, document.createElement("div"))).toBe("cancel");
  });

  // **`#identity-mismatch` is BODY-LEVEL and outlives any one session** (session-dom.ts unmounts and
  // remounts only `#session`'s own children), so a second session calling this reuses the SAME
  // element a first session may have called it on. The "close" handler must be an idempotent
  // ASSIGNMENT, never `addEventListener` — which would leave the first session's listener stacked
  // beside the second's, firing forever after every dialog it never gets to answer.
  it("a second session reusing the dialog does not stack a close listener", async () => {
    const host = mount();
    const dialog = host.querySelector<HTMLDialogElement>("#identity-mismatch")!;
    const addSpy = vi.spyOn(dialog, "addEventListener");
    void askIdentityMismatch(m, host);          // session 1 opens the dialog, then ends unanswered
    const second = askIdentityMismatch(m, host); // session 2 reuses the SAME element
    expect(addSpy.mock.calls.some(([type]) => type === "close")).toBe(false);
    dialog.dispatchEvent(new Event("close"));
    expect(await second).toBe("cancel");
  });
});
