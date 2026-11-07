// e2e/lib/app.mjs
// Drives the native Xpromptvs app through its DEV-BUILD automation port (app/Sources/Automation.swift).
// The replacement for Playwright's `_electron`, which cannot attach to an app's WKWebView.
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { rmSync, readFileSync } from "node:fs";
import net from "node:net";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const ROOT = new URL("../..", import.meta.url).pathname;
// THE CHECKS' OWN BUNDLE. desktop/release is the USER'S — `npm --prefix desktop run dev|start|package`
// build it and the person runs it — so nothing automated builds or launches it: every check builds
// with `npm --prefix desktop run build:check` (or `RDEV_APP_OUT=$CHECK_APP_OUT sh scripts/assemble-app.sh`)
// and launches from here. Same signing identity, so TCC's grants carry over.
export const CHECK_APP_OUT = `${ROOT}desktop/release-check`;
export const APP_EXE = process.env.RDEV_APP ?? `${CHECK_APP_OUT}/Xpromptvs Development.app/Contents/MacOS/Xpromptvs Development`;
export const APP_CHANNEL = (() => {
  try { return JSON.parse(readFileSync(join(dirname(dirname(APP_EXE)), "Resources/release.json"), "utf8")).channel === "staging" ? "staging" : "public"; }
  catch { return "public"; } // older check bundles predate release metadata
})();

async function freePort() {
  return await new Promise((resolve) => {
    const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

/**
 * `AppProfile.uuid(name)` (app/Core/AppProfile.swift): SHA-256 of `ai.xpromptvs.development/profile/<name>`, the
 * first 16 bytes stamped as a version-5 UUID. WebKit names the store's directory with it, lowercase.
 */
export function profileStoreID(name, channel = APP_CHANNEL) {
  if (channel === "staging") name = "staging:" + name;
  const b = createHash("sha256").update(`ai.xpromptvs.development/profile/${name}`).digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function profileCleanupPaths(profile,channel=APP_CHANNEL) {
  if(typeof profile!=="string"||!/^[A-Za-z0-9._-]{1,64}$/.test(profile)||profile==='.'||profile==='..')throw Error('Invalid isolated profile');
  return [join(homedir(),"Library","Application Support","ai.xpromptvs.development",...(channel==='staging'?["channels","staging"]:[]),"profiles",profile),
    join(homedir(),"Library","WebKit","ai.xpromptvs.development","WebsiteDataStore",profileStoreID(profile,channel))];
}

/** Launch the app with an isolated profile and connect to its automation port. */
export async function launchApp({ profile, env = {}, args = [], stdio = ["ignore", "pipe", "pipe"], launchServices = false } = {}) {
  const port = await freePort();
  // **FAIL-SAFE BY DEFAULT: never sign with the developer's REAL identity.** `RDEV_E2E_STORE` names
  // the directory (under `~/Library/Application Support/`) holding this host's keys and its trust
  // record; leaving it unset falls through to the real `dev.rdev.host` — the same one a Mac actually
  // enrolled on this machine uses (`FileRecordStore.defaultDirectory`). AGENTS.md: "anything
  // automated names its own `RDEV_E2E_STORE` — a developer's real identity is not a fixture." A
  // caller that already named one (in `env` or in the ambient environment, the way
  // `adopt-by-code-check.mjs` does before spawning children) keeps it untouched and owns its own
  // cleanup; only when NEITHER is set do we generate a fresh one here and remove it ourselves.
  const ownsStore = env.RDEV_E2E_STORE === undefined && process.env.RDEV_E2E_STORE === undefined;
  const store = ownsStore ? `ai.xpromptvs.developmentcheck.${process.pid}.${Date.now()}` : undefined;
  const storeDir = store ? join(homedir(), "Library", "Application Support", store) : undefined;
  // THE PROFILE, ON THE SAME TERMS. Unset, `RDEV_APP_PROFILE` falls through to the person's OWN
  // profile (`AppProfile.resolve`: `ai.xpromptvs.development` itself — their settings, their web storage). A
  // caller that names one (the argument, `env`, or the ambient environment) owns it and its cleanup;
  // otherwise we generate one and remove it when the app is gone, exactly as the store above.
  // (Before 2026-09-26 `app-smoke.mjs` named `smoke-<pid>` and never removed it.)
  const ownsProfile = profile === undefined && env.RDEV_APP_PROFILE === undefined && process.env.RDEV_APP_PROFILE === undefined;
  if (ownsProfile) profile = `check-${process.pid}-${Date.now()}`;
  // A profile is TWO directories: its settings, and the `WKWebsiteDataStore(forIdentifier:)` its web
  // views keep under ~/Library/WebKit — named by the UUID `AppProfile` derives from the name.
  const profileDirs = ownsProfile ? profileCleanupPaths(profile) : [];
  let storeCleaned = false;
  const cleanupStore = () => {
    if (!storeDir || storeCleaned) return;
    storeCleaned = true;
    try { rmSync(storeDir, { recursive: true, force: true }); } catch { /* best effort */ }
  };
  const runtimeEnv = { ...process.env, ...env, RDEV_APP_AUTOMATION: String(port),
    ...(profile ? { RDEV_APP_PROFILE: profile } : {}), ...(store ? { RDEV_E2E_STORE: store } : {}) };
  // Direct exec has LaunchServices type=NULL and cannot become the native key application.
  // Opt in only for actual foreground checks; default checks retain their direct process exit status.
  const launchMarker = `rdev-check-${process.pid}-${port}-${Date.now()}`;
  const markerArg = `--rdev-check-launch=${launchMarker}`;
  const launchEnv = Object.entries(runtimeEnv).filter(([key,value]) => value !== undefined &&
    (key.startsWith('RDEV_') || ['PATH','LANG','TMPDIR','SHELL'].includes(key) || Object.hasOwn(env,key)));
  const launchArgs = ['-n','-W','-a',dirname(dirname(dirname(APP_EXE))),
    ...launchEnv.flatMap(([key,value]) => ['--env',`${key}=${value}`]),'--args',...args,markerArg];
  const proc = spawn(launchServices ? '/usr/bin/open' : APP_EXE, launchServices ? launchArgs : args,
    { env:runtimeEnv, stdio });
  const markedPIDs = () => {
    try{return execFileSync('/usr/bin/pgrep',['-f',launchMarker],{encoding:'utf8'}).trim().split(/\s+/).map(Number).filter(pid=>Number.isInteger(pid)&&pid>1);}catch{return [];}
  };
  const forceStop = () => {
    // Only this randomly tagged disposable check. The installed app and other profiles are never targets.
    if(launchServices)for(const pid of markedPIDs())try{process.kill(pid,'SIGKILL');}catch{}
    proc.kill('SIGKILL');
  };
  const output = [];
  // How the app ENDED — `{ code, signal }` — recorded at the source so `quit()` can report it even
  // when the process died before anyone asked (a crash, or a check that SIGKILLed it).
  let exitStatus = null;
  const removeProfile = () => {
    for (const dir of profileDirs) { try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ } }
  };
  // ALSO when THIS process exits first: a check that SIGKILLs its apps from its own `exit` handler
  // (app-e2e-check, a signalled run) never sees the app's exit event, and a caller-named profile
  // used to be removed right there. Synchronous, so it runs inside `exit`.
  if (profileDirs.length || launchServices) process.once("exit", () => { if(launchServices && !exitStatus)forceStop(); removeProfile(); });
  let launcherStatus = null, targetPID = null;
  let resolveAppExit;
  const actualExited = new Promise(resolve => { resolveAppExit = resolve; });
  const launcherExited = new Promise((resolve) => proc.once("exit", (code, signal) => {
    launcherStatus = {code,signal};
    if(launchServices){resolve(launcherStatus);return;}
    exitStatus = { code, signal };
    // On EXIT, not on the socket closing: a quitting app still writes its profile after the port
    // goes away, and a directory removed under it would simply be recreated.
    removeProfile();
    resolve(exitStatus);
  }));
  const exited = launchServices ? actualExited : launcherExited;
  proc.stdout?.on("data", (d) => output.push(String(d)));
  proc.stderr?.on("data", (d) => output.push(String(d)));
  let sock;
  for (let i = 0; i < 100 && !sock; i++) {
    sock = await new Promise((resolve) => {
      const s = net.connect(port, "127.0.0.1", () => resolve(s));
      s.once("error", () => resolve(undefined));
    });
    if (!sock) await sleep(100);
  }
  if (!sock) { forceStop(); throw new Error(`automation port never opened\n${output.join("")}`); }
  let next = 1, buf = "", closed = null;
  const pending = new Map();
  // A dead app must REJECT every call, never leave it pending: the connect-phase `once("error")`
  // is spent, and without these a check awaiting an eval hangs forever.
  const fail = (why) => {
    if (closed) return;
    closed = new Error(`automation socket ${why}\n${output.join("")}`);
    for (const p of pending.values()) p.reject(closed);
    pending.clear();
    // The app is gone (crashed, killed, or quitting normally — this fires on all three), so its
    // store is no longer in use: clean up HERE rather than only at the end of `quit()`, which
    // short-circuits when the process already died (e.g. a check that SIGKILLs it directly and only
    // then calls `quit()` in a `finally`).
    cleanupStore();
  };
  sock.on("error", (e) => fail(`error: ${e.message}`));
  sock.on("close", () => fail("closed"));
  sock.on("data", (d) => {
    buf += d;
    for (let i; (i = buf.indexOf("\n")) >= 0;) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      const r = JSON.parse(line); const p = pending.get(r.id);
      // A reply to an id we are not waiting for (the app's `{"ok":false}` for an unparseable
      // request carries id null) is ignored rather than crashing the check on `undefined.resolve`.
      if (!p) continue;
      pending.delete(r.id);
      r.ok ? p.resolve(r.value) : p.reject(new Error(r.error));
    }
  });
  const call = (cmd, params = {}) => new Promise((resolve, reject) => {
    if (closed) { reject(closed); return; }
    const id = next++; pending.set(id, { resolve, reject });
    sock.write(JSON.stringify({ id, cmd, ...params }) + "\n");
  });
  if(launchServices) {
    let identifyTimer;
    try {
      const target = await Promise.race([call('process'),new Promise((_,reject)=>{identifyTimer=setTimeout(()=>reject(Error('launched app identification timed out')),3000);})]);
      if(!Number.isInteger(target.pid)||target.pid<=1)throw Error('invalid launched app PID');
      const command = execFileSync('/bin/ps',['-p',String(target.pid),'-o','command='],{encoding:'utf8'}).trim();
      if(!command.endsWith(markerArg))throw Error('automation belongs to another launched app');
      targetPID=target.pid;
    } catch(error) {
      sock.destroy();forceStop();
      const deadline=Date.now()+3000;
      while(markedPIDs().length&&Date.now()<deadline)await sleep(25);
      if(!markedPIDs().length){removeProfile();cleanupStore();}
      throw error;
    } finally {clearTimeout(identifyTimer);}

    const monitor=setInterval(()=>{
      try{process.kill(targetPID,0);return;}catch(error){if(error.code!=='ESRCH')throw error;}
      clearInterval(monitor);
      // LaunchServices cannot report the target's exit code. Observe actual disappearance, and
      // keep the launcher's status separate instead of treating open's early exit as app exit.
      exitStatus={code:null,signal:null,appExited:true,launcher:launcherStatus};
      removeProfile();resolveAppExit(exitStatus);
    },50);
  }
  const app = {
    proc, output, call, launchServices, get targetPID(){return targetPID;},
    /** The profile this run uses — generated (and removed on exit) unless the caller named one. */
    profile,
    /** Actual app lifetime. LaunchServices exit codes are unavailable; launcher status is separate. */
    exited,
    windows: () => call("windows"),
    eval: (window, js) => call("eval", { window, js }),
    click: (window, selector) => call("click", { window, selector }),
    fill: (window, selector, value) => call("fill", { window, selector, value }),
    console: (window) => call("console", { window }),
    /** A REAL Edit ▸ Paste into `window` (WebKit's own paste of the general pasteboard), dev builds only. */
    paste: (window) => call("paste", { window }),
    bridge: (op, ...args) => call("bridge", { op, args }),
    /** The Dock's badge text, or null with none (dev builds only). */
    dockBadge: () => call("dockBadge"),
    /** Poll an async function body until it returns truthy. */
    async waitFor(window, js, timeout = 30_000) {
      const end = Date.now() + timeout;
      for (;;) {
        try { const v = await app.eval(window, js); if (v) return v; } catch { /* not ready */ }
        if (Date.now() > end) throw new Error(`timed out waiting for: ${js}`);
        await sleep(100);
      }
    },
    /** The first window of `kind` whose id is not in `known`. */
    async waitForWindow(kind, known = [], timeout = 20_000) {
      const end = Date.now() + timeout;
      for (;;) {
        const w = (await app.windows()).find((w) => w.kind === kind && !known.includes(w.id));
        if (w) return w;
        if (Date.now() > end) throw new Error(`no new ${kind} window`);
        await sleep(100);
      }
    },
    /**
     * "This Mac" (kind `client`, `app://client/index.html?local=1`) whose id is not in `known` — at launch, THE
     * window the app opens: the launch has been terminal-first since 2026-10-03 (`AppDelegate` calls
     * `windows.openLocal` and opens no dashboard; docs/desktop-app.md, "The local window"). That window comes
     * from `AppWindows.openLocal` DIRECTLY, with no `ConnectAttempts` attempt behind it, so a check of the
     * attempt path (`localPending`, a row lit and unlit by its window) must open its own This Mac through
     * `openLocal` — closing this one first, since there is only ever ONE.
     */
    async waitForLocal(known = [], timeout = 20_000) {
      const end = Date.now() + timeout;
      for (;;) {
        const ws = await app.windows();
        const w = ws.find((w) => w.kind === "client" && w.url.includes("local=1") && !known.includes(w.id));
        if (w) return w;
        if (Date.now() > end) throw new Error(`no This Mac window: ${JSON.stringify(ws)}`);
        await sleep(100);
      }
    },
    /**
     * The Macs utility — the dashboard, `app://ui/index.html`, kind `home` (the Sharing window is kind `home`
     * too, at `?view=share`) — opened as a person opens it since the launch stopped opening it: from This Mac's
     * status-bar button ("Other Devices", `#macs-open`), which calls `__rdevShell.openMacs` → `ClientBridge`
     * `openMacs` → `AppWindows.openHome`. The UI bridge has no op for it, so `app.bridge` cannot. `local` is
     * the id of a This Mac window. Resolves once the dashboard's page has run (`#door-share` is moved out of
     * its template by `desktop/src/renderer/main.ts`) and the window is ON SCREEN (`HomeWindow` shows at
     * `didFinishLoad`, and AppKit's last-window rule does not count a window that never was).
     */
    async openMacs(local, timeout = 20_000) {
      await app.waitFor(local, "return location.protocol !== 'about:' && typeof window.__rdevShell?.openMacs === 'function'", timeout);
      await app.eval(local, "window.__rdevShell.openMacs(); return true");
      const end = Date.now() + timeout;
      let macs;
      for (;;) {
        const ws = await app.windows();
        macs = ws.find((w) => w.kind === "home" && !w.url.includes("view=share"));
        if (macs?.visible) break;
        if (Date.now() > end) throw new Error(`the Macs utility never came on screen: ${JSON.stringify(ws)}`);
        await sleep(100);
      }
      await app.waitFor(macs.id, "return location.protocol !== 'about:' && document.readyState === 'complete' && !!window.rdevApp && !!document.getElementById('door-share')", timeout);
      return macs;
    },
    /**
     * Quit gracefully and report HOW the app ended: `{ code, signal, forced }`. `forced` means the
     * graceful quit did not finish within 10 s and the app was SIGKILLed; `code` 0 with no signal
     * is the only clean result. A process that was already gone reports how it went.
     */
    async quit() {
      if (exitStatus) { cleanupStore(); return { ...exitStatus, forced: false }; }   // already gone
      // NOT awaited: the port answers a connection's commands IN ORDER, so a quit queued behind an
      // eval that never returns (a script sent to a dead web content process) is never answered —
      // and awaiting it hung the check forever instead of reaching the SIGKILL below.
      call("quit").catch(() => { /* socket closes as it quits */ });
      const done = await Promise.race([exited, sleep(10_000).then(() => null)]);
      // The Go runtime inside the app forwards signals; SIGKILL is the backstop (docs/gotchas.md).
      let forced = false;
      if (!done) { forced = true; forceStop(); await exited; }
      cleanupStore();
      return { ...exitStatus, forced };
    },
  };
  return app;
}
