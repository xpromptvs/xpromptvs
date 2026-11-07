import { afterEach, describe, expect, it, vi } from "vitest";
import { deflateSync } from "fflate";
import { PREVIEW_HANDOVER_MS, PREVIEW_MAX_MS, TermPreview, joinHello, parseTermScreen } from "../src/client/offer-screen";
import { storedDeflate } from "./support/term-wire";
import type { XtermView, XtermViewOpts } from "../src/client/xterm-view";

/// THE OFFER'S SCREEN (docs/sources-and-focus.md, "The offer carries the tab bar"): what the page says as it joins, the
/// screen the host's offer carries, and the inert picture painted under the tab's slot until its own content comes.
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const text = (u: Uint8Array) => new TextDecoder().decode(u);

describe("joinHello", () => {
  it("says the join intent, and the grid when it has one, as JSON the host's JoinHello reads", () => {
    expect(text(joinHello({ grid: { cols: 120, rows: 40 }, intent: "connect" }))).toBe('{"grid":{"cols":120,"rows":40},"intent":"connect"}');
    expect(text(joinHello({ grid: null, intent: "reconnect" }))).toBe('{"intent":"reconnect"}');
  });
});

describe("parseTermScreen", () => {
  const screen = new TextEncoder().encode("\x1b[H\x1b[2Jhello, \x1b[32mworld\x1b[0m");
  it("inflates the host's raw DEFLATE, and the mock's stored blocks", () => {
    for (const packed of [deflateSync(screen, { level: 6 }), storedDeflate(screen)]) {
      const s = parseTermScreen({ t: "term-screen", id: "tmux:$4", cols: 120, rows: 40, data: b64(packed) });
      expect(s && { id: s.id, cols: s.cols, rows: s.rows, text: text(s.bytes) })
        .toEqual({ id: "tmux:$4", cols: 120, rows: 40, text: text(screen) });
    }
  });

  it("anything else is no screen — never a fault", () => {
    const data = b64(storedDeflate(screen));
    for (const m of [null, 7, {}, { t: "term-list" }, { t: "term-screen", id: 3, cols: 80, rows: 24, data },
                     { t: "term-screen", id: "pty:1", cols: 0, rows: 24, data },
                     { t: "term-screen", id: "pty:1", cols: 80.5, rows: 24, data },
                     { t: "term-screen", id: "pty:1", cols: 80, rows: 24, data: "%%% not base64" },
                     { t: "term-screen", id: "pty:1", cols: 80, rows: 24, data: b64(new Uint8Array([0xff, 0xfe, 0xfd])) }]) {
      expect(parseTermScreen(m), JSON.stringify(m)).toBeNull();
    }
  });
});

describe("TermPreview", () => {
  afterEach(() => { vi.useRealTimers(); document.body.innerHTML = ""; });

  /// A fake xterm: what the preview asked of it.
  function fakeMount() {
    const calls: string[] = [];
    let opts: XtermViewOpts | undefined;
    const mount = (_el: HTMLElement, o: XtermViewOpts): XtermView => {
      opts = o;
      return {
        resizeTo: (c: number, r: number) => calls.push(`resize ${c}x${r}`),
        write: (d: string | Uint8Array) => calls.push(`write ${typeof d === "string" ? d : text(d)}`),
        dispose: () => calls.push("dispose"),
      } as unknown as XtermView;
    };
    return { mount, calls, opts: () => opts! };
  }
  const SCREEN = { id: "tmux:$2", cols: 90, rows: 30, bytes: new TextEncoder().encode("the screen") };

  it("paints the screen at its grid, inert, UNDER every slot, with tmux's widths for a tmux tab", () => {
    document.body.innerHTML = `<div id="xterm"><canvas class="xterm-gpu-surface"></canvas><div class="xterm-tab"></div></div>`;
    const area = document.getElementById("xterm")!;
    const f = fakeMount();
    const p = new TermPreview(area, f.mount);
    p.show(SCREEN, { fontSize: 13, theme: {} as never });
    const el = area.querySelector<HTMLElement>(".xterm-preview")!;
    expect([...area.children].map((c) => c.className)).toEqual(["xterm-gpu-surface", "xterm-preview", "xterm-tab"]);
    expect(el.inert).toBe(true);
    expect(f.calls).toEqual(["resize 90x30", "write the screen"]);
    expect(f.opts()).toMatchObject({ widths: "tmux", renderer: "dom", fontSize: 13 });
    expect(p.tab).toBe("tmux:$2");
  });

  it("goes at once, after the handover, or at the latest after PREVIEW_MAX_MS — and only once", () => {
    vi.useFakeTimers();
    document.body.innerHTML = `<div id="xterm"></div>`;
    const area = document.getElementById("xterm")!;
    const f = fakeMount();
    const p = new TermPreview(area, f.mount);
    p.show(SCREEN, { fontSize: 13, theme: {} as never });
    p.remove(PREVIEW_HANDOVER_MS);
    vi.advanceTimersByTime(PREVIEW_HANDOVER_MS - 1);
    expect(area.querySelector(".xterm-preview"), "still under the fading slot").not.toBeNull();
    vi.advanceTimersByTime(1);
    expect(area.querySelector(".xterm-preview")).toBeNull();
    expect(p.tab).toBeNull();
    p.show(SCREEN, { fontSize: 13, theme: {} as never });
    vi.advanceTimersByTime(PREVIEW_MAX_MS);
    expect(area.querySelector(".xterm-preview"), "no stale picture").toBeNull();
    p.remove();
    expect(f.calls.filter((c) => c === "dispose")).toHaveLength(2);
  });
});

 it('advertises fast data only when explicitly requested within the bounded hello', () => {
   const bytes = joinHello({grid: {cols:80,rows:24}, intent:'connect', fastData:1});
   expect(JSON.parse(new TextDecoder().decode(bytes))).toEqual({grid:{cols:80,rows:24},intent:'connect',fastData:1});
   expect(bytes.length).toBeLessThanOrEqual(1024);
 });
