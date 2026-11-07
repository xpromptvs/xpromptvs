import { describe, expect, it, vi } from "vitest";
import {
  folderQuestion, localPasteApi, megabytes, pathPieces, quotedPath, sizeQuestion,
} from "../src/client/paste-local";
import typing from "../../protocol/fixtures/paste-typing.json";

// THE SAME VECTORS THE HOST TYPES A SAVED FILE'S PATH WITH (RdevCore `PasteTyping`): a folder's path pasted on
// This Mac is typed exactly as a pasted file's path is, so Claude Code and Codex take both alike.
describe("a path as it is typed — protocol/fixtures/paste-typing.json, shared with the host", () => {
  it.each(typing.quoted)("$path", (v) => { expect(quotedPath(v.path)).toBe(v.typed); });
  it("each path its own piece, followed by a space", () => {
    expect(pathPieces(typing.pieces.paths)).toEqual(typing.pieces.typed);
  });
});

describe("localPasteApi — the app's `__rdevShell`", () => {
  it("is null outside the app, and in an app shell that predates it", () => {
    expect(localPasteApi(undefined)).toBeNull();
    expect(localPasteApi({})).toBeNull();
    expect(localPasteApi({ pasteboardFiles: async () => [], preparePaste: async () => [], discardPaste: async () => null })).toBeNull();
  });
  it("reads what was copied, prepares paths and discards urls through the shell", async () => {
    const shell = {
      pasteboardFiles: vi.fn(async () => [{ path: "/a/P", name: "P", dir: true }, { path: 3 }, { path: "/a/n.txt", name: "n.txt", dir: false }]),
      preparePaste: vi.fn(async () => [{ url: "app://client/__paste/t/P.zip", name: "P.zip", type: "application/zip", size: 9 }]),
      discardPaste: vi.fn(async () => null),
      cancelPaste: vi.fn(async () => null),
    };
    const api = localPasteApi(shell)!;
    expect(await api.files()).toEqual([{ path: "/a/P", name: "P", dir: true }, { path: "/a/n.txt", name: "n.txt", dir: false }]);
    expect(await api.prepare(["/a/P"])).toEqual([{ url: "app://client/__paste/t/P.zip", name: "P.zip", type: "application/zip", size: 9 }]);
    expect(shell.preparePaste).toHaveBeenCalledWith(["/a/P"]);
    api.discard(["app://client/__paste/t/P.zip"]);
    expect(shell.discardPaste).toHaveBeenCalledWith(["app://client/__paste/t/P.zip"]);
    api.cancel();
    expect(shell.cancelPaste).toHaveBeenCalledTimes(1);
  });
  it("a refusal (a `-`-prefixed reason, the bridge's way) rejects with it; a malformed answer rejects", async () => {
    const api = localPasteApi({ pasteboardFiles: async () => "nope", preparePaste: async () => "-not-offered", discardPaste: async () => null, cancelPaste: async () => null })!;
    expect(await api.files()).toEqual([]);
    await expect(api.prepare(["/x"])).rejects.toThrow("not-offered");
    const bad = localPasteApi({ pasteboardFiles: async () => [], preparePaste: async () => [{ url: 1 }], discardPaste: async () => null, cancelPaste: async () => null })!;
    await expect(bad.prepare(["/x"])).rejects.toThrow();
  });
  it("a shell that throws reads as nothing copied, never as an error", async () => {
    const api = localPasteApi({ pasteboardFiles: async () => { throw new Error("gone"); }, preparePaste: async () => [], discardPaste: async () => null, cancelPaste: async () => null })!;
    expect(await api.files()).toEqual([]);
  });
});

describe("what the person is asked", () => {
  const P = { path: "/u/Projects", name: "Projects", dir: true };
  const Q = { path: "/u/Notes", name: "Notes", dir: true };
  const f = { path: "/u/a.txt", name: "a.txt", dir: false };
  it("one folder: by name, its path or a zip", () => {
    expect(folderQuestion([P])).toEqual({
      title: "Paste “Projects”",
      body: "It is a folder on this Mac. Paste its path, or compress it and send it as a .zip.",
      path: "Paste the path", send: "Compress and send",
    });
  });
  it("several: counted, and the files beside the folders are said to go as they are", () => {
    expect(folderQuestion([P, Q])).toEqual({
      title: "Paste 2 folders",
      body: "They are folders on this Mac. Paste their paths, or compress them and send them as .zip files.",
      path: "Paste the paths", send: "Compress and send",
    });
    expect(folderQuestion([P, f])).toEqual({
      title: "Paste 2 items",
      body: "“Projects” is a folder on this Mac. Paste the paths, or compress the folder and send it with the file as it is.",
      path: "Paste the paths", send: "Compress and send",
    });
  });
  it("a big paste says its size and that it may take a while", () => {
    expect(megabytes(73 * 1024 * 1024)).toBe(73);
    expect(megabytes(100)).toBe(1);
    expect(sizeQuestion("Projects.zip", 73 * 1024 * 1024)).toBe("Send Projects.zip? It is 73 MB, so it may take a while.");
    expect(sizeQuestion("3 files", 120 * 1024 * 1024)).toBe("Send 3 files? They are 120 MB, so they may take a while.");
  });
});
