import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FILE_ANSWER_MS, FILE_STALL_MS, FileViewer, fileErrorText } from "../src/client/file-viewer";

/// THE CLIENT'S HALF OF AN IMAGE PATH OPENING (docs/terminal.md, "An image path opens on the client"): the request,
/// the pieces assembled into the picture, and every way it does not open — a note, never an empty modal.
describe("FileViewer", () => {
  let sent: Array<Record<string, unknown>>, notes: string[], flashed: string[], cleared: number[];
  let viewer: FileViewer;
  beforeEach(() => {
    vi.useFakeTimers();
    sent = []; notes = []; flashed = []; cleared = [];
    document.body.innerHTML = `<div id="stage"></div>`;
    // jsdom has no <dialog> modality: the methods only toggle `open`.
    HTMLDialogElement.prototype.showModal = function (this: HTMLDialogElement) { this.open = true; };
    HTMLDialogElement.prototype.close = function (this: HTMLDialogElement) { this.open = false; this.dispatchEvent(new Event("close")); };
    URL.createObjectURL = vi.fn(() => "blob:test");
    URL.revokeObjectURL = vi.fn();
    viewer = new FileViewer({
      send: (m) => sent.push(m as Record<string, unknown>),
      showNote: (t) => { notes.push(t); return notes.length; }, clearNote: (k) => cleared.push(k), flashNote: (t) => flashed.push(t),
      root: document.getElementById("stage")!,
    });
  });
  afterEach(() => { viewer.dispose(); vi.useRealTimers(); });
  const dialog = () => document.querySelector<HTMLDialogElement>(".file-viewer");
  const b64 = (s: string) => btoa(s);

  it("asks the host for the tab's path, shows only the decoded picture after assembling it", () => {
    viewer.open("tmux:$4", "shots/a.png");
    expect(sent).toEqual([{ t: "file-get", id: "f1", term: "tmux:$4", path: "shots/a.png" }]);
    expect(notes).toEqual([]);
    expect(dialog(), "nothing opens before the host says the image is coming").toBeNull();
    viewer.handle({ t: "file-begin", id: "f1", name: "a.png", mime: "image/png", size: 6, path: "/Users/me/shots/a.png" });
    expect(cleared).toEqual([]);
    expect(dialog()).toBeNull();
    viewer.handle({ t: "file-data", id: "f1", seq: 0, data: b64("abc") });
    expect(dialog()).toBeNull();
    viewer.handle({ t: "file-data", id: "f1", seq: 1, data: b64("def") });
    viewer.handle({ t: "file-end", id: "f1" });
    expect(URL.createObjectURL).toHaveBeenCalledOnce();
    const blob = vi.mocked(URL.createObjectURL).mock.calls[0]![0] as Blob;
    expect([blob.size, blob.type]).toEqual([6, "image/png"]);
    expect(dialog()!.querySelector("img")!.getAttribute("src")).toBe("blob:test");
    expect(dialog()?.open).toBe(false);
    dialog()!.querySelector('img')!.dispatchEvent(new Event('load'));
    expect(dialog()?.open).toBe(true);
    expect(dialog()!.classList.contains('ss-dialog')).toBe(true);
    expect(dialog()!.querySelector('.file-viewer-name')!.textContent).toBe('a.png');
  });

  it("a path that names no image opens nothing: a note says why", () => {
    for (const [reason, text] of [["not-found", "No such file: x.png"], ["not-image", "Not an image: x.png"],
                                   ["too-large", "Too large to preview (over 20 MB): x.png"], ["not-driver", "Only the device in control can open files"]]) {
      viewer.open("pty:1", "x.png");
      viewer.handle({ t: "file-error", id: `f${sent.length}`, reason });
      expect(flashed.at(-1)).toBe(text);
      expect(fileErrorText(reason!, "x.png")).toBe(text);
    }
    expect(dialog()).toBeNull();
  });

  it("a Mac that does not answer, and one that stops sending, are said; their late messages change nothing", () => {
    viewer.open("pty:1", "a.png");
    vi.advanceTimersByTime(FILE_ANSWER_MS);
    expect(flashed).toEqual(["The Mac did not answer"]);
    expect(viewer.handle({ t: "file-begin", id: "f1", name: "a.png", mime: "image/png", size: 3 }), "still the viewer's").toBe(true);
    expect(dialog()).toBeNull();
    viewer.open("pty:1", "b.png");
    viewer.handle({ t: "file-begin", id: "f2", name: "b.png", mime: "image/png", size: 3 });
    vi.advanceTimersByTime(FILE_STALL_MS);
    expect(dialog()).toBeNull();
    expect(flashed.at(-1)).toBe("The Mac stopped sending b.png");
  });

  it("a newer tap drops the request before it; a piece out of order fails it; other messages are not its", () => {
    viewer.open("pty:1", "a.png");
    viewer.open("pty:1", "b.png");
    viewer.handle({ t: "file-begin", id: "f1", name: "a.png", mime: "image/png", size: 3 });
    expect(dialog(), "the dropped request's answer opens nothing").toBeNull();
    viewer.handle({ t: "file-begin", id: "f2", name: "b.png", mime: "image/png", size: 6 });
    viewer.handle({ t: "file-data", id: "f2", seq: 1, data: b64("abc") });
    expect(dialog()).toBeNull();
    expect(flashed.at(-1)).toBe("Could not open b.png");
    expect(viewer.handle({ t: "term-list", tabs: [] })).toBe(false);
  });

  it("closing takes the picture away and drops a request on its way", () => {
    viewer.open("pty:1", "a.png");
    viewer.handle({ t: "file-begin", id: "f1", name: "a.png", mime: "image/png", size: 3 });
    viewer.close();
    expect(dialog()?.open ?? false).toBe(false);
    viewer.handle({ t: "file-data", id: "f1", seq: 0, data: b64("abc") });
    viewer.handle({ t: "file-end", id: "f1" });
    expect(URL.createObjectURL).not.toHaveBeenCalled();
  });
  it('closing during image decoding prevents a late load from reopening the preview',()=>{
    viewer.open('pty:1','a.png');
    viewer.handle({t:'file-begin',id:'f1',name:'a.png',mime:'image/png',size:3});
    viewer.handle({t:'file-data',id:'f1',seq:0,data:b64('abc')});
    viewer.handle({t:'file-end',id:'f1'});
    const image=dialog()!.querySelector('img')!;
    const load=image.onload!;
    viewer.close();load.call(image,new Event('load'));
    expect(dialog()?.open).toBe(false);expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:test');
  });
  it('the close button releases a decoded preview',()=>{
    viewer.open('pty:1','a.png');
    viewer.handle({t:'file-begin',id:'f1',name:'a.png',mime:'image/png',size:3});
    viewer.handle({t:'file-data',id:'f1',seq:0,data:b64('abc')});
    viewer.handle({t:'file-end',id:'f1'});
    dialog()!.querySelector('img')!.dispatchEvent(new Event('load'));
    expect(dialog()?.open).toBe(true);
    dialog()!.querySelector<HTMLButtonElement>('.file-viewer-close')!.click();
    expect(dialog()?.open).toBe(false);expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:test');
  });

});
