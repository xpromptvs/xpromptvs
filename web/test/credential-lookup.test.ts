import { afterEach, describe, expect, test, vi } from "vitest";
import { CREDENTIAL_LOOKUP_DEADLINE_MS, credentialLookupOutcome } from "../src/lib/credential-lookup";

// §10.1's discovery lookup: the one field a WebAuthn assertion cannot carry.
//
// **NOTHING HERE IS A SECURITY BOUNDARY AND THE TESTS MUST NOT READ AS IF IT WERE.** The answer is
// a hint from a Worker §4 puts inside the adversary model; `verifyDiscoveredRoot` is what makes it
// usable. What is asserted here is that the request is well-formed, that every unhappy answer
// collapses to one outcome a caller can act on, and that a silent Worker cannot stall a person.
const CREDENTIAL = Uint8Array.from([0xa1, 0x0f, 0x7c, 0x2b]);
const ROOT = Uint8Array.from([1, 2, 3, 4, 5]);

const ok = (body: unknown): Response =>
  ({ ok: true, json: async () => body }) as unknown as Response;

afterEach(() => { vi.useRealTimers(); });

describe("the lookup itself", () => {
  test("asks for the credential by its base64url name and decodes the descriptor", async () => {
    const seen: string[] = [];
    const found = await credentialLookupOutcome("https://cp.test", CREDENTIAL, (async (url) => {
      seen.push(String(url));
      return ok({ root: "AQIDBAU" });
    }) as typeof fetch);
    expect(seen).toEqual(["https://cp.test/credential/oQ98Kw"]);
    expect(found.kind).toBe("found");
    expect([...(found as { root: Uint8Array }).root]).toEqual([...ROOT]);
  });

  // Junk and a thrown request are UNKNOWN — never `found`, and never the Worker's own `absent`.
  test("junk and a thrown request are unknown", async () => {
    for (const fetcher of [
      async () => ok({}),
      async () => ok({ root: "not base64url!" }),
      async () => { throw new Error("offline"); },
    ]) {
      expect((await credentialLookupOutcome("https://cp.test", CREDENTIAL, fetcher as typeof fetch)).kind)
        .toBe("unknown");
    }
  });

  // **BOUNDED, for the reason §12.2 gives about publication**: a request that is neither answered
  // nor refused has not failed, and without a deadline a silent Worker holds a person in front of a
  // spinner for as long as it likes.
  test("a Worker that never answers is abandoned at the deadline", async () => {
    vi.useFakeTimers();
    let aborted = false;
    const pending = credentialLookupOutcome("https://cp.test", CREDENTIAL,
      ((_url: unknown, init: RequestInit) => new Promise<Response>((_resolve, reject) => {
        init.signal!.addEventListener("abort", () => {
          aborted = true;
          reject(new Error("aborted"));
        });
      })) as unknown as typeof fetch);

    await vi.advanceTimersByTimeAsync(CREDENTIAL_LOOKUP_DEADLINE_MS + 1);
    expect((await pending).kind).toBe("unknown");
    expect(aborted).toBe(true);
  });
});

// **`absent` APART FROM `unknown`, FOR ONE PURPOSE ONLY** — never the TRUST decision, where only
// `found` leads anywhere and telling the rest apart would tempt a caller into reading "the Worker
// said no" as evidence about the identity.
//
// This tells them apart for something much weaker — whether to OFFER a person the option of deleting
// a passkey. Not evidence, not a verdict: a reason to raise the subject or stay quiet. A Worker that
// never replied has told us nothing, and inviting somebody to destroy a credential on the strength
// of a timeout would be inviting it on the strength of their Wi-Fi.
describe("credentialLookupOutcome", () => {
  const notFound = {
    ok: false, status: 404, json: async () => ({ error: "not-found" }),
  } as unknown as Response;

  test("a descriptor is found", async () => {
    const out = await credentialLookupOutcome("https://cp.test", CREDENTIAL,
                                              (async () => ok({ root: "AQIDBAU" })) as typeof fetch);
    expect(out.kind).toBe("found");
    if (out.kind === "found") expect([...out.root]).toEqual([...ROOT]);
  });

  // The DO's own 404 body. `credential-do.ts` answers `{ error: "not-found" }` when it holds no
  // root, which is the only answer in the system that means "I looked, and there is nothing".
  test("the DO saying it holds nothing is ABSENT", async () => {
    expect((await credentialLookupOutcome("https://cp.test", CREDENTIAL,
                                          (async () => notFound) as typeof fetch)).kind)
      .toBe("absent");
  });

  // A path that does not match the route falls through to the ASSETS binding, which 404s with HTML.
  // Same status, entirely different meaning, and reading it as "absent" would offer deletion on the
  // strength of a routing mistake.
  test("a 404 that is not the DO's is UNKNOWN", async () => {
    const html = { ok: false, status: 404, json: async () => { throw new Error("not json"); } };
    expect((await credentialLookupOutcome("https://cp.test", CREDENTIAL,
                                          (async () => html as unknown as Response) as typeof fetch)).kind)
      .toBe("unknown");
  });

  test("a refusal, a server error, junk and a thrown request are all UNKNOWN", async () => {
    const cases: Array<() => Promise<Response>> = [
      async () => ({ ok: false, status: 500, json: async () => ({}) }) as unknown as Response,
      async () => ({ ok: false, status: 429, json: async () => ({}) }) as unknown as Response,
      async () => ok({}),
      async () => { throw new Error("offline"); },
    ];
    for (const fetcher of cases) {
      expect((await credentialLookupOutcome("https://cp.test", CREDENTIAL, fetcher as typeof fetch))
        .kind).toBe("unknown");
    }
  });

  // The bounded deadline is the same one, for the same reason: a silent Worker must not stall a
  // person in front of a spinner. Silence is UNKNOWN, never absent.
  test("a silent Worker times out as UNKNOWN, not as absent", async () => {
    vi.useFakeTimers();
    const pending = credentialLookupOutcome("https://cp.test", CREDENTIAL,
      ((_url: unknown, init: RequestInit) => new Promise((_resolve, reject) => {
        init.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      })) as unknown as typeof fetch);
    await vi.advanceTimersByTimeAsync(CREDENTIAL_LOOKUP_DEADLINE_MS + 1);
    expect((await pending).kind).toBe("unknown");
  });
});
