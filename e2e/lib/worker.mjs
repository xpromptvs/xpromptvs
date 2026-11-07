// Stopping a `wrangler dev` so that it actually stops.
//
// **`wrangler dev` is not one process** — the chain is `npx` → `wrangler` (node) → `workerd` — and
// **`process.on("exit")` does not run when the check is signalled.** Together those leak a `workerd`
// that gets reparented to launchd and **spins a core**. Measured 2026-09-14: sixteen orphans from
// one session's opt-in checks held 702% CPU and 5.7 GB of RSS between them, and every one of those
// runs had printed `ok`.
//
// Both halves are measured, and both are needed:
//
//   - **`child.kill()` on normal exit is FINE.** That was the first hypothesis and it is wrong: a
//     probe that spawned a worker and killed the direct child took `workerd` with it every time.
//   - **A SIGNALLED check cleans up nothing.** SIGTERM the check and `workerd` is still there four
//     seconds later, because `exit` handlers do not run for a signalled process. `timeout 900 node
//     e2e/…` does exactly this when it fires, which is how these were actually made.
//
// So: handle the signals, and kill the GROUP rather than the pid, because by then the direct child
// may already be gone while its grandchild is not.
//
// The shell gates have their own answer to the same problem — `track_pid` plus the registry in
// `scripts/lib.sh`, which reaps on the NEXT run because a trap cannot run on SIGKILL. This is the
// Node equivalent, and it is deliberately one implementation rather than six copies: the negated pid
// is the kind of detail that gets dropped when it is pasted around.

/**
 * Own a spawned `wrangler dev` (or anything else with grandchildren) for the life of this process.
 *
 * **The child MUST have been spawned with `detached: true`** — that is what puts it in its own
 * process group, and without it the negated-pid kill below has no group to address and throws.
 *
 * Returns `stop`, which is idempotent and safe to call again.
 */
export function trackWorker(child) {
  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    // **THE NEGATED PID IS THE WHOLE POINT** — it addresses the process GROUP, which is what reaches
    // `workerd`. SIGTERM first so it can close its sockets, then SIGKILL unconditionally: a check
    // must never depend on a child agreeing to die.
    for (const signal of ["SIGTERM", "SIGKILL"]) {
      try { process.kill(-child.pid, signal); } catch { /* already gone */ }
    }
  };

  process.on("exit", stop);
  // The half that was missing. Exiting with the conventional status keeps the caller's view honest:
  // a check that was killed should not report a tidy success it did not have.
  for (const [signal, status] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
    process.on(signal, () => { stop(); process.exit(status); });
  }
  return stop;
}
