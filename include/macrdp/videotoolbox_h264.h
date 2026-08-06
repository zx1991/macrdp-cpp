#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct macrdp_vt_h264_encoder macrdp_vt_h264_encoder;

void macrdp_vt_h264_encoder_set_enabled(int enabled);

macrdp_vt_h264_encoder* macrdp_vt_h264_encoder_new(
    uint32_t width,
    uint32_t height,
    uint32_t bitrate,
    uint32_t frame_rate,
    uint32_t key_frame_interval);

void macrdp_vt_h264_encoder_free(macrdp_vt_h264_encoder* encoder);

/*
 * Encode one I420 frame. The returned packet is owned by the encoder and is
 * valid until the next call or until the encoder is freed.
 *
 * Returns 1 when a packet is available, 0 when VideoToolbox has no completed
 * packet yet, and a negative value on error.
 */
int macrdp_vt_h264_encoder_encode(
    macrdp_vt_h264_encoder* encoder,
    const uint8_t* y_plane,
    const uint8_t* u_plane,
    const uint8_t* v_plane,
    const uint32_t strides[3],
    uint64_t frame_index,
    uint8_t** output,
    uint32_t* output_size);

const char* macrdp_vt_h264_encoder_last_error(
    const macrdp_vt_h264_encoder* encoder);

#ifdef __cplusplus
}
#endif
