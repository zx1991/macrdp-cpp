#include "macrdp/video_adaptation.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>

#define MACRDP_VIDEO_MIN_BITRATE_BPS 750000U
#define MACRDP_VIDEO_INITIAL_FPS 5U
#define MACRDP_VIDEO_HEALTHY_ACK_MS 1250U
#define MACRDP_VIDEO_SLOW_ACK_MS 2000U
#define MACRDP_VIDEO_SEVERE_ACK_MS 4000U
#define MACRDP_VIDEO_FAST_RECOVERY_SAMPLES 4U
#define MACRDP_VIDEO_FAST_RECOVERY_MS 1000U
#define MACRDP_VIDEO_STEADY_RECOVERY_SAMPLES 8U
#define MACRDP_VIDEO_STEADY_RECOVERY_MS 3000U
#define MACRDP_VIDEO_OUTPUT_RECOVERY_QUIET_MS 2000U
#define MACRDP_VIDEO_QUEUE_RECOVERY_QUIET_MS 5000U
#define MACRDP_VIDEO_REDUCTION_COOLDOWN_MS 1500U
#define MACRDP_VIDEO_FPS_PRESSURE_MS 750U
#define MACRDP_VIDEO_PERSISTENT_PRESSURE_MS 2000U
#define MACRDP_VIDEO_ENCODER_WINDOW_MS 1000U
#define MACRDP_VIDEO_ENCODER_MIN_SAMPLES 10U
#define MACRDP_VIDEO_ENCODER_SKIP_PERCENT 10U
#define MACRDP_VIDEO_ENCODER_RECOVERY_QUIET_MS 5000U

static uint32_t macrdp_video_max_u32(uint32_t left, uint32_t right)
{
	return left > right ? left : right;
}

static uint32_t macrdp_video_min_u32(uint32_t left, uint32_t right)
{
	return left < right ? left : right;
}

static uint32_t macrdp_video_scale_bitrate(const macrdp_video_adaptation* adaptation,
	                                       uint32_t numerator,
	                                       uint32_t denominator)
{
	uint64_t scaled = 0;

	if (!adaptation || denominator == 0)
		return 0;
	scaled = (uint64_t)adaptation->current_bitrate_bps * numerator / denominator;
	if (scaled < adaptation->min_bitrate_bps)
		scaled = adaptation->min_bitrate_bps;
	if (scaled > adaptation->max_bitrate_bps)
		scaled = adaptation->max_bitrate_bps;
	return (uint32_t)scaled;
}

static bool macrdp_video_elapsed(uint64_t now_ms, uint64_t then_ms, uint64_t interval_ms)
{
	return now_ms >= then_ms && now_ms - then_ms >= interval_ms;
}

static uint64_t macrdp_video_deadline(uint64_t now_ms, uint64_t interval_ms)
{
	if (UINT64_MAX - now_ms < interval_ms)
		return UINT64_MAX;
	return now_ms + interval_ms;
}

static bool macrdp_video_reduce_bitrate(macrdp_video_adaptation* adaptation,
	                                    uint32_t numerator,
	                                    uint32_t denominator,
	                                    uint64_t now_ms)
{
	const uint32_t next = macrdp_video_scale_bitrate(adaptation, numerator, denominator);

	if (!macrdp_video_elapsed(now_ms, adaptation->last_bitrate_change_ms,
	                         MACRDP_VIDEO_REDUCTION_COOLDOWN_MS))
		return false;
	if (next >= adaptation->current_bitrate_bps)
		return false;
	adaptation->current_bitrate_bps = next;
	adaptation->last_bitrate_change_ms = now_ms;
	return true;
}

static bool macrdp_video_reduce_fps(macrdp_video_adaptation* adaptation,
	                                uint32_t numerator,
	                                uint32_t denominator,
	                                uint64_t now_ms)
{
	uint32_t next = 1;

	if (!adaptation || denominator == 0)
		return false;
	if (!macrdp_video_elapsed(now_ms, adaptation->last_fps_change_ms,
	                         MACRDP_VIDEO_REDUCTION_COOLDOWN_MS))
		return false;
	next = adaptation->current_fps * numerator / denominator;
	if (next < 1)
		next = 1;
	if (next >= adaptation->current_fps)
		return false;
	adaptation->current_fps = next;
	adaptation->last_fps_change_ms = now_ms;
	return true;
}

static bool macrdp_video_reduce_fps_step(macrdp_video_adaptation* adaptation,
	                                     uint64_t now_ms)
{
	if (!adaptation || adaptation->current_fps <= 1)
		return false;
	if (!macrdp_video_elapsed(now_ms, adaptation->last_fps_change_ms,
	                         MACRDP_VIDEO_REDUCTION_COOLDOWN_MS))
		return false;
	adaptation->current_fps--;
	adaptation->last_fps_change_ms = now_ms;
	return true;
}

static void macrdp_video_reset_health(macrdp_video_adaptation* adaptation)
{
	adaptation->healthy_bitrate_samples = 0;
	adaptation->healthy_fps_samples = 0;
}

void macrdp_video_adaptation_init(macrdp_video_adaptation* adaptation,
	                              uint32_t max_bitrate_bps,
	                              uint32_t max_fps,
	                              uint64_t now_ms)
{
	uint32_t initial_bitrate = 0;

	if (!adaptation)
		return;
	memset(adaptation, 0, sizeof(*adaptation));
	adaptation->max_bitrate_bps = max_bitrate_bps > 0 ? max_bitrate_bps : 1;
	adaptation->min_bitrate_bps = macrdp_video_min_u32(
		adaptation->max_bitrate_bps, MACRDP_VIDEO_MIN_BITRATE_BPS);
	initial_bitrate = adaptation->max_bitrate_bps / 8U;
	adaptation->current_bitrate_bps = macrdp_video_min_u32(
		adaptation->max_bitrate_bps,
		macrdp_video_max_u32(adaptation->min_bitrate_bps, initial_bitrate));
	adaptation->initial_bitrate_bps = adaptation->current_bitrate_bps;
	adaptation->max_fps = max_fps > 0 ? max_fps : 1;
	adaptation->current_fps = macrdp_video_min_u32(
		adaptation->max_fps, MACRDP_VIDEO_INITIAL_FPS);
	adaptation->initial_fps = adaptation->current_fps;
	adaptation->last_bitrate_change_ms = now_ms;
	adaptation->last_fps_change_ms = now_ms;
}

uint32_t macrdp_video_adaptation_observe(
	macrdp_video_adaptation* adaptation,
	const macrdp_video_adaptation_observation* observation)
{
	uint32_t reasons = MACRDP_VIDEO_ADAPT_NONE;
	const bool new_ack = adaptation && observation &&
		observation->acknowledged_samples > adaptation->observed_ack_samples;
	const bool new_stall = adaptation && observation &&
		observation->ack_stalls > adaptation->observed_ack_stalls;
	const bool ack_after_stall = new_ack && adaptation->stalled_ack_pending;
	bool pressure = false;
	bool pressure_started = false;
	bool fps_pressure = false;
	bool persistent_pressure = false;
	bool encoder_pressure = false;

	if (!adaptation || !observation)
		return MACRDP_VIDEO_ADAPT_NONE;

	adaptation->observed_ack_samples = observation->acknowledged_samples;
	adaptation->observed_ack_stalls = observation->ack_stalls;
	if (observation->encoder_completed_frames <
	        adaptation->observed_encoder_completed_frames ||
	    observation->encoder_no_output_frames <
	        adaptation->observed_encoder_no_output_frames)
	{
		adaptation->encoder_window_completed_frames = 0;
		adaptation->encoder_window_no_output_frames = 0;
		adaptation->encoder_window_started_ms = 0;
		adaptation->observed_encoder_completed_frames = 0;
		adaptation->observed_encoder_no_output_frames = 0;
	}
	if (observation->encoder_completed_frames >
	    adaptation->observed_encoder_completed_frames)
	{
		adaptation->encoder_window_completed_frames +=
			observation->encoder_completed_frames -
			adaptation->observed_encoder_completed_frames;
		adaptation->encoder_window_no_output_frames +=
			observation->encoder_no_output_frames -
			adaptation->observed_encoder_no_output_frames;
		if (adaptation->encoder_window_started_ms == 0)
			adaptation->encoder_window_started_ms = observation->now_ms;
	}
	adaptation->observed_encoder_completed_frames = observation->encoder_completed_frames;
	adaptation->observed_encoder_no_output_frames = observation->encoder_no_output_frames;
	if (adaptation->encoder_window_started_ms != 0 &&
	    macrdp_video_elapsed(observation->now_ms,
	                         adaptation->encoder_window_started_ms,
	                         MACRDP_VIDEO_ENCODER_WINDOW_MS))
	{
		const uint64_t completed = adaptation->encoder_window_completed_frames;
		const uint64_t skip_threshold =
			(completed / 100U) * MACRDP_VIDEO_ENCODER_SKIP_PERCENT +
			((completed % 100U) * MACRDP_VIDEO_ENCODER_SKIP_PERCENT + 99U) /
				100U;
		encoder_pressure =
			completed >= MACRDP_VIDEO_ENCODER_MIN_SAMPLES &&
			adaptation->encoder_window_no_output_frames >= skip_threshold;
		adaptation->encoder_window_completed_frames = 0;
		adaptation->encoder_window_no_output_frames = 0;
		adaptation->encoder_window_started_ms = 0;
	}
	if (observation->output_suppressed)
	{
		macrdp_video_reset_health(adaptation);
		adaptation->output_pressure_active = false;
		adaptation->pressure_started_ms = 0;
		adaptation->fps_pressure_applied = false;
		adaptation->stalled_ack_pending = false;
		adaptation->encoder_window_completed_frames = 0;
		adaptation->encoder_window_no_output_frames = 0;
		adaptation->encoder_window_started_ms = 0;
		return MACRDP_VIDEO_ADAPT_NONE;
	}
	if (encoder_pressure)
	{
		const uint64_t quiet_deadline = macrdp_video_deadline(
			observation->now_ms, MACRDP_VIDEO_ENCODER_RECOVERY_QUIET_MS);
		macrdp_video_reset_health(adaptation);
		if (quiet_deadline > adaptation->recovery_not_before_ms)
			adaptation->recovery_not_before_ms = quiet_deadline;
	}
	if (ack_after_stall)
		adaptation->stalled_ack_pending = false;
	if (new_stall)
		adaptation->stalled_ack_pending = true;

	pressure = observation->output_blocked || observation->transport_queue_pressure ||
	           observation->client_queue_pressure;
	if (pressure)
	{
		const uint64_t quiet_deadline = macrdp_video_deadline(
			observation->now_ms,
			observation->transport_queue_pressure || observation->client_queue_pressure
				? MACRDP_VIDEO_QUEUE_RECOVERY_QUIET_MS
				: MACRDP_VIDEO_OUTPUT_RECOVERY_QUIET_MS);
		macrdp_video_reset_health(adaptation);
		if (quiet_deadline > adaptation->recovery_not_before_ms)
			adaptation->recovery_not_before_ms = quiet_deadline;
	}
	pressure_started = pressure && !adaptation->output_pressure_active;
	fps_pressure = pressure && adaptation->output_pressure_active &&
		macrdp_video_elapsed(observation->now_ms,
		                    adaptation->pressure_started_ms,
		                    MACRDP_VIDEO_FPS_PRESSURE_MS);
	persistent_pressure = pressure && adaptation->output_pressure_active &&
		macrdp_video_elapsed(observation->now_ms,
		                    adaptation->pressure_started_ms,
		                    MACRDP_VIDEO_PERSISTENT_PRESSURE_MS);
	if (pressure_started)
		adaptation->pressure_started_ms = observation->now_ms;
	adaptation->output_pressure_active = pressure;
	if (!pressure)
	{
		adaptation->pressure_started_ms = 0;
		adaptation->fps_pressure_applied = false;
	}

	if (new_stall)
	{
		const bool bitrate_changed =
			macrdp_video_reduce_bitrate(adaptation, 2, 3, observation->now_ms);
		const bool fps_changed =
			macrdp_video_reduce_fps(adaptation, 1, 2, observation->now_ms);
		if (bitrate_changed || fps_changed)
			reasons |= MACRDP_VIDEO_ADAPT_ACK_STALL;
	}
	else if (new_ack && !ack_after_stall &&
	         observation->last_ack_latency_ms >= MACRDP_VIDEO_SEVERE_ACK_MS)
	{
		const bool bitrate_changed =
			macrdp_video_reduce_bitrate(adaptation, 3, 4, observation->now_ms);
		const bool fps_changed =
			macrdp_video_reduce_fps(adaptation, 1, 2, observation->now_ms);
		if (bitrate_changed || fps_changed)
			reasons |= MACRDP_VIDEO_ADAPT_ACK_LATENCY;
	}
	else if (encoder_pressure &&
	         macrdp_video_reduce_fps(adaptation, 3, 4, observation->now_ms))
	{
		reasons |= MACRDP_VIDEO_ADAPT_ENCODER_NO_OUTPUT;
	}
	else
	{
		if (fps_pressure && !adaptation->fps_pressure_applied &&
		    macrdp_video_reduce_fps_step(adaptation, observation->now_ms))
		{
			if (observation->output_blocked)
				reasons |= MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED;
			if (observation->transport_queue_pressure)
				reasons |= MACRDP_VIDEO_ADAPT_TRANSPORT_QUEUE;
			if (observation->client_queue_pressure)
				reasons |= MACRDP_VIDEO_ADAPT_CLIENT_QUEUE;
			adaptation->fps_pressure_applied = true;
		}
		if (persistent_pressure &&
		    macrdp_video_reduce_bitrate(adaptation, 2, 3, observation->now_ms))
		{
			if (observation->output_blocked)
				reasons |= MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED;
			if (observation->transport_queue_pressure)
				reasons |= MACRDP_VIDEO_ADAPT_TRANSPORT_QUEUE;
			if (observation->client_queue_pressure)
				reasons |= MACRDP_VIDEO_ADAPT_CLIENT_QUEUE;
			adaptation->pressure_started_ms = observation->now_ms;
		}
		if (new_ack && !ack_after_stall &&
		    observation->last_ack_latency_ms >= MACRDP_VIDEO_SLOW_ACK_MS &&
		    macrdp_video_reduce_fps(adaptation, 3, 4, observation->now_ms))
		{
			reasons |= MACRDP_VIDEO_ADAPT_ACK_LATENCY;
		}
	}

	if (reasons != MACRDP_VIDEO_ADAPT_NONE)
	{
		macrdp_video_reset_health(adaptation);
		return reasons;
	}

	if (new_ack && !ack_after_stall && !pressure &&
	    observation->last_ack_latency_ms <= MACRDP_VIDEO_HEALTHY_ACK_MS)
	{
		const bool fast_bitrate_recovery =
			adaptation->current_bitrate_bps <= adaptation->initial_bitrate_bps;
		const bool fast_fps_recovery =
			adaptation->current_fps <= adaptation->initial_fps;
		const uint32_t bitrate_samples = fast_bitrate_recovery
			? MACRDP_VIDEO_FAST_RECOVERY_SAMPLES
			: MACRDP_VIDEO_STEADY_RECOVERY_SAMPLES;
		const uint32_t fps_samples = fast_fps_recovery
			? MACRDP_VIDEO_FAST_RECOVERY_SAMPLES
			: MACRDP_VIDEO_STEADY_RECOVERY_SAMPLES;
		const uint64_t bitrate_interval_ms = fast_bitrate_recovery
			? MACRDP_VIDEO_FAST_RECOVERY_MS
			: MACRDP_VIDEO_STEADY_RECOVERY_MS;
		const uint64_t fps_interval_ms = fast_fps_recovery
			? MACRDP_VIDEO_FAST_RECOVERY_MS
			: MACRDP_VIDEO_STEADY_RECOVERY_MS;

		adaptation->healthy_bitrate_samples++;
		adaptation->healthy_fps_samples++;
		if (adaptation->current_bitrate_bps < adaptation->max_bitrate_bps &&
		    observation->now_ms >= adaptation->recovery_not_before_ms &&
		    adaptation->healthy_bitrate_samples >= bitrate_samples &&
		    macrdp_video_elapsed(observation->now_ms,
		                        adaptation->last_bitrate_change_ms,
		                        bitrate_interval_ms))
		{
			const uint32_t increment = fast_bitrate_recovery
				? macrdp_video_max_u32(500000U, adaptation->current_bitrate_bps / 2U)
				: 500000U;
			const uint64_t next =
				(uint64_t)adaptation->current_bitrate_bps + increment;
			adaptation->current_bitrate_bps = (uint32_t)(
				next > adaptation->max_bitrate_bps ? adaptation->max_bitrate_bps : next);
			adaptation->healthy_bitrate_samples = 0;
			adaptation->last_bitrate_change_ms = observation->now_ms;
			reasons |= MACRDP_VIDEO_ADAPT_RECOVER_BITRATE;
		}
		if (adaptation->current_fps < adaptation->max_fps &&
		    observation->now_ms >= adaptation->recovery_not_before_ms &&
		    adaptation->healthy_fps_samples >= fps_samples &&
		    macrdp_video_elapsed(observation->now_ms,
		                        adaptation->last_fps_change_ms,
		                        fps_interval_ms))
		{
			const uint32_t increment = fast_fps_recovery
				? macrdp_video_max_u32(1U, adaptation->current_fps / 2U)
				: 1U;
			adaptation->current_fps = macrdp_video_min_u32(
				adaptation->max_fps, adaptation->current_fps + increment);
			adaptation->healthy_fps_samples = 0;
			adaptation->last_fps_change_ms = observation->now_ms;
			reasons |= MACRDP_VIDEO_ADAPT_RECOVER_FPS;
		}
	}
	else if (new_ack && !ack_after_stall)
	{
		macrdp_video_reset_health(adaptation);
	}
	return reasons;
}

bool macrdp_video_adaptation_frame_ready(
	const macrdp_video_adaptation* adaptation,
	uint64_t now_ms)
{
	if (!adaptation || adaptation->current_fps == 0 ||
	    adaptation->last_frame_submitted_ms == 0)
		return true;
	return macrdp_video_adaptation_frame_wait_ms(adaptation, now_ms) == 0;
}

uint32_t macrdp_video_adaptation_frame_wait_ms(
	const macrdp_video_adaptation* adaptation,
	uint64_t now_ms)
{
	uint64_t interval_ms = 0;
	uint64_t elapsed_ms = 0;
	uint64_t remaining_ms = 0;

	if (!adaptation || adaptation->current_fps == 0 ||
	    adaptation->last_frame_submitted_ms == 0)
		return 0;
	interval_ms = (1000U + adaptation->current_fps - 1U) / adaptation->current_fps;
	if (now_ms < adaptation->last_frame_submitted_ms)
		return interval_ms > UINT32_MAX ? UINT32_MAX : (uint32_t)interval_ms;
	elapsed_ms = now_ms - adaptation->last_frame_submitted_ms;
	if (elapsed_ms >= interval_ms)
		return 0;
	remaining_ms = interval_ms - elapsed_ms;
	return remaining_ms > UINT32_MAX ? UINT32_MAX : (uint32_t)remaining_ms;
}

void macrdp_video_adaptation_frame_submitted(
	macrdp_video_adaptation* adaptation,
	uint64_t now_ms)
{
	if (adaptation)
		adaptation->last_frame_submitted_ms = now_ms;
}

const char* macrdp_video_adaptation_reason_name(uint32_t reasons)
{
	if (reasons & MACRDP_VIDEO_ADAPT_ACK_STALL)
		return "ack-stall";
	if (reasons & MACRDP_VIDEO_ADAPT_ENCODER_NO_OUTPUT)
		return "encoder-no-output";
	if (reasons & MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED)
		return "output-blocked";
	if (reasons & MACRDP_VIDEO_ADAPT_TRANSPORT_QUEUE)
		return "transport-queue";
	if (reasons & MACRDP_VIDEO_ADAPT_CLIENT_QUEUE)
		return "client-queue";
	if (reasons & MACRDP_VIDEO_ADAPT_ACK_LATENCY)
		return "ack-latency";
	if ((reasons & (MACRDP_VIDEO_ADAPT_RECOVER_BITRATE |
	                MACRDP_VIDEO_ADAPT_RECOVER_FPS)) != 0)
		return "healthy-recovery";
	return "none";
}
