import { describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { findImagePaths, pathLinksAt } from "../src/client/term-paths";

/// AN IMAGE PATH IN THE TERMINAL (docs/terminal.md, "An image path opens on the client"): what is a path to an image,
/// what is underlined, and the path it names.
const paths = (line: string) => findImagePaths(line).map((m) => ({ shown: line.slice(m.index, m.index + m.length), path: m.path }));

describe("findImagePaths", () => {
  it("finds absolute, home, relative and bare names, any case", () => {
    expect(paths("saved /Users/me/Desktop/shot.png and ~/a/b.JPG, then ./out/c.webp or d.gif")).toEqual([
      { shown: "/Users/me/Desktop/shot.png", path: "/Users/me/Desktop/shot.png" },
      { shown: "~/a/b.JPG", path: "~/a/b.JPG" },
      { shown: "./out/c.webp", path: "./out/c.webp" },
      { shown: "d.gif", path: "d.gif" },
    ]);
  });

  it("a quoted path keeps its spaces; an escaped space is a space", () => {
    expect(paths(`open 'Screenshot 2026-10-05 at 10.00.00.png' now`)).toEqual([
      { shown: "Screenshot 2026-10-05 at 10.00.00.png", path: "Screenshot 2026-10-05 at 10.00.00.png" }]);
    expect(paths(`"~/My Pictures/x.heic"`)).toEqual([{ shown: "~/My Pictures/x.heic", path: "~/My Pictures/x.heic" }]);
    expect(paths(String.raw`cp Screenshot\ 1.png /tmp/`)).toEqual([{ shown: String.raw`Screenshot\ 1.png`, path: "Screenshot 1.png" }]);
  });

  it("ends where a sentence or a bracket does, never inside a longer name", () => {
    expect(paths("see shot.png. And (logo.svg), [b.tif]: done")).toEqual([
      { shown: "shot.png", path: "shot.png" }, { shown: "logo.svg", path: "logo.svg" }, { shown: "b.tif", path: "b.tif" }]);
    expect(paths("--out=render.avif")).toEqual([{ shown: "render.avif", path: "render.avif" }]);
    for (const line of ["shot.png.bak", "archive.pngx", "png", "notes.txt", "a.png2", "x.jpg_old"]) expect(paths(line), line).toEqual([]);
  });

  it("an image URL is a link, never a path", () => {
    expect(paths("https://example.com/i/cat.png and file.png")).toEqual([{ shown: "file.png", path: "file.png" }]);
  });

  it("a file: URL naming an image is a path: the whole URL underlined, its escapes decoded, whatever its host", () => {
    expect(paths("saved file:///Users/me/Desktop/shot.png")).toEqual([
      { shown: "file:///Users/me/Desktop/shot.png", path: "/Users/me/Desktop/shot.png" }]);
    expect(paths("file://Isaacs-Mac.local/Users/me/Screenshot%202026-10-05%20at%2010.00.00%20(1).PNG")).toEqual([
      { shown: "file://Isaacs-Mac.local/Users/me/Screenshot%202026-10-05%20at%2010.00.00%20(1).PNG",
        path: "/Users/me/Screenshot 2026-10-05 at 10.00.00 (1).PNG" }]);
    expect(paths("FILE://localhost/tmp/%E2%9C%93.heic")).toEqual([{ shown: "FILE://localhost/tmp/%E2%9C%93.heic", path: "/tmp/✓.heic" }]);
  });

  it("a file: URL ends as a bare path does — a sentence, a bracket, a quote, a markdown link", () => {
    expect(paths("see file:///tmp/a.png. And (file:///tmp/b.jpg), [shot](file:///tmp/c.gif) 'file:///tmp/d.webp' <file:///tmp/e.svg>")
      .map((p) => p.shown)).toEqual(["file:///tmp/a.png", "file:///tmp/b.jpg", "file:///tmp/c.gif", "file:///tmp/d.webp", "file:///tmp/e.svg"]);
    expect(paths("file:///tmp/a.png?raw=1").map((p) => p.path)).toEqual(["/tmp/a.png"]);
  });

  it("a file: URL naming no image, or one that does not decode, is nothing — and no piece of it a bare path", () => {
    for (const line of ["file:///tmp/notes.txt", "file:///tmp/shot.png.bak", "file:///tmp/dir.png/notes.txt",
                        "file:///tmp/bad%zz.png", "https://example.com/?u=file:///tmp/a.png", "profile:///tmp/a.png"]) {
      expect(paths(line), line).toEqual([]);
    }
  });

  it("several on a line, in order", () => {
    expect(paths("a.png b.jpg").map((p) => p.path)).toEqual(["a.png", "b.jpg"]);
  });
});

/// A terminal `cols` wide showing `lines`, each ended by a real line break (as an app that wraps its own output writes).
async function screen(cols: number, lines: string[]): Promise<Terminal> {
  const term = new Terminal({ cols, rows: 24, allowProposedApi: true });
  await new Promise<void>((r) => term.write(lines.join("\r\n"), r));
  return term;
}
/// What a tap on each row would open, and the cells each row's piece covers (1-based columns).
const rowLinks = (term: Terminal, row: number) =>
  pathLinksAt(term, row + 1, () => {}).map((l) => ({ path: l.text, x: [l.range.start.x, l.range.end.x], y: l.range.start.y - 1 }));

describe("pathLinksAt — a path an APP broke over rows", () => {
  const PATH = "/Users/isaac/build/turingstown/artifacts/library-level-study/revised/street-approach.png";

  it("Codex's list, 51 columns: every row of a broken path opens the WHOLE path, each row its own piece", async () => {
    // As Codex drew it on an iPhone (2026-10-06): broken after `/` and `-`, the rest indented under the path.
    const term = await screen(51, [
      "• Paths:",
      "  • /Users/isaac/build/turingstown/artifacts/",
      "    library-level-study/revised/street-",
      "    approach.png",
      "  • /Users/isaac/build/turingstown/artifacts/",
      "    library-level-study/revised/gentle-",
      "    approach.png",
    ]);
    expect(rowLinks(term, 1)).toEqual([{ path: PATH, x: [5, 45], y: 1 }]);
    expect(rowLinks(term, 2)).toEqual([{ path: PATH, x: [5, 39], y: 2 }]);
    expect(rowLinks(term, 3)).toEqual([{ path: PATH, x: [5, 16], y: 3 }]);
    expect(rowLinks(term, 5).map((l) => l.path)).toEqual([PATH.replace("street-", "gentle-")]);
    expect(rowLinks(term, 0)).toEqual([]);
  });

  it("a path broken at the very last column, with no separator, is joined too", async () => {
    const head = "/Users/me/screenshots/2026/october/a-very-long-name";   // 51 characters: the whole row
    const term = await screen(51, [head, "-of-a-shot.png"]);
    expect(rowLinks(term, 1).map((l) => l.path)).toEqual([head + "-of-a-shot.png"]);
  });

  it("joins NOTHING that is not one path broken for want of room", async () => {
    const term = await screen(51, [
      "src/",                                                   // a short row: nothing was broken
      "a.png",
      "  /Users/isaac/build/a-long-directory/with/levels/",    // a long row, but the next is a NEW path
      "  /Users/isaac/x.png",
      "This sentence is long enough to wrap, a well-",         // a hyphen in prose: no path in it
      "known shot.png",
      "  • /Users/isaac/build/turingstown/artifacts/",          // the next row indented DEEPER than the path
      "        deeper.png",
    ]);
    expect(rowLinks(term, 1).map((l) => l.path)).toEqual(["a.png"]);
    expect(rowLinks(term, 3).map((l) => l.path)).toEqual(["/Users/isaac/x.png"]);
    expect(rowLinks(term, 5).map((l) => l.path)).toEqual(["shot.png"]);
    expect(rowLinks(term, 7).map((l) => l.path)).toEqual(["deeper.png"]);
  });

  it("a file: URL an app broke over rows opens whole, from every row", async () => {
    const term = await screen(51, [
      "  • file:///Users/isaac/build/turingstown/artifacts/",
      "    library-level-study/revised/street-approach.png",
    ]);
    expect(rowLinks(term, 0).map((l) => l.path)).toEqual([PATH]);
    expect(rowLinks(term, 1).map((l) => l.path)).toEqual([PATH]);
  });

  it("a path the TERMINAL wrapped is still one path", async () => {
    const term = new Terminal({ cols: 20, rows: 10, allowProposedApi: true });
    await new Promise<void>((r) => term.write("see /Users/me/pictures/shot.png ok", r));
    expect(rowLinks(term, 1).map((l) => l.path)).toEqual(["/Users/me/pictures/shot.png"]);
  });
});
