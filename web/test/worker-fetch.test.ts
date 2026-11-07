import { afterEach, describe, expect, test, vi } from "vitest";
import { workerFetch } from "../src/lib/worker-fetch";

// **The app's client window cannot `fetch` its own Worker** — `app://client` is an origin the
// Worker sends no CORS for — so inside the app the three Worker calls ride `__rdevShell.request`,
// which the NATIVE side performs against the signalling origin for an allow-list of paths
// (`app/Core/WorkerRequest.swift`). This helper is the page's half: a `typeof fetch` over that
// bridge, and plain `fetch` everywhere else. What it must get right is what the three call sites
// read — `ok`, `status`, `json()` — and that a refusal looks like a network error, never like an
// answer.
type Shell = { signalingBase?: string; request?: (path: string, init: unknown) => Promise<unknown> };
const g = globalThis as unknown as { __rdevShell?: Shell };
afterEach(() => { delete g.__rdevShell; vi.unstubAllGlobals(); });

const BASE = "https://cp.test";
const ROOT = "A".repeat(43);

describe("workerFetch", () => {
  test("with no shell it IS the global fetch — a browser is unchanged", async () => {
    const real = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", real);
    const f = workerFetch();
    await f(`${BASE}/directory/${ROOT}/challenge`, { method: "POST" });
    expect(real).toHaveBeenCalledTimes(1);
  });

  test("a shell WITHOUT request (an older app) also falls back to fetch", async () => {
    const real = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", real);
    g.__rdevShell = { signalingBase: BASE };
    await workerFetch()(`${BASE}/credential/abcd`);
    expect(real).toHaveBeenCalledTimes(1);
  });

  test("inside the app: the PATH and a text body cross, and the answer reads like a Response", async () => {
    const real = vi.fn();
    vi.stubGlobal("fetch", real);
    const request = vi.fn(async () => ({ status: 200, body: '{"sessions":[]}' }));
    g.__rdevShell = { signalingBase: BASE, request };
    const res = await workerFetch()(`${BASE}/directory/${ROOT}/list`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: '{"a":"b"}',
    });
    expect(real).not.toHaveBeenCalled();
    expect(request).toHaveBeenCalledWith(`/directory/${ROOT}/list`, { method: "POST", body: '{"a":"b"}' });
    expect(res.ok).toBe(true);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sessions: [] });
  });

  test("a GET with no init sends GET and no body", async () => {
    const request = vi.fn(async () => ({ status: 200, body: '{"root":"AQ"}' }));
    g.__rdevShell = { signalingBase: BASE, request };
    await workerFetch()(`${BASE}/credential/abcd`);
    expect(request).toHaveBeenCalledWith("/credential/abcd", { method: "GET" });
  });

  test("a ws signalling base still names the http Worker", async () => {
    const request = vi.fn(async () => ({ status: 200, body: "{}" }));
    g.__rdevShell = { signalingBase: "wss://cp.test", request };
    await workerFetch()(`${BASE}/credential/abcd`);
    expect(request).toHaveBeenCalledTimes(1);
  });

  test("a non-2xx answer is an ANSWER: not ok, its status, its body", async () => {
    g.__rdevShell = { signalingBase: BASE,
                      request: async () => ({ status: 404, body: '{"error":"not-found"}' }) };
    const res = await workerFetch()(`${BASE}/credential/abcd`);
    expect(res.ok).toBe(false);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not-found" });
  });

  test("a null-body status does not throw building the Response", async () => {
    g.__rdevShell = { signalingBase: BASE, request: async () => ({ status: 204, body: "" }) };
    const res = await workerFetch()(`${BASE}/credential/abcd`);
    expect(res.status).toBe(204);
    expect(await res.text()).toBe("");
  });

  test("a native REFUSAL rejects like a network error, never resolves", async () => {
    g.__rdevShell = { signalingBase: BASE, request: async () => { throw new Error("refused: path"); } };
    await expect(workerFetch()(`${BASE}/health`)).rejects.toBeInstanceOf(TypeError);
  });

  test("a malformed native answer rejects too", async () => {
    g.__rdevShell = { signalingBase: BASE, request: async () => ({ status: "200" }) };
    await expect(workerFetch()(`${BASE}/credential/abcd`)).rejects.toBeInstanceOf(TypeError);
  });

  test("ANOTHER ORIGIN is refused in the page, before the bridge is asked", async () => {
    const request = vi.fn(async () => ({ status: 200, body: "{}" }));
    g.__rdevShell = { signalingBase: BASE, request };
    await expect(workerFetch()("https://evil.test/credential/abcd")).rejects.toBeInstanceOf(TypeError);
    await expect(workerFetch()("http://cp.test/credential/abcd")).rejects.toBeInstanceOf(TypeError);
    expect(request).not.toHaveBeenCalled();
  });

  test("a query string crosses as written, so the native side can refuse it", async () => {
    const request = vi.fn(async () => { throw new Error("refused"); });
    g.__rdevShell = { signalingBase: BASE, request };
    await expect(workerFetch()(`${BASE}/credential/abcd?x=1`)).rejects.toBeInstanceOf(TypeError);
    expect(request).toHaveBeenCalledWith("/credential/abcd?x=1", { method: "GET" });
  });

  test("an aborted signal rejects with AbortError — before and during", async () => {
    const request = vi.fn(() => new Promise<unknown>(() => {}));
    g.__rdevShell = { signalingBase: BASE, request };
    const before = new AbortController();
    before.abort();
    await expect(workerFetch()(`${BASE}/credential/abcd`, { signal: before.signal }))
      .rejects.toMatchObject({ name: "AbortError" });
    expect(request).not.toHaveBeenCalled();

    const during = new AbortController();
    const pending = workerFetch()(`${BASE}/credential/abcd`, { signal: during.signal });
    during.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  });
});
