import { describe, expect, it } from "vitest";
import { directoryRequestBody, ed25519PublicKey, rootId, verifyEd25519 } from "@rdev/protocol";
import { listDirectorySessions } from "../src/lib/directory-api";
import { base64urlDecode, base64urlEncode } from "../src/lib/base64url";

// A CHARACTERISATION of the signed listing, written before `signDirectoryRequest` was factored out
// of it: the request the Worker receives must verify under the Worker's own rebuild, and a
// malformed row is dropped rather than defaulted.
const priv = new Uint8Array(32).fill(7);
const identity = { root: new Uint8Array([1, 2, 3]), bundle: new Uint8Array([9, 9]), signingPrivateKey: priv };
const challenge = base64urlEncode(new Uint8Array(32).fill(0x66));

describe("listDirectorySessions", () => {
  it("signs a list the Worker's rebuild verifies, and keeps only well-formed rows", async () => {
    const posted: Record<string, string>[] = [];
    const fetcher = (async (url: string, init?: RequestInit) => {
      if (url.endsWith("/challenge")) return new Response(JSON.stringify({ challenge }));
      posted.push(JSON.parse(String(init?.body)));
      return new Response(JSON.stringify({ sessions: [
        { code: "A", token: "t", label: "Mac", device_id: "d" }, { code: "B" }] }));
    }) as typeof fetch;
    const rows = await listDirectorySessions("https://cp.test", identity, fetcher,
                                             (n) => new Uint8Array(n).fill(0x44));
    expect(rows).toEqual([{ code: "A", token: "t", label: "Mac", device_id: "d" }]);
    const sent = posted[0]!;
    expect(sent.bundle).toBe(base64urlEncode(identity.bundle));
    const body = directoryRequestBody("list", base64urlDecode(challenge)!, rootId(identity.root),
                                      base64urlDecode(sent.operation_id!)!, new Uint8Array(0))!;
    expect(verifyEd25519(base64urlDecode(sent.signature!)!, body, ed25519PublicKey(priv))).toBe(true);
  });
});
