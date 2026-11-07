/// **THE ONE GPU DEVICE EVERY WEBGPU TERMINAL SHARES.** WebGL caps a page at 16 contexts in both engines
/// (measured: 20 terminals, 4 lost — docs/superpowers/specs/2026-10-03-gpu-terminal-renderer-spike.md), and
/// every open tab keeps a live terminal; one `GPUDevice` drives any number of canvases.
///
/// Requested once, on first use. A SOFTWARE adapter (`isFallbackAdapter` — SwiftShader, headless Chromium
/// without a GPU) is refused: it draws slower than the DOM renderer it would replace. No adapter, no device
/// or a refusal answers null, remembered — the DOM renderer draws and nothing asks again. A device that is
/// LOST tells every terminal on it (they go back to the DOM renderer), and the next request starts afresh.

let pending: Promise<GPUDevice | null> | null = null;
/// The device once the request has settled with one — so a terminal mounted after can attach at once.
let ready: GPUDevice | null = null;
const lostListeners = new Set<() => void>();

/// The shared device if it is already there (no waiting); null otherwise.
export function readyGpu(): GPUDevice | null { return ready; }

/// Where the shared device stands: never asked for, being asked for, there, or not to be had here.
export type GpuState = "untried" | "pending" | "ready" | "unavailable";
let settled = false;
export function gpuState(): GpuState {
  if (ready) return "ready";
  if (!pending) return "untried";
  return settled ? "unavailable" : "pending";
}

/// WebGPU exists in this browser at all (`navigator.gpu`) — no adapter has been asked for.
export function webgpuExists(): boolean {
  return typeof navigator !== "undefined" && typeof (navigator as Navigator & { gpu?: unknown }).gpu === "object"
    && (navigator as Navigator & { gpu?: unknown }).gpu !== null;
}

/// The shared device, or null where WebGPU cannot draw here.
export function requestGpu(): Promise<GPUDevice | null> {
  if (pending) return pending;
  settled = false;
  pending = (async () => {
    if (!webgpuExists()) return null;
    try {
      const adapter = await navigator.gpu.requestAdapter({ powerPreference: "low-power" });
      if (!adapter) return null;
      // Newer browsers report it on `info`; older ones on the adapter.
      const fallback = (adapter.info as GPUAdapterInfo & { isFallbackAdapter?: boolean } | undefined)?.isFallbackAdapter
        ?? (adapter as GPUAdapter & { isFallbackAdapter?: boolean }).isFallbackAdapter ?? false;
      if (fallback) return null;
      const device = await adapter.requestDevice();
      ready = device;
      void device.lost.then((info) => {
        console.warn(`[webgpu] device lost (${info.reason}): ${info.message}`);
        pending = null;
        if (ready === device) ready = null;
        for (const listener of [...lostListeners]) listener();
      });
      device.addEventListener("uncapturederror", (e) => {
        console.error("[webgpu]", (e as GPUUncapturedErrorEvent).error.message);
      });
      return device;
    } catch (e) {
      console.warn("[webgpu] no device; the DOM renderer draws", e);
      return null;
    }
  })();
  void pending.then(() => { settled = true; });
  return pending;
}

/// Called when the shared device is lost. Returns the unsubscribe.
export function onGpuLost(listener: () => void): () => void {
  lostListeners.add(listener);
  return () => { lostListeners.delete(listener); };
}
