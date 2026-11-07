/// WHICH BUNDLE IS ACTUALLY RUNNING, taken from the module's own URL.
///
/// This exists because of a failure this repo has already paid for in full: the app points a phone
/// or browser at the DEPLOYED Worker while `build:all` rebuilds only the LOCAL `web/dist`, so two
/// clients run two different bundles with no error anywhere. AGENTS.md records it costing a whole
/// session — a CSS fix verified in local dist, on :8787, on :5173 and in two engines while the
/// reporter's Safari kept showing the pre-fix build.
///
/// Vite content-hashes the entry, so its filename IS the build identity. Reporting it to the host
/// turns "is the client stale?" from an argument into a string comparison against `web/dist`.
///
/// TAKEN FROM `import.meta.url`, NOT FROM A BUILD-TIME CONSTANT: a constant is baked in by the same
/// build whose freshness is in question, so a stale bundle would report its own stale value with
/// total confidence. The URL is what the browser actually fetched.
export function buildTagFrom(moduleUrl: string): string {
  // A bare filename, a full URL, and a URL with a query or fragment all have to reduce to the same
  // thing — the served path can carry either, and a tag that changes shape is one that cannot be
  // compared by eye against `ls web/dist/assets`.
  const withoutFragment = moduleUrl.split("#")[0] ?? "";
  const withoutQuery = withoutFragment.split("?")[0] ?? "";
  const last = withoutQuery.split("/").pop() ?? "";
  return last === "" ? "unknown" : last;
}
