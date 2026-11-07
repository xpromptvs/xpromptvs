import { describe, expect, test } from "vitest";
import { scannerModel, type ScanState } from "../src/client/qr-scan";

/**
 * **THE WORDING IS MOST OF WHAT THIS SURFACE IS**, and a camera, a permission prompt and a physical
 * QR are the three things a unit test cannot have. So the model is pure and every string is here.
 */
describe("scannerModel", () => {
  /**
   * **SAID, NOT DISCOVERED.** `getUserMedia` needs a secure context, so the camera cannot work on
   * `dev-local.sh`'s LAN origin — exactly as passkeys cannot, and for the same reason. A dead
   * preview with no explanation is the failure this arm exists to prevent.
   */
  test("an insecure origin explains itself", () => {
    const v = scannerModel({ kind: "insecure" });
    expect(v.body).toMatch(/secure|https/i);
    expect(v.showVideo).toBe(false);
    expect(v.actions.map((a) => a.id)).toContain("close");
  });

  test("no camera is not an error", () => {
    const v = scannerModel({ kind: "no-camera" });
    expect(v.heading).not.toMatch(/error|fail/i);
    expect(v.showVideo).toBe(false);
  });

  /**
   * A refused permission is a DECISION, not a fault — the same rule this repo applies to a
   * dismissed passkey prompt, and for the same reason: the two are not separable.
   */
  test("a refused camera does not scold", () => {
    const v = scannerModel({ kind: "refused" });
    expect(v.heading).not.toMatch(/error|denied|fail/i);
    expect(v.body).toMatch(/camera/i);
  });

  test("scanning shows the preview and leaves nothing to decide", () => {
    const v = scannerModel({ kind: "scanning" });
    expect(v.showVideo).toBe(true);
    expect(v.actions.map((a) => a.id)).toEqual(["close"]);
  });

  /** The refusal that matters, and it NAMES the origin so a person knows which sticker they got. */
  test("a foreign origin is refused by name, with no preview", () => {
    const v = scannerModel({ kind: "foreign", origin: "https://evil.example" });
    expect(v.body).toContain("https://evil.example");
    expect(v.body).toMatch(/not for this app|different/i);
    expect(v.showVideo).toBe(false);
  });

  test("every state yields a heading and a body", () => {
    const states: ScanState[] = [{ kind: "insecure" }, { kind: "no-camera" }, { kind: "asking" },
      { kind: "refused" }, { kind: "scanning" }, { kind: "foreign", origin: "x" },
      { kind: "failed", reason: "y" }];
    for (const s of states) {
      const v = scannerModel(s);
      expect(v.heading.length, s.kind).toBeGreaterThan(0);
      expect(v.body.length, s.kind).toBeGreaterThan(0);
    }
  });
});
