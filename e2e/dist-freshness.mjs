// dist-freshness.mjs — is the page a browser gate is about to drive actually running THIS code?
//
// Two origins serve the client: :5173 is vite (live source) and :8787 is wrangler serving `web/dist`, a
// BUILD ARTIFACT. A gate pointed at :8787 while `dist` is stale measures OLD CODE and reports confident,
// meaningless results — which reads exactly like the change not working.
//
// THE DECISIVE CHECK IS dist-vs-SOURCE, NOT served-vs-dist. In the 2026-07-29 incident that motivated
// this, :8787 served `client-DgiH6c-y.js` and local `web/dist` contained `client-DgiH6c-y.js` — they
// matched perfectly, and both were 8 hours stale. A served-vs-dist comparison would have printed "fresh".
// What was actually true is that every source file was newer than the bundle. Both checks run below; the
// mtime one is the one that earns its keep.
//
// Use from a gate:
//   import { checkDistFreshness } from "./dist-freshness.mjs";
//   const fresh = await checkDistFreshness(base);
//   if (!fresh.ok) { console.error(fresh.message); process.exit(3); }
// Or directly:
//   node e2e/dist-freshness.mjs [origin]
import { readdirSync, statSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
// Everything vite pulls into the client bundle. `@rdev/protocol` is aliased to ../protocol/src by
// web/vite.config.ts, so it is source for this purpose even though it lives outside web/.
const SOURCE_PATHS = ["web/src", "web/public", "web/index.html", "web/host.html", "web/vite.config.ts", "protocol/src"];
const DIST_ASSETS = "web/dist/assets";

/// Newest mtime under a file or directory, skipping node_modules. Returns {ms, path} or null.
function newest(path, best = null) {
  if (!existsSync(path)) return best;
  const st = statSync(path);
  if (st.isDirectory()) {
    for (const entry of readdirSync(path)) {
      if (entry === "node_modules" || entry.startsWith(".")) continue;
      best = newest(join(path, entry), best);
    }
    return best;
  }
  return !best || st.mtimeMs > best.ms ? { ms: st.mtimeMs, path } : best;
}

const rel = (p) => p.slice(REPO.length + 1);
const ago = (ms) => {
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 90) return `${s}s ago`;
  if (s < 5400) return `${Math.round(s / 60)}m ago`;
  return `${(s / 3600).toFixed(1)}h ago`;
};

/// Is `web/dist` newer than every source file that feeds it?
export function distIsBuiltFromCurrentSource() {
  const bundle = newest(join(REPO, DIST_ASSETS));
  if (!bundle) return { ok: false, reason: "no-dist", message: `web/dist/assets is missing — run: cd web && npm run build` };
  let src = null;
  for (const p of SOURCE_PATHS) src = newest(join(REPO, p), src);
  if (!src) return { ok: true, reason: "no-source-found", bundle };
  if (src.ms <= bundle.ms) return { ok: true, reason: "fresh", bundle, src };
  return {
    ok: false, reason: "stale-dist", bundle, src,
    message: [
      `STALE BUILD: web/dist is older than the source it is built from.`,
      `  newest source : ${rel(src.path)}  (${ago(src.ms)})`,
      `  newest bundle : ${rel(bundle.path)}  (${ago(bundle.ms)})`,
      `An origin serving web/dist (:8787) is running OLD CODE, so any result from it is meaningless.`,
      `Fix: cd web && npm run build     — and prefer 'npm run dev' over 'dev:only', which keeps dist in step.`,
    ].join("\n"),
  };
}

/// What the origin actually serves: the vite dev server (live source) or a specific built bundle.
export async function servedBundle(base) {
  const res = await fetch(base, { redirect: "follow" });
  const html = await res.text();
  if (/\/src\/client\/main\.ts/.test(html)) return { kind: "vite-dev" };
  const m = html.match(/client-[A-Za-z0-9_-]+\.js/);
  return m ? { kind: "built", asset: m[0] } : { kind: "unknown" };
}

/// Full check for a gate. `base` is the origin the gate will drive.
export async function checkDistFreshness(base) {
  let served;
  try { served = await servedBundle(base); }
  catch (e) { return { ok: false, reason: "unreachable", message: `Cannot reach ${base}: ${e.message}` }; }

  // The vite dev server compiles source per request, so dist cannot make it stale. Nothing to check.
  if (served.kind === "vite-dev") return { ok: true, reason: "vite-dev", note: `${base} is the vite dev server (live source)` };
  if (served.kind === "unknown") return { ok: true, reason: "unknown-origin", note: `${base} serves neither a vite entry nor a hashed bundle — not checked` };

  const built = distIsBuiltFromCurrentSource();
  if (!built.ok) return { ...built, served };

  // dist is current; confirm the origin is serving THAT dist and not a cached/older deploy.
  const local = existsSync(join(REPO, DIST_ASSETS)) &&
    readdirSync(join(REPO, DIST_ASSETS)).find((f) => /^client-[A-Za-z0-9_-]+\.js$/.test(f));
  if (local && served.asset !== local) {
    return {
      ok: false, reason: "origin-mismatch", served,
      message: [
        `ORIGIN MISMATCH: ${base} serves ${served.asset}, but web/dist contains ${local}.`,
        `The origin is serving a different build — a stale worker, a cache, or a deploy that has not propagated.`,
        `Restart the wrangler dev server, or hard-reload if this is a browser cache.`,
      ].join("\n"),
    };
  }
  return { ok: true, reason: "fresh", note: `${base} serves ${served.asset}, built ${ago(built.bundle.ms)}` };
}

// CLI: node e2e/dist-freshness.mjs [origin]
if (import.meta.url === `file://${process.argv[1]}`) {
  const base = process.argv[2] ?? process.env.RDEV_BASE ?? "http://127.0.0.1:8787";
  const r = await checkDistFreshness(base);
  console.log(r.ok ? `FRESH  ${r.note ?? r.reason}` : r.message);
  process.exit(r.ok ? 0 : 1);
}
