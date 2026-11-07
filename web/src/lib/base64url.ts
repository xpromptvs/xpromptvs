/// URL-safe base64 without padding — the encoding §11.3's envelopes, §12.1's returns and the pairing
/// carrier all use.
///
/// **One copy for the web client.** There were three: `client/pairing.ts`, `client/e2e-signalling.ts`
/// and a fourth about to be written for the shell's grant hand-off. They agreed, which is the only
/// reason nothing had broken yet — the decoders differed in whether they rejected an empty string,
/// and that difference is exactly the kind that surfaces as one path accepting what another refuses.
/// `@rdev/protocol` keeps its own, deliberately: it must not depend on `atob`/`btoa` being present.

/// bytes → URL-safe base64, padding stripped.
export function base64urlEncode (bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// URL-safe base64 → bytes, or null. **An empty string is null**, not an empty array: every caller
/// here is decoding something that must exist, and "" is what an absent field looks like.
export function base64urlDecode (value: string): Uint8Array | null {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}
