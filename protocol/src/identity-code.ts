/// **§10.1's identity, as a person actually reads it.**
///
/// Sixty-four hexadecimal characters is a wall of text: people glance at it and press the button.
/// `C1P9-HM5S-6D93-FPDC` is a thing two screens can be held side by side to compare. **Replacing a
/// check nobody performs with one they might is the whole argument** — an unusable check is a weaker
/// check, which is why this replaces the old "never abbreviated" rule rather than bending it.
///
/// Crockford's alphabet, so there is no `I`/`1`, `O`/`0` or `L`/`1` to misread across two screens,
/// nothing that reads as a word, and no case to get wrong when reading one aloud.
///
/// **Eighty bits, and where that is load-bearing.** On sign-in it is belt and braces: discovery pins
/// all three inputs to `H(root)` — `rp_id` from local policy, `credential_id` from the assertion the
/// person just produced, the public key by the ECDSA check — so the root id is fully determined by
/// which passkey they picked and no look-alike is constructible at any length. At §12.1, where a
/// browser hands a Mac a bundle the Mac did not produce, it is a real check: forging a match means a
/// targeted preimage against 80 bits, not a birthday collision, because the victim already holds the
/// identity being impersonated.
///
/// DISPLAY ONLY. There is no decoder because nothing takes an identity as input, and a parser with
/// no caller is a surface with no caller.
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// The prefix of `root_id` this reads. Ten bytes is eighty bits is exactly sixteen characters, with
/// no padding character to explain to anybody.
export const IDENTITY_CODE_BYTES = 10;

export function identityCode (rootId: Uint8Array): string {
  // Shorter than the prefix is not an identity, and a half-length code would LOOK like one. An
  // empty string is visibly nothing.
  if (rootId.length < IDENTITY_CODE_BYTES) return "";

  let out = "";
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < IDENTITY_CODE_BYTES; i += 1) {
    // `acc` never exceeds twelve bits: five are drained before each byte is added, so the 32-bit
    // shift below cannot reach the sign bit.
    acc = (acc << 8) | rootId[i]!;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += ALPHABET[(acc >> bits) & 31];
    }
  }
  return out.replace(/(.{4})(?=.)/g, "$1-");
}
