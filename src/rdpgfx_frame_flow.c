#include "macrdp/rdpgfx_frame_flow.h"

#include <freerdp/channels/rdpgfx.h>
#include <string.h>

#define MACRDP_RDPGFX_PROMOTION_ACKS 12U
#define MACRDP_RDPGFX_PROMOTION_ACK_MAX_MS 250U
#define MACRDP_RDPGFX_DEMOTION_ACK_MS 400U
#define MACRDP_RDPGFX_ACK_STALL_MS 750U
#define MACRDP_RDPGFX_QUEUE_PRESSURE_DIVISOR 16U
#define MACRDP_RDPGFX_CLIENT_QUEUE_MIN_BYTES (16U * 1024U)
#define MACRDP_RDPGFX_CLIENT_QUEUE_MAX_BYTES (64U * 1024U)

static BOOL macrdp_rdpgfx_frame_id_acknowledged(UINT32 frame_id, UINT32 acknowledged_frame_id)
{
	return (INT32)(acknowledged_frame_id - frame_id) >= 0;
}

static UINT32 macrdp_rdpgfx_active_frames(const macrdp_rdpgfx_frame_flow* flow)
{
	UINT32 count = 0;
	UINT32 index = 0;

	if (!flow)
		return 0;

	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		if (flow->slots[index].active)
			count++;
	}
	return count;
}

static UINT32 macrdp_rdpgfx_client_queue_threshold(
	const macrdp_rdpgfx_frame_flow* flow)
{
	UINT64 average_frame_bytes = 0;
	UINT64 threshold_bytes = MACRDP_RDPGFX_CLIENT_QUEUE_MIN_BYTES;

	if (flow && flow->sent_frames > 0)
		average_frame_bytes = flow->encoded_bytes / flow->sent_frames;
	if (average_frame_bytes >=
	    MACRDP_RDPGFX_CLIENT_QUEUE_MAX_BYTES / MACRDP_RDPGFX_H264_MAX_WINDOW)
	{
		return MACRDP_RDPGFX_CLIENT_QUEUE_MAX_BYTES;
	}

	threshold_bytes = average_frame_bytes * MACRDP_RDPGFX_H264_MAX_WINDOW;
	if (threshold_bytes < MACRDP_RDPGFX_CLIENT_QUEUE_MIN_BYTES)
		threshold_bytes = MACRDP_RDPGFX_CLIENT_QUEUE_MIN_BYTES;
	return (UINT32)threshold_bytes;
}

static void macrdp_rdpgfx_demote(macrdp_rdpgfx_frame_flow* flow, UINT64* reason)
{
	if (!flow)
		return;
	flow->stable_ack_count = 0;
	if (flow->window_size > 1)
	{
		flow->window_size = 1;
		flow->window_demotions++;
		if (reason)
			(*reason)++;
	}
}

static macrdp_rdpgfx_frame_slot* macrdp_rdpgfx_find_slot(
	macrdp_rdpgfx_frame_flow* flow,
	UINT32 frame_id)
{
	UINT32 index = 0;

	if (!flow)
		return NULL;
	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		macrdp_rdpgfx_frame_slot* slot = &flow->slots[index];
		if (slot->active && slot->frame_id == frame_id)
			return slot;
	}
	return NULL;
}

void macrdp_rdpgfx_frame_flow_init(macrdp_rdpgfx_frame_flow* flow)
{
	if (!flow)
		return;
	memset(flow, 0, sizeof(*flow));
	flow->window_size = 1;
}

BOOL macrdp_rdpgfx_frame_flow_reserve(macrdp_rdpgfx_frame_flow* flow,
                                      UINT32 frame_id,
                                      UINT64 now_ms)
{
	UINT32 index = 0;
	macrdp_rdpgfx_frame_slot* existing = macrdp_rdpgfx_find_slot(flow, frame_id);

	if (!flow)
		return FALSE;
	if (existing)
		return TRUE;
	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		macrdp_rdpgfx_frame_slot* slot = &flow->slots[index];
		if (!slot->active)
		{
			slot->frame_id = frame_id;
			slot->reserved_at_ms = now_ms;
			slot->sent_at_ms = 0;
			slot->active = TRUE;
			slot->sent = FALSE;
			return TRUE;
		}
	}
	return FALSE;
}

void macrdp_rdpgfx_frame_flow_release(macrdp_rdpgfx_frame_flow* flow, UINT32 frame_id)
{
	macrdp_rdpgfx_frame_slot* slot = macrdp_rdpgfx_find_slot(flow, frame_id);

	if (slot)
		memset(slot, 0, sizeof(*slot));
}

void macrdp_rdpgfx_frame_flow_sent(macrdp_rdpgfx_frame_flow* flow,
                                   UINT32 frame_id,
                                   UINT64 encoded_bytes,
                                   UINT64 now_ms)
{
	macrdp_rdpgfx_frame_slot* slot = macrdp_rdpgfx_find_slot(flow, frame_id);

	if (!flow)
		return;
	if (!slot)
	{
		if (!macrdp_rdpgfx_frame_flow_reserve(flow, frame_id, now_ms))
			return;
		slot = macrdp_rdpgfx_find_slot(flow, frame_id);
	}
	if (!slot || slot->sent)
		return;

	slot->sent = TRUE;
	slot->sent_at_ms = now_ms;
	flow->sent_frames++;
	flow->encoded_bytes += encoded_bytes;
	if (flow->first_sent_at_ms == 0)
		flow->first_sent_at_ms = now_ms;
}

void macrdp_rdpgfx_frame_flow_acknowledge(macrdp_rdpgfx_frame_flow* flow,
                                          UINT32 frame_id,
                                          UINT32 queue_depth,
                                          UINT64 now_ms)
{
	UINT32 index = 0;
	UINT32 acknowledged = 0;
	UINT64 sample_sent_at_ms = 0;

	if (!flow)
		return;
	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		macrdp_rdpgfx_frame_slot* slot = &flow->slots[index];
		if (!slot->active || !slot->sent ||
		    !macrdp_rdpgfx_frame_id_acknowledged(slot->frame_id, frame_id))
			continue;
		if (slot->sent_at_ms > sample_sent_at_ms)
			sample_sent_at_ms = slot->sent_at_ms;
		memset(slot, 0, sizeof(*slot));
		acknowledged++;
	}
	if (acknowledged == 0)
		return;

	flow->acknowledged_frames += acknowledged;
	flow->stall_active = FALSE;
	flow->last_client_queue_bytes =
		queue_depth == SUSPEND_FRAME_ACKNOWLEDGEMENT
			? QUEUE_DEPTH_UNAVAILABLE
			: queue_depth;
	if (queue_depth != QUEUE_DEPTH_UNAVAILABLE &&
	    queue_depth != SUSPEND_FRAME_ACKNOWLEDGEMENT)
	{
		if (queue_depth > flow->max_client_queue_bytes)
			flow->max_client_queue_bytes = queue_depth;
		flow->client_queue_reports++;
	}
	if (sample_sent_at_ms > 0 && now_ms >= sample_sent_at_ms)
	{
		const UINT64 latency_ms = now_ms - sample_sent_at_ms;
		flow->acknowledged_samples++;
		flow->last_ack_latency_ms = latency_ms;
		flow->total_ack_latency_ms += latency_ms;
		if (latency_ms > flow->max_ack_latency_ms)
			flow->max_ack_latency_ms = latency_ms;

		if (latency_ms >= MACRDP_RDPGFX_DEMOTION_ACK_MS)
		{
			macrdp_rdpgfx_demote(flow, &flow->demotions_ack_latency);
		}
		else if (queue_depth != QUEUE_DEPTH_UNAVAILABLE &&
		         queue_depth != SUSPEND_FRAME_ACKNOWLEDGEMENT &&
		         queue_depth >= macrdp_rdpgfx_client_queue_threshold(flow))
		{
			macrdp_rdpgfx_demote(flow, &flow->demotions_queue_depth);
		}
		else if (!flow->output_pressure &&
		         latency_ms <= MACRDP_RDPGFX_PROMOTION_ACK_MAX_MS)
		{
			flow->stable_ack_count++;
			if (flow->window_size == 1 &&
			    flow->stable_ack_count >= MACRDP_RDPGFX_PROMOTION_ACKS)
			{
				flow->window_size = MACRDP_RDPGFX_H264_MAX_WINDOW;
				flow->window_promotions++;
				flow->stable_ack_count = 0;
			}
		}
		else
		{
			flow->stable_ack_count = 0;
		}
	}
}

void macrdp_rdpgfx_frame_flow_observe_output(macrdp_rdpgfx_frame_flow* flow,
                                             BOOL output_blocked,
                                             UINT64 transport_queue_bytes,
                                             UINT64 transport_queue_limit,
                                             UINT64 now_ms)
{
	UINT32 index = 0;
	UINT64 oldest_sent_at_ms = 0;
	const UINT64 queue_pressure_threshold =
		transport_queue_limit / MACRDP_RDPGFX_QUEUE_PRESSURE_DIVISOR;
	const BOOL queue_pressure = transport_queue_limit > 0 &&
		queue_pressure_threshold > 0 &&
		transport_queue_bytes >= queue_pressure_threshold;

	if (!flow)
		return;
	flow->output_pressure = output_blocked || queue_pressure;
	if (output_blocked)
		macrdp_rdpgfx_demote(flow, &flow->demotions_output_blocked);
	else if (queue_pressure)
		macrdp_rdpgfx_demote(flow, &flow->demotions_queue_pressure);

	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		const macrdp_rdpgfx_frame_slot* slot = &flow->slots[index];
		if (!slot->active || !slot->sent || slot->sent_at_ms == 0)
			continue;
		if (oldest_sent_at_ms == 0 || slot->sent_at_ms < oldest_sent_at_ms)
			oldest_sent_at_ms = slot->sent_at_ms;
	}
	if (oldest_sent_at_ms == 0 || now_ms < oldest_sent_at_ms)
	{
		flow->stall_active = FALSE;
		return;
	}
	if (now_ms - oldest_sent_at_ms >= MACRDP_RDPGFX_ACK_STALL_MS)
	{
		if (!flow->stall_active)
		{
			flow->ack_stalls++;
			flow->stall_active = TRUE;
		}
		macrdp_rdpgfx_demote(flow, &flow->demotions_ack_stall);
	}
}

BOOL macrdp_rdpgfx_h264_window_full(const macrdp_rdpgfx_frame_flow* flow,
                                    UINT32 queue_depth)
{
	if (queue_depth == SUSPEND_FRAME_ACKNOWLEDGEMENT)
		return FALSE;

	if (!flow || flow->window_size == 0)
		return TRUE;
	return macrdp_rdpgfx_active_frames(flow) >= flow->window_size;
}

void macrdp_rdpgfx_frame_flow_get_stats(const macrdp_rdpgfx_frame_flow* flow,
                                        UINT64 now_ms,
                                        macrdp_rdpgfx_frame_flow_stats* stats)
{
	UINT32 index = 0;
	UINT64 oldest_sent_at_ms = 0;
	UINT64 elapsed_ms = 0;

	if (!stats)
		return;
	memset(stats, 0, sizeof(*stats));
	if (!flow)
		return;

	stats->window_size = flow->window_size;
	stats->sent_frames = flow->sent_frames;
	stats->acknowledged_frames = flow->acknowledged_frames;
	stats->acknowledged_samples = flow->acknowledged_samples;
	stats->last_ack_latency_ms = flow->last_ack_latency_ms;
	stats->max_ack_latency_ms = flow->max_ack_latency_ms;
	stats->last_client_queue_bytes = flow->last_client_queue_bytes;
	stats->max_client_queue_bytes = flow->max_client_queue_bytes;
	stats->client_queue_demotion_threshold_bytes =
		macrdp_rdpgfx_client_queue_threshold(flow);
	stats->client_queue_reports = flow->client_queue_reports;
	stats->window_promotions = flow->window_promotions;
	stats->window_demotions = flow->window_demotions;
	stats->ack_stalls = flow->ack_stalls;
	stats->demotions_ack_latency = flow->demotions_ack_latency;
	stats->demotions_queue_depth = flow->demotions_queue_depth;
	stats->demotions_output_blocked = flow->demotions_output_blocked;
	stats->demotions_queue_pressure = flow->demotions_queue_pressure;
	stats->demotions_ack_stall = flow->demotions_ack_stall;
	stats->encoded_bytes = flow->encoded_bytes;
	if (flow->acknowledged_samples > 0)
		stats->average_ack_latency_ms =
			flow->total_ack_latency_ms / flow->acknowledged_samples;
	if (flow->sent_frames > 0)
		stats->average_frame_bytes = flow->encoded_bytes / flow->sent_frames;

	for (index = 0; index < MACRDP_RDPGFX_H264_MAX_WINDOW; index++)
	{
		const macrdp_rdpgfx_frame_slot* slot = &flow->slots[index];
		if (!slot->active)
			continue;
		stats->active_frames++;
		if (slot->sent)
		{
			stats->outstanding_frames++;
			if (slot->sent_at_ms > 0 &&
			    (oldest_sent_at_ms == 0 || slot->sent_at_ms < oldest_sent_at_ms))
				oldest_sent_at_ms = slot->sent_at_ms;
		}
		else
		{
			stats->reserved_frames++;
		}
	}
	if (oldest_sent_at_ms > 0 && now_ms >= oldest_sent_at_ms)
		stats->oldest_outstanding_ms = now_ms - oldest_sent_at_ms;
	if (flow->first_sent_at_ms > 0 && now_ms > flow->first_sent_at_ms)
		elapsed_ms = now_ms - flow->first_sent_at_ms;
	if (elapsed_ms > 0)
	{
		stats->sent_fps_milli = flow->sent_frames * 1000000U / elapsed_ms;
		stats->effective_bitrate_bps = flow->encoded_bytes * 8000U / elapsed_ms;
	}
}

BOOL macrdp_rdpgfx_frame_id_should_advance(UINT32 current_frame_id,
                                           UINT32 candidate_frame_id)
{
	return current_frame_id == candidate_frame_id ||
	       (INT32)(candidate_frame_id - current_frame_id) > 0;
}
