/* VENDORED from @chainsafe/libp2p-noise 17.0.0, file `src/types.ts` — TRIMMED.
 * Copyright ChainSafe Systems. Licensed Apache-2.0 OR MIT; see ./VENDOR.md.
 *
 * The original also declares libp2p's own surface (ConnectionEncrypter, NoiseExtensions, the
 * protobuf payload) and imports `@libp2p/interface` and `@libp2p/utils` for it. None of that is
 * reachable from the Noise core, and carrying it would drag libp2p into a client that has nothing
 * to do with libp2p — measured at 201 KB minified against 75 KB for this set. Only the five
 * interfaces the core actually consumes are kept, verbatim.
 */
import type { Nonce } from './nonce.js'
import type { Uint8ArrayList } from 'uint8arraylist'

export interface KeyPair {
  publicKey: Uint8Array
  privateKey: Uint8Array
}

export interface ICrypto {
  generateKeypair(): KeyPair
  dh(keypair: KeyPair, publicKey: Uint8Array | Uint8ArrayList): Uint8Array
  encrypt(plaintext: Uint8Array | Uint8ArrayList, nonce: Uint8Array, ad: Uint8Array, k: Uint8Array): Uint8ArrayList | Uint8Array
  decrypt(ciphertext: Uint8Array | Uint8ArrayList, nonce: Uint8Array, ad: Uint8Array, k: Uint8Array, dst?: Uint8Array): Uint8ArrayList | Uint8Array
  hash(data: Uint8Array | Uint8ArrayList): Uint8Array
  hkdf(ck: Uint8Array, ikm: Uint8Array): [Uint8Array, Uint8Array, Uint8Array]
}

export interface ICipherState {
  /**
   * A cipher key of 32 bytes (which may be empty). Empty is a special value
   * which indicates k has not yet been initialized.
   */
  k?: Uint8Array
  /**
   * An 8-byte (64-bit) unsigned integer nonce.
   *
   * For performance reasons, the nonce is represented as a Nonce object
   * The nonce is treated as a uint64, even though the underlying `number` only
   * has 52 safely-available bits.
   */
  n: Nonce
}

export interface ISymmetricState {
  cs: ICipherState
  /** A chaining key of 32 bytes. */
  ck: Uint8Array
  /** A hash output of 32 bytes. */
  h: Uint8Array
}

export interface IHandshakeState {
  ss: ISymmetricState
  /** The local static key pair */
  s?: KeyPair
  /** The local ephemeral key pair */
  e?: KeyPair
  /** The remote party's static public key */
  rs?: Uint8Array | Uint8ArrayList
  /** The remote party's ephemeral public key */
  re?: Uint8Array | Uint8ArrayList
}
