#include <freerdp/config.h>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/constants.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/log.h>
#include <freerdp/settings.h>
#include <freerdp/streamdump.h>

#include <winpr/assert.h>
#include <winpr/synch.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG CLIENT_TAG("macrdp-loopback")

typedef struct
{
	rdpClientContext common;
	uint64_t start_us;
	uint64_t connected_us;
	uint64_t duration_us;
	uint64_t next_input_us;
	uint64_t input_sequence;
	uint64_t frame_count;
	uint64_t first_frame_us;
	uint64_t last_frame_us;
	uint64_t frame_interval_total_us;
	uint64_t frame_interval_max_us;
	uint64_t invalid_rect_total;
	uint64_t gfx_frame_count;
	uint64_t gfx_wire_command_count;
	uint64_t gfx_codec_counts[RDPGFX_CODECID_MAX];
	uint64_t gfx_avc420_count;
	uint64_t gfx_avc444_count;
	uint64_t input_clicks_sent;
	uint64_t input_send_failures;
	uint64_t gfx_first_frame_us;
	uint64_t gfx_last_frame_us;
	uint64_t gfx_frame_interval_total_us;
	uint64_t gfx_frame_interval_max_us;
	RdpgfxClientContext* gfx;
	uint32_t last_width;
	uint32_t last_height;
} loopback_context;

static uint64_t monotonic_us(void)
{
	struct timespec ts = { 0 };

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		return 0;
	return (uint64_t)ts.tv_sec * UINT64_C(1000000) + (uint64_t)ts.tv_nsec / UINT64_C(1000);
}

static uint64_t env_duration_us(void)
{
	const char* value = getenv("MACRDP_LOOPBACK_DURATION_MS");
	char* end = NULL;
	unsigned long long milliseconds = 0;

	if (!value || !*value)
		return UINT64_C(15000000);

	milliseconds = strtoull(value, &end, 10);
	if (end == value || *end != '\0' || milliseconds == 0
	    || milliseconds > UINT64_MAX / UINT64_C(1000))
		return UINT64_C(15000000);
	return (uint64_t)milliseconds * UINT64_C(1000);
}

static BOOL env_gfx_enabled(void)
{
	const char* value = getenv("MACRDP_LOOPBACK_GFX");
	return !(value && (*value == '0' || *value == 'n' || *value == 'N'));
}

static BOOL loopback_begin_paint(rdpContext* context)
{
	rdpGdi* gdi = NULL;

	WINPR_ASSERT(context);
	gdi = context->gdi;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd
	    || !gdi->primary->hdc->hwnd->invalid)
		return FALSE;

	gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static uint64_t loopback_gfx_stat(const loopback_context* loop, size_t index)
{
	return loop->gfx ? rdpgfx_stats_value_for_index(loop->gfx, index) : 0;
}

static void loopback_update_gfx_codec_counts(loopback_context* loop)
{
	if (!loop->gfx)
		return;

	for (size_t index = 0; index < RDPGFX_CODECID_MAX; index++)
		loop->gfx_codec_counts[index] = loopback_gfx_stat(loop, index);

	loop->gfx_avc420_count = loop->gfx_codec_counts[RDPGFX_CODECID_AVC420];
	loop->gfx_avc444_count = loop->gfx_codec_counts[RDPGFX_CODECID_AVC444]
	    + loop->gfx_codec_counts[RDPGFX_CODECID_AVC444v2];
}

static void loopback_sample_gfx(loopback_context* loop, uint64_t now)
{
	const size_t command_offset = RDPGFX_CODECID_MAX;
	const uint64_t frame_count = loopback_gfx_stat(
	    loop, command_offset + RDPGFX_CMDID_ENDFRAME);

	if (frame_count <= loop->gfx_frame_count)
		return;

	if (loop->gfx_frame_count == 0)
		loop->gfx_first_frame_us = now;
	else if (now >= loop->gfx_last_frame_us)
	{
		const uint64_t interval = now - loop->gfx_last_frame_us;
		loop->gfx_frame_interval_total_us += interval;
		if (interval > loop->gfx_frame_interval_max_us)
			loop->gfx_frame_interval_max_us = interval;
	}

	loop->gfx_frame_count = frame_count;
	loop->gfx_last_frame_us = now;
	loop->gfx_wire_command_count = loopback_gfx_stat(
		loop, command_offset + RDPGFX_CMDID_WIRETOSURFACE_1)
	    + loopback_gfx_stat(loop, command_offset + RDPGFX_CMDID_WIRETOSURFACE_2);
	loopback_update_gfx_codec_counts(loop);
}

static void loopback_on_channel_connected(
    void* context,
    const ChannelConnectedEventArgs* event)
{
	loopback_context* loop = (loopback_context*)context;

	if (!loop || !event || !event->name)
		return;

	if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
		loop->gfx = (RdpgfxClientContext*)event->pInterface;

	freerdp_client_OnChannelConnectedEventHandler(&loop->common, event);
}

static void loopback_on_channel_disconnected(
    void* context,
    const ChannelDisconnectedEventArgs* event)
{
	loopback_context* loop = (loopback_context*)context;

	if (!loop || !event || !event->name)
		return;

	freerdp_client_OnChannelDisconnectedEventHandler(&loop->common, event);
	if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
		loop->gfx = NULL;
}

static BOOL loopback_end_paint(rdpContext* context)
{
	loopback_context* loop = (loopback_context*)context;
	rdpGdi* gdi = context->gdi;
	HGDI_WND window = NULL;
	const uint64_t now = monotonic_us();
	uint64_t interval = 0;

	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
		return TRUE;

	window = gdi->primary->hdc->hwnd;
	if (!window->invalid || window->invalid->null)
		return TRUE;

	if (loop->frame_count == 0)
		loop->first_frame_us = now;
	else if (now >= loop->last_frame_us)
	{
		interval = now - loop->last_frame_us;
		loop->frame_interval_total_us += interval;
		if (interval > loop->frame_interval_max_us)
			loop->frame_interval_max_us = interval;
	}

	loop->last_frame_us = now;
	loop->frame_count++;
	loop->invalid_rect_total += window->ninvalid;
	loop->last_width = (uint32_t)gdi->width;
	loop->last_height = (uint32_t)gdi->height;

	if (loop->frame_count == 1 || loop->frame_count % 30 == 0)
	{
		WLog_INFO(TAG,
		          "decoded frame=%" PRIu64 " invalid_rects=%" PRIu32 " size=%" PRIu32 "x%" PRIu32,
		          loop->frame_count,
		          window->ninvalid,
		          loop->last_width,
		          loop->last_height);
	}
	return TRUE;
}

static BOOL loopback_desktop_resize(rdpContext* context)
{
	rdpSettings* settings = NULL;
	rdpGdi* gdi = NULL;

	WINPR_ASSERT(context);
	settings = context->settings;
	gdi = context->gdi;
	if (!settings || !gdi)
		return FALSE;

	return gdi_resize(gdi,
	                  freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
	                  freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

static BOOL loopback_pre_connect(freerdp* instance)
{
	rdpSettings* settings = NULL;
	const BOOL gfx_enabled = env_gfx_enabled();

	WINPR_ASSERT(instance);
	WINPR_ASSERT(instance->context);
	settings = instance->context->settings;
	WINPR_ASSERT(settings);
	if (PubSub_SubscribeChannelConnected(
	        instance->context->pubSub, loopback_on_channel_connected) < 0
	    || PubSub_SubscribeChannelDisconnected(
           instance->context->pubSub, loopback_on_channel_disconnected) < 0)
		return FALSE;

	if (!freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, gfx_enabled)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxH264, gfx_enabled)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, !gfx_enabled)
	    || !freerdp_settings_set_bool(settings, FreeRDP_RemoteFxImageCodec, !gfx_enabled)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxProgressiveV2, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_GfxPlanar, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_UnicodeInput, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_HasExtendedMouseEvent, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_HasHorizontalWheel, TRUE))
		return FALSE;

	return TRUE;
}

static BOOL loopback_post_connect(freerdp* instance)
{
	loopback_context* loop = (loopback_context*)instance->context;

	if (!gdi_init(instance, PIXEL_FORMAT_XRGB32))
		return FALSE;

	loop->connected_us = monotonic_us();
	loop->start_us = loop->connected_us;
	loop->next_input_us = loop->connected_us + UINT64_C(500000);
	instance->context->update->BeginPaint = loopback_begin_paint;
	instance->context->update->EndPaint = loopback_end_paint;
	instance->context->update->DesktopResize = loopback_desktop_resize;
	WLog_INFO(TAG, "connected; duration=%" PRIu64 "ms gfx=%s",
	          loop->duration_us / UINT64_C(1000), env_gfx_enabled() ? "on" : "off");
	return TRUE;
}

static void loopback_post_disconnect(freerdp* instance)
{
	if (instance && instance->context)
	{
		PubSub_UnsubscribeChannelConnected(
		    instance->context->pubSub, loopback_on_channel_connected);
		PubSub_UnsubscribeChannelDisconnected(
		    instance->context->pubSub, loopback_on_channel_disconnected);
		gdi_free(instance);
	}
}

static BOOL loopback_global_init(void)
{
	return TRUE;
}

static void loopback_global_uninit(void)
{
}

static BOOL loopback_client_new(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(context);
	if (!instance)
		return FALSE;

	instance->PreConnect = loopback_pre_connect;
	instance->PostConnect = loopback_post_connect;
	instance->PostDisconnect = loopback_post_disconnect;
	return TRUE;
}

static void loopback_client_free(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(instance);
	WINPR_UNUSED(context);
}

static int loopback_client_start(rdpContext* context)
{
	WINPR_UNUSED(context);
	return 0;
}

static int loopback_client_stop(rdpContext* context)
{
	WINPR_UNUSED(context);
	return 0;
}

static void loopback_send_input(loopback_context* loop)
{
	rdpInput* input = loop->common.context.input;
	const UINT16 x = (UINT16)(320 + (loop->input_sequence % 4) * 80);
	const UINT16 y = (UINT16)(240 + (loop->input_sequence % 3) * 80);

	if (!input)
		return;

	loop->input_sequence++;
	if (!freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y))
		loop->input_send_failures++;
	if (!freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN, x, y))
		loop->input_send_failures++;
	if (!freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON1, x, y))
		loop->input_send_failures++;
	loop->input_clicks_sent++;
	WLog_INFO(TAG, "sent mouse click=%" PRIu64 " x=%" PRIu16 " y=%" PRIu16,
	          loop->input_sequence, x, y);
}

static DWORD loopback_run(loopback_context* loop)
{
	rdpContext* context = (rdpContext*)loop;
	freerdp* instance = context->instance;
	HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
	DWORD status = 0;
	DWORD count = 0;
	DWORD result = 0;

	if (!freerdp_connect(instance))
	{
		result = freerdp_get_last_error(context);
		WLog_ERR(TAG, "connection failed: 0x%08" PRIx32, result);
		return result;
	}

	while (!freerdp_shall_disconnect_context(context))
	{
		const uint64_t now = monotonic_us();
		loopback_sample_gfx(loop, now);
		if (loop->duration_us > 0 && now >= loop->connected_us + loop->duration_us)
			break;

		if (now >= loop->next_input_us)
		{
			loopback_send_input(loop);
			loop->next_input_us = now + UINT64_C(1000000);
		}

		count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
		if (count == 0)
		{
			WLog_ERR(TAG, "freerdp_get_event_handles failed");
			break;
		}

		status = WaitForMultipleObjects(count, handles, FALSE, 50);
		if (status == WAIT_FAILED)
		{
			WLog_ERR(TAG, "WaitForMultipleObjects failed");
			break;
		}

		if (!freerdp_check_event_handles(context))
		{
			result = freerdp_get_last_error(context);
			if (result != FREERDP_ERROR_SUCCESS)
				WLog_ERR(TAG, "event handling failed: 0x%08" PRIx32, result);
			break;
		}
		loopback_sample_gfx(loop, monotonic_us());
	}

	loopback_sample_gfx(loop, monotonic_us());
	loopback_update_gfx_codec_counts(loop);
	freerdp_disconnect(instance);
	return result;
}

static int loopback_entry_points(RDP_CLIENT_ENTRY_POINTS* entry)
{
	ZeroMemory(entry, sizeof(*entry));
	entry->Version = RDP_CLIENT_INTERFACE_VERSION;
	entry->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry->GlobalInit = loopback_global_init;
	entry->GlobalUninit = loopback_global_uninit;
	entry->ContextSize = sizeof(loopback_context);
	entry->ClientNew = loopback_client_new;
	entry->ClientFree = loopback_client_free;
	entry->ClientStart = loopback_client_start;
	entry->ClientStop = loopback_client_stop;
	return 0;
}

int main(int argc, char** argv)
{
	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	rdpContext* context = NULL;
	loopback_context* loop = NULL;
	int status = 0;
	int result = 1;

	loopback_entry_points(&entry);
	context = freerdp_client_context_new(&entry);
	if (!context)
		return 1;
	loop = (loopback_context*)context;
	loop->duration_us = env_duration_us();

	status = freerdp_client_settings_parse_command_line(context->settings, argc, argv, FALSE);
	if (status)
	{
		(void)freerdp_client_settings_command_line_status_print(context->settings, status, argc,
		                                                        argv);
		goto out;
	}

	if (!stream_dump_register_handlers(context, CONNECTION_STATE_MCS_CREATE_REQUEST, FALSE))
		goto out;
	if (freerdp_client_start(context) != 0)
		goto out;

	result = (int)loopback_run(loop);
	if (freerdp_client_stop(context) != 0)
		result = 1;

	printf("loopback summary: frames=%" PRIu64 " first_frame_ms=%" PRIu64
	       " avg_interval_ms=%" PRIu64 " max_interval_ms=%" PRIu64
	       " invalid_rects=%" PRIu64 " size=%" PRIu32 "x%" PRIu32
	       " input_clicks_sent=%" PRIu64 " input_send_failures=%" PRIu64
	       " gfx_frames=%" PRIu64 " gfx_first_frame_ms=%" PRIu64
	       " gfx_avg_interval_ms=%" PRIu64 " gfx_max_interval_ms=%" PRIu64
	       " gfx_wire_commands=%" PRIu64 " gfx_avc420=%" PRIu64
	       " gfx_avc444=%" PRIu64
	       " gfx_codec_uncompressed=%" PRIu64
	       " gfx_codec_cavideo=%" PRIu64
	       " gfx_codec_planar=%" PRIu64
	       " gfx_codec_progressive=%" PRIu64
	       " gfx_codec_progressive_v2=%" PRIu64 "\n",
	       loop->frame_count,
	       loop->first_frame_us > loop->connected_us
	           ? (loop->first_frame_us - loop->connected_us) / UINT64_C(1000)
	           : 0,
	       loop->frame_count > 1
	           ? loop->frame_interval_total_us / (loop->frame_count - 1) / UINT64_C(1000)
	           : 0,
	       loop->frame_interval_max_us / UINT64_C(1000),
	       loop->invalid_rect_total,
	       loop->last_width,
	       loop->last_height,
	       loop->input_clicks_sent,
	       loop->input_send_failures,
	       loop->gfx_frame_count,
	       loop->gfx_first_frame_us > loop->connected_us
	           ? (loop->gfx_first_frame_us - loop->connected_us) / UINT64_C(1000)
	           : 0,
	       loop->gfx_frame_count > 1
	           ? loop->gfx_frame_interval_total_us / (loop->gfx_frame_count - 1)
	                 / UINT64_C(1000)
	           : 0,
	       loop->gfx_frame_interval_max_us / UINT64_C(1000),
	       loop->gfx_wire_command_count,
	       loop->gfx_avc420_count,
	       loop->gfx_avc444_count,
	       loop->gfx_codec_counts[RDPGFX_CODECID_UNCOMPRESSED],
	       loop->gfx_codec_counts[RDPGFX_CODECID_CAVIDEO],
	       loop->gfx_codec_counts[RDPGFX_CODECID_PLANAR],
	       loop->gfx_codec_counts[RDPGFX_CODECID_CAPROGRESSIVE],
	       loop->gfx_codec_counts[RDPGFX_CODECID_CAPROGRESSIVE_V2]);

out:
	freerdp_client_context_free(context);
	return result;
}
