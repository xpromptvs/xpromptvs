import { describe, expect, it } from "vitest";
import { InputModality } from "../src/client/input-modality";

/// Whether focusing the terminal would raise a SOFT keyboard is a property of the GESTURE, not of the
/// device: an iPad with a hardware keyboard, or a touchscreen laptop, has a coarse pointer and still
/// types on real keys after a ⌘K or a mouse click.
describe("InputModality", () => {
  it("starts from the device's guess until an input says otherwise", () => {
    expect(new InputModality(true).lastWasTouch()).toBe(true);
    expect(new InputModality(false).lastWasTouch()).toBe(false);
  });

  it("a touch or a pen tap is touch; a mouse press or a key is not", () => {
    const m = new InputModality(false);
    m.pointer("touch"); expect(m.lastWasTouch()).toBe(true);
    m.key();            expect(m.lastWasTouch()).toBe(false);
    m.pointer("pen");   expect(m.lastWasTouch()).toBe(true);
    m.pointer("mouse"); expect(m.lastWasTouch()).toBe(false);
  });
});
