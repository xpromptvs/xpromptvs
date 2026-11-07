/** Experimental application-workspace presentation. The caller owns source admission, input routing,
 * video binding and DOM placement. Never expose the packed <video> as a fallback picture.
 * Call reset() before replacing its track, stop() on disconnect, and dispose() on source removal.
 * One video upload supplies both the visible premultiplied picture and its semantic hit mask. */
export interface WorkspacePresentation {
  format: "workspace-rgb-alpha-hit-v1";
  logicalWidth: 1280;
  logicalHeight: 800;
}
export function validWorkspacePresentation(value: unknown): value is WorkspacePresentation {
  if (!value || typeof value !== "object") return false;
  const p = value as Partial<WorkspacePresentation>;
  return p.format === "workspace-rgb-alpha-hit-v1" && p.logicalWidth === 1280 && p.logicalHeight === 800;
}
export function workspacePanelSize(p: WorkspacePresentation, width: number, height: number): { w: number; h: number } | null {
  if (!validWorkspacePresentation(p) || !Number.isInteger(width) || !Number.isInteger(height)
      || width <= 0 || height <= 0 || width > 3840 || height > 800 || width % 3 !== 0
      || width / 3 * p.logicalHeight !== height * p.logicalWidth) return null;
  return { w: width / 3, h: height };
}

const VERTEX = "attribute vec2 p;varying vec2 uv;void main(){uv=(p+1.)*.5;gl_Position=vec4(p,0.,1.);}";
const FRAGMENT = `precision highp float;varying vec2 uv;uniform sampler2D tex;uniform float maskPass;
void main(){vec3 c=texture2D(tex,vec2(uv.x/3.,uv.y)).rgb;
float a=texture2D(tex,vec2((1.+uv.x)/3.,uv.y)).r;
float h=texture2D(tex,vec2((2.+uv.x)/3.,uv.y)).r;
gl_FragColor=maskPass>.5?vec4(h,h,h,1.):vec4(min(c,vec3(a)),a);}`;
interface Resources {
  program: WebGLProgram; buffer: WebGLBuffer; video: WebGLTexture; mask: WebGLTexture;
  framebuffer: WebGLFramebuffer; pass: WebGLUniformLocation | null;
}

export class WorkspaceRenderer {
  readonly canvas: HTMLCanvasElement;
  private readonly gl: WebGLRenderingContext;
  private resources: Resources | null = null;
  private callback: number | null = null;
  private epoch = 0;
  private running = false;
  private disposed = false;
  private lost = false;
  private ready = false;
  private width = 0;
  private height = 0;
  private source: HTMLVideoElement["srcObject"] = null;
  private track = "";
  private readonly pixel = new Uint8Array(4);
  private readonly listeners = new AbortController();

  constructor(private readonly video: HTMLVideoElement, private readonly presentation: WorkspacePresentation) {
    if (!validWorkspacePresentation(presentation)) throw new Error("Unsupported workspace presentation");
    if (!video.requestVideoFrameCallback || !video.cancelVideoFrameCallback) throw new Error("Workspace requires video frame callbacks");
    this.canvas = video.ownerDocument.createElement("canvas");
    this.canvas.className = "workspace-picture";
    this.canvas.style.pointerEvents = "none";
    this.canvas.style.background = "transparent";
    this.canvas.width = presentation.logicalWidth; this.canvas.height = presentation.logicalHeight;
    const gl = this.canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error("Workspace requires WebGL");
    this.gl = gl;
    this.initialize();
    const signal = this.listeners.signal;
    this.canvas.addEventListener("webglcontextlost", e => {
      e.preventDefault(); this.lost = true; this.setReady(false); this.cancel(); this.resources = null;
    }, { signal });
    this.canvas.addEventListener("webglcontextrestored", () => {
      if (this.disposed) return;
      this.lost = false;
      try { this.initialize(); this.reset(); } catch { this.stop(); }
    }, { signal });
    video.addEventListener("emptied", () => this.reset(), { signal });
    video.addEventListener("resize", () => this.reset(), { signal });
  }

  logicalSize(): { w: number; h: number } { return { w: this.presentation.logicalWidth, h: this.presentation.logicalHeight }; }
  start(): void {
    if (this.disposed || this.running) return;
    this.running = true; this.reset();
  }
  stop(): void { this.running = false; this.cancel(); this.invalidate(); }
  reset(): void {
    if (this.disposed) return;
    this.cancel(); this.invalidate();
    this.source = this.video.srcObject; this.track = this.trackIdentity();
    this.schedule();
  }
  dispose(): void {
    if (this.disposed) return;
    this.stop(); this.disposed = true; this.listeners.abort(); this.release(); this.canvas.remove();
  }

  /** Normalized logical coordinates, not coded-panel coordinates. null means UNKNOWN: callers must
   * not treat it as a terminal gap. Bounds outside a ready picture are transparent. */
  hitAt(x: number, y: number): boolean | null {
    if (this.disposed || this.lost || !this.ready || !Number.isFinite(x) || !Number.isFinite(y)) return null;
    if (!this.sameSource() || this.video.videoWidth !== this.width * 3 || this.video.videoHeight !== this.height) {
      this.reset(); return null;
    }
    if (x < 0 || y < 0 || x > 1 || y > 1) return false;
    const gl = this.gl, r = this.resources;
    if (!r || gl.isContextLost()) { this.invalidate(); return null; }
    try {
      gl.bindFramebuffer(gl.FRAMEBUFFER, r.framebuffer);
      gl.readPixels(Math.min(this.width - 1, Math.floor(x * this.width)),
        this.height - 1 - Math.min(this.height - 1, Math.floor(y * this.height)), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, this.pixel);
      if (gl.getError() !== gl.NO_ERROR) { this.invalidate(); return null; }
      return this.pixel[0]! >= 128;
    } catch { this.invalidate(); return null; }
    finally { gl.bindFramebuffer(gl.FRAMEBUFFER, null); }
  }

  private trackIdentity(): string {
    const stream = this.video.srcObject;
    return stream && "getVideoTracks" in stream ? stream.getVideoTracks().map(t => t.id).join("\0") : this.video.currentSrc;
  }
  private sameSource(): boolean {
    const stream = this.video.srcObject;
    const ended = stream && "getVideoTracks" in stream && stream.getVideoTracks().some(t => t.readyState === "ended");
    return !ended && this.source === stream && this.track === this.trackIdentity();
  }
  private cancel(): void {
    ++this.epoch;
    if (this.callback !== null) this.video.cancelVideoFrameCallback(this.callback);
    this.callback = null;
  }
  get isReady(): boolean { return this.ready; }
  private setReady(value: boolean): void {
    if (this.ready === value) return;
    this.ready = value;
    this.canvas.dispatchEvent(new Event("workspacereadychange"));
  }
  private invalidate(): void {
    this.setReady(false);
    if (this.lost || this.disposed) return;
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
  }
  private schedule(): void {
    if (!this.running || this.disposed || this.lost || this.callback !== null) return;
    const epoch = this.epoch;
    this.callback = this.video.requestVideoFrameCallback(() => {
      if (epoch !== this.epoch || !this.running || this.disposed || this.lost) return;
      this.callback = null;
      if (!this.sameSource()) { this.reset(); return; }
      try { this.paint(); } catch { this.invalidate(); }
      this.schedule();
    });
  }
  private paint(): void {
    const gl = this.gl, r = this.resources;
    const size = workspacePanelSize(this.presentation, this.video.videoWidth, this.video.videoHeight);
    if (!r || !size || this.video.readyState < 2 || gl.isContextLost()) { this.invalidate(); return; }
    if (this.width !== size.w || this.height !== size.h) {
      this.width = size.w; this.height = size.h;
      this.canvas.width = size.w; this.canvas.height = size.h;
      gl.bindTexture(gl.TEXTURE_2D, r.mask);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, size.w, size.h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, r.framebuffer);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, r.mask, 0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) { this.invalidate(); return; }
    }
    gl.useProgram(r.program); gl.viewport(0, 0, size.w, size.h);
    gl.bindTexture(gl.TEXTURE_2D, r.video);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, this.video);
    gl.bindFramebuffer(gl.FRAMEBUFFER, r.framebuffer); gl.uniform1f(r.pass, 1); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.uniform1f(r.pass, 0); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    if (gl.getError() !== gl.NO_ERROR) { this.invalidate(); return; }
    this.setReady(true);
  }
  private initialize(): void {
    const gl = this.gl;
    if (gl.getParameter(gl.MAX_TEXTURE_SIZE) < 3840 || gl.getParameter(gl.MAX_RENDERBUFFER_SIZE) < 1280) throw new Error("Workspace resolution unsupported");
    const shaders: WebGLShader[] = [];
    let program: WebGLProgram | null = null, buffer: WebGLBuffer | null = null;
    let video: WebGLTexture | null = null, mask: WebGLTexture | null = null, framebuffer: WebGLFramebuffer | null = null;
    try {
      program = gl.createProgram(); if (!program) throw new Error("Workspace program allocation failed");
      for (const [type, code] of [[gl.VERTEX_SHADER, VERTEX], [gl.FRAGMENT_SHADER, FRAGMENT]] as const) {
        const shader = gl.createShader(type); if (!shader) throw new Error("Workspace shader allocation failed");
        shaders.push(shader); gl.shaderSource(shader, code); gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error("Workspace shader compilation failed");
        gl.attachShader(program, shader);
      }
      gl.linkProgram(program); if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error("Workspace shader link failed");
      gl.useProgram(program); buffer = gl.createBuffer(); if (!buffer) throw new Error("Workspace buffer allocation failed");
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,1,1]), gl.STATIC_DRAW);
      const p = gl.getAttribLocation(program, "p"); gl.enableVertexAttribArray(p); gl.vertexAttribPointer(p, 2, gl.FLOAT, false, 0, 0);
      video = gl.createTexture(); mask = gl.createTexture(); framebuffer = gl.createFramebuffer();
      if (!video || !mask || !framebuffer) throw new Error("Workspace texture allocation failed");
      gl.activeTexture(gl.TEXTURE0); gl.uniform1i(gl.getUniformLocation(program, "tex"), 0);
      for (const texture of [video, mask]) {
        gl.bindTexture(gl.TEXTURE_2D, texture);
        for (const key of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, key, texture === video ? gl.LINEAR : gl.NEAREST);
        for (const key of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T]) gl.texParameteri(gl.TEXTURE_2D, key, gl.CLAMP_TO_EDGE);
      }
      this.resources = { program, buffer, video, mask, framebuffer, pass: gl.getUniformLocation(program, "maskPass") };
      this.width = this.height = 0; this.invalidate();
    } catch (error) {
      if (program) gl.deleteProgram(program); if (buffer) gl.deleteBuffer(buffer);
      if (video) gl.deleteTexture(video); if (mask) gl.deleteTexture(mask); if (framebuffer) gl.deleteFramebuffer(framebuffer);
      throw error;
    } finally { for (const shader of shaders) gl.deleteShader(shader); }
  }
  private release(): void {
    const r = this.resources; this.resources = null;
    if (!r || this.lost) return;
    const gl = this.gl;
    gl.deleteProgram(r.program); gl.deleteBuffer(r.buffer); gl.deleteTexture(r.video); gl.deleteTexture(r.mask); gl.deleteFramebuffer(r.framebuffer);
  }
}
