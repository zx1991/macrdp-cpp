#include <AppKit/AppKit.h>

#include <freerdp/log.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/server/shadow.h>

#include "macrdp/clipboard_transfer.hpp"
#include "macrdp/cliprdr_adapter.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
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

std::atomic_bool g_clipboard_enabled{true};

constexpr std::size_t kMaxClipboardBytes = 16U * 1024U * 1024U;
std::mutex pasteboard_mutex;

struct PasteboardSnapshot {
    NSInteger change_count = 0;
    std::optional<std::string> text;
};

struct CliprdrState {
    CliprdrServerContext* context = nullptr;
    std::atomic_bool stop_requested{false};
    std::thread monitor_thread;
    std::mutex monitor_mutex;
    std::condition_variable monitor_cv;
    std::mutex operation_mutex;
    macrdp::ClipboardTransferState transfer;
    bool channel_ready = false;
    NSInteger last_change_count = -1;
    std::string last_published_text;
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

        NSStringEncoding encoding = format_id == macrdp::clipboard_format_unicode_text
            ? NSUTF16LittleEndianStringEncoding
            : NSWindowsCP1252StringEncoding;
        NSData* data = [value dataUsingEncoding:encoding allowLossyConversion:YES];
        if (data == nil || [data length] > kMaxClipboardBytes - 2U) {
            return result;
        }

        result.resize(
            [data length]
            + (format_id == macrdp::clipboard_format_unicode_text ? 2U : 1U));
        std::memcpy(result.data(), [data bytes], [data length]);
        result[result.size() - 1U] = 0;
        if (format_id == macrdp::clipboard_format_unicode_text) {
            result[result.size() - 2U] = 0;
        }
    }
    return result;
}

std::optional<std::string> decode_text(const BYTE* data, std::size_t size, UINT32 format_id) {
    if ((data == nullptr && size != 0) || size > kMaxClipboardBytes
        || !macrdp::ClipboardTransferState::has_valid_payload_alignment(
            format_id,
            size)) {
        return std::nullopt;
    }

    if (format_id == macrdp::clipboard_format_unicode_text) {
        while (size >= 2U && data[size - 1U] == 0 && data[size - 2U] == 0) {
            size -= 2U;
        }
    } else {
        while (size > 0 && data[size - 1U] == 0) {
            --size;
        }
    }

    @autoreleasepool {
        NSStringEncoding encoding = format_id == macrdp::clipboard_format_unicode_text
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
        formats[format_count++].formatId = macrdp::clipboard_format_unicode_text;
        formats[format_count++].formatId = macrdp::clipboard_format_text;
    }

    CLIPRDR_FORMAT_LIST list = {};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = format_count;
    list.formats = formats;

    return state->context->ServerFormatList(state->context, &list);
}

void publish_if_changed_locked(CliprdrState* state, bool force) {
    if (state == nullptr || state->stop_requested.load(std::memory_order_acquire)
        || !state->channel_ready) {
        return;
    }

    const auto snapshot = read_pasteboard();
    if (!force && snapshot.change_count == state->last_change_count) {
        return;
    }
    if (!force && snapshot.text.value_or(std::string{}) == state->last_published_text) {
        state->last_change_count = snapshot.change_count;
        return;
    }

    const UINT status = send_local_format_list(state, snapshot);
    if (status != CHANNEL_RC_OK) {
        WLog_WARN(TAG, "Unable to publish macOS clipboard formats: %" PRIu32, status);
        return;
    }

    state->last_change_count = snapshot.change_count;
    state->last_published_text = snapshot.text.value_or(std::string{});
}

void publish_if_changed(CliprdrState* state, bool force) {
    if (state == nullptr) {
        return;
    }
    std::lock_guard operation_lock(state->operation_mutex);
    publish_if_changed_locked(state, force);
}

UINT client_capabilities(
    CliprdrServerContext* context,
    const CLIPRDR_CAPABILITIES*) {
    auto* state = state_for(context);
    if (state == nullptr) {
        return ERROR_INVALID_HANDLE;
    }
    std::lock_guard operation_lock(state->operation_mutex);
    if (state->stop_requested.load(std::memory_order_acquire)) {
        return CHANNEL_RC_OK;
    }
    state->channel_ready = true;
    publish_if_changed_locked(state, true);
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
    std::lock_guard operation_lock(state->operation_mutex);
    if (state->stop_requested.load(std::memory_order_acquire)) {
        return CHANNEL_RC_OK;
    }

    UINT32 requested_format = 0;
    for (UINT32 index = 0; index < format_list->numFormats; ++index) {
        const UINT32 format_id = format_list->formats[index].formatId;
        if (format_id == macrdp::clipboard_format_unicode_text) {
            requested_format = macrdp::clipboard_format_unicode_text;
            break;
        }
        if (format_id == macrdp::clipboard_format_text) {
            requested_format = macrdp::clipboard_format_text;
        }
    }

    if (context->ServerFormatListResponse == nullptr) {
        return ERROR_INVALID_HANDLE;
    }

    CLIPRDR_FORMAT_LIST_RESPONSE response = {};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = requested_format == 0 ? CB_RESPONSE_FAIL : CB_RESPONSE_OK;

    if (requested_format == 0) {
        return context->ServerFormatListResponse(context, &response);
    }
    if (context->ServerFormatDataRequest == nullptr) {
        return ERROR_INVALID_HANDLE;
    }
    if (!state->transfer.begin_remote_request(requested_format)) {
        response.common.msgFlags = CB_RESPONSE_FAIL;
        WLog_WARN(TAG, "Remote clipboard request queue is full or stopped");
        return context->ServerFormatListResponse(context, &response);
    }

    CLIPRDR_FORMAT_DATA_REQUEST request = {};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = requested_format;

    const UINT response_status = context->ServerFormatListResponse(context, &response);
    if (response_status != CHANNEL_RC_OK) {
        (void)state->transfer.cancel_latest_remote_request(requested_format);
        return response_status;
    }
    const UINT request_status = context->ServerFormatDataRequest(context, &request);
    if (request_status != CHANNEL_RC_OK) {
        (void)state->transfer.cancel_latest_remote_request(requested_format);
    }
    return request_status;
}

UINT client_format_data_request(
    CliprdrServerContext* context,
    const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    auto* state = state_for(context);
    if (state == nullptr || request == nullptr) {
        return ERROR_INVALID_PARAMETER;
    }
    std::lock_guard operation_lock(state->operation_mutex);
    if (state->stop_requested.load(std::memory_order_acquire)) {
        return CHANNEL_RC_OK;
    }

    const bool supported = macrdp::ClipboardTransferState::is_text_format(
        request->requestedFormatId);
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
    std::lock_guard operation_lock(state->operation_mutex);
    if (state->stop_requested.load(std::memory_order_acquire)) {
        return CHANNEL_RC_OK;
    }

    const auto format_id = state->transfer.finish_remote_request();
    if (!format_id.has_value()) {
        WLog_WARN(TAG, "Ignoring unsolicited remote clipboard data response");
        return CHANNEL_RC_OK;
    }
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) != 0
        || (response->common.msgFlags & CB_RESPONSE_OK) == 0) {
        return CHANNEL_RC_OK;
    }
    const auto text = decode_text(
        response->requestedFormatData,
        response->common.dataLen,
        *format_id);
    WLog_INFO(TAG,
              "Received client clipboard data: format=%" PRIu32 " bytes=%" PRIu32,
              *format_id,
              response->common.dataLen);
    if (!text.has_value() || !write_pasteboard(*text)) {
        return ERROR_INVALID_DATA;
    }

    const auto snapshot = read_pasteboard();
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
    std::unique_lock stop_lock(state->monitor_mutex);
    while (!state->stop_requested.load(std::memory_order_acquire)) {
        stop_lock.unlock();
        publish_if_changed(state, false);
        stop_lock.lock();
        state->monitor_cv.wait_for(
            stop_lock,
            std::chrono::milliseconds{250},
            [state] {
                return state->stop_requested.load(std::memory_order_acquire);
            });
    }
}

} // namespace

extern "C" BOOL macrdp_shadow_cliprdr_init(rdpShadowClient* client) {
    if (!g_clipboard_enabled.load(std::memory_order_acquire)) {
        return TRUE;
    }
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

extern "C" void macrdp_shadow_cliprdr_set_enabled(BOOL enabled) {
    g_clipboard_enabled.store(enabled != FALSE, std::memory_order_release);
}

extern "C" void macrdp_shadow_cliprdr_uninit(rdpShadowClient* client) {
    if (client == nullptr || client->cliprdr == nullptr) {
        return;
    }

    auto* context = client->cliprdr;
    auto* state = state_for(context);
    if (state != nullptr) {
        {
            std::lock_guard operation_lock(state->operation_mutex);
            state->stop_requested.store(true, std::memory_order_release);
            state->channel_ready = false;
            state->transfer.stop();
        }
        state->monitor_cv.notify_all();
        if (state->monitor_thread.joinable()) {
            state->monitor_thread.join();
        }
    }
    if (context->Stop != nullptr) {
        (void)context->Stop(context);
    }
    client->cliprdr = nullptr;
    context->custom = nullptr;
    cliprdr_server_context_free(context);
    delete state;
}
