import { controlPlaneOrigin } from "./signaling-base";

/**
 * **The Worker's HTTP API, from whichever surface this page is running on.**
 *
 * In a browser this is plain `fetch`: the page is served BY the Worker, so every call is
 * same-origin. The native app's client window is served from `app://client/`, an origin the Worker
 * sends no CORS for, so there `fetch` fails before a byte is read. Rather than teach the Worker to
 * trust an origin that any WKWebView can claim, the app performs these requests NATIVELY
 * (`__rdevShell.request`, `app/Sources/ClientBridge.swift`) — against its own signalling origin
 * and ONLY for the allow-list in `app/Core/WorkerRequest.swift`: §12.2's `challenge`, `register`
 * and `list`, and §10.1's `GET /credential/<id>`. `docs/desktop-app.md`, "Native Worker requests".
 *
 * **The page never names an origin to the bridge, only a PATH.** A URL on any other origin is
 * refused HERE, before the bridge is asked, and the native side refuses again whatever is not on its
 * list — this is not a proxy.
 *
 * What comes back is a real `Response`, because the three callers read `ok`, `status`, `json()` and
 * nothing else, and a refusal REJECTS with a `TypeError` exactly as a failed `fetch` does — a
 * caller must never mistake "the bridge said no" for an answer from the Worker.
 */
type ShellRequest = (path: string, init: { method: string; body?: string }) => Promise<unknown>;

export function workerFetch (): typeof fetch {
  const shell = (globalThis as { __rdevShell?: { request?: ShellRequest } }).__rdevShell;
  const request = shell?.request;
  if (typeof request !== "function") {
    // Looked up at CALL time, so a test (or anything else) that replaces `fetch` is honoured.
    return ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init)) as typeof fetch;
  }
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const signal = init?.signal ?? undefined;
    if (signal?.aborted) throw abortError();

    const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const origin = controlPlaneOrigin();
    let url: URL;
    try { url = new URL(raw); } catch { throw new TypeError("worker request: not a URL"); }
    if (url.origin !== new URL(origin).origin) {
      throw new TypeError("worker request: not the control plane's origin");
    }
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? init.body : undefined;
    if (init?.body != null && body === undefined) throw new TypeError("worker request: body must be text");

    const answer = request.call(shell, url.pathname + url.search,
                                body === undefined ? { method } : { method, body });
    const reply = await (signal ? raceAbort(answer, signal) : answer.catch(refused));
    return toResponse(reply);
  }) as typeof fetch;
}

function refused (e: unknown): never {
  throw new TypeError(`worker request refused: ${e instanceof Error ? e.message : String(e)}`);
}

function raceAbort (answer: Promise<unknown>, signal: AbortSignal): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortError());
    signal.addEventListener("abort", onAbort, { once: true });
    answer.then(
      (v) => { signal.removeEventListener("abort", onAbort); resolve(v); },
      (e) => { signal.removeEventListener("abort", onAbort); try { refused(e); } catch (t) { reject(t); } },
    );
  });
}

function abortError (): Error {
  return new DOMException("The operation was aborted.", "AbortError");
}

/// Statuses a `Response` must be built with NO body, or the constructor throws.
const NULL_BODY = new Set([101, 103, 204, 205, 304]);

function toResponse (reply: unknown): Response {
  const r = reply as { status?: unknown; body?: unknown; headers?: unknown } | null;
  if (!r || typeof r.status !== "number" || !Number.isInteger(r.status) || r.status < 200 || r.status > 599
      || (r.body !== undefined && typeof r.body !== "string")) {
    throw new TypeError("worker request: malformed answer");
  }
  const headers = new Headers();
  if (r.headers && typeof r.headers === "object") {
    for (const [k, v] of Object.entries(r.headers as Record<string, unknown>)) {
      if (typeof v === "string") { try { headers.set(k, v); } catch { /* not a header */ } }
    }
  }
  return new Response(NULL_BODY.has(r.status) ? null : (r.body as string | undefined) ?? "",
                      { status: r.status, headers });
}
