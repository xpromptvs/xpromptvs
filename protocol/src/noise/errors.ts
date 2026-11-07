/* VENDORED from @chainsafe/libp2p-noise 17.0.0, file `src/errors.ts`.
 * Copyright ChainSafe Systems. Licensed Apache-2.0 OR MIT; see ./VENDOR.md.
 *
 * UNMODIFIED except for this header.
 */
export class InvalidCryptoExchangeError extends Error {
  public code: string

  constructor (message = 'Invalid crypto exchange') {
    super(message)
    this.code = InvalidCryptoExchangeError.code
  }

  static readonly code = 'ERR_INVALID_CRYPTO_EXCHANGE'
}
