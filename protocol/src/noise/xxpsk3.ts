/* OURS, not vendored — the only file in this directory that is.
 *
 * `Noise_XXpsk3_25519_ChaChaPoly_SHA256`, which §11.1 of the E2E protocol specification names for
 * `pair`. The vendored base implements XX and has no PSK support of any kind; a `psk3` modifier is
 * exactly two additions from revision 34, and both of them fail SILENTLY when wrong — a handshake
 * that omits either completes perfectly between two copies of the same mistake. That is why this is
 * checked against the published Cacophony vectors and not against a second implementation of ours.
 */
import { AbstractHandshakeState, CipherState } from './protocol.js'
import { Uint8ArrayList } from 'uint8arraylist'
import type { HandshakeStateInit } from './protocol.js'

export interface XXpsk3Init extends HandshakeStateInit {
  /** 32 bytes. For `pair` this is `PairingSeed`'s derived `psk` (§9.1) — never transmitted. */
  psk: Uint8Array
}

export class XXpsk3HandshakeState extends AbstractHandshakeState {
  private readonly psk: Uint8Array

  constructor (init: XXpsk3Init) {
    super(init)
    this.psk = init.psk
  }

  /**
   * Revision 34 §5.2, MixKeyAndHash.
   *
   * Needs no new primitive: `ICrypto.hkdf` already returns THREE outputs, and the base's `mixKey`
   * simply ignores the third.
   */
  private mixKeyAndHash (psk: Uint8Array): void {
    const [ck, tempH, tempK] = this.crypto.hkdf(this.ss.ck, psk)
    this.ss.ck = ck
    this.ss.mixHash(tempH)
    this.ss.cs = new CipherState(this.crypto, tempK)
  }

  /**
   * Revision 34 §9.3: in a PSK handshake the `e` token calls `MixKey(e.public_key)` IN ADDITION to
   * `MixHash`. Omit it and the first payload travels unencrypted and every later key differs — which
   * is also why XX's first message carries 32 bytes of overhead and XXpsk3's carries 48.
   */
  private writeEPsk (): Uint8Array {
    const pk = this.writeE()
    this.ss.mixKey(pk)
    return pk
  }

  private readEPsk (message: Uint8ArrayList, offset = 0): void {
    this.readE(message, offset)
    // `readE` stores a Uint8ArrayList sublist, while `mixKey` hands its argument to noble's HMAC,
    // which requires a real Uint8Array. The write side returns one already.
    this.ss.mixKey((this.re as Uint8ArrayList).subarray())
  }

  // -> e
  writeMessageA (payload: Uint8Array | Uint8ArrayList): Uint8Array | Uint8ArrayList {
    return new Uint8ArrayList(this.writeEPsk(), this.ss.encryptAndHash(payload))
  }

  // <- e, ee, s, es
  writeMessageB (payload: Uint8Array | Uint8ArrayList): Uint8Array | Uint8ArrayList {
    const e = this.writeEPsk()
    this.writeEE()
    const encS = this.writeS()
    this.writeES()
    return new Uint8ArrayList(e, encS, this.ss.encryptAndHash(payload))
  }

  // -> s, se, psk
  writeMessageC (payload: Uint8Array | Uint8ArrayList): Uint8Array | Uint8ArrayList {
    const encS = this.writeS()
    this.writeSE()
    this.mixKeyAndHash(this.psk)
    return new Uint8ArrayList(encS, this.ss.encryptAndHash(payload))
  }

  readMessageA (message: Uint8ArrayList): Uint8Array | Uint8ArrayList {
    this.readEPsk(message)
    return this.ss.decryptAndHash(message.sublist(32))
  }

  readMessageB (message: Uint8ArrayList): Uint8Array | Uint8ArrayList {
    this.readEPsk(message)
    this.readEE()
    const consumed = this.readS(message, 32)
    this.readES()
    return this.ss.decryptAndHash(message.sublist(32 + consumed))
  }

  readMessageC (message: Uint8ArrayList): Uint8Array | Uint8ArrayList {
    const consumed = this.readS(message)
    this.readSE()
    this.mixKeyAndHash(this.psk)
    return this.ss.decryptAndHash(message.sublist(consumed))
  }
}
