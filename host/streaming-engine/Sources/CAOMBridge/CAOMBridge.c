#include "CAOMBridge.h"
#include "aom/aom_encoder.h"
#include "aom/aom_image.h"
#include "aom/aomcx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

typedef const char *(*llv_aom_version_function)(void);
typedef aom_codec_iface_t *(*llv_aom_av1_interface_function)(void);
typedef aom_codec_err_t (*llv_aom_config_default_function)(
    aom_codec_iface_t *, aom_codec_enc_cfg_t *, unsigned int
);
typedef aom_codec_err_t (*llv_aom_encoder_init_function)(
    aom_codec_ctx_t *, aom_codec_iface_t *, const aom_codec_enc_cfg_t *,
    aom_codec_flags_t, int
);
typedef aom_codec_err_t (*llv_aom_config_set_function)(
    aom_codec_ctx_t *, const aom_codec_enc_cfg_t *
);
typedef aom_codec_err_t (*llv_aom_control_function)(aom_codec_ctx_t *, int, ...);
typedef aom_codec_err_t (*llv_aom_encode_function)(
    aom_codec_ctx_t *, const aom_image_t *, aom_codec_pts_t, unsigned long,
    aom_enc_frame_flags_t
);
typedef const aom_codec_cx_pkt_t *(*llv_aom_output_function)(
    aom_codec_ctx_t *, aom_codec_iter_t *
);
typedef aom_codec_err_t (*llv_aom_destroy_function)(aom_codec_ctx_t *);
typedef const char *(*llv_aom_codec_error_function)(const aom_codec_ctx_t *);
typedef const char *(*llv_aom_codec_detail_function)(const aom_codec_ctx_t *);
typedef aom_image_t *(*llv_aom_image_wrap_function)(
    aom_image_t *, aom_img_fmt_t, unsigned int, unsigned int, unsigned int,
    unsigned char *
);

struct llv_aom_runtime {
    llv_aom_version_function version_function;
    llv_aom_av1_interface_function av1_interface;
    llv_aom_config_default_function config_default;
    llv_aom_encoder_init_function encoder_init;
    llv_aom_config_set_function config_set;
    llv_aom_control_function control;
    llv_aom_encode_function encode;
    llv_aom_output_function output;
    llv_aom_destroy_function destroy;
    llv_aom_codec_error_function codec_error;
    llv_aom_codec_detail_function codec_detail;
    llv_aom_image_wrap_function image_wrap;
};

struct llv_aom_encoder {
    llv_aom_runtime *runtime;
    aom_codec_ctx_t codec;
    uint32_t width;
    uint32_t height;
    uint8_t *u;
    uint8_t *v;
    uint8_t *output;
    size_t output_capacity;
    int codec_initialized;
    aom_codec_enc_cfg_t configuration;
    int32_t scalability_mode;
    uint8_t temporal_phase;
    int reference_mode;
    int reference_plan_pending;
    llv_aom_reference_plan reference_plan;
};

uint32_t llv_aom_temporal_layer_bitrate(
    int32_t scalability_mode,
    uint32_t total_kilobits_per_second,
    uint32_t temporal_id
) {
    static const uint16_t l1t1[] = { 1000 };
    static const uint16_t l1t2[] = { 645, 1000 };
    static const uint16_t l1t3[] = { 540, 703, 1000 };
    const uint16_t *permille = NULL;
    size_t count = 0;
    switch (scalability_mode) {
        case LLV_AOM_SCALABILITY_L1T1:
            permille = l1t1;
            count = sizeof(l1t1) / sizeof(l1t1[0]);
            break;
        case LLV_AOM_SCALABILITY_L1T2:
            permille = l1t2;
            count = sizeof(l1t2) / sizeof(l1t2[0]);
            break;
        case LLV_AOM_SCALABILITY_L1T3:
            permille = l1t3;
            count = sizeof(l1t3) / sizeof(l1t3[0]);
            break;
        default:
            return 0;
    }
    if (temporal_id >= count) {
        return 0;
    }
    return (uint32_t)(
        (uint64_t)total_kilobits_per_second * permille[temporal_id] / 1000
    );
}

static void llv_aom_set_error(
    char *error,
    size_t error_capacity,
    const char *format,
    const char *detail
) {
    if (error == NULL || error_capacity == 0) {
        return;
    }
    (void)snprintf(error, error_capacity, format, detail == NULL ? "" : detail);
}

int llv_aom_runtime_open(
    llv_aom_runtime **runtime_out,
    char *error,
    size_t error_capacity
) {
    if (runtime_out == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "runtime output pointer is null");
        return LLV_AOM_RUNTIME_NOT_FOUND;
    }
    *runtime_out = NULL;

    llv_aom_runtime *runtime = calloc(1, sizeof(*runtime));
    if (runtime == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "out of memory creating AV1 runtime");
        return LLV_AOM_RUNTIME_OUT_OF_MEMORY;
    }
    runtime->version_function = aom_codec_version_str;
    runtime->av1_interface = aom_codec_av1_cx;
    runtime->config_default = aom_codec_enc_config_default;
    runtime->encoder_init = aom_codec_enc_init_ver;
    runtime->config_set = aom_codec_enc_config_set;
    runtime->control = aom_codec_control;
    runtime->encode = aom_codec_encode;
    runtime->output = aom_codec_get_cx_data;
    runtime->destroy = aom_codec_destroy;
    runtime->codec_error = aom_codec_error;
    runtime->codec_detail = aom_codec_error_detail;
    runtime->image_wrap = aom_img_wrap;

    *runtime_out = runtime;
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

void llv_aom_runtime_close(llv_aom_runtime *runtime) {
    if (runtime == NULL) {
        return;
    }
    free(runtime);
}

const char *llv_aom_runtime_version(const llv_aom_runtime *runtime) {
    if (runtime == NULL || runtime->version_function == NULL) {
        return "";
    }
    return runtime->version_function();
}

static int llv_aom_codec_failure(
    llv_aom_encoder *encoder,
    const char *operation,
    aom_codec_err_t codec_status,
    char *error,
    size_t error_capacity
) {
    const char *summary = encoder->runtime->codec_error(&encoder->codec);
    const char *detail = encoder->runtime->codec_detail(&encoder->codec);
    if (error != NULL && error_capacity > 0) {
        (void)snprintf(
            error,
            error_capacity,
            "%s failed with libaom status %d: %s%s%s",
            operation,
            codec_status,
            summary == NULL ? "unknown error" : summary,
            detail == NULL ? "" : ": ",
            detail == NULL ? "" : detail
        );
    }
    return LLV_AOM_ENCODER_CODEC_ERROR;
}

/* CONTENT MODE. Defaults to AOM_CONTENT_SCREEN, which is right for rdev's usual subject -- a macOS
 * window full of anti-aliased text, where palette and intra block copy earn their place.
 *
 * IT IS ALSO SELECTABLE AGAIN, and the history is worth keeping because it nearly became folklore.
 * AOM_CONTENT_DEFAULT segfaulted in every configuration tried -- both content modes, 1/4/12
 * threads, row-MT on and off, 320x240 and 806x1854, detector set and skipped -- and was twice
 * documented here as "unsupported by this libaom build". That was WRONG. The cause was rdev's own
 * malformed infinite-GOP setting (kf_max_dist = 0; see the kf_mode block), which corrupted GOP
 * state and left a null function pointer that only the screen-content path happened to avoid. With
 * kf_max_dist = INT32_MAX the whole matrix encodes.
 *
 * THE LESSON, since it cost a day: a crash that appears only under one setting is not evidence that
 * the setting is unsupported. Both "cpu-used <= 6 is unsupported" and "AOM_CONTENT_DEFAULT is
 * unsupported" were the SAME defect wearing two costumes, and the shipped configuration was the one
 * surviving corner of the table -- which made a broken config look like a working one.
 *
 * RDEV_LIBAOM_TUNE_CONTENT selects screen|default|film. It exists to answer an OPEN question: does
 * forcing screen-content tools hurt full-frame motion such as scrolling? Palette and intra block
 * copy are INTRA tools, and rdev's SVT path deliberately chose an ADAPTIVE detector for that reason.
 * An unrecognised value aborts rather than silently encoding in a mode nobody picked.
 */
static int llv_aom_tune_content(void) {
    const char *raw = getenv("RDEV_LIBAOM_TUNE_CONTENT");
    if (raw == NULL || raw[0] == '\0' || strcmp(raw, "screen") == 0) { return AOM_CONTENT_SCREEN; }
    if (strcmp(raw, "default") == 0) { return AOM_CONTENT_DEFAULT; }
    if (strcmp(raw, "film") == 0) { return AOM_CONTENT_FILM; }
    fprintf(stderr, "[encode] RDEV_LIBAOM_TUNE_CONTENT=%s is not screen|default|film\n", raw);
    abort();
}

/* TWO THREADING OVERRIDES, kept as apparatus.
 *
 * They were added to test whether the pattern_search crash was a row-multithreading bug. IT WAS
 * NOT -- single-threaded with row-MT off crashed identically -- and that negative is what redirected
 * the search to the encoder configuration, where the real cause (kf_max_dist = 0) was.
 *
 * They stay because nothing else can vary either value: threads is 12 PER SOURCE with nothing
 * scaling it to the machine or the number of sources, which CLAUDE.md flags as unmeasured on small
 * machines. Two sources on a 4-core Mac ask for 24 encoder threads.
 *
 * All three default to the profile's own values, so an unset environment is byte-identical to what
 * ships. Unrecognised values abort rather than being clamped: this is measurement apparatus, and a
 * typo that quietly encoded under different settings would corrupt the comparison it exists for.
 */
static int llv_aom_env_int(const char *name, int fallback, int low, int high) {
    const char *raw = getenv(name);
    if (raw == NULL || raw[0] == '\0') { return fallback; }
    long value = strtol(raw, NULL, 10);
    if (value < low || value > high) {
        fprintf(stderr, "[encode] %s=%s is out of range %d..%d\n", name, raw, low, high);
        abort();
    }
    return (int)value;
}

static int llv_aom_apply_control(
    llv_aom_encoder *encoder,
    int control,
    int value,
    const char *operation,
    char *error,
    size_t error_capacity
) {
    aom_codec_err_t status = encoder->runtime->control(
        &encoder->codec, control, value
    );
    if (status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder, operation, status, error, error_capacity
        );
    }
    return LLV_AOM_RUNTIME_OK;
}

static int llv_aom_apply_pointer_control(
    llv_aom_encoder *encoder,
    int control,
    void *value,
    const char *operation,
    char *error,
    size_t error_capacity
) {
    aom_codec_err_t status = encoder->runtime->control(
        &encoder->codec, control, value
    );
    if (status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder, operation, status, error, error_capacity
        );
    }
    return LLV_AOM_RUNTIME_OK;
}

static int llv_aom_configure_svc(
    llv_aom_encoder *encoder,
    const aom_codec_enc_cfg_t *codec_configuration,
    char *error,
    size_t error_capacity
) {
    if (encoder->scalability_mode == LLV_AOM_SCALABILITY_L1T1) {
        return LLV_AOM_RUNTIME_OK;
    }
    const int temporal_layers = encoder->scalability_mode;
    aom_svc_params_t parameters;
    memset(&parameters, 0, sizeof(parameters));
    parameters.number_spatial_layers = 1;
    parameters.number_temporal_layers = temporal_layers;
    parameters.scaling_factor_num[0] = 1;
    parameters.scaling_factor_den[0] = 1;
    for (int temporal_id = 0; temporal_id < temporal_layers; temporal_id++) {
        parameters.min_quantizers[temporal_id] = codec_configuration->rc_min_quantizer;
        parameters.max_quantizers[temporal_id] = codec_configuration->rc_max_quantizer;
        parameters.framerate_factor[temporal_id] =
            1 << (temporal_layers - temporal_id - 1);
        parameters.layer_target_bitrate[temporal_id] = (int)
            llv_aom_temporal_layer_bitrate(
                encoder->scalability_mode,
                codec_configuration->rc_target_bitrate,
                (uint32_t)temporal_id
            );
    }
    return llv_aom_apply_pointer_control(
        encoder,
        AV1E_SET_SVC_PARAMS,
        &parameters,
        "AV1E_SET_SVC_PARAMS",
        error,
        error_capacity
    );
}

static void llv_aom_frame_dependency(
    const llv_aom_encoder *encoder,
    int force_keyframe,
    uint8_t *temporal_id,
    uint8_t *template_id
) {
    if (force_keyframe) {
        *temporal_id = 0;
        *template_id = 0;
        return;
    }
    switch (encoder->scalability_mode) {
        case LLV_AOM_SCALABILITY_L1T1:
            *temporal_id = 0;
            *template_id = 1;
            break;
        case LLV_AOM_SCALABILITY_L1T2:
            if (encoder->temporal_phase == 0) {
                *temporal_id = 1;
                *template_id = 2;
            } else {
                *temporal_id = 0;
                *template_id = 1;
            }
            break;
        case LLV_AOM_SCALABILITY_L1T3:
            switch (encoder->temporal_phase) {
                case 0:
                    *temporal_id = 2;
                    *template_id = 3;
                    break;
                case 1:
                    *temporal_id = 1;
                    *template_id = 2;
                    break;
                case 2:
                    *temporal_id = 2;
                    *template_id = 4;
                    break;
                default:
                    *temporal_id = 0;
                    *template_id = 1;
                    break;
            }
            break;
    }
}

static int llv_aom_configure_svc_frame(
    llv_aom_encoder *encoder,
    uint8_t temporal_id,
    uint8_t template_id,
    char *error,
    size_t error_capacity
) {
    if (encoder->scalability_mode == LLV_AOM_SCALABILITY_L1T1) {
        return LLV_AOM_RUNTIME_OK;
    }
    aom_svc_layer_id_t layer_id;
    memset(&layer_id, 0, sizeof(layer_id));
    layer_id.temporal_layer_id = temporal_id;
    int status = llv_aom_apply_pointer_control(
        encoder,
        AV1E_SET_SVC_LAYER_ID,
        &layer_id,
        "AV1E_SET_SVC_LAYER_ID",
        error,
        error_capacity
    );
    if (status != LLV_AOM_RUNTIME_OK) {
        return status;
    }

    aom_svc_ref_frame_config_t references;
    memset(&references, 0, sizeof(references));
    if (template_id == 0) {
        references.ref_idx[0] = 0;
        references.refresh[0] = 1;
    } else if (template_id == 1) {
        references.reference[0] = 1;
        references.ref_idx[0] = 0;
        references.refresh[0] = 1;
    } else if (template_id == 2) {
        references.reference[0] = 1;
        references.ref_idx[0] = 0;
        if (encoder->scalability_mode == LLV_AOM_SCALABILITY_L1T3) {
            references.ref_idx[3] = 1;
            references.refresh[1] = 1;
        }
    } else if (template_id == 3) {
        references.reference[0] = 1;
        references.ref_idx[0] = 0;
    } else {
        references.reference[0] = 1;
        references.ref_idx[0] = 1;
    }
    return llv_aom_apply_pointer_control(
        encoder,
        AV1E_SET_SVC_REF_FRAME_CONFIG,
        &references,
        "AV1E_SET_SVC_REF_FRAME_CONFIG",
        error,
        error_capacity
    );
}

static void llv_aom_advance_temporal_phase(
    llv_aom_encoder *encoder,
    int is_keyframe
) {
    if (is_keyframe) {
        encoder->temporal_phase = 0;
    } else if (encoder->scalability_mode == LLV_AOM_SCALABILITY_L1T2) {
        encoder->temporal_phase = (uint8_t)((encoder->temporal_phase + 1) % 2);
    } else if (encoder->scalability_mode == LLV_AOM_SCALABILITY_L1T3) {
        encoder->temporal_phase = (uint8_t)((encoder->temporal_phase + 1) % 4);
    }
}

int llv_aom_encoder_create(
    const llv_aom_encoder_configuration *configuration,
    llv_aom_encoder **encoder_out,
    char *error,
    size_t error_capacity
) {
    if (configuration == NULL || encoder_out == NULL
        || configuration->width < 72 || configuration->width > 3840
        || configuration->height < 64 || configuration->height > 2160
        || configuration->width % 2 != 0 || configuration->height % 2 != 0
        || configuration->fps == 0 || configuration->bitrate < 1000
        || configuration->threads == 0 || configuration->threads > 64
        || configuration->cpu_used > 12
        || configuration->tile_columns > 6 || configuration->tile_rows > 6
        || configuration->rc_buffer_milliseconds == 0
        || configuration->rc_buffer_milliseconds > 10000
        || configuration->rc_initial_buffer_milliseconds == 0
        || configuration->rc_initial_buffer_milliseconds > configuration->rc_buffer_milliseconds
        || configuration->rc_optimal_buffer_milliseconds == 0
        || configuration->rc_optimal_buffer_milliseconds > configuration->rc_buffer_milliseconds
        || (configuration->auto_tiles != LLV_AOM_USE_DEFAULT
            && configuration->auto_tiles != 0 && configuration->auto_tiles != 1)
        || (configuration->screen_detection_mode != LLV_AOM_USE_DEFAULT
            && configuration->screen_detection_mode != 1
            && configuration->screen_detection_mode != 2)
        || (configuration->aq_mode != LLV_AOM_USE_DEFAULT
            && configuration->aq_mode != 0 && configuration->aq_mode != 3)
        || (configuration->sharpness != LLV_AOM_USE_DEFAULT
            && (configuration->sharpness < 0 || configuration->sharpness > 7))
        || (configuration->adaptive_sharpness != LLV_AOM_USE_DEFAULT
            && configuration->adaptive_sharpness != 0
            && configuration->adaptive_sharpness != 1)
        || (configuration->cdef_mode != LLV_AOM_USE_DEFAULT
            && (configuration->cdef_mode < 0 || configuration->cdef_mode > 3))
        || (configuration->loopfilter_mode != LLV_AOM_USE_DEFAULT
            && (configuration->loopfilter_mode < 0 || configuration->loopfilter_mode > 3))
        || configuration->scalability_mode < LLV_AOM_SCALABILITY_L1T1
        || configuration->scalability_mode > LLV_AOM_SCALABILITY_L1T3) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 encoder configuration");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    *encoder_out = NULL;

    llv_aom_encoder *encoder = calloc(1, sizeof(*encoder));
    if (encoder == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "out of memory creating AV1 encoder");
        return LLV_AOM_RUNTIME_OUT_OF_MEMORY;
    }
    int status = llv_aom_runtime_open(
        &encoder->runtime, error, error_capacity
    );
    if (status != LLV_AOM_RUNTIME_OK) {
        llv_aom_encoder_destroy(encoder);
        return status;
    }

    encoder->width = configuration->width;
    encoder->height = configuration->height;
    encoder->scalability_mode = configuration->scalability_mode;
    size_t chroma_plane_bytes = (size_t)encoder->width * encoder->height / 4;
    if (posix_memalign((void **)&encoder->u, 64, chroma_plane_bytes) != 0
        || posix_memalign((void **)&encoder->v, 64, chroma_plane_bytes) != 0) {
        llv_aom_set_error(error, error_capacity, "%s", "out of memory allocating AV1 chroma planes");
        llv_aom_encoder_destroy(encoder);
        return LLV_AOM_RUNTIME_OUT_OF_MEMORY;
    }

    memset(&encoder->configuration, 0, sizeof(encoder->configuration));
    aom_codec_err_t codec_status = encoder->runtime->config_default(
        encoder->runtime->av1_interface(),
        &encoder->configuration,
        AOM_USAGE_REALTIME
    );
    if (codec_status != AOM_CODEC_OK) {
        status = llv_aom_codec_failure(
            encoder, "aom_codec_enc_config_default", codec_status,
            error, error_capacity
        );
        llv_aom_encoder_destroy(encoder);
        return status;
    }
    encoder->configuration.g_w = configuration->width;
    encoder->configuration.g_h = configuration->height;
    encoder->configuration.g_timebase.num = 1;
    encoder->configuration.g_timebase.den = (int)configuration->fps;
    encoder->configuration.g_threads =
        (unsigned int)llv_aom_env_int("RDEV_LIBAOM_THREADS",
                                     (int)configuration->threads, 1, 64);
    encoder->configuration.g_lag_in_frames = 0;
    encoder->configuration.g_pass = AOM_RC_ONE_PASS;
    encoder->configuration.rc_end_usage = AOM_CBR;
    encoder->configuration.rc_target_bitrate = configuration->bitrate / 1000;
    /* RATE-CONTROL BUFFER, and a knob to widen it.
     *
     * The profile ships 100 ms with optimal/initial at 50, which is tuned for latency: a small
     * buffer forces the encoder to hit its target over a short window, so a burst cannot run ahead
     * and arrive late. The cost is quality under exactly the content that bursts. A scroll dirties
     * every pixel at once, and with 100 ms of slack the rate controller must raise the quantizer
     * immediately rather than borrowing against the next second -- which is visible as a produced
     * bitrate that overshoots and then pays back over several reporting windows.
     *
     * RDEV_LIBAOM_RC_BUFFER_MS scales all three together, preserving the profile's 2:1:1 ratio
     * between total, optimal and initial. Unset keeps the profile's own values exactly.
     *
     * WIDENING IT COSTS LATENCY, which is the whole reason it is small. It is a measurement knob
     * for finding where the quality/latency trade actually sits for screen content, not a setting
     * to raise blindly: the frames that a bigger buffer lets grow are frames that take longer to
     * send. Watch `[latency]` and the client's jitter buffer, not just the picture.
     */
    unsigned int buffer_ms = configuration->rc_buffer_milliseconds;
    unsigned int optimal_ms = configuration->rc_optimal_buffer_milliseconds;
    unsigned int initial_ms = configuration->rc_initial_buffer_milliseconds;
    const char *buffer_override = getenv("RDEV_LIBAOM_RC_BUFFER_MS");
    if (buffer_override != NULL && buffer_override[0] != '\0') {
        long requested = strtol(buffer_override, NULL, 10);
        if (requested < 20 || requested > 5000) {
            fprintf(stderr,
                    "[encode] RDEV_LIBAOM_RC_BUFFER_MS=%s is not 20..5000\n", buffer_override);
            abort();
        }
        buffer_ms = (unsigned int)requested;
        optimal_ms = buffer_ms / 2;
        initial_ms = buffer_ms / 2;
        fprintf(stderr, "[encode] rc buffer %ums (optimal/initial %ums)\n", buffer_ms, optimal_ms);
    }
    encoder->configuration.rc_buf_sz = buffer_ms;
    encoder->configuration.rc_buf_initial_sz = initial_ms;
    encoder->configuration.rc_buf_optimal_sz = optimal_ms;
    encoder->configuration.rc_dropframe_thresh = 0;
    /* INFINITE GOP: keyframes are ON DEMAND ONLY, driven by PLI/FIR from the receiver.
     *
     * kf_max_dist IS INT32_MAX AND MUST NOT BE 0. `AOM_KF_DISABLED` with kf_max_dist = 0 reads like
     * the natural spelling of "never" and it CORRUPTS libaom's GOP state instead. Measured against
     * vanilla libaom v3.14.1 on 2026-08-19, 806x1854, everything else held equal:
     *
     *                              kf_max_dist=0     kf_max_dist=INT32_MAX
     *   screen  + cpu-used 12         OK                    OK
     *   screen  + cpu-used 6          SEGV                  OK
     *   default + cpu-used 12         SEGV                  OK
     *   default + cpu-used 6          SEGV                  OK
     *
     * Either half alone is harmless -- AOM_KF_DISABLED with the default distance is fine, and
     * kf_max_dist = 0 under AOM_KF_AUTO is fine -- so only the PAIR is malformed. The crash is a
     * null dereference in pattern_search reached from both av1_rd_pick_inter_mode and
     * av1_nonrd_pick_inter_mode_sb, which is why it looked like two unrelated libaom bugs: one
     * "cpu-used <= 6 is unsupported", one "AOM_CONTENT_DEFAULT is unsupported". Neither was true.
     * rdev shipped `screen` + cpu-used 12, which is the ONE surviving corner of that table.
     *
     * rdev's own VideoToolbox path always had this right -- infinite GOP there was
     * MaxKeyFrameInterval = Int32.max, never 0. The libaom port deviated.
     */
    encoder->configuration.kf_mode = AOM_KF_DISABLED;
    encoder->configuration.kf_min_dist = 0;
    encoder->configuration.kf_max_dist = 2147483647u;

    codec_status = encoder->runtime->encoder_init(
        &encoder->codec,
        encoder->runtime->av1_interface(),
        &encoder->configuration,
        0,
        AOM_ENCODER_ABI_VERSION
    );
    if (codec_status != AOM_CODEC_OK) {
        status = llv_aom_codec_failure(
            encoder, "aom_codec_enc_init_ver", codec_status,
            error, error_capacity
        );
        llv_aom_encoder_destroy(encoder);
        return status;
    }
    encoder->codec_initialized = 1;

    struct {
        int control;
        int value;
        const char *operation;
    } controls[] = {
        { AOME_SET_CPUUSED, (int)configuration->cpu_used, "AOME_SET_CPUUSED" },
        { AV1E_SET_ROW_MT, llv_aom_env_int("RDEV_LIBAOM_ROW_MT", 1, 0, 1), "AV1E_SET_ROW_MT" },
        { AV1E_SET_TILE_COLUMNS, (int)configuration->tile_columns, "AV1E_SET_TILE_COLUMNS" },
        { AV1E_SET_TILE_ROWS, (int)configuration->tile_rows, "AV1E_SET_TILE_ROWS" },
        { AV1E_SET_TUNE_CONTENT, llv_aom_tune_content(), "AV1E_SET_TUNE_CONTENT" },
    };
    for (size_t index = 0; index < sizeof(controls) / sizeof(controls[0]); index++) {
        status = llv_aom_apply_control(
            encoder,
            controls[index].control,
            controls[index].value,
            controls[index].operation,
            error,
            error_capacity
        );
        if (status != LLV_AOM_RUNTIME_OK) {
            llv_aom_encoder_destroy(encoder);
            return status;
        }
    }
    struct {
        int control;
        int value;
        const char *operation;
    } optional_controls[] = {
        { AV1E_SET_AUTO_TILES, configuration->auto_tiles, "AV1E_SET_AUTO_TILES" },
        { AV1E_SET_SCREEN_CONTENT_DETECTION_MODE, configuration->screen_detection_mode,
          "AV1E_SET_SCREEN_CONTENT_DETECTION_MODE" },
        { AV1E_SET_AQ_MODE, configuration->aq_mode, "AV1E_SET_AQ_MODE" },
        { AOME_SET_SHARPNESS, configuration->sharpness, "AOME_SET_SHARPNESS" },
        { AV1E_SET_ENABLE_ADAPTIVE_SHARPNESS, configuration->adaptive_sharpness,
          "AV1E_SET_ENABLE_ADAPTIVE_SHARPNESS" },
        { AV1E_SET_ENABLE_CDEF, configuration->cdef_mode, "AV1E_SET_ENABLE_CDEF" },
        { AV1E_SET_LOOPFILTER_CONTROL, configuration->loopfilter_mode,
          "AV1E_SET_LOOPFILTER_CONTROL" },
    };
    for (size_t index = 0;
         index < sizeof(optional_controls) / sizeof(optional_controls[0]);
         index++) {
        if (optional_controls[index].value == LLV_AOM_USE_DEFAULT) {
            continue;
        }
        status = llv_aom_apply_control(
            encoder,
            optional_controls[index].control,
            optional_controls[index].value,
            optional_controls[index].operation,
            error,
            error_capacity
        );
        if (status != LLV_AOM_RUNTIME_OK) {
            llv_aom_encoder_destroy(encoder);
            return status;
        }
    }
    status = llv_aom_configure_svc(
        encoder, &encoder->configuration, error, error_capacity
    );
    if (status != LLV_AOM_RUNTIME_OK) {
        llv_aom_encoder_destroy(encoder);
        return status;
    }

    *encoder_out = encoder;
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

int llv_aom_encoder_set_bitrate(
    llv_aom_encoder *encoder,
    uint32_t bitrate,
    char *error,
    size_t error_capacity
) {
    if (encoder == NULL || !encoder->codec_initialized || bitrate < 1000) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 encoder bitrate");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }

    const aom_codec_enc_cfg_t previous = encoder->configuration;
    aom_codec_enc_cfg_t candidate = previous;
    candidate.rc_target_bitrate = bitrate / 1000;
    aom_codec_err_t codec_status = encoder->runtime->config_set(
        &encoder->codec, &candidate
    );
    if (codec_status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder, "aom_codec_enc_config_set", codec_status,
            error, error_capacity
        );
    }

    char svc_error[1024];
    int status = llv_aom_configure_svc(
        encoder, &candidate, svc_error, sizeof(svc_error)
    );
    if (status != LLV_AOM_RUNTIME_OK) {
        (void)encoder->runtime->config_set(&encoder->codec, &previous);
        char rollback_error[1024];
        (void)llv_aom_configure_svc(
            encoder, &previous, rollback_error, sizeof(rollback_error)
        );
        llv_aom_set_error(error, error_capacity, "%s", svc_error);
        return status;
    }

    encoder->configuration = candidate;
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

/* A CICP code point is an 8-bit field in the AV1 sequence header, so anything outside 0..255 is
 * not a value the bitstream can carry. LLV_AOM_USE_DEFAULT means "do not set this at all". */
static int llv_aom_valid_cicp(int32_t value) {
    return value == LLV_AOM_USE_DEFAULT || (value >= 0 && value <= 255);
}

int llv_aom_encoder_set_color_config(
    llv_aom_encoder *encoder,
    int32_t color_primaries,
    int32_t transfer_characteristics,
    int32_t matrix_coefficients,
    int32_t color_range,
    char *error,
    size_t error_capacity
) {
    if (encoder == NULL || !encoder->codec_initialized
        || !llv_aom_valid_cicp(color_primaries)
        || !llv_aom_valid_cicp(transfer_characteristics)
        || !llv_aom_valid_cicp(matrix_coefficients)
        || (color_range != LLV_AOM_USE_DEFAULT
            && color_range != AOM_CR_STUDIO_RANGE
            && color_range != AOM_CR_FULL_RANGE)) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 colour configuration");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    struct {
        int control;
        int32_t value;
        const char *operation;
    } controls[] = {
        { AV1E_SET_COLOR_PRIMARIES, color_primaries, "AV1E_SET_COLOR_PRIMARIES" },
        { AV1E_SET_TRANSFER_CHARACTERISTICS, transfer_characteristics,
          "AV1E_SET_TRANSFER_CHARACTERISTICS" },
        { AV1E_SET_MATRIX_COEFFICIENTS, matrix_coefficients, "AV1E_SET_MATRIX_COEFFICIENTS" },
        { AV1E_SET_COLOR_RANGE, color_range, "AV1E_SET_COLOR_RANGE" },
    };
    for (size_t index = 0; index < sizeof(controls) / sizeof(controls[0]); index++) {
        if (controls[index].value == LLV_AOM_USE_DEFAULT) {
            continue;
        }
        /* STATUS-CHECKED, like every other control here. A refused control encodes perfectly and
         * is indistinguishable from an applied one, so discarding the status would leave an
         * untagged stream that looks exactly like a tagged one from every vantage point except a
         * decode. */
        int status = llv_aom_apply_control(
            encoder,
            controls[index].control,
            (int)controls[index].value,
            controls[index].operation,
            error,
            error_capacity
        );
        if (status != LLV_AOM_RUNTIME_OK) {
            return status;
        }
    }
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

int llv_aom_encoder_set_active_map(
    llv_aom_encoder *encoder,
    const uint8_t *active_map,
    uint32_t rows,
    uint32_t columns,
    char *error,
    size_t error_capacity
) {
    if (encoder == NULL || !encoder->codec_initialized
        || rows != (encoder->height + 15) / 16
        || columns != (encoder->width + 15) / 16) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 active map dimensions");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    if (active_map != NULL) {
        size_t cell_count = (size_t)rows * columns;
        for (size_t index = 0; index < cell_count; index++) {
            if (active_map[index] > 1) {
                llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 active map value");
                return LLV_AOM_ENCODER_INVALID_ARGUMENT;
            }
        }
    }
    aom_active_map_t map = {
        .active_map = (unsigned char *)active_map,
        .rows = rows,
        .cols = columns,
    };
    return llv_aom_apply_pointer_control(
        encoder, AOME_SET_ACTIVEMAP, &map, "AOME_SET_ACTIVEMAP",
        error, error_capacity
    );
}

int llv_aom_encoder_set_reference_plan(
    llv_aom_encoder *encoder, const llv_aom_reference_plan *plan,
    char *error, size_t error_capacity
) {
    if (!encoder || !plan || encoder->scalability_mode != LLV_AOM_SCALABILITY_L1T1
        || plan->enabled_references > 127 || plan->recovery > 1) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid L1T1 reference plan");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    for (int i = 0; i < 7; ++i) {
        if (plan->reference_slots[i] > 7) {
            llv_aom_set_error(error, error_capacity, "%s", "invalid AV1 reference slot");
            return LLV_AOM_ENCODER_INVALID_ARGUMENT;
        }
    }
    encoder->reference_plan = *plan;
    encoder->reference_mode = 1;
    encoder->reference_plan_pending = 1;
    return LLV_AOM_RUNTIME_OK;
}

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
) {
    if (encoder == NULL || luma == NULL || chroma == NULL || packet_out == NULL
        || luma_stride < encoder->width || chroma_stride < encoder->width) {
        llv_aom_set_error(error, error_capacity, "%s", "invalid NV12 frame");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    memset(packet_out, 0, sizeof(*packet_out));
    llv_aom_split_nv12_chroma(
        chroma,
        chroma_stride,
        encoder->u,
        encoder->width / 2,
        encoder->v,
        encoder->width / 2,
        encoder->width,
        encoder->height
    );

    aom_image_t image;
    if (encoder->runtime->image_wrap(
            &image,
            AOM_IMG_FMT_I420,
            encoder->width,
            encoder->height,
            1,
            (unsigned char *)luma
        ) == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "aom_img_wrap failed");
        return LLV_AOM_ENCODER_CODEC_ERROR;
    }
    image.planes[AOM_PLANE_Y] = (unsigned char *)luma;
    image.planes[AOM_PLANE_U] = encoder->u;
    image.planes[AOM_PLANE_V] = encoder->v;
    image.stride[AOM_PLANE_Y] = (int)luma_stride;
    image.stride[AOM_PLANE_U] = (int)(encoder->width / 2);
    image.stride[AOM_PLANE_V] = (int)(encoder->width / 2);

    uint8_t temporal_id = 0;
    uint8_t template_id = 0;
    llv_aom_frame_dependency(
        encoder, force_keyframe, &temporal_id, &template_id
    );
    int control_status = llv_aom_configure_svc_frame(
        encoder, temporal_id, template_id, error, error_capacity
    );
    if (control_status != LLV_AOM_RUNTIME_OK) {
        return control_status;
    }
    aom_enc_frame_flags_t flags = force_keyframe ? AOM_EFLAG_FORCE_KF : 0;
    if (encoder->reference_mode) {
        if (!encoder->reference_plan_pending) {
            llv_aom_set_error(error, error_capacity, "%s", "explicit reference plan required for every frame");
            return LLV_AOM_ENCODER_INVALID_ARGUMENT;
        }
        aom_svc_ref_frame_config_t references;
        memset(&references, 0, sizeof(references));
        const llv_aom_reference_plan *plan = &encoder->reference_plan;
        for (int i = 0; i < 7; ++i) {
            references.ref_idx[i] = plan->reference_slots[i];
            references.reference[i] = (plan->enabled_references >> i) & 1;
        }
        for (int i = 0; i < 8; ++i) references.refresh[i] = (plan->refresh_slot_mask >> i) & 1;
        control_status = llv_aom_apply_pointer_control(encoder, AV1E_SET_SVC_REF_FRAME_CONFIG,
            &references, "AV1E_SET_SVC_REF_FRAME_CONFIG", error, error_capacity);
        if (control_status != LLV_AOM_RUNTIME_OK) return control_status;
        if (plan->recovery && !force_keyframe) {
            flags |= AOM_EFLAG_ERROR_RESILIENT | AOM_EFLAG_SET_PRIMARY_REF_NONE | AOM_EFLAG_NO_REF_FRAME_MVS;
        }
    }
    aom_codec_err_t codec_status = encoder->runtime->encode(
        &encoder->codec, &image, (aom_codec_pts_t)frame_id, 1, flags
    );
    if (codec_status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder, "aom_codec_encode", codec_status, error, error_capacity
        );
    }
    encoder->reference_plan_pending = 0;
    int high_motion_screen_rtc = 0;
    codec_status = encoder->runtime->control(
        &encoder->codec,
        AV1E_GET_HIGH_MOTION_CONTENT_SCREEN_RTC,
        &high_motion_screen_rtc
    );
    if (codec_status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder,
            "AV1E_GET_HIGH_MOTION_CONTENT_SCREEN_RTC",
            codec_status,
            error,
            error_capacity
        );
    }

    aom_codec_iter_t iterator = NULL;
    const aom_codec_cx_pkt_t *codec_packet;
    const aom_codec_cx_pkt_t *frame_packet = NULL;
    size_t frame_packet_count = 0;
    while ((codec_packet = encoder->runtime->output(
                &encoder->codec, &iterator
            )) != NULL) {
        if (codec_packet->kind == AOM_CODEC_CX_FRAME_PKT) {
            frame_packet = codec_packet;
            frame_packet_count++;
        }
    }
    if (frame_packet_count != 1 || frame_packet == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "zero-lag libaom did not emit exactly one frame packet");
        return LLV_AOM_ENCODER_UNEXPECTED_OUTPUT;
    }
    if (frame_packet->data.frame.sz > encoder->output_capacity) {
        uint8_t *resized = realloc(
            encoder->output, frame_packet->data.frame.sz
        );
        if (resized == NULL) {
            llv_aom_set_error(error, error_capacity, "%s", "out of memory copying AV1 output");
            return LLV_AOM_RUNTIME_OUT_OF_MEMORY;
        }
        encoder->output = resized;
        encoder->output_capacity = frame_packet->data.frame.sz;
    }
    memcpy(
        encoder->output,
        frame_packet->data.frame.buf,
        frame_packet->data.frame.sz
    );
    packet_out->data = encoder->output;
    packet_out->size = frame_packet->data.frame.sz;
    packet_out->is_keyframe = (frame_packet->data.frame.flags & AOM_FRAME_IS_KEY) != 0;
    if (packet_out->is_keyframe) {
        temporal_id = 0;
        template_id = 0;
    }
    packet_out->temporal_id = temporal_id;
    packet_out->template_id = template_id;
    packet_out->high_motion_screen_rtc = high_motion_screen_rtc == 1 ? 1 : 0;
    llv_aom_advance_temporal_phase(encoder, packet_out->is_keyframe);
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

int llv_aom_encoder_complete(
    llv_aom_encoder *encoder,
    char *error,
    size_t error_capacity
) {
    if (encoder == NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "AV1 encoder is null");
        return LLV_AOM_ENCODER_INVALID_ARGUMENT;
    }
    aom_codec_err_t codec_status = encoder->runtime->encode(
        &encoder->codec, NULL, 0, 0, 0
    );
    if (codec_status != AOM_CODEC_OK) {
        return llv_aom_codec_failure(
            encoder, "aom_codec_encode(flush)", codec_status,
            error, error_capacity
        );
    }
    aom_codec_iter_t iterator = NULL;
    if (encoder->runtime->output(&encoder->codec, &iterator) != NULL) {
        llv_aom_set_error(error, error_capacity, "%s", "zero-lag libaom emitted delayed output");
        return LLV_AOM_ENCODER_UNEXPECTED_OUTPUT;
    }
    if (error != NULL && error_capacity > 0) {
        error[0] = '\0';
    }
    return LLV_AOM_RUNTIME_OK;
}

void llv_aom_encoder_destroy(llv_aom_encoder *encoder) {
    if (encoder == NULL) {
        return;
    }
    if (encoder->codec_initialized && encoder->runtime != NULL) {
        (void)encoder->runtime->destroy(&encoder->codec);
    }
    free(encoder->output);
    free(encoder->v);
    free(encoder->u);
    llv_aom_runtime_close(encoder->runtime);
    free(encoder);
}

void llv_aom_split_nv12_chroma(
    const uint8_t *source,
    size_t source_stride,
    uint8_t *u,
    size_t u_stride,
    uint8_t *v,
    size_t v_stride,
    size_t width,
    size_t height
) {
    const size_t chroma_width = width / 2;
    const size_t chroma_height = height / 2;
    for (size_t row = 0; row < chroma_height; row++) {
        const uint8_t *source_row = source + row * source_stride;
        uint8_t *u_row = u + row * u_stride;
        uint8_t *v_row = v + row * v_stride;
        size_t column = 0;
#if defined(__aarch64__)
        for (; column + 16 <= chroma_width; column += 16) {
            uint8x16x2_t uv = vld2q_u8(source_row + column * 2);
            vst1q_u8(u_row + column, uv.val[0]);
            vst1q_u8(v_row + column, uv.val[1]);
        }
#endif
        for (; column < chroma_width; column++) {
            u_row[column] = source_row[column * 2];
            v_row[column] = source_row[column * 2 + 1];
        }
    }
}
