import { describe, expect, it } from "vitest";
import { isValidTabName, renameIntent, TAB_NAME_MAX_BYTES, tidyTabName, type RenameField } from "../src/client/tab-name";
import vectors from "../../protocol/fixtures/tab-names.json";

const bytes = (s: string) => new TextEncoder().encode(s).length;

describe("isValidTabName — the host's rule (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md §2.3)", () => {
  it("takes an empty name (it CLEARS) and an ordinary one", () => {
    expect(isValidTabName("")).toBe(true);
    expect(isValidTabName("build server")).toBe(true);
    expect(isValidTabName("ü 日本 🙂  ")).toBe(true);
  });
  it("counts UTF-8 BYTES, not characters", () => {
    const at = "é".repeat(TAB_NAME_MAX_BYTES / 2);            // two bytes each
    expect(bytes(at)).toBe(TAB_NAME_MAX_BYTES);
    expect(isValidTabName(at)).toBe(true);
    expect(isValidTabName(at + "x")).toBe(false);
  });
  it("refuses every control character, C1 included", () => {
    for (const c of ["\t", "\n", "\u0000", "\u001b", "\u007f", "\u0085", "\u009f"]) expect(isValidTabName(`a${c}b`)).toBe(false);
  });
});

// THE SAME VECTORS SWIFT ASSERTS (RdevCore `TabNameTests`): the host refuses a name the client thinks
// is fine only if these two lines are drawn in different places.
describe("isValidTabName — protocol/fixtures/tab-names.json, shared with the host", () => {
  it.each(vectors.valid)("valid: %j", (name) => { expect(isValidTabName(name)).toBe(true); });
  it.each(vectors.invalid)("invalid: %j", (name) => { expect(isValidTabName(name)).toBe(false); });
  it("tidies every invalid vector into a valid name", () => {
    for (const name of vectors.invalid) expect(isValidTabName(tidyTabName(name))).toBe(true);
  });
});

describe("tidyTabName — what the field sends", () => {
  it("trims, and turns a control character into a space", () => {
    expect(tidyTabName("  build  ")).toBe("build");
    expect(tidyTabName("a\tb\nc")).toBe("a b c");
  });
  it("cuts at the byte limit on a character boundary, never inside one", () => {
    const long = "🙂".repeat(100);                            // four bytes each
    const t = tidyTabName(long);
    expect(bytes(t)).toBeLessThanOrEqual(TAB_NAME_MAX_BYTES);
    expect(t).toBe("🙂".repeat(TAB_NAME_MAX_BYTES / 4));
    expect(isValidTabName(t)).toBe(true);
  });
  it("drops a lone surrogate, which no host string can hold", () => {
    expect(tidyTabName("a\ud800b")).toBe("ab");
    expect(tidyTabName("a\udc00")).toBe("a");
  });
  it("always produces a valid name", () => {
    for (const raw of ["\u0085x\u009f", "x".repeat(400), "\u0000"]) expect(isValidTabName(tidyTabName(raw))).toBe(true);
  });
});

describe("renameIntent — what a committed field asks the host for", () => {
  const unnamed: RenameField = { value: "zsh", placeholder: "zsh", named: false, clearable: true };
  const named: RenameField = { value: "build", placeholder: "zsh", named: true, clearable: true };
  const tmux: RenameField = { value: "work", placeholder: "work", named: false, clearable: false };

  it("sends a changed name, tidied", () => {
    expect(renameIntent(unnamed, "  api  ")).toBe("api");
    expect(renameIntent(tmux, "deploy")).toBe("deploy");
  });
  it("sends nothing for the name it opened with", () => {
    expect(renameIntent(unnamed, "zsh")).toBeNull();
    expect(renameIntent(named, " build ")).toBeNull();
  });
  it("EMPTY clears a name the tab has, and asks nothing of one without", () => {
    expect(renameIntent(named, "  ")).toBe("");
    expect(renameIntent(unnamed, "")).toBeNull();
  });
  it("EMPTY on a tmux tab is a cancel — tmux has no unnamed session", () => {
    expect(renameIntent(tmux, "")).toBeNull();
  });
});
