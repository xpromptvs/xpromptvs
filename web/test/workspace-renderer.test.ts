// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { WorkspaceRenderer, validWorkspacePresentation, workspacePanelSize } from "../src/client/workspace-renderer";

const presentation = { format: "workspace-rgb-alpha-hit-v1", logicalWidth: 1280, logicalHeight: 800 } as const;
function fixture() {
  let width = 3840, height = 800, hit = 255, error = 0;
  const gl = new Proxy({
    getParameter: () => 4096, getShaderParameter: () => true, getProgramParameter: () => true,
    getAttribLocation: () => 0, getUniformLocation: () => ({}),
    checkFramebufferStatus: () => 0x8cd5, getError: () => error, isContextLost: () => false,
    readPixels: vi.fn((_x, _y, _w, _h, _format, _type, out) => { out[0] = hit; }),
    texImage2D: vi.fn(), drawArrays: vi.fn(), deleteTexture: vi.fn(),
    FRAMEBUFFER_COMPLETE: 0x8cd5, NO_ERROR: 0,
  } as Record<string, any>, { get: (target, key: string) => key in target ? target[key] : key.startsWith("create") ? () => ({}) : /^[A-Z_0-9]+$/.test(key) ? 1 : vi.fn() });
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(gl as any);
  const video = document.createElement("video");
  Object.defineProperties(video, { videoWidth: { get: () => width }, videoHeight: { get: () => height }, readyState: { get: () => 4 } });
  let next = 0;
  const callbacks = new Map<number, VideoFrameRequestCallback>();
  video.requestVideoFrameCallback = vi.fn(cb => { callbacks.set(++next, cb); return next; });
  video.cancelVideoFrameCallback = vi.fn(id => { callbacks.delete(id); });
  const renderer = new WorkspaceRenderer(video, presentation);
  return { video, renderer, gl, callbacks, setHit: (v: number) => { hit = v; }, setError: (v: number) => { error = v; },
    resize: (w: number, h: number) => { width = w; height = h; },
    frame: () => { const [id, cb] = callbacks.entries().next().value!; callbacks.delete(id); cb(0, {} as VideoFrameCallbackMetadata); } };
}
afterEach(() => vi.restoreAllMocks());

describe("workspace presentation contract", () => {
  it("rejects unknown formats, invalid logical geometry and oversized/misaligned coded frames", () => {
    expect(validWorkspacePresentation(presentation)).toBe(true);
    for (const value of [null, {}, { ...presentation, format: "rgb" }, { ...presentation, logicalWidth: NaN }, { ...presentation, logicalHeight: 801 }]) expect(validWorkspacePresentation(value)).toBe(false);
    expect(workspacePanelSize(presentation, 3840, 800)).toEqual({ w: 1280, h: 800 });
    expect(workspacePanelSize(presentation, 1920, 400)).toEqual({ w: 640, h: 400 });
    for (const [w,h] of [[0,0],[3841,800],[7680,1600],[1280,800],[3840,799]]) expect(workspacePanelSize(presentation,w!,h!)).toBeNull();
  });
});

describe("workspace frame and mask ownership", () => {
  it("has one outstanding callback and admits hits only after both passes from one upload", () => {
    const f=fixture(); expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.renderer.start(); f.renderer.start(); expect(f.callbacks.size).toBe(1);
    f.frame(); expect(f.callbacks.size).toBe(1);
    expect(f.gl.drawArrays).toHaveBeenCalledTimes(2);
    expect(f.gl.texImage2D.mock.calls.filter((a: any[]) => a.at(-1)===f.video)).toHaveLength(1);
    expect(f.renderer.hitAt(.5,.5)).toBe(true);
    expect(f.gl.readPixels.mock.calls.at(-1).slice(0,4)).toEqual([640,399,1,1]);
    f.setHit(127); expect(f.renderer.hitAt(1,1)).toBe(false);
    f.setHit(128); expect(f.renderer.hitAt(0,0)).toBe(true);
    expect(f.renderer.hitAt(-.1,0)).toBe(false); expect(f.renderer.hitAt(NaN,0)).toBeNull();
    f.renderer.dispose(); expect(f.callbacks.size).toBe(0);
  });
  it("invalidates old masks immediately on decoded geometry or track replacement", () => {
    const f=fixture(); f.renderer.start(); f.frame();
    f.resize(1920,400); expect(f.renderer.hitAt(.5,.5)).toBeNull(); f.frame(); expect(f.renderer.hitAt(.5,.5)).toBe(true);
    Object.defineProperty(f.video,"srcObject",{value:{getVideoTracks:()=>[{id:"replacement"}]},configurable:true});
    expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.renderer.reset(); expect(f.callbacks.size).toBe(1); expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.frame(); expect(f.renderer.hitAt(.5,.5)).toBe(true); f.renderer.dispose();
  });
  it("fails closed on unsupported frames, GPU errors and context loss", () => {
    const f=fixture(); f.renderer.start(); f.frame(); f.resize(7680,1600); f.frame(); expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.resize(3840,800); f.setError(1282); f.frame(); expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.setError(0); f.frame(); expect(f.renderer.hitAt(.5,.5)).toBe(true);
    f.renderer.canvas.dispatchEvent(new Event("webglcontextlost",{cancelable:true}));
    expect(f.renderer.hitAt(.5,.5)).toBeNull(); expect(f.callbacks.size).toBe(0);
    f.renderer.canvas.dispatchEvent(new Event("webglcontextrestored")); expect(f.callbacks.size).toBe(1);
    expect(f.renderer.hitAt(.5,.5)).toBeNull(); f.frame(); expect(f.renderer.hitAt(.5,.5)).toBe(true); f.renderer.dispose();
  });
  it("stop/reset fence a queued old callback and dispose is final", () => {
    const f=fixture(); f.renderer.start(); const stale=[...f.callbacks.values()][0];
    f.renderer.reset(); stale!(0,{} as VideoFrameCallbackMetadata); expect(f.gl.drawArrays).not.toHaveBeenCalled(); expect(f.callbacks.size).toBe(1);
    f.renderer.stop(); expect(f.callbacks.size).toBe(0); expect(f.renderer.hitAt(.5,.5)).toBeNull();
    f.renderer.start(); f.frame(); f.renderer.dispose(); f.renderer.dispose(); f.renderer.start();
    expect(f.callbacks.size).toBe(0); expect(f.renderer.hitAt(.5,.5)).toBeNull(); expect(f.gl.deleteTexture).toHaveBeenCalled();
  });
});
it('does not route using the last mask after its MediaStream track ends',()=>{
 const f=fixture();const track={id:'ended-test',readyState:'live'};
 Object.defineProperty(f.video,'srcObject',{value:{getVideoTracks:()=>[track]},configurable:true});
 f.renderer.start();f.frame();expect(f.renderer.hitAt(.5,.5)).toBe(true);
 track.readyState='ended';expect(f.renderer.hitAt(.5,.5)).toBeNull();f.renderer.dispose();
});
