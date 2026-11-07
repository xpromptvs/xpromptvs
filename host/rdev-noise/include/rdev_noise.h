/* The Noise session ABI — the boundary between the Swift host and `snow`.
 *
 * WRITTEN BY HAND AND KEPT HONEST BY A TEST. rules_rust emits the archive, not a header, so this
 * file and `src/lib.rs` are two statements of one contract and can drift. `NoiseSessionTests`
 * exercises every function here through Swift, so a signature that disagrees fails to compile or
 * fails the suite rather than corrupting a handshake at runtime.
 *
 * Patterns are MODES, not strings: a caller cannot ask for a protocol the specification does not
 * name, which keeps §11.1's table the single source of truth.
 */
#ifndef RDEV_NOISE_H
#define RDEV_NOISE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RdevNoiseSession RdevNoiseSession;

/** `enroll`, `auth`, `resume` — Noise_XX_25519_ChaChaPoly_SHA256. */
#define RDEV_NOISE_XX 0
/** `pair` — Noise_XXpsk3_25519_ChaChaPoly_SHA256. Requires a 32-byte PSK. */
#define RDEV_NOISE_PAIR 1

#define RDEV_NOISE_OK 0
#define RDEV_NOISE_ERR_ARGS (-1)
/** The output buffer was too small; nothing was consumed. */
#define RDEV_NOISE_ERR_BUFFER (-2)
/** Decryption or handshake failure. Spec §11.3: this TERMINATES the signalling session — a caller
 *  must not retry the message. */
#define RDEV_NOISE_ERR_NOISE (-3)

/** Build a session, or NULL. `psk` must be non-NULL exactly when `mode` is RDEV_NOISE_PAIR.
 *  `static_priv` is 32 bytes; `psk`, when given, is 32 bytes. */
RdevNoiseSession *rdev_noise_new(int32_t mode, bool initiator,
                                 const uint8_t *prologue, size_t prologue_len,
                                 const uint8_t *static_priv, const uint8_t *psk);

void rdev_noise_free(RdevNoiseSession *session);

/** True once the handshake has completed and the session carries transport keys. */
bool rdev_noise_is_transport(const RdevNoiseSession *session);

/** Write one message — handshake or transport, whichever the session is in. */
int32_t rdev_noise_write(RdevNoiseSession *session,
                         const uint8_t *payload, size_t payload_len,
                         uint8_t *out, size_t out_cap, size_t *out_len);

/** Read one message, writing its payload to `out`. */
int32_t rdev_noise_read(RdevNoiseSession *session,
                        const uint8_t *msg, size_t msg_len,
                        uint8_t *out, size_t out_cap, size_t *out_len);

/** The handshake hash `h` (32 bytes). Spec §11.2 binds `client-confirm` and the device proof to it,
 *  so this is protocol input, not a diagnostic. Available during the handshake AND after it. */
int32_t rdev_noise_handshake_hash(const RdevNoiseSession *session, uint8_t *out32);

/** The peer's static public key (32 bytes), which §11.1 requires be checked against the certified
 *  chain before anything is activated. */
int32_t rdev_noise_remote_static(const RdevNoiseSession *session, uint8_t *out32);

#ifdef __cplusplus
}
#endif
#endif /* RDEV_NOISE_H */
