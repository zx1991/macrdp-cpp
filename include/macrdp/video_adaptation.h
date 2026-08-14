#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

typedef enum
{
	MACRDP_VIDEO_ADAPT_NONE = 0,
	MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED = 1U << 0,
	MACRDP_VIDEO_ADAPT_TRANSPORT_QUEUE = 1U << 1,
	MACRDP_VIDEO_ADAPT_CLIENT_QUEUE = 1U << 2,
	MACRDP_VIDEO_ADAPT_ACK_LATENCY = 1U << 3,
	MACRDP_VIDEO_ADAPT_ACK_STALL = 1U << 4,
	MACRDP_VIDEO_ADAPT_RECOVER_BITRATE = 1U << 5,
	MACRDP_VIDEO_ADAPT_RECOVER_FPS = 1U << 6
} macrdp_video_adaptation_reason;

typedef struct
{
	uint64_t now_ms;
	uint64_t acknowledged_samples;
	uint64_t last_ack_latency_ms;
	uint64_t ack_stalls;
	bool output_blocked;
	bool transport_queue_pressure;
	bool client_queue_pressure;
	bool output_suppressed;
} macrdp_video_adaptation_observation;

typedef struct
{
	uint32_t max_bitrate_bps;
	uint32_t min_bitrate_bps;
	uint32_t initial_bitrate_bps;
	uint32_t current_bitrate_bps;
	uint32_t max_fps;
	uint32_t initial_fps;
	uint32_t current_fps;
	uint32_t healthy_bitrate_samples;
	uint32_t healthy_fps_samples;
	uint64_t observed_ack_samples;
	uint64_t observed_ack_stalls;
	uint64_t last_bitrate_change_ms;
	uint64_t last_fps_change_ms;
	uint64_t last_frame_submitted_ms;
	uint64_t pressure_started_ms;
	uint64_t recovery_not_before_ms;
	bool output_pressure_active;
	bool fps_pressure_applied;
	bool stalled_ack_pending;
} macrdp_video_adaptation;

void macrdp_video_adaptation_init(macrdp_video_adaptation* adaptation,
	                              uint32_t max_bitrate_bps,
	                              uint32_t max_fps,
	                              uint64_t now_ms);

uint32_t macrdp_video_adaptation_observe(
	macrdp_video_adaptation* adaptation,
	const macrdp_video_adaptation_observation* observation);

bool macrdp_video_adaptation_frame_ready(
	const macrdp_video_adaptation* adaptation,
	uint64_t now_ms);

uint32_t macrdp_video_adaptation_frame_wait_ms(
	const macrdp_video_adaptation* adaptation,
	uint64_t now_ms);

void macrdp_video_adaptation_frame_submitted(
	macrdp_video_adaptation* adaptation,
	uint64_t now_ms);

const char* macrdp_video_adaptation_reason_name(uint32_t reasons);

#ifdef __cplusplus
}
#endif
