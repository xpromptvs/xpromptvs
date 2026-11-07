/* OURS. The post-handshake half of a Noise session.
 *
 * `Split()` yields two cipher states, and which one a party SENDS with depends on its role: the
 * initiator writes with the first and reads with the second, the responder the reverse. Getting that
 * backwards produces a session where neither side can read the other — loud — but a session that
 * shares one state in both directions is far worse and much quieter, because it works perfectly
 * until the nonces collide.
 */
import type { CipherState } from './protocol.js'
import type { Uint8ArrayList } from 'uint8arraylist'
import { alloc as uint8ArrayAlloc } from 'uint8arrays/alloc'

/** Transport messages carry no associated data; the handshake hash already bound the session. */
const NO_AD = uint8ArrayAlloc(0)

export class NoiseTransport {
  private readonly send: CipherState
  private readonly recv: CipherState

  /** `split` is `SymmetricState.split()`'s pair, in its order. */
  constructor (split: [CipherState, CipherState], initiator: boolean) {
    const [first, second] = split
    this.send = initiator ? first : second
    this.recv = initiator ? second : first
  }

  write (payload: Uint8Array | Uint8ArrayList): Uint8Array | Uint8ArrayList {
    return this.send.encryptWithAd(NO_AD, payload)
  }

  read (message: Uint8Array | Uint8ArrayList): Uint8Array | Uint8ArrayList {
    return this.recv.decryptWithAd(NO_AD, message)
  }
}
