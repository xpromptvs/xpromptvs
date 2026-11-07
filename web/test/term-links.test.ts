import { describe, expect, it } from "vitest";
import { openableLink, openLink } from "../src/client/term-links";

describe("openableLink", () => {
  it("opens http and https, normalised", () => {
    expect(openableLink("https://example.com/a?b=1#c")).toBe("https://example.com/a?b=1#c");
    expect(openableLink("HTTP://Example.com")).toBe("http://example.com/");
    expect(openableLink("http://localhost:5173")).toBe("http://localhost:5173/");
  });
  it("refuses everything else: javascript:, a file (on a remote Mac it names THAT Mac's), other schemes, junk", () => {
    for (const s of ["javascript:alert(1)", "file:///etc/passwd", "mailto:a@b.c", "app://client/index.html",
                     "ssh://host", "data:text/html,x", "not a url", ""]) expect(openableLink(s), s).toBeNull();
  });
});

describe("openLink", () => {
  it("opens an allowed link in a new tab, noopener — and nothing else", () => {
    const calls: unknown[][] = [];
    const open = (...a: unknown[]) => { calls.push(a); };
    expect(openLink("https://example.com/x", open)).toBe(true);
    expect(openLink("javascript:alert(1)", open)).toBe(false);
    expect(calls).toEqual([["https://example.com/x", "_blank", "noopener,noreferrer"]]);
  });
});
