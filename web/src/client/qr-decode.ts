/**
 * One method, two implementations, and the caller cannot tell which it has.
 *
 * `detect` returns the decoded text or null, and **never throws** — see `createDecoder` for why.
 */
export interface QrDecoder {
  detect (source: HTMLVideoElement): Promise<string | null>;
}

interface BarcodeLike { rawValue: string }
interface DetectorLike { detect (source: CanvasImageSource): Promise<BarcodeLike[]> }
type DetectorCtor = new (opts: { formats: string[] }) => DetectorLike;

/**
 * **MEASURED 2026-09-15: Chromium has `BarcodeDetector` and WebKit does not**, while both have
 * `getUserMedia`. So Chromium decodes natively for nothing, and iPad and iPhone cannot decode at all
 * without something shipped.
 *
 * **CHECK IT ON A SECURE ORIGIN.** On `about:blank` every one of these capabilities reads false —
 * `mediaDevices` requires a secure context — so a probe there measures the context rather than the
 * browser, which is how this table was nearly recorded backwards.
 */
export function decoderKind (): "native" | "fallback" {
  return typeof (globalThis as { BarcodeDetector?: unknown }).BarcodeDetector !== "undefined"
    ? "native" : "fallback";
}

/**
 * **`jsqr` IS IMPORTED LAZILY, AND ON ONE ENGINE.** 128 KB minified, 46 KB gzipped — which Chromium
 * must never fetch, and which WebKit fetches when the sheet opens rather than on page load. A static
 * import would put it in the entry bundle for everybody, which is what the build check guards.
 */
export async function createDecoder (): Promise<QrDecoder> {
  if (decoderKind() === "native") {
    const Ctor = (globalThis as unknown as { BarcodeDetector: DetectorCtor }).BarcodeDetector;
    const detector = new Ctor({ formats: ["qr_code"] });
    return {
      async detect (source) {
        // **A THROWN FRAME IS NOT A FAILED SCAN.** Cameras produce unreadable frames constantly —
        // motion blur, a hand over the lens, an autofocus hunt — and the next one is usually fine.
        try {
          const found = await detector.detect(source);
          return found.length > 0 ? found[0]!.rawValue : null;
        } catch { return null; }
      },
    };
  }

  const { default: jsQR } = await import("jsqr");
  // ONE canvas for the whole scan: a fresh one per frame at 30fps is garbage the decoder does not
  // need. `willReadFrequently` is the hint for a surface that is read back every frame.
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  return {
    async detect (source) {
      // A video with no intrinsic size yet has no pixels to read; `drawImage` would throw.
      if (!ctx || !source.videoWidth || !source.videoHeight) return null;
      canvas.width = source.videoWidth;
      canvas.height = source.videoHeight;
      try {
        ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
        const { data, width, height } = ctx.getImageData(0, 0, canvas.width, canvas.height);
        return jsQR(data, width, height)?.data ?? null;
      } catch { return null; }
    },
  };
}
