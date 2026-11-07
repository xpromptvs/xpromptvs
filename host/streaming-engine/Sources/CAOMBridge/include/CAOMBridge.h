#ifndef LLV_CAOM_BRIDGE_H
#define LLV_CAOM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llv_aom_runtime llv_aom_runtime;
typedef struct llv_aom_encoder llv_aom_encoder;

#define LLV_AOM_USE_DEFAULT (-1)

enum {
    LLV_AOM_RUNTIME_OK = 0,
    LLV_AOM_RUNTIME_NOT_FOUND = 1,
    LLV_AOM_RUNTIME_OUT_OF_MEMORY = 4,
    LLV_AOM_ENCODER_INVALID_ARGUMENT = 10,
    LLV_AOM_ENCODER_CODEC_ERROR = 11,
    LLV_AOM_ENCODER_UNEXPECTED_OUTPUT = 12,
};

enum {
    LLV_AOM_SCALABILITY_L1T1 = 1,
    LLV_AOM_SCALABILITY_L1T2 = 2,
    LLV_AOM_SCALABILITY_L1T3 = 3,
};

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t bitrate;
    uint32_t threads;
    uint32_t cpu_used;
    uint32_t tile_columns;
    uint32_t tile_rows;
    uint32_t rc_buffer_milliseconds;
    uint32_t rc_initial_buffer_milliseconds;
    uint32_t rc_optimal_buffer_milliseconds;
    int32_t auto_tiles;
    int32_t screen_detection_mode;
    int32_t aq_mode;
    int32_t sharpness;
    int32_t adaptive_sharpness;
    int32_t cdef_mode;
    int32_t loopfilter_mode;
    int32_t scalability_mode;
} llv_aom_encoder_configuration;

typedef struct {
    const uint8_t *data;
    size_t size;
    int is_keyframe;
    uint8_t temporal_id;
    uint8_t template_id;
    int high_motion_screen_rtc;
} llv_aom_encoded_packet;

uint32_t llv_aom_temporal_layer_bitrate(
    int32_t scalability_mode,
    uint32_t total_kilobits_per_second,
    uint32_t temporal_id
);

int llv_aom_runtime_open(
    llv_aom_runtime **runtime_out,
    char *error,
    size_t error_capacity
);

void llv_aom_runtime_close(llv_aom_runtime *runtime);

const char *llv_aom_runtime_version(const llv_aom_runtime *runtime);

int llv_aom_encoder_create(
    const llv_aom_encoder_configuration *configuration,
    llv_aom_encoder **encoder_out,
    char *error,
    size_t error_capacity
);

/* One explicit L1T1 frame. Once enabled, every encode must supply a fresh plan.
 * Recovery remains an inter frame; flags discard inherited entropy/MV state. */
typedef struct {
    uint8_t reference_slots[7];
    uint8_t enabled_references;
    uint8_t refresh_slot_mask;
    uint8_t recovery;
} llv_aom_reference_plan;

int llv_aom_encoder_set_reference_plan(
    llv_aom_encoder *encoder, const llv_aom_reference_plan *plan,
    char *error, size_t error_capacity
);

int llv_aom_encoder_encode_nv12(
    llv_aom_encoder *encoder,
    const uint8_t *luma,
    size_t luma_stride,
    const uint8_t *chroma,
    size_t chroma_stride,
    uint64_t frame_id,
    int force_keyframe,
    llv_aom_encoded_packet *packet_out,
    char *error,
    size_t error_capacity
);

int llv_aom_encoder_set_bitrate(
    llv_aom_encoder *encoder,
    uint32_t bitrate,
    char *error,
    size_t error_capacity
);

/* Writes the colour description (CICP) the AV1 sequence header carries, as CICP code points:
 * `color_primaries`/`transfer_characteristics`/`matrix_coefficients` are the values from
 * ITU-T H.273 (1 = BT.709 on all three), and `color_range` is 0 for studio/limited range and 1
 * for full. LLV_AOM_USE_DEFAULT on any field leaves libaom's own default in place, which for
 * the three CICP fields is 2 = "unspecified".
 *
 * MUST BE CALLED BEFORE THE FIRST FRAME. The sequence header is written with the first
 * keyframe, so a later call cannot retag frames already emitted.
 *
 * UNTAGGED IS A BUG, NOT A DEFAULT. A decoder handed "unspecified" falls back to a heuristic —
 * VideoToolbox's is keyed on RESOLUTION — so an untagged stream decodes with the wrong matrix
 * below roughly 720px wide and the right one above it, i.e. its colour SHIFTS as the streamed
 * resolution changes. It looks perfect on any large window, which is why nothing catches it by
 * eye.
 *
 * SEPARATE FROM llv_aom_encoder_create RATHER THAN FOUR MORE FIELDS ON
 * llv_aom_encoder_configuration, for one hard reason: Swift imports a C struct with a
 * memberwise initialiser that requires EVERY field, and that struct is constructed at three
 * call sites in Tests/LLVCoreTests/AV1BridgeTests.swift, which gate G1 freezes. Nothing is lost
 * by the split — aom_codec_enc_cfg_t has no colour fields either, so these values are only ever
 * reachable through controls, which are inherently post-init.
 */
int llv_aom_encoder_set_color_config(
    llv_aom_encoder *encoder,
    int32_t color_primaries,
    int32_t transfer_characteristics,
    int32_t matrix_coefficients,
    int32_t color_range,
    char *error,
    size_t error_capacity
);

int llv_aom_encoder_set_active_map(
    llv_aom_encoder *encoder,
    const uint8_t *active_map,
    uint32_t rows,
    uint32_t columns,
    char *error,
    size_t error_capacity
);

int llv_aom_encoder_complete(
    llv_aom_encoder *encoder,
    char *error,
    size_t error_capacity
);

void llv_aom_encoder_destroy(llv_aom_encoder *encoder);

void llv_aom_split_nv12_chroma(
    const uint8_t *source,
    size_t source_stride,
    uint8_t *u,
    size_t u_stride,
    uint8_t *v,
    size_t v_stride,
    size_t width,
    size_t height
);

#ifdef __cplusplus
}
#endif

#endif
