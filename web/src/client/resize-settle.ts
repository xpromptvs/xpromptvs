/** Hold expensive size reactions, never layout. Recompute at the final geometry, not from a
 * queued intermediate measurement. Repeated gestures replace the pending settle. */
export class ResizeSettle {
  private held = false;
  private generation = 0;
  private pending = new Map<object, Map<string, () => void>>();
  constructor(private frame: (run: () => void) => void = run => requestAnimationFrame(run)) {}
  setActive(on: boolean): void {
    const generation = ++this.generation;
    this.held = true;
    if (on) return;
    // Allow the final resize / ResizeObserver delivery to join the same batch.
    this.frame(() => this.frame(() => {
      if (generation !== this.generation) return;
      this.held = false;
      const pending = this.pending; this.pending = new Map();
      for (const jobs of pending.values()) for (const run of jobs.values()) run();
    }));
  }
  defer(owner: object, key: string, run: () => void): boolean {
    if (!this.held) return false;
    let jobs = this.pending.get(owner);
    if (!jobs) this.pending.set(owner, jobs = new Map());
    jobs.set(key, run);
    return true;
  }
  cancel(owner: object): void { this.pending.delete(owner); }
}
export const windowResizeSettle = new ResizeSettle();

declare global { interface Window { __rdevWindowResize?: (active: boolean) => void } }
