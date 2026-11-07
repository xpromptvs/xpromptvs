/** Shared classic-script runtime, also shipped by the native app's home (`app://ui`). */
export interface ShellstormMotion {
  begin(options: {row?: HTMLElement | null; button?: HTMLElement | null; onCancel?: () => void; onRestored?: () => void}): boolean;
  prepareSession(): void;
  finish(): void;
  unlight(row: HTMLElement): void;
  whenReady(callback: () => void): void;
  close(callback: () => void): void;
  /// Put the busy button back — here, after a connect the controller refused.
  restore?(connected?: boolean): void;
  /// Abandon the pending attempt: the busy button back, the pending session reveal withdrawn. False
  /// when nothing was pending.
  cancel?(): boolean;
  /// Re-run the idempotent decorate/preferences/debug sync — for markup built after load (session-dom.ts).
  resync?(): void;
  /// Re-sample the tint (`.safari-tint`, `<html>`/`<body>`, `<meta name="theme-color">`) against the
  /// CURRENT theme. `session-motion.js`'s `finish()` only paints the colour it sampled at the START of
  /// the slide it is finishing, so a theme change with no slide to carry it leaves those targets at the
  /// old theme's colour — invisible in-page (the three bands cover `<body>`) but wrong in Safari's
  /// toolbar tint. No-op before the first slide.
  retint?(): void;
  readonly active: boolean;
}
export const shellstormMotion = (): ShellstormMotion | undefined =>
  (window as Window & {ShellstormMotion?: ShellstormMotion}).ShellstormMotion;
