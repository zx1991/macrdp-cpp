#pragma once

#include <stddef.h>

#include <freerdp/channels/rdpgfx.h>
#include <freerdp/server/shadow.h>

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct macrdp_h264_worker macrdp_h264_worker;

typedef struct
{
	UINT32 codecId;
	UINT32 width;
	UINT32 height;
	BOOL hasData;
	BOOL failed;
	RDPGFX_AVC420_BITMAP_STREAM avc420;
	RDPGFX_AVC444_BITMAP_STREAM avc444;
} macrdp_h264_encoded_frame;

typedef struct
{
	UINT64 submitted;
	UINT64 completed;
	UINT64 encodeTimeMsTotal;
	UINT64 encodeTimeMsMax;
	UINT64 lastEncodeTimeMs;
	UINT64 outputBytes;
	UINT64 noOutputFrames;
} macrdp_h264_worker_stats;

macrdp_h264_worker* macrdp_h264_worker_new(rdpShadowEncoder* encoder);
void macrdp_h264_worker_free(macrdp_h264_worker* worker);

HANDLE macrdp_h264_worker_event(const macrdp_h264_worker* worker);
BOOL macrdp_h264_worker_busy(const macrdp_h264_worker* worker);
BOOL macrdp_h264_worker_has_completion(const macrdp_h264_worker* worker);
void macrdp_h264_worker_get_stats(
	const macrdp_h264_worker* worker,
	macrdp_h264_worker_stats* stats);

/* Apply these per-client targets immediately before the next encode. */
BOOL macrdp_h264_worker_set_targets(
	macrdp_h264_worker* worker,
	UINT32 bitrate_bps,
	UINT32 frame_rate);

/* Return 1 when accepted, 0 when a previous frame is still in flight, and
 * -1 for invalid input or an internal worker failure. */
int macrdp_h264_worker_submit(
	macrdp_h264_worker* worker,
	const BYTE* frame,
	size_t frame_size,
	UINT32 stride,
	UINT32 width,
	UINT32 height,
	UINT32 format,
	UINT32 codec_id,
	const RECTANGLE_16* region);

/* Wait until the current job has completed. The completion, if any, remains
 * available to macrdp_h264_worker_take. */
BOOL macrdp_h264_worker_wait_idle(macrdp_h264_worker* worker);

/* Return 1 with a result, 0 when the completion had no packet, and -1 on
 * failure. The caller owns the returned frame until it is freed. */
int macrdp_h264_worker_take(
	macrdp_h264_worker* worker,
	macrdp_h264_encoded_frame* frame);
void macrdp_h264_encoded_frame_free(macrdp_h264_encoded_frame* frame);

#ifdef __cplusplus
}
#endif
