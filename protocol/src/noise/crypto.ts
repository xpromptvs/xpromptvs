/* VENDORED from @chainsafe/libp2p-noise 17.0.0, file `src/crypto.ts`.
 * Copyright ChainSafe Systems. Licensed Apache-2.0 OR MIT; see ./VENDOR.md.
 *
 * Adapts ICryptoInterface to the ICrypto the core consumes. UNMODIFIED except for this header.
 */
import type { ICrypto, KeyPair } from './types.js'
import type { Uint8ArrayList } from 'uint8arraylist'

/** Underlying crypto implementation, meant to be overridable */
export interface ICryptoInterface {
  hashSHA256(data: Uint8Array | Uint8ArrayList): Uint8Array

  getHKDF(ck: Uint8Array, ikm: Uint8Array): [Uint8Array, Uint8Array, Uint8Array]

  generateX25519KeyPair(): KeyPair
  generateX25519KeyPairFromSeed(seed: Uint8Array): KeyPair
  generateX25519SharedKey(privateKey: Uint8Array | Uint8ArrayList, publicKey: Uint8Array | Uint8ArrayList): Uint8Array

  chaCha20Poly1305Encrypt(plaintext: Uint8Array | Uint8ArrayList, nonce: Uint8Array, ad: Uint8Array, k: Uint8Array): Uint8ArrayList | Uint8Array
  chaCha20Poly1305Decrypt(ciphertext: Uint8Array | Uint8ArrayList, nonce: Uint8Array, ad: Uint8Array, k: Uint8Array, dst?: Uint8Array): Uint8ArrayList | Uint8Array
}

export function wrapCrypto (crypto: ICryptoInterface): ICrypto {
  return {
    generateKeypair: crypto.generateX25519KeyPair,
    dh: (keypair, publicKey) => crypto.generateX25519SharedKey(keypair.privateKey, publicKey).subarray(0, 32),
    encrypt: crypto.chaCha20Poly1305Encrypt,
    decrypt: crypto.chaCha20Poly1305Decrypt,
    hash: crypto.hashSHA256,
    hkdf: crypto.getHKDF
  }
}
