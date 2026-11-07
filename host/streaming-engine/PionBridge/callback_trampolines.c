#include "callback_trampolines.h"

#include <time.h>

uint64_t llv_pion_uptime_nanoseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

void llv_pion_call_state(
    llv_pion_state_callback callback,
    uint64_t context,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (callback != NULL) {
        callback(context, bytes, byte_count);
    }
}

void llv_pion_call_message(
    llv_pion_message_callback callback,
    uint64_t context,
    uint8_t channel,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (callback != NULL) {
        callback(context, channel, bytes, byte_count);
    }
}

void llv_pion_call_error(
    llv_pion_error_callback callback,
    uint64_t context,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (callback != NULL) {
        callback(context, bytes, byte_count);
    }
}

void llv_pion_call_recovery_keyframe(
    llv_pion_recovery_keyframe_callback callback,
    uint64_t context,
    uint64_t stream_id
) {
    if (callback != NULL) {
        callback(context, stream_id);
    }
}

void llv_pion_call_impairment_nack(
    llv_pion_impairment_nack_callback callback,
    uint64_t context
) {
    if (callback != NULL) {
        callback(context);
    }
}

int32_t llv_pion_call_recovery_policy(
    llv_pion_recovery_policy_callback callback,
    uint64_t context,
    uint64_t sequence,
    uint8_t tier,
    uint32_t media_bitrate_bits_per_second
) {
    if (callback == NULL) {
        return -1;
    }
    return callback(
        context, sequence, tier, media_bitrate_bits_per_second);
}
