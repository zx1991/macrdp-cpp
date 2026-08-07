#include <freerdp/config.h>

#include <freerdp/addin.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rdpsnd.h>
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
#include <winpr/cast.h>
#include <winpr/synch.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG CLIENT_TAG("macrdp-loopback")

#define LOOPBACK_CF_TEXT 1U
#define LOOPBACK_CF_UNICODETEXT 13U

static const char* loopback_client_clipboard_default =
	"macrdp loopback client clipboard text";
static const char* loopback_server_clipboard_default =
	"macrdp loopback server clipboard text";

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
	uint64_t input_synchronize_events_sent;
	uint64_t input_keyboard_events_sent;
	uint64_t input_keyboard_repeats_sent;
	uint64_t input_unicode_events_sent;
	uint64_t input_wheel_events_sent;
	uint64_t input_right_button_events_sent;
	uint64_t input_middle_button_events_sent;
	uint64_t input_extended_mouse_events_sent;
	uint64_t input_drag_events_sent;
	uint64_t input_send_failures;
	uint64_t clipboard_server_format_lists_received;
	uint64_t clipboard_server_format_list_responses_sent;
	uint64_t clipboard_server_data_requests_sent;
	uint64_t clipboard_server_data_responses_received;
	uint64_t clipboard_client_format_lists_sent;
	uint64_t clipboard_client_format_list_responses_received;
	uint64_t clipboard_client_data_requests_received;
	uint64_t clipboard_client_data_responses_sent;
	uint64_t clipboard_matches;
	uint64_t clipboard_failures;
	uint64_t gfx_first_frame_us;
	uint64_t gfx_last_frame_us;
	uint64_t gfx_frame_interval_total_us;
	uint64_t gfx_frame_interval_max_us;
	uint64_t audio_format_supported_calls;
	uint64_t audio_server_formats_received;
	uint64_t audio_open_count;
	uint64_t audio_play_callbacks;
	uint64_t audio_pcm_bytes;
	uint64_t audio_pcm_frames;
	uint64_t audio_first_play_us;
	uint64_t audio_last_play_us;
	uint64_t audio_interval_total_us;
	uint64_t audio_interval_max_us;
	uint64_t audio_non_pcm_callbacks;
	uint16_t audio_format_tag;
	uint16_t audio_channels;
	uint32_t audio_sample_rate;
	uint16_t audio_bits_per_sample;
	RdpgfxClientContext* gfx;
	CliprdrClientContext* cliprdr;
	UINT32 clipboard_server_format;
	BOOL clipboard_monitor_ready;
	BOOL clipboard_server_data_received;
	BOOL clipboard_client_format_list_sent;
	uint32_t last_width;
	uint32_t last_height;
} loopback_context;

typedef struct
{
	rdpsndDevicePlugin device;
	loopback_context* loop;
} loopback_rdpsnd_device;

static FREERDP_LOAD_CHANNEL_ADDIN_ENTRY_FN loopback_original_addin_provider = NULL;

static uint64_t monotonic_us(void);

static uint64_t loopback_audio_now(loopback_context* loop)
{
	const uint64_t now = monotonic_us();

	if (loop->audio_play_callbacks == 0)
		loop->audio_first_play_us = now;
	else if (now >= loop->audio_last_play_us)
	{
		const uint64_t interval = now - loop->audio_last_play_us;
		loop->audio_interval_total_us += interval;
		if (interval > loop->audio_interval_max_us)
			loop->audio_interval_max_us = interval;
	}
	loop->audio_last_play_us = now;
	return now;
}

static loopback_context* loopback_audio_context(rdpsndDevicePlugin* device)
{
	loopback_rdpsnd_device* audio = (loopback_rdpsnd_device*)device;
	return audio ? audio->loop : NULL;
}

static BOOL loopback_audio_format_supported(
	rdpsndDevicePlugin* device,
	const AUDIO_FORMAT* format)
{
	loopback_context* loop = loopback_audio_context(device);
	if (loop)
		loop->audio_format_supported_calls++;

	/* The loopback test pins the channel to PCM below. Keep the device honest
	 * so a compressed server format cannot be mistaken for raw PCM delivery. */
	return format != NULL && format->wFormatTag == WAVE_FORMAT_PCM;
}

static BOOL loopback_audio_open(
	rdpsndDevicePlugin* device,
	const AUDIO_FORMAT* format,
	UINT32 latency)
{
	loopback_context* loop = loopback_audio_context(device);
	WINPR_UNUSED(latency);
	if (!loop || !format)
		return FALSE;

	loop->audio_open_count++;
	loop->audio_format_tag = format->wFormatTag;
	loop->audio_channels = format->nChannels;
	loop->audio_sample_rate = format->nSamplesPerSec;
	loop->audio_bits_per_sample = format->wBitsPerSample;
	return TRUE;
}

static UINT32 loopback_audio_get_volume(WINPR_ATTR_UNUSED rdpsndDevicePlugin* device)
{
	return 0;
}

static BOOL loopback_audio_set_volume(
	WINPR_ATTR_UNUSED rdpsndDevicePlugin* device,
	WINPR_ATTR_UNUSED UINT32 value)
{
	return TRUE;
}

static UINT loopback_audio_play_ex(
	rdpsndDevicePlugin* device,
	const AUDIO_FORMAT* format,
	const BYTE* data,
	size_t size)
{
	loopback_context* loop = loopback_audio_context(device);
	if (!loop || (!data && size != 0))
		return CHANNEL_RC_BAD_INIT_HANDLE;

	(void)loopback_audio_now(loop);
	loop->audio_play_callbacks++;
	loop->audio_pcm_bytes += size;
	if (format)
	{
		loop->audio_format_tag = format->wFormatTag;
		loop->audio_channels = format->nChannels;
		loop->audio_sample_rate = format->nSamplesPerSec;
		loop->audio_bits_per_sample = format->wBitsPerSample;
		if (format->wFormatTag != WAVE_FORMAT_PCM)
			loop->audio_non_pcm_callbacks++;
		if (format->nBlockAlign != 0)
			loop->audio_pcm_frames += size / format->nBlockAlign;
	}
	return CHANNEL_RC_OK;
}

static UINT loopback_audio_play(
	rdpsndDevicePlugin* device,
	const BYTE* data,
	size_t size)
{
	return loopback_audio_play_ex(device, NULL, data, size);
}

static void loopback_audio_close(WINPR_ATTR_UNUSED rdpsndDevicePlugin* device)
{
}

static void loopback_audio_free(rdpsndDevicePlugin* device)
{
	free(device);
}

static BOOL loopback_audio_default_format(
	rdpsndDevicePlugin* device,
	const AUDIO_FORMAT* desired,
	AUDIO_FORMAT* default_format)
{
	WINPR_UNUSED(device);
	if (!desired || !default_format)
		return FALSE;
	*default_format = *desired;
	default_format->data = NULL;
	return TRUE;
}

static UINT loopback_audio_server_format_announce(
	rdpsndDevicePlugin* device,
	const AUDIO_FORMAT* formats,
	size_t count)
{
	loopback_context* loop = loopback_audio_context(device);
	WINPR_UNUSED(formats);
	if (loop)
		loop->audio_server_formats_received += count;
	return CHANNEL_RC_OK;
}

static UINT VCAPITYPE loopback_rdpsnd_client_subsystem_entry(
	PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry_points)
{
	loopback_rdpsnd_device* audio = NULL;
	rdpContext* context = NULL;

	if (!entry_points || !entry_points->pRegisterRdpsndDevice)
		return CHANNEL_RC_BAD_INIT_HANDLE;
	context = freerdp_rdpsnd_get_context(entry_points->rdpsnd);
	if (!context)
		return CHANNEL_RC_BAD_INIT_HANDLE;

	audio = (loopback_rdpsnd_device*)calloc(1, sizeof(*audio));
	if (!audio)
		return CHANNEL_RC_NO_MEMORY;
	audio->loop = (loopback_context*)context;
	audio->device.FormatSupported = loopback_audio_format_supported;
	audio->device.Open = loopback_audio_open;
	audio->device.GetVolume = loopback_audio_get_volume;
	audio->device.SetVolume = loopback_audio_set_volume;
	audio->device.Play = loopback_audio_play;
	audio->device.Close = loopback_audio_close;
	audio->device.Free = loopback_audio_free;
	audio->device.DefaultFormat = loopback_audio_default_format;
	audio->device.ServerFormatAnnounce = loopback_audio_server_format_announce;
	audio->device.PlayEx = loopback_audio_play_ex;
	entry_points->pRegisterRdpsndDevice(entry_points->rdpsnd, &audio->device);
	return CHANNEL_RC_OK;
}

static PVIRTUALCHANNELENTRY loopback_addin_provider(
	LPCSTR name,
	LPCSTR subsystem,
	LPCSTR type,
	DWORD flags)
{
	/* The channel entry itself remains FreeRDP-owned. This provider is only
	 * replacing the selected static RDPSND device backend. */
	if (name && strcmp(name, RDPSND_CHANNEL_NAME) == 0
	    && (flags & FREERDP_ADDIN_CHANNEL_STATIC) != 0
	    && subsystem && strcmp(subsystem, "macrdp") == 0)
		return WINPR_FUNC_PTR_CAST(&loopback_rdpsnd_client_subsystem_entry, PVIRTUALCHANNELENTRY);

	return loopback_original_addin_provider
	           ? loopback_original_addin_provider(name, subsystem, type, flags)
	           : NULL;
}

static BOOL loopback_install_audio_provider(void)
{
	loopback_original_addin_provider = freerdp_get_current_addin_provider();
	if (!loopback_original_addin_provider)
		loopback_original_addin_provider = freerdp_channels_load_static_addin_entry;
	if (!loopback_original_addin_provider)
		return FALSE;
	return freerdp_register_addin_provider(loopback_addin_provider, 0) == CHANNEL_RC_OK;
}

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

static DWORD env_event_delay_ms(void)
{
	const char* value = getenv("MACRDP_LOOPBACK_EVENT_DELAY_MS");
	char* end = NULL;
	unsigned long long milliseconds = 0;

	if (!value || !*value)
		return 0;
	milliseconds = strtoull(value, &end, 10);
	if (end == value || *end != '\0' || milliseconds > UINT32_MAX)
		return 0;
	return (DWORD)milliseconds;
}

static BOOL env_keyboard_probe_enabled(void)
{
	const char* value = getenv("MACRDP_LOOPBACK_PROBE_F");
	return value && *value && *value != '0' && *value != 'n' && *value != 'N';
}

static BOOL env_gfx_enabled(void)
{
	const char* value = getenv("MACRDP_LOOPBACK_GFX");
	return !(value && (*value == '0' || *value == 'n' || *value == 'N'));
}

static const char* env_clipboard_text(const char* name, const char* fallback)
{
	const char* value = getenv(name);
	return value && *value ? value : fallback;
}

static const char* loopback_client_clipboard_text(void)
{
	return env_clipboard_text(
	    "MACRDP_LOOPBACK_CLIENT_CLIPBOARD_TEXT", loopback_client_clipboard_default);
}

static const char* loopback_server_clipboard_text(void)
{
	return env_clipboard_text(
	    "MACRDP_LOOPBACK_SERVER_CLIPBOARD_TEXT", loopback_server_clipboard_default);
}

static BOOL loopback_clipboard_format_supported(UINT32 format_id)
{
	return format_id == LOOPBACK_CF_UNICODETEXT || format_id == LOOPBACK_CF_TEXT;
}

static size_t loopback_encode_clipboard(
    const char* text,
    UINT32 format_id,
    BYTE** output)
{
	const size_t length = strlen(text);
	BYTE* data = NULL;

	*output = NULL;
	if (!loopback_clipboard_format_supported(format_id))
		return 0;

	if (format_id == LOOPBACK_CF_UNICODETEXT)
	{
		if (length > (SIZE_MAX / 2U) - 1U)
			return 0;
		data = (BYTE*)malloc((length + 1U) * 2U);
		if (!data)
			return 0;
		for (size_t index = 0; index < length; index++)
		{
			if ((unsigned char)text[index] > 0x7FU)
			{
				free(data);
				return 0;
			}
			data[index * 2U] = (BYTE)text[index];
			data[index * 2U + 1U] = 0;
		}
		data[length * 2U] = 0;
		data[length * 2U + 1U] = 0;
		*output = data;
		return (length + 1U) * 2U;
	}

	data = (BYTE*)malloc(length + 1U);
	if (!data)
		return 0;
	memcpy(data, text, length);
	data[length] = 0;
	*output = data;
	return length + 1U;
}

static BOOL loopback_clipboard_data_matches(
    const CLIPRDR_FORMAT_DATA_RESPONSE* response,
    UINT32 format_id,
    const char* expected)
{
	const size_t expected_length = strlen(expected);
	const BYTE* data = response->requestedFormatData;
	size_t length = response->common.dataLen;

	if ((response->common.msgFlags & CB_RESPONSE_FAIL) != 0
	    || (data == NULL && length != 0)
	    || !loopback_clipboard_format_supported(format_id))
		return FALSE;

	if (format_id == LOOPBACK_CF_UNICODETEXT)
	{
		if ((length & 1U) != 0)
			return FALSE;
		while (length >= 2U && data[length - 1U] == 0 && data[length - 2U] == 0)
			length -= 2U;
		if (length != expected_length * 2U)
			return FALSE;
		for (size_t index = 0; index < expected_length; index++)
		{
			if (data[index * 2U] != (BYTE)expected[index] || data[index * 2U + 1U] != 0)
				return FALSE;
		}
		return TRUE;
	}

	while (length > 0 && data[length - 1U] == 0)
		length--;
	return length == expected_length
	    && memcmp(data, expected, expected_length) == 0;
}

static UINT loopback_send_client_format_list(loopback_context* loop)
{
	CLIPRDR_FORMAT formats[2] = { 0 };
	CLIPRDR_FORMAT_LIST list = { 0 };
	UINT status = ERROR_INVALID_HANDLE;

	if (!loop || !loop->cliprdr || !loop->cliprdr->ClientFormatList)
		return status;

	formats[0].formatId = LOOPBACK_CF_UNICODETEXT;
	formats[1].formatId = LOOPBACK_CF_TEXT;
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = ARRAYSIZE(formats);
	list.formats = formats;
	status = loop->cliprdr->ClientFormatList(loop->cliprdr, &list);
	if (status == CHANNEL_RC_OK)
	{
		loop->clipboard_client_format_lists_sent++;
		WLog_INFO(TAG, "sent client clipboard format list");
	}
	else
	{
		loop->clipboard_failures++;
		WLog_ERR(TAG, "failed to send client clipboard format list: %" PRIu32, status);
	}
	return status;
}

static UINT loopback_monitor_ready(
    CliprdrClientContext* context,
    const CLIPRDR_MONITOR_READY* monitor_ready)
{
	loopback_context* loop = context ? (loopback_context*)context->custom : NULL;
	WINPR_UNUSED(monitor_ready);
	if (!loop)
		return ERROR_INVALID_PARAMETER;
	loop->clipboard_monitor_ready = TRUE;
	WLog_INFO(TAG, "clipboard monitor ready");
	return CHANNEL_RC_OK;
}

static UINT loopback_server_format_list(
    CliprdrClientContext* context,
    const CLIPRDR_FORMAT_LIST* format_list)
{
	loopback_context* loop = context ? (loopback_context*)context->custom : NULL;
	CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
	CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
	UINT32 selected_format = 0;
	UINT status = CHANNEL_RC_OK;

	if (!loop || !format_list || (format_list->numFormats != 0 && !format_list->formats))
		return ERROR_INVALID_PARAMETER;

	loop->clipboard_server_format_lists_received++;
	WLog_INFO(TAG, "received server clipboard format list: formats=%" PRIu32,
	          format_list->numFormats);
	for (UINT32 index = 0; index < format_list->numFormats; index++)
	{
		const UINT32 format_id = format_list->formats[index].formatId;
		if (format_id == LOOPBACK_CF_UNICODETEXT)
		{
			selected_format = format_id;
			break;
		}
		if (format_id == LOOPBACK_CF_TEXT)
			selected_format = format_id;
	}

	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = selected_format ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
	if (!context->ClientFormatListResponse)
		return ERROR_INVALID_HANDLE;
	status = context->ClientFormatListResponse(context, &response);
	WLog_INFO(TAG, "sent server clipboard format list response: status=%" PRIu32, status);
	if (status != CHANNEL_RC_OK)
	{
		loop->clipboard_failures++;
		return status;
	}
	loop->clipboard_server_format_list_responses_sent++;
	if (!selected_format)
	{
		loop->clipboard_failures++;
		return CHANNEL_RC_OK;
	}

	loop->clipboard_server_format = selected_format;
	request.common.msgType = CB_FORMAT_DATA_REQUEST;
	request.requestedFormatId = selected_format;
	if (!context->ClientFormatDataRequest)
		return ERROR_INVALID_HANDLE;
	status = context->ClientFormatDataRequest(context, &request);
	WLog_INFO(TAG, "sent server clipboard data request: status=%" PRIu32, status);
	if (status == CHANNEL_RC_OK)
		loop->clipboard_server_data_requests_sent++;
	else
		loop->clipboard_failures++;
	return status;
}

static UINT loopback_server_format_data_response(
    CliprdrClientContext* context,
    const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	loopback_context* loop = context ? (loopback_context*)context->custom : NULL;

	if (!loop || !response)
		return ERROR_INVALID_PARAMETER;
	loop->clipboard_server_data_responses_received++;
	if (!loopback_clipboard_data_matches(
	        response, loop->clipboard_server_format, loopback_server_clipboard_text()))
	{
		loop->clipboard_failures++;
		WLog_ERR(TAG, "server-to-client clipboard content did not match");
		return ERROR_INVALID_DATA;
	}
	loop->clipboard_server_data_received = TRUE;
	loop->clipboard_matches++;
	WLog_INFO(TAG, "server-to-client clipboard content matched");
	return CHANNEL_RC_OK;
}

static UINT loopback_server_format_list_response(
    CliprdrClientContext* context,
    const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	loopback_context* loop = context ? (loopback_context*)context->custom : NULL;

	if (!loop || !response)
		return ERROR_INVALID_PARAMETER;
	loop->clipboard_client_format_list_responses_received++;
	if ((response->common.msgFlags & CB_RESPONSE_FAIL) != 0)
		loop->clipboard_failures++;
	return CHANNEL_RC_OK;
}

static UINT loopback_server_format_data_request(
    CliprdrClientContext* context,
    const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	loopback_context* loop = context ? (loopback_context*)context->custom : NULL;
	CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
	BYTE* data = NULL;
	const char* text = NULL;
	UINT status = CHANNEL_RC_OK;

	if (!loop || !request)
		return ERROR_INVALID_PARAMETER;
	loop->clipboard_client_data_requests_received++;
	WLog_INFO(TAG, "received server clipboard data request: format=%" PRIu32,
	          request->requestedFormatId);
	text = loopback_client_clipboard_text();
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	response.common.dataLen = (UINT32)loopback_encode_clipboard(
	    text, request->requestedFormatId, &data);
	response.requestedFormatData = data;
	if (!loopback_clipboard_format_supported(request->requestedFormatId)
	    || !data || response.common.dataLen == 0)
	{
		response.common.msgFlags = CB_RESPONSE_FAIL;
		response.common.dataLen = 0;
		response.requestedFormatData = NULL;
	}
	if (!context->ClientFormatDataResponse)
		status = ERROR_INVALID_HANDLE;
	else
		status = context->ClientFormatDataResponse(context, &response);
	free(data);
	if (status == CHANNEL_RC_OK && response.common.msgFlags == CB_RESPONSE_OK)
	{
		loop->clipboard_client_data_responses_sent++;
		WLog_INFO(TAG, "sent client clipboard data response: bytes=%" PRIu32,
		          response.common.dataLen);
	}
	else
		loop->clipboard_failures++;
	return status;
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
	if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		loop->cliprdr = (CliprdrClientContext*)event->pInterface;
		if (loop->cliprdr)
		{
			loop->cliprdr->custom = loop;
			loop->cliprdr->MonitorReady = loopback_monitor_ready;
			loop->cliprdr->ServerFormatList = loopback_server_format_list;
			loop->cliprdr->ServerFormatListResponse = loopback_server_format_list_response;
			loop->cliprdr->ServerFormatDataRequest = loopback_server_format_data_request;
			loop->cliprdr->ServerFormatDataResponse = loopback_server_format_data_response;
		}
	}

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
	if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		loop->cliprdr = NULL;
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
	const char* audio_channel[] = { RDPSND_CHANNEL_NAME, "sys:macrdp", "format:1",
		                              "rate:44100", "channel:2" };

	WINPR_ASSERT(instance);
	WINPR_ASSERT(instance->context);
	settings = instance->context->settings;
	WINPR_ASSERT(settings);
	if (PubSub_SubscribeChannelConnected(
	        instance->context->pubSub, loopback_on_channel_connected) < 0
	    || PubSub_SubscribeChannelDisconnected(
	           instance->context->pubSub, loopback_on_channel_disconnected) < 0)
		return FALSE;

	/* FreeRDP uses rdpdr during activation even though this test does not
	 * exercise device data redirection. The loopback client installs a
	 * no-op/counting RDPSND backend so audio delivery is observable without a
	 * real speaker. */
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
	    || !freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_SupportSkipChannelJoin, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE)
	    || !freerdp_settings_set_uint32(settings, FreeRDP_MultitransportFlags, 0)
	    || !freerdp_settings_set_bool(settings, FreeRDP_UnicodeInput, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_HasExtendedMouseEvent, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_HasHorizontalWheel, TRUE)
	    || !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE))
		return FALSE;

	(void)freerdp_client_del_static_channel(settings, RDPSND_CHANNEL_NAME);
	(void)freerdp_client_del_dynamic_channel(settings, RDPSND_CHANNEL_NAME);
	if (!freerdp_client_add_static_channel(settings, ARRAYSIZE(audio_channel), audio_channel)
	    || !freerdp_client_add_dynamic_channel(
           settings, ARRAYSIZE(audio_channel), audio_channel))
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

static void loopback_record_input_result(
    loopback_context* loop,
    uint64_t* counter,
    BOOL result)
{
	(*counter)++;
	if (!result)
		loop->input_send_failures++;
}

static BOOL loopback_send_mouse_event(
    loopback_context* loop,
    UINT16 flags,
    UINT16 x,
    UINT16 y)
{
	const BOOL result = freerdp_input_send_mouse_event(
	    loop->common.context.input, flags, x, y);
	if (!result)
		loop->input_send_failures++;
	return result;
}

static BOOL loopback_send_extended_mouse_event(
	loopback_context* loop,
	UINT16 flags,
	UINT16 x,
	UINT16 y)
{
	const BOOL result = freerdp_input_send_extended_mouse_event(
	    loop->common.context.input, flags, x, y);
	loopback_record_input_result(loop, &loop->input_extended_mouse_events_sent, result);
	return result;
}

static void loopback_send_keyboard_pair(loopback_context* loop, UINT32 scan_code)
{
	rdpInput* input = loop->common.context.input;
	loopback_record_input_result(
	    loop,
	    &loop->input_keyboard_events_sent,
	    freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, scan_code));
	loopback_record_input_result(
	    loop,
	    &loop->input_keyboard_events_sent,
	    freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, scan_code));
}

static void loopback_send_keyboard_repeat_sequence(loopback_context* loop, UINT32 scan_code)
{
	rdpInput* input = loop->common.context.input;
	loopback_record_input_result(
	    loop,
	    &loop->input_keyboard_events_sent,
	    freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, scan_code));
	for (int repeat = 0; repeat < 2; repeat++)
	{
		loop->input_keyboard_repeats_sent++;
		loopback_record_input_result(
		    loop,
		    &loop->input_keyboard_events_sent,
		    freerdp_input_send_keyboard_event_ex(input, TRUE, TRUE, scan_code));
	}
	loopback_record_input_result(
	    loop,
	    &loop->input_keyboard_events_sent,
	    freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, scan_code));
}

static void loopback_send_input(loopback_context* loop)
{
	rdpInput* input = loop->common.context.input;
	const UINT16 x = (UINT16)(320 + (loop->input_sequence % 4) * 80);
	const UINT16 y = (UINT16)(240 + (loop->input_sequence % 3) * 80);

	if (!input)
		return;

	loop->input_sequence++;
	if (loop->input_sequence == 1)
	{
		const UINT16 wheel_positive = PTR_FLAGS_WHEEL | 0x0078;
		const UINT16 wheel_negative = PTR_FLAGS_WHEEL | PTR_FLAGS_WHEEL_NEGATIVE | 0x0088;
		const UINT16 horizontal_positive = PTR_FLAGS_HWHEEL | 0x0078;
		const UINT16 horizontal_negative = PTR_FLAGS_HWHEEL | PTR_FLAGS_WHEEL_NEGATIVE | 0x0088;
		const UINT16 drag_x = x + 80;
		const UINT16 drag_y = y + 80;
		BOOL drag_succeeded = TRUE;

		loopback_record_input_result(
		    loop,
		    &loop->input_synchronize_events_sent,
		    freerdp_input_send_synchronize_event(input, 0));
		// Exercise the initial down, repeated down, and release states with a
		// function key that does not type into the active application.
		loopback_send_keyboard_repeat_sequence(loop, RDP_SCANCODE_F17);
		// Exercise each modifier independently so a failed key-up cannot hide
		// behind a combination that changes the foreground application's action.
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_LCONTROL);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_RCONTROL);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_LSHIFT);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_RSHIFT);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_LMENU);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_RMENU);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_LWIN);
		loopback_send_keyboard_pair(loop, RDP_SCANCODE_RWIN);
		// Also cover the recovery path for clients that omit E0 on key-up.
		loopback_record_input_result(
		    loop,
		    &loop->input_keyboard_events_sent,
		    freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, RDP_SCANCODE_LWIN));
		loopback_record_input_result(
		    loop,
		    &loop->input_keyboard_events_sent,
		    freerdp_input_send_keyboard_event(
		        input,
		        KBD_FLAGS_RELEASE,
		        RDP_SCANCODE_CODE(RDP_SCANCODE_LWIN)));
		if (env_keyboard_probe_enabled())
		{
			// This opt-in probe exercises the ordinary F scan-code path. It is
			// disabled by default because it intentionally types one character
			// into the active macOS application during a live smoke test.
			loopback_send_keyboard_pair(loop, RDP_SCANCODE_KEY_F);
			WLog_INFO(TAG, "sent keyboard probe F");
		}
		// U+0000 exercises the Unicode input path without typing visible text
		// into the foreground macOS application during this protocol test.
		loopback_record_input_result(
		    loop,
		    &loop->input_unicode_events_sent,
		    freerdp_input_send_unicode_keyboard_event(input, 0, 0));
		loopback_record_input_result(
		    loop,
		    &loop->input_unicode_events_sent,
		    freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE, 0));
		loopback_record_input_result(
		    loop,
		    &loop->input_wheel_events_sent,
		    freerdp_input_send_mouse_event(input, wheel_positive, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_wheel_events_sent,
		    freerdp_input_send_mouse_event(input, wheel_negative, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_wheel_events_sent,
		    freerdp_input_send_mouse_event(input, horizontal_positive, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_wheel_events_sent,
		    freerdp_input_send_mouse_event(input, horizontal_negative, x, y));

		loopback_record_input_result(
		    loop,
		    &loop->input_right_button_events_sent,
		    freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON2 | PTR_FLAGS_DOWN, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_right_button_events_sent,
		    freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON2, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_middle_button_events_sent,
		    freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON3 | PTR_FLAGS_DOWN, x, y));
		loopback_record_input_result(
		    loop,
		    &loop->input_middle_button_events_sent,
		    freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON3, x, y));
		loopback_send_extended_mouse_event(loop, PTR_XFLAGS_DOWN | PTR_XFLAGS_BUTTON1, x, y);
		loopback_send_extended_mouse_event(loop, PTR_XFLAGS_BUTTON1, x, y);
		loopback_send_extended_mouse_event(loop, PTR_XFLAGS_DOWN | PTR_XFLAGS_BUTTON2, x, y);
		loopback_send_extended_mouse_event(loop, PTR_XFLAGS_BUTTON2, x, y);

		const BOOL drag_start = loopback_send_mouse_event(loop, PTR_FLAGS_MOVE, x, y);
		const BOOL drag_down = loopback_send_mouse_event(
		    loop, PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN, x, y);
		const BOOL drag_move = loopback_send_mouse_event(loop, PTR_FLAGS_MOVE, drag_x, drag_y);
		const BOOL drag_up = loopback_send_mouse_event(loop, PTR_FLAGS_BUTTON1, drag_x, drag_y);
		drag_succeeded = drag_start && drag_down && drag_move && drag_up;
		if (drag_succeeded)
			loop->input_drag_events_sent = 1;
		else
			loop->input_drag_events_sent = 0;
	}
	const BOOL click_move = loopback_send_mouse_event(loop, PTR_FLAGS_MOVE, x, y);
	const BOOL click_down = loopback_send_mouse_event(
	    loop, PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN, x, y);
	const BOOL click_up = loopback_send_mouse_event(loop, PTR_FLAGS_BUTTON1, x, y);
	if (click_move && click_down && click_up)
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
	const DWORD event_delay_ms = env_event_delay_ms();
	const uint64_t slow_start_us = loop->connected_us + UINT64_C(2000000);

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
		if (loop->clipboard_monitor_ready && loop->clipboard_server_data_received
		    && !loop->clipboard_client_format_list_sent)
		{
			if (loopback_send_client_format_list(loop) == CHANNEL_RC_OK)
				loop->clipboard_client_format_list_sent = TRUE;
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
		/* Let protocol setup and the first desktop frame complete before
		 * deliberately slowing the client event loop. */
		if (event_delay_ms > 0 && loop->gfx_frame_count > 0
		    && monotonic_us() >= slow_start_us)
			Sleep(event_delay_ms);
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
	if (!loopback_install_audio_provider())
	{
		WLog_ERR(TAG, "could not install loopback RDPSND provider");
		goto out;
	}
	if (freerdp_client_start(context) != 0)
		goto out;

	result = (int)loopback_run(loop);
	if (freerdp_client_stop(context) != 0)
		result = 1;

	printf("loopback summary: frames=%" PRIu64 " first_frame_ms=%" PRIu64
	       " avg_interval_ms=%" PRIu64 " max_interval_ms=%" PRIu64
	       " invalid_rects=%" PRIu64 " size=%" PRIu32 "x%" PRIu32
	       " input_clicks_sent=%" PRIu64
	       " input_synchronize_events_sent=%" PRIu64
	       " input_keyboard_events_sent=%" PRIu64
	       " input_keyboard_repeats_sent=%" PRIu64
	       " input_unicode_events_sent=%" PRIu64
	       " input_wheel_events_sent=%" PRIu64
	       " input_right_button_events_sent=%" PRIu64
	       " input_middle_button_events_sent=%" PRIu64
	       " input_extended_mouse_events_sent=%" PRIu64
	       " input_drag_events_sent=%" PRIu64
	       " input_send_failures=%" PRIu64
	       " clipboard_server_format_lists_received=%" PRIu64
	       " clipboard_server_format_list_responses_sent=%" PRIu64
	       " clipboard_server_data_requests_sent=%" PRIu64
	       " clipboard_server_data_responses_received=%" PRIu64
	       " clipboard_client_format_lists_sent=%" PRIu64
	       " clipboard_client_format_list_responses_received=%" PRIu64
	       " clipboard_client_data_requests_received=%" PRIu64
	       " clipboard_client_data_responses_sent=%" PRIu64
	       " clipboard_matches=%" PRIu64
	       " clipboard_failures=%" PRIu64
	       " gfx_frames=%" PRIu64 " gfx_first_frame_ms=%" PRIu64
	       " gfx_avg_interval_ms=%" PRIu64 " gfx_max_interval_ms=%" PRIu64
	       " gfx_wire_commands=%" PRIu64 " gfx_avc420=%" PRIu64
	       " gfx_avc444=%" PRIu64
	       " gfx_codec_uncompressed=%" PRIu64
	       " gfx_codec_cavideo=%" PRIu64
	       " gfx_codec_planar=%" PRIu64
	       " gfx_codec_progressive=%" PRIu64
	       " gfx_codec_progressive_v2=%" PRIu64
	       " audio_server_formats=%" PRIu64
	       " audio_format_supported_calls=%" PRIu64
	       " audio_open_count=%" PRIu64
	       " audio_play_callbacks=%" PRIu64
	       " audio_pcm_bytes=%" PRIu64
	       " audio_pcm_frames=%" PRIu64
	       " audio_first_play_ms=%" PRIu64
	       " audio_avg_interval_ms=%" PRIu64
	       " audio_max_interval_ms=%" PRIu64
	       " audio_non_pcm_callbacks=%" PRIu64
	       " audio_format_tag=%" PRIu16
	       " audio_channels=%" PRIu16
	       " audio_sample_rate=%" PRIu32
	       " audio_bits_per_sample=%" PRIu16 "\n",
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
	       loop->input_synchronize_events_sent,
	       loop->input_keyboard_events_sent,
	       loop->input_keyboard_repeats_sent,
	       loop->input_unicode_events_sent,
	       loop->input_wheel_events_sent,
	       loop->input_right_button_events_sent,
	       loop->input_middle_button_events_sent,
	       loop->input_extended_mouse_events_sent,
	       loop->input_drag_events_sent,
	       loop->input_send_failures,
	       loop->clipboard_server_format_lists_received,
	       loop->clipboard_server_format_list_responses_sent,
	       loop->clipboard_server_data_requests_sent,
	       loop->clipboard_server_data_responses_received,
	       loop->clipboard_client_format_lists_sent,
	       loop->clipboard_client_format_list_responses_received,
	       loop->clipboard_client_data_requests_received,
	       loop->clipboard_client_data_responses_sent,
	       loop->clipboard_matches,
	       loop->clipboard_failures,
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
	       loop->gfx_codec_counts[RDPGFX_CODECID_CAPROGRESSIVE_V2],
	       loop->audio_server_formats_received,
	       loop->audio_format_supported_calls,
	       loop->audio_open_count,
	       loop->audio_play_callbacks,
	       loop->audio_pcm_bytes,
	       loop->audio_pcm_frames,
	       loop->audio_first_play_us > loop->connected_us
	           ? (loop->audio_first_play_us - loop->connected_us) / UINT64_C(1000)
	           : 0,
	       loop->audio_play_callbacks > 1
	           ? loop->audio_interval_total_us / (loop->audio_play_callbacks - 1)
	                 / UINT64_C(1000)
	           : 0,
	       loop->audio_interval_max_us / UINT64_C(1000),
	       loop->audio_non_pcm_callbacks,
	       loop->audio_format_tag,
	       loop->audio_channels,
	       loop->audio_sample_rate,
	       loop->audio_bits_per_sample);

out:
	if (loopback_original_addin_provider)
		(void)freerdp_register_addin_provider(loopback_original_addin_provider, 0);
	freerdp_client_context_free(context);
	return result;
}
