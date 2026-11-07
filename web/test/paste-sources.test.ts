import { describe, expect, it } from "vitest";
import { canReadClipboard, chooseClipboard, fileSources, readClipboard, transferContents } from "../src/client/paste-sources";

const nav = (read?: () => Promise<unknown>) => ({ clipboard: read ? { read } : undefined }) as unknown as Navigator;
const item = (types: Record<string, Blob>) => ({ types: Object.keys(types), getType: async (t: string) => types[t] });

describe("chooseClipboard — §2.3: an image wins, else plain text", () => {
  it("prefers an image even with text beside it", () => {
    expect(chooseClipboard([{ types: ["text/plain", "image/png"] }])).toEqual({ item: 0, type: "image/png" });
    expect(chooseClipboard([{ types: ["text/plain"] }, { types: ["image/jpeg"] }])).toEqual({ item: 1, type: "image/jpeg" });
  });
  it("takes text, and nothing usable is null", () => {
    expect(chooseClipboard([{ types: ["text/html", "text/plain"] }])).toEqual({ item: 0, type: "text/plain" });
    expect(chooseClipboard([{ types: ["text/html"] }])).toBeNull();
    expect(chooseClipboard([])).toBeNull();
  });
});

describe("readClipboard", () => {
  it("is unavailable without the API (an insecure origin)", async () => {
    expect(canReadClipboard(nav())).toBe(false);
    expect(await readClipboard(nav())).toEqual({ ok: false, why: "unavailable" });
  });
  it("a refused read is a DISMISSAL, not a failure", async () => {
    expect(await readClipboard(nav(() => Promise.reject(new DOMException("no", "NotAllowedError"))))).toEqual({ ok: false, why: "dismissed" });
  });
  it("an image is a file named pasted.<ext>, text is text, empty text is empty", async () => {
    const png = new Blob([new Uint8Array([1, 2])], { type: "image/png" });
    const r = await readClipboard(nav(async () => [item({ "image/png": png, "text/plain": new Blob(["u"]) })]));
    expect(r).toMatchObject({ ok: true, source: { kind: "file", name: "pasted.png", type: "image/png" } });
    // jsdom's Blob has no text(): shimmed here, never in product code.
    const textBlob = (s: string) => Object.assign(new Blob([s]), { text: async () => s });
    expect(await readClipboard(nav(async () => [item({ "text/plain": textBlob("hi\nthere") })])))
      .toEqual({ ok: true, source: { kind: "text", text: "hi\nthere" } });
    expect(await readClipboard(nav(async () => [item({ "text/plain": textBlob("") })]))).toEqual({ ok: false, why: "empty" });
  });
});

describe("files and transfers", () => {
  it("fits names and types to the wire", () => {
    const f = new File([new Uint8Array(1)], "é".repeat(300) + ".png", { type: "image/png" });
    const [s] = fileSources([f]);
    expect(s?.kind).toBe("file");
    expect(new TextEncoder().encode((s as { name: string }).name).length).toBeLessThanOrEqual(255);
  });
  it("a transfer with files is files; without, its text", () => {
    const f = new File(["x"], "a.txt");
    const withFiles = { types: ["Files", "text/plain"], files: [f], getData: () => "t" } as unknown as DataTransfer;
    expect(transferContents(withFiles)).toEqual({ files: [f], text: null });
    const textOnly = { types: ["text/plain"], files: [], getData: (t: string) => (t === "text/plain" ? "hello" : "") } as unknown as DataTransfer;
    expect(transferContents(textOnly)).toEqual({ files: [], text: "hello" });
    expect(transferContents(null)).toEqual({ files: [], text: null });
  });
});
