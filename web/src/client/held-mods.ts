/// Modifiers for the on-screen key strip, held like real keys.
///
/// A finger holds ⌘ on the strip while another taps a letter on the soft keyboard — the two surfaces
/// share one screen, so multi-touch makes this work the way a physical keyboard does. No latching, no
/// timing, no hidden state: a modifier is down exactly while a finger is on it.
///
/// This replaced a sticky/double-tap-to-lock model. Sticky needed no second finger, but it put the
/// modifier's state in the user's head rather than under their thumb — and a lock that outlives the
/// gesture is the one that gets left on. Hold cannot be left on: releasing the finger releases the key.
///
/// Pure: no DOM, no clock, no timers.

export type Mod = "shift" | "ctrl" | "alt" | "meta";
export type ModState = "off" | "held";

/// Bit values, chosen to match `modsBitmask` in input.ts so a mask can be OR'd straight into a
/// `win-key`. CapsLock (16) exists there and is deliberately unreachable from the strip.
const BITS: Record<Mod, number> = { shift: 1, ctrl: 2, alt: 4, meta: 8 };

export const ALL_MODS: readonly Mod[] = ["shift", "ctrl", "alt", "meta"];

export class HeldMods {
  private held = new Set<Mod>();

  state(mod: Mod): ModState { return this.held.has(mod) ? "held" : "off"; }

  /// Idempotent: a repeated `down` for a modifier already held is a no-op, so a duplicated
  /// pointer event cannot desynchronise the caller's wire state from this one.
  down(mod: Mod): boolean {
    if (this.held.has(mod)) return false;
    this.held.add(mod);
    return true;
  }

  /// Returns whether this actually released something, so the caller can skip a redundant key-up.
  up(mod: Mod): boolean { return this.held.delete(mod); }

  active(): Mod[] { return ALL_MODS.filter((m) => this.held.has(m)); }

  mask(): number { return this.active().reduce((acc, m) => acc | BITS[m], 0); }

  /// Empty the set and report what was held, so the caller can send the matching key-ups.
  /// Returning the list rather than a boolean is what lets the window path keep the host's
  /// `currentFlags` in step with the strip.
  clearAll(): Mod[] {
    const was = this.active();
    this.held.clear();
    return was;
  }
}
