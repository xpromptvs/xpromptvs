import { afterEach, describe, expect, test } from "vitest";
import { createDecoder, decoderKind } from "../src/client/qr-decode";

/**
 * **THE DECISION, not the decode.** `detect` needs a real `<video>` with pixels, which jsdom has
 * not got — so what is asserted here is which engine's path is taken and how it behaves at its
 * edges. `e2e/qr-scan-check.mjs` decodes a real QR in both engines, which is where the `jsqr`
 * fallback stops being a branch nobody takes.
 */

type Global = { BarcodeDetector?: unknown };
afterEach(() => { delete (globalThis as Global).BarcodeDetector; });

describe("decoderKind", () => {
  test("native when BarcodeDetector exists", () => {
    (globalThis as Global).BarcodeDetector = class {};
    expect(decoderKind()).toBe("native");
  });

  /**
   * **WebKit — iPad and iPhone — has none.** Measured 2026-09-15 on a SECURE origin; on
   * `about:blank` even Chromium reports none, because `mediaDevices` needs a secure context and a
   * probe there measures the context rather than the browser.
   */
  test("fallback when it does not", () => {
    expect(decoderKind()).toBe("fallback");
  });
});

describe("createDecoder", () => {
  test("uses BarcodeDetector when present, and asks it for QR only", async () => {
    const seen: unknown[] = [];
    (globalThis as Global).BarcodeDetector = class {
      constructor (opts: unknown) { seen.push(opts); }
      async detect () { return [{ rawValue: "AAAAAAAAAAAAAAAAAAAAAA" }]; }
    };
    const d = await createDecoder();
    expect(seen).toEqual([{ formats: ["qr_code"] }]);
    expect(await d.detect({} as HTMLVideoElement)).toBe("AAAAAAAAAAAAAAAAAAAAAA");
  });

  test("a frame with no code is null, not an error", async () => {
    (globalThis as Global).BarcodeDetector = class { async detect () { return []; } };
    expect(await (await createDecoder()).detect({} as HTMLVideoElement)).toBeNull();
  });

  /**
   * **A THROWN FRAME IS NOT A FAILED SCAN.** Cameras produce unreadable frames constantly — motion
   * blur, a hand over the lens, an autofocus hunt — and the next one is usually fine. A rejection
   * here would end the scan on the first of them.
   */
  test("a throwing frame is null, not a rejection", async () => {
    (globalThis as Global).BarcodeDetector = class {
      async detect (): Promise<never> { throw new Error("no"); }
    };
    await expect((await createDecoder()).detect({} as HTMLVideoElement)).resolves.toBeNull();
  });
});
