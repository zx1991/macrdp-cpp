#include <AppKit/AppKit.h>

#include <freerdp/log.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/server/shadow.h>

#include "macrdp/cliprdr_adapter.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#define TAG SERVER_TAG("macrdp.cliprdr")

namespace {

constexpr UINT32 kCfText = 1;
constexpr UINT32 kCfUnicodeText = 13;
constexpr std::size_t kMaxClipboardBytes = 16U * 1024U * 1024U;
std::mutex pasteboard_mutex;

struct PasteboardSnapshot {
    NSInteger change_count = 0;
    std::optional<std::string> text;
};

struct CliprdrState {
    rdpShadowClient* client = nullptr;
    CliprdrServerContext* context = nullptr;
    std::atomic_bool stop_requested{false};
    std::thread monitor_thread;
    std::mutex channel_mutex;
    std::mutex clipboard_mutex;
    NSInteger last_change_count = -1;
    std::string last_published_text;
    UINT32 pending_remote_format = kCfUnicodeText;
};

CliprdrState* state_for(CliprdrServerContext* context) {
    return context == nullptr ? nullptr : static_cast<CliprdrState*>(context->custom);
}

PasteboardSnapshot read_pasteboard() {
    PasteboardSnapshot snapshot;
    std::lock_guard lock(pasteboard_mutex);
    @autoreleasepool {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        snapshot.change_count = pasteboard.changeCount;
        NSString* value = [pasteboard stringForType:NSPasteboardTypeString];
        if (value == nil) {
            return snapshot;
        }

        NSData* data = [value dataUsingEncoding:NSUTF8StringEncoding];
        if (data == nil || [data length] > kMaxClipboardBytes) {
            return snapshot;
        }
        const NSUInteger length = [data length];
        snapshot.text = length == 0
            ? std::string{}
            : std::string(static_cast<const char*>([data bytes]), length);
    }
    return snapshot;
}

bool write_pasteboard(const std::string& text) {
    if (text.size() > kMaxClipboardBytes) {
        return false;
    }

    std::lock_guard lock(pasteboard_mutex);
    @autoreleasepool {
        NSString* value = [[NSString alloc]
            initWithBytes:text.data()
                   length:text.size()
                 encoding:NSUTF8StringEncoding];
        if (value == nil) {
            return false;
        }

        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        return [pasteboard clearContents]
            && [pasteboard setString:value forType:NSPasteboardTypeString];
    }
}

std::vector<BYTE> encode_text(const std::string& text, UINT32 format_id) {
    std::vector<BYTE> result;
    if (text.size() > kMaxClipboardBytes) {
        return result;
    }

    @autoreleasepool {
        NSString* value = [[NSString alloc]
            initWithBytes:text.data()
                   length:text.size()
                 encoding:NSUTF8StringEncoding];
        if (value == nil) {
            return result;
        }

        NSStringEncoding encoding = format_id == kCfUnicodeText
            ? NSUTF16LittleEndianStringEncoding
            : NSWindowsCP1252StringEncoding;
        NSData* data = [value dataUsingEncoding:encoding allowLossyConversion:YES];
        if (data == nil || [data length] > kMaxClipboardBytes - 2U) {
            return result;
        }

        result.resize([data length] + (format_id == kCfUnicodeText ? 2U : 1U));
        std::memcpy(result.data(), [data bytes], [data length]);
        result[result.size() - 1U] = 0;
        if (format_id == kCfUnicodeText) {
            result[result.size() - 2U] = 0;
        }
    }
    return result;
}

std::optional<std::string> decode_text(const BYTE* data, std::size_t size, UINT32 format_id) {
    if ((data == nullptr && size != 0) || size > kMaxClipboardBytes) {
        return std::nullopt;
    }

    if (format_id == kCfUnicodeText) {
        size &= ~static_cast<std::size_t>(1U);
        while (size >= 2U && data[size - 1U] == 0 && data[size - 2U] == 0) {
            size -= 2U;
        }
    } else {
        while (size > 0 && data[size - 1U] == 0) {
            --size;
        }
    }

    @autoreleasepool {
        NSStringEncoding encoding = format_id == kCfUnicodeText
            ? NSUTF16LittleEndianStringEncoding
            : NSWindowsCP1252StringEncoding;
        NSString* value = [[NSString alloc]
            initWithBytes:data length:size encoding:encoding];
        if (value == nil) {
            return std::nullopt;
        }
        NSData* utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8 == nil || [utf8 length] > kMaxClipboardBytes) {
            return std::nullopt;
        }
        return std::string(
            static_cast<const char*>([utf8 bytes]),
            [utf8 length]);
    }
}

UINT send_local_format_list(CliprdrState* state, const PasteboardSnapshot& snapshot) {
    if (state == nullptr || state->context == nullptr || state->context->ServerFormatList == nullptr) {
        return ERROR_INVALID_HANDLE;
    }

    CLIPRDR_FORMAT formats[2] = {};
    UINT32 format_count = 0;
    if (snapshot.text.has_value()) {
        formats[format_count++].formatId = kCfUnicodeText;
        formats[format_count++].formatId = kCfText;
    }

    CLIPRDR_FORMAT_LIST list = {};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = format_count;
    list.formats = formats;

    std::lock_guard lock(state->channel_mutex);
    return state->context->ServerFormatList(state->context, &list);
}

void publish_if_changed(CliprdrState* state, bool force) {
    if (state == nullptr || state->stop_requested.load()) {
        return;
    }

    const auto snapshot = read_pasteboard();
    {
        std::lock_guard lock(state->clipboard_mutex);
        if (!force && snapshot.change_count == state->last_change_count) {
            return;
        }
        if (!force && snapshot.text.value_or(std::string{}) == state->last_published_text) {
            state->last_change_count = snapshot.change_count;
            return;
        }
    }

    const UINT status = send_local_format_list(state, snapshot);
    if (status != CHANNEL_RC_OK) {
        WLog_WARN(TAG, "Unable to publish macOS clipboard formats: %" PRIu32, status);
        return;
    }

    std::lock_guard lock(state->clipboard_mutex);
    state->last_change_count = snapshot.change_count;
    state->last_published_text = snapshot.text.value_or(std::string{});
}

UINT client_capabilities(
    CliprdrServerContext* context,
    const CLIPRDR_CAPABILITIES*) {
    auto* state = state_for(context);
    publish_if_changed(state, true);
    return CHANNEL_RC_OK;
}

UINT client_format_list(
    CliprdrServerContext* context,
    const CLIPRDR_FORMAT_LIST* format_list) {
    auto* state = state_for(context);
    if (state == nullptr || format_list == nullptr
        || (format_list->numFormats != 0 && format_list->formats == nullptr)) {
        return ERROR_INVALID_PARAMETER;
    }

    UINT32 requested_format = 0;
    for (UINT32 index = 0; index < format_list->numFormats; ++index) {
        const UINT32 format_id = format_list->formats[index].formatId;
        if (format_id == kCfUnicodeText) {
            requested_format = kCfUnicodeText;
            break;
        }
        if (format_id == kCfText) {
            requested_format = kCfText;
        }
    }

    if (requested_format == 0) {
        CLIPRDR_FORMAT_LIST_RESPONSE response = {};
        response.common.msgType = CB_FORMAT_LIST_RESPONSE;
        response.common.msgFlags = CB_RESPONSE_FAIL;

        std::lock_guard lock(state->channel_mutex);
        if (context->ServerFormatListResponse == nullptr) {
            return ERROR_INVALID_HANDLE;
        }
        return context->ServerFormatListResponse(context, &response);
    }

    CLIPRDR_FORMAT_LIST_RESPONSE response = {};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;

    CLIPRDR_FORMAT_DATA_REQUEST request = {};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = requested_format;
    {
        std::lock_guard lock(state->clipboard_mutex);
        state->pending_remote_format = requested_format;
    }

    std::lock_guard lock(state->channel_mutex);
    if (context->ServerFormatListResponse == nullptr
        || context->ServerFormatDataRequest == nullptr) {
        return ERROR_INVALID_HANDLE;
    }
    const UINT response_status = context->ServerFormatListResponse(context, &response);
    if (response_status != CHANNEL_RC_OK) {
        return response_status;
    }
    return context->ServerFormatDataRequest(context, &request);
}

UINT client_format_data_request(
    CliprdrServerContext* context,
    const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    auto* state = state_for(context);
    if (state == nullptr || request == nullptr) {
        return ERROR_INVALID_PARAMETER;
    }

    const bool supported = request->requestedFormatId == kCfUnicodeText
        || request->requestedFormatId == kCfText;
    const auto snapshot = read_pasteboard();
    const auto data = supported && snapshot.text.has_value()
        ? encode_text(*snapshot.text, request->requestedFormatId)
        : std::vector<BYTE>{};

    CLIPRDR_FORMAT_DATA_RESPONSE response = {};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = supported && snapshot.text.has_value() && !data.empty()
        ? CB_RESPONSE_OK
        : CB_RESPONSE_FAIL;
    response.common.dataLen = static_cast<UINT32>(data.size());
    response.requestedFormatData = data.empty() ? nullptr : data.data();

    std::lock_guard lock(state->channel_mutex);
    if (context->ServerFormatDataResponse == nullptr) {
        return ERROR_INVALID_HANDLE;
    }
    return context->ServerFormatDataResponse(context, &response);
}

UINT client_format_data_response(
    CliprdrServerContext* context,
    const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
    auto* state = state_for(context);
    if (state == nullptr || response == nullptr) {
        return ERROR_INVALID_PARAMETER;
    }
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) != 0) {
        return CHANNEL_RC_OK;
    }

    UINT32 format_id = kCfUnicodeText;
    {
        std::lock_guard lock(state->clipboard_mutex);
        format_id = state->pending_remote_format;
    }
    const auto text = decode_text(
        response->requestedFormatData,
        response->common.dataLen,
        format_id);
    WLog_INFO(TAG,
              "Received client clipboard data: format=%" PRIu32 " bytes=%" PRIu32,
              format_id,
              response->common.dataLen);
    if (!text.has_value() || !write_pasteboard(*text)) {
        return ERROR_INVALID_DATA;
    }

    const auto snapshot = read_pasteboard();
    std::lock_guard lock(state->clipboard_mutex);
    state->last_change_count = snapshot.change_count;
    state->last_published_text = *text;
    return CHANNEL_RC_OK;
}

UINT client_format_list_response(
    CliprdrServerContext*,
    const CLIPRDR_FORMAT_LIST_RESPONSE*) {
    return CHANNEL_RC_OK;
}

UINT client_lock_clipboard_data(
    CliprdrServerContext*,
    const CLIPRDR_LOCK_CLIPBOARD_DATA*) {
    return CHANNEL_RC_OK;
}

UINT client_unlock_clipboard_data(
    CliprdrServerContext*,
    const CLIPRDR_UNLOCK_CLIPBOARD_DATA*) {
    return CHANNEL_RC_OK;
}

void clipboard_monitor(CliprdrState* state) {
    while (!state->stop_requested.load()) {
        publish_if_changed(state, false);
        std::this_thread::sleep_for(std::chrono::milliseconds{250});
    }
}

} // namespace

extern "C" BOOL macrdp_shadow_cliprdr_init(rdpShadowClient* client) {
    if (client == nullptr || client->vcm == nullptr) {
        return FALSE;
    }

    auto* context = cliprdr_server_context_new(client->vcm);
    if (context == nullptr) {
        return FALSE;
    }

    auto state = std::unique_ptr<CliprdrState>(new (std::nothrow) CliprdrState{});
    if (!state) {
        cliprdr_server_context_free(context);
        return FALSE;
    }

    state->client = client;
    state->context = context;
    context->custom = state.get();
    context->useLongFormatNames = FALSE;
    context->streamFileClipEnabled = FALSE;
    context->fileClipNoFilePaths = TRUE;
    context->canLockClipData = FALSE;
    context->hasHugeFileSupport = FALSE;
    context->ClientCapabilities = client_capabilities;
    context->ClientFormatList = client_format_list;
    context->ClientFormatListResponse = client_format_list_response;
    context->ClientFormatDataRequest = client_format_data_request;
    context->ClientLockClipboardData = client_lock_clipboard_data;
    context->ClientUnlockClipboardData = client_unlock_clipboard_data;
    context->ClientFormatDataResponse = client_format_data_response;

    if (context->Start == nullptr || context->Start(context) != CHANNEL_RC_OK) {
        cliprdr_server_context_free(context);
        return FALSE;
    }

    try {
        state->monitor_thread = std::thread(clipboard_monitor, state.get());
    } catch (...) {
        (void)context->Stop(context);
        cliprdr_server_context_free(context);
        return FALSE;
    }

    client->cliprdr = context;
    state.release();
    WLog_INFO(TAG, "Clipboard channel enabled (text formats only)");
    return TRUE;
}

extern "C" void macrdp_shadow_cliprdr_uninit(rdpShadowClient* client) {
    if (client == nullptr || client->cliprdr == nullptr) {
        return;
    }

    auto* context = client->cliprdr;
    auto* state = state_for(context);
    if (state != nullptr) {
        state->stop_requested.store(true);
        if (state->monitor_thread.joinable()) {
            state->monitor_thread.join();
        }
    }
    if (context->Stop != nullptr) {
        (void)context->Stop(context);
    }
    client->cliprdr = nullptr;
    cliprdr_server_context_free(context);
    delete state;
}
