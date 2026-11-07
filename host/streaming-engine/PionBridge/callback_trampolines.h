#ifndef LLV_PION_CALLBACK_TRAMPOLINES_H
#define LLV_PION_CALLBACK_TRAMPOLINES_H

#include <stddef.h>
#include <stdint.h>

typedef void (*llv_pion_state_callback)(
    uint64_t, const uint8_t *, size_t);
typedef void (*llv_pion_message_callback)(
    uint64_t, uint8_t, const uint8_t *, size_t);
typedef void (*llv_pion_error_callback)(
    uint64_t, const uint8_t *, size_t);
typedef void (*llv_pion_recovery_keyframe_callback)(uint64_t, uint64_t);
typedef void (*llv_pion_impairment_nack_callback)(uint64_t);
typedef int32_t (*llv_pion_recovery_policy_callback)(
    uint64_t, uint64_t, uint8_t, uint32_t);

enum {
    LLV_PION_RECOVERY_NACK_RTX = 1,
    LLV_PION_RECOVERY_OFF = 2,
    LLV_PION_RECOVERY_NACK_RTX_FLEXFEC = 3,
};

enum {
    LLV_PION_FLEXFEC_POLICY_ADAPTIVE = 1,
    LLV_PION_FLEXFEC_POLICY_OFF = 2,
    LLV_PION_FLEXFEC_POLICY_LOW = 3,
    LLV_PION_FLEXFEC_POLICY_MEDIUM = 4,
    LLV_PION_FLEXFEC_POLICY_HIGH = 5,
};

enum {
    LLV_PION_FLEXFEC_TIER_OFF = 0,
    LLV_PION_FLEXFEC_TIER_LOW = 1,
    LLV_PION_FLEXFEC_TIER_MEDIUM = 2,
    LLV_PION_FLEXFEC_TIER_HIGH = 3,
};

enum {
    LLV_PION_AV1_SCALABILITY_L1T1 = 1,
    LLV_PION_AV1_SCALABILITY_L1T2 = 2,
    LLV_PION_AV1_SCALABILITY_L1T3 = 3,
};

typedef struct {
    const char *local_ip;
    const char *remote_ip;
    uint16_t signal_port;
    uint16_t ice_port;
    uint8_t recovery_mode;
    uint8_t diagnostic_recovery_trace;
    uint16_t rtx_max_age_milliseconds;
    const uint8_t *impairment_profile_json;
    size_t impairment_profile_json_byte_count;
    int64_t impairment_seed;
    uint64_t callback_context;
    llv_pion_state_callback state_callback;
    llv_pion_message_callback message_callback;
    llv_pion_error_callback error_callback;
    llv_pion_recovery_keyframe_callback recovery_keyframe_callback;
    llv_pion_impairment_nack_callback impairment_nack_callback;
    uint8_t flexfec_policy;
    uint8_t scalability_mode;
    uint16_t frames_per_second;
    uint32_t total_rtp_budget_bits_per_second;
    llv_pion_recovery_policy_callback recovery_policy_callback;
    const uint8_t *flexfec_controller_policy_json;
    size_t flexfec_controller_policy_json_byte_count;
    uint8_t rtx_age_mode;
    uint16_t rtx_age_multiplier_milli;
    uint16_t rtx_age_cap_milliseconds;
} llv_pion_session_configuration;

typedef struct {
    uint64_t stream_id;
    uint64_t frame_id;
    uint64_t input_sequence;
    uint64_t host_processing_nanoseconds;
    uint64_t encode_nanoseconds;
    uint8_t is_keyframe;
    uint8_t scalability_mode;
    uint8_t temporal_id;
    uint8_t template_id;
    uint8_t reserved[4];
    const uint8_t *bytes;
    size_t byte_count;
} llv_pion_outbound_frame;

void llv_pion_call_state(
    llv_pion_state_callback, uint64_t, const uint8_t *, size_t);
void llv_pion_call_message(
    llv_pion_message_callback, uint64_t, uint8_t,
    const uint8_t *, size_t);
void llv_pion_call_error(
    llv_pion_error_callback, uint64_t, const uint8_t *, size_t);
void llv_pion_call_recovery_keyframe(
    llv_pion_recovery_keyframe_callback, uint64_t, uint64_t);
void llv_pion_call_impairment_nack(
    llv_pion_impairment_nack_callback, uint64_t);
int32_t llv_pion_call_recovery_policy(
    llv_pion_recovery_policy_callback, uint64_t, uint64_t, uint8_t, uint32_t);
uint64_t llv_pion_uptime_nanoseconds(void);

#endif
