#pragma once

#include <winpr/wtypes.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define MACRDP_RDPGFX_H264_MAX_WINDOW 2U

typedef struct
{
	UINT32 frame_id;
	UINT64 reserved_at_ms;
	UINT64 sent_at_ms;
	BOOL active;
	BOOL sent;
} macrdp_rdpgfx_frame_slot;

typedef struct
{
	macrdp_rdpgfx_frame_slot slots[MACRDP_RDPGFX_H264_MAX_WINDOW];
	UINT32 window_size;
	UINT32 stable_ack_count;
	BOOL output_pressure;
	BOOL stall_active;
	UINT64 sent_frames;
	UINT64 acknowledged_frames;
	UINT64 acknowledged_samples;
	UINT64 encoded_bytes;
	UINT64 first_sent_at_ms;
	UINT64 last_ack_latency_ms;
	UINT64 total_ack_latency_ms;
	UINT64 max_ack_latency_ms;
	UINT32 last_client_queue_bytes;
	UINT32 max_client_queue_bytes;
	UINT64 client_queue_reports;
	UINT64 window_promotions;
	UINT64 window_demotions;
	UINT64 ack_stalls;
	UINT64 demotions_ack_latency;
	UINT64 demotions_queue_depth;
	UINT64 demotions_output_blocked;
	UINT64 demotions_queue_pressure;
	UINT64 demotions_ack_stall;
} macrdp_rdpgfx_frame_flow;

typedef struct
{
	UINT32 window_size;
	UINT32 active_frames;
	UINT32 reserved_frames;
	UINT32 outstanding_frames;
	UINT64 sent_frames;
	UINT64 acknowledged_frames;
	UINT64 acknowledged_samples;
	UINT64 last_ack_latency_ms;
	UINT64 average_ack_latency_ms;
	UINT64 max_ack_latency_ms;
	UINT32 last_client_queue_bytes;
	UINT32 max_client_queue_bytes;
	UINT64 client_queue_reports;
	UINT64 oldest_outstanding_ms;
	UINT64 encoded_bytes;
	UINT64 average_frame_bytes;
	UINT64 sent_fps_milli;
	UINT64 effective_bitrate_bps;
	UINT64 window_promotions;
	UINT64 window_demotions;
	UINT64 ack_stalls;
	UINT64 demotions_ack_latency;
	UINT64 demotions_queue_depth;
	UINT64 demotions_output_blocked;
	UINT64 demotions_queue_pressure;
	UINT64 demotions_ack_stall;
} macrdp_rdpgfx_frame_flow_stats;

void macrdp_rdpgfx_frame_flow_init(macrdp_rdpgfx_frame_flow* flow);

BOOL macrdp_rdpgfx_frame_flow_reserve(macrdp_rdpgfx_frame_flow* flow,
	                                  UINT32 frame_id,
	                                  UINT64 now_ms);

void macrdp_rdpgfx_frame_flow_release(macrdp_rdpgfx_frame_flow* flow,
	                                  UINT32 frame_id);

void macrdp_rdpgfx_frame_flow_sent(macrdp_rdpgfx_frame_flow* flow,
	                               UINT32 frame_id,
	                               UINT64 encoded_bytes,
	                               UINT64 now_ms);

void macrdp_rdpgfx_frame_flow_acknowledge(macrdp_rdpgfx_frame_flow* flow,
	                                      UINT32 frame_id,
	                                      UINT32 queue_depth,
	                                      UINT64 now_ms);

void macrdp_rdpgfx_frame_flow_observe_output(macrdp_rdpgfx_frame_flow* flow,
	                                         BOOL output_blocked,
	                                         UINT64 transport_queue_bytes,
	                                         UINT64 transport_queue_limit,
	                                         UINT64 now_ms);

BOOL macrdp_rdpgfx_h264_window_full(const macrdp_rdpgfx_frame_flow* flow,
	                                UINT32 queue_depth);

void macrdp_rdpgfx_frame_flow_get_stats(
	const macrdp_rdpgfx_frame_flow* flow,
	UINT64 now_ms,
	macrdp_rdpgfx_frame_flow_stats* stats);

BOOL macrdp_rdpgfx_frame_id_should_advance(UINT32 current_frame_id,
	                                      UINT32 candidate_frame_id);

#ifdef __cplusplus
}
#endif
