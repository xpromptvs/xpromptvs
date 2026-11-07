import { describe, it, expect } from "vitest";
import { resumeId } from "../src/lib/resume-id";

function memStore(): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k),
    clear: () => m.clear(),
    key: () => null,
    get length() { return m.size; },
  } as Storage;
}

describe("resumeId", () => {
  it("generates and persists on first call", () => {
    const s = memStore();
    let n = 0;
    const id = resumeId(s, () => `gen-${n++}`);
    expect(id).toBe("gen-0");
    expect(s.getItem("rdev.resumeId")).toBe("gen-0");
  });
  it("returns the persisted value on subsequent calls (stable)", () => {
    const s = memStore();
    let n = 0;
    const first = resumeId(s, () => `gen-${n++}`);
    const second = resumeId(s, () => `gen-${n++}`);
    expect(second).toBe(first);
    expect(n).toBe(1); // generator called only once
  });
});
