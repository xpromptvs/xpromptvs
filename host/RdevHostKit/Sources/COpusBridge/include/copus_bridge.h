#ifndef COPUS_BRIDGE_H
#define COPUS_BRIDGE_H

/* Swift reaches libopus through this header.
 *
 * IT IS NOT AN EMPTY PASS-THROUGH, AND CPionBridge's SHIM IS NOT THE MODEL HERE. libopus's control
 * entry point is a C VARIADIC — `int opus_encoder_ctl(OpusEncoder *st, int request, ...)` — and
 * Swift cannot call C variadic functions at all. Every ctl therefore needs a fixed-signature
 * wrapper on the C side; there is no Swift-side workaround, and discovering that after writing the
 * Swift is the expensive order to discover it in.
 *
 * The wrappers are the ONLY thing this shim adds. Everything else is opus's own declarations,
 * reachable as the `COpusBridge` module. */

#include <opus/opus.h>

/* Set one integer-valued encoder ctl. Returns OPUS_OK (0) or a negative opus error.
 *
 * EVERY CALLER MUST CHECK THIS. A refused setting is indistinguishable from an applied one, which
 * is the rule every VTSessionSetProperty in this project already follows: silence must mean
 * applied, or a whole configuration can be quietly absent. */
static inline int rdev_opus_encoder_ctl_set(OpusEncoder *st, int request, opus_int32 value) {
    return opus_encoder_ctl(st, request, value);
}

/* Read one integer-valued encoder ctl back. Used only by tests — the product never reads settings
 * back, because create-failure plus a checked set is already the guard. */
static inline int rdev_opus_encoder_ctl_get(OpusEncoder *st, int request, opus_int32 *value) {
    return opus_encoder_ctl(st, request, value);
}

#endif
