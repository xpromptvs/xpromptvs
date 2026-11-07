/// Whether the input that led to a focus decision was a TOUCH — so focusing the terminal would raise a
/// SOFT keyboard (term-view-policy.ts, `softKeyboard`).
///
/// A property of the GESTURE, not of the device. `(any-pointer: coarse)` is right for showing touch
/// affordances, but as a focus rule it also took focus away from an iPad with a hardware keyboard or a
/// touchscreen laptop: ⌘K → New terminal left typing going nowhere. So the last pointer press decides
/// (`touch`, or `pen` — an Apple Pencil tap raises the keyboard too), and a key or a mouse press says
/// real keys are in use. Before any input the DEVICE's guess stands.
export class InputModality {
  private touch: boolean;

  constructor(coarseDevice: boolean) { this.touch = coarseDevice; }

  /// A `pointerdown`'s `pointerType`.
  pointer(type: string): void { this.touch = type === "touch" || type === "pen"; }

  /// A `keydown`: a hardware keyboard, or the soft keyboard already up — either way no NEW keyboard.
  key(): void { this.touch = false; }

  lastWasTouch(): boolean { return this.touch; }
}
