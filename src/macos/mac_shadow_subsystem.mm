#include <freerdp/config.h>

#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>

#include <freerdp/input.h>
#include <freerdp/log.h>
#include <freerdp/server/shadow.h>
#include <winpr/input.h>
#include <winpr/synch.h>

#include "macrdp/display_capture.hpp"
#include "macrdp/display_topology.hpp"
#include "macrdp/input_ownership.hpp"
#include "macrdp/input_queue.hpp"
#include "macrdp/input_translation.hpp"
#include "macrdp/shadow_config.h"
#include "mac_shadow_subsystem.hpp"
#include "shadow_screen.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#define TAG SERVER_TAG("macrdp")

namespace {

struct CredentialConfig {
    std::string username;
    std::string domain;
    std::string password;
};

std::mutex g_credentials_mutex;
CredentialConfig g_credentials;

struct CaptureConfig {
    std::uint32_t display_id = 0;
    std::uint32_t max_width = 0;
    std::uint32_t max_height = 0;
    std::uint32_t frame_rate = 30;
    bool audio_enabled = true;
};

struct DisplaySessionGeometry {
    macrdp::DisplayGeometry display;
    std::uint64_t generation = 0;
    std::uint32_t surface_width = 0;
    std::uint32_t surface_height = 0;
};

std::mutex g_capture_config_mutex;
CaptureConfig g_capture_config;
std::atomic_bool g_input_enabled{true};
std::atomic_bool g_audio_enabled{true};

void clear_secret(std::string& value) {
    volatile char* data = value.empty() ? nullptr : value.data();
    for (std::size_t index = 0; data != nullptr && index < value.size(); ++index) {
        data[index] = '\0';
    }
    value.clear();
}

bool constant_time_equal(const std::string& expected, const char* actual) {
    if (actual == nullptr) {
        return expected.empty();
    }

    const std::size_t actual_size = std::strlen(actual);
    const std::size_t compared_size = std::max(expected.size(), actual_size);
    unsigned difference = static_cast<unsigned>(expected.size() ^ actual_size);
    for (std::size_t index = 0; index < compared_size; ++index) {
        const unsigned expected_byte = index < expected.size()
            ? static_cast<unsigned>(static_cast<unsigned char>(expected[index]))
            : 0U;
        const unsigned actual_byte = index < actual_size
            ? static_cast<unsigned>(static_cast<unsigned char>(actual[index]))
            : 0U;
        difference |= expected_byte ^ actual_byte;
    }
    return difference == 0;
}

enum class InputEventKind {
    synchronize,
    keyboard,
    unicode,
    mouse,
    extended_mouse,
    reset,
};

struct InputEvent {
    InputEventKind kind = InputEventKind::mouse;
    macrdp::InputClientId client_id = 0;
    UINT16 flags = 0;
    UINT16 code = 0;
    UINT32 synchronize_flags = 0;
    UINT16 x = 0;
    UINT16 y = 0;
    std::uint64_t display_generation = 0;
    std::chrono::steady_clock::time_point enqueued_at{};
};

struct mac_shadow_subsystem {
    rdpShadowSubsystem common{};
    std::unique_ptr<macrdp::DisplayCapture> capture;
    std::unique_ptr<macrdp::DisplayTopology> display_topology;
    std::thread capture_thread;
    std::thread publish_thread;
    std::thread audio_thread;
    std::atomic_bool stop_requested{false};
    std::mutex lifecycle_mutex;
    std::mutex capture_clients_mutex;
    std::condition_variable capture_clients_condition;
    std::unordered_set<const rdpShadowClient*> capture_clients;
    std::unordered_set<const rdpShadowClient*> suppressed_capture_clients;
    std::atomic<std::uint32_t> capture_client_count{0};
    std::atomic<std::uint32_t> capture_output_client_count{0};
    std::mutex display_commit_mutex;
    std::mutex display_geometry_mutex;
    std::optional<DisplaySessionGeometry> display_geometry;
    bool display_transitioning = true;
    bool selected_display_available = false;
    std::chrono::steady_clock::time_point last_topology_poll{};
    std::chrono::steady_clock::time_point last_missing_display_log{};
    std::mutex input_mutex;
    std::mutex input_queue_mutex;
    std::condition_variable input_queue_condition;
    std::condition_variable input_queue_space_condition;
    std::deque<InputEvent> input_queue;
    std::thread input_thread;
    CGEventSourceRef input_event_source = nullptr;
    bool input_enabled = true;
    std::atomic_bool input_stop_requested{false};
    macrdp::InputOwnership input_ownership;
    std::mutex client_ids_mutex;
    std::unordered_map<const rdpShadowClient*, macrdp::InputClientId> client_ids;
    macrdp::InputClientId next_client_id = 1;
    std::mutex pending_frame_mutex;
    std::condition_variable pending_frame_condition;
    std::optional<macrdp::Frame> pending_frame;
    std::string username;
    std::string domain;
    std::string password;
    CaptureConfig capture_config;
    bool left_button_down = false;
    bool right_button_down = false;
    bool other_button_down = false;
    bool x_button_1_down = false;
    bool x_button_2_down = false;
    std::int32_t pointer_x = 0;
    std::int32_t pointer_y = 0;
    std::uint32_t last_frame_width = 0;
    std::uint32_t last_frame_height = 0;
    std::uint32_t last_surface_width = 0;
    std::uint32_t last_surface_height = 0;
    std::chrono::steady_clock::time_point last_slow_frame_log{};
    std::chrono::steady_clock::time_point last_input_pipeline_log{};
    std::atomic_bool force_full_frame{true};
    std::atomic<std::uint64_t> captured_frames{0};
    std::atomic<std::uint64_t> coalesced_frames{0};
    std::atomic<std::uint64_t> published_frames{0};
    std::atomic<std::uint64_t> changed_frames{0};
    std::atomic<std::uint64_t> copied_bytes{0};
    std::atomic<std::uint64_t> capture_copied_bytes{0};
    std::atomic<std::uint64_t> dirty_region_frames{0};
    std::atomic<std::uint64_t> dirty_region_rects{0};
    std::atomic<std::uint64_t> full_copy_frames{0};
    std::atomic<std::uint64_t> full_copy_forced_frames{0};
    std::atomic<std::uint64_t> full_copy_no_metadata_frames{0};
    std::atomic<std::uint64_t> full_copy_scaled_frames{0};
    std::atomic<std::uint64_t> full_scan_frames{0};
    std::atomic<std::uint64_t> capture_copy_time_us_total{0};
    std::atomic<std::uint64_t> capture_copy_time_us_max{0};
    std::atomic<std::uint64_t> surface_copy_time_us_total{0};
    std::atomic<std::uint64_t> surface_copy_time_us_max{0};
    std::atomic<std::uint64_t> publish_wait_time_us_total{0};
    std::atomic<std::uint64_t> publish_wait_time_us_max{0};
    std::atomic<std::uint64_t> audio_captured_frames{0};
    std::atomic<std::uint64_t> audio_published_chunks{0};
    std::atomic<std::uint64_t> audio_delivered_clients{0};
    std::atomic<std::uint64_t> audio_dropped_frames{0};
    std::chrono::steady_clock::time_point last_pipeline_log{};
    std::chrono::steady_clock::time_point last_audio_log{};
    std::atomic<std::uint64_t> input_synchronize_events{0};
    std::atomic<std::uint64_t> input_keyboard_events{0};
    std::atomic<std::uint64_t> input_keyboard_repeats{0};
    std::atomic<std::uint64_t> input_keyboard_release_recoveries{0};
    std::atomic<std::uint64_t> input_keyboard_unmatched_releases{0};
    std::atomic<std::uint64_t> input_unicode_events{0};
    std::atomic<std::uint64_t> input_mouse_events{0};
    std::atomic<std::uint64_t> input_wheel_events{0};
    std::atomic<std::uint64_t> input_left_button_events{0};
    std::atomic<std::uint64_t> input_right_button_events{0};
    std::atomic<std::uint64_t> input_middle_button_events{0};
    std::atomic<std::uint64_t> input_drag_events{0};
    std::atomic<std::uint64_t> input_extended_mouse_events{0};
    std::atomic<std::uint64_t> input_injection_failures{0};
    std::atomic<std::uint64_t> input_events_processed{0};
    std::atomic<std::uint64_t> input_keyboard_events_processed{0};
    std::atomic<std::uint64_t> input_event_queue_delay_us_total{0};
    std::atomic<std::uint64_t> input_event_queue_delay_us_max{0};
    std::atomic<std::uint64_t> input_keyboard_queue_delay_us_total{0};
    std::atomic<std::uint64_t> input_keyboard_queue_delay_us_max{0};
    std::atomic<std::uint64_t> input_motion_coalesced{0};
    std::atomic<std::uint64_t> input_motion_dropped{0};
    std::atomic<std::uint64_t> input_stale_pointer_events{0};
    std::atomic<std::uint64_t> input_queue_wait_events{0};
    std::atomic<std::uint64_t> input_queue_wait_time_us_total{0};
    std::atomic<std::uint64_t> input_queue_wait_time_us_max{0};
    std::atomic<std::uint64_t> input_queue_max_depth{0};
};

using MacShadowSubsystem = struct mac_shadow_subsystem;

constexpr std::size_t kInputQueueLimit = 4096;
constexpr std::uint16_t kExtendedKeyIdentityBit = 0x0100U;
constexpr std::uint16_t kExtended1KeyIdentityBit = 0x0200U;

bool register_capture_client(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client) {
    if (subsystem == nullptr || client == nullptr) {
        return false;
    }

    std::lock_guard lock(subsystem->capture_clients_mutex);
    if (subsystem->capture_clients.contains(client)) {
        return true;
    }

    const bool first_client = subsystem->capture_clients.empty();
    if (first_client && subsystem->capture != nullptr && !subsystem->capture->start()) {
        WLog_ERR(TAG, "Unable to resume ScreenCaptureKit for a client: %s",
                 subsystem->capture->last_error().c_str());
        return false;
    }

    subsystem->capture_clients.insert(client);
    subsystem->capture_client_count.store(
        static_cast<std::uint32_t>(subsystem->capture_clients.size()),
        std::memory_order_release);
    subsystem->capture_output_client_count.store(
        static_cast<std::uint32_t>(
            subsystem->capture_clients.size() - subsystem->suppressed_capture_clients.size()),
        std::memory_order_release);
    if (subsystem->capture != nullptr) {
        subsystem->capture->set_video_enabled(true);
    }
    subsystem->force_full_frame.store(true, std::memory_order_release);
    subsystem->capture_clients_condition.notify_all();
    if (first_client && subsystem->capture != nullptr) {
        WLog_INFO(TAG, "Screen capture resumed for the first active client");
    }
    return true;
}

bool set_capture_client_suppressed(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client,
    bool suppressed) {
    if (subsystem == nullptr || client == nullptr) {
        return false;
    }

    std::lock_guard lock(subsystem->capture_clients_mutex);
    if (!subsystem->capture_clients.contains(client)) {
        return true;
    }
    const bool was_suppressed = subsystem->suppressed_capture_clients.contains(client);
    if (was_suppressed == suppressed) {
        return true;
    }

    const bool had_output_clients = subsystem->suppressed_capture_clients.size()
        < subsystem->capture_clients.size();
    if (suppressed) {
        subsystem->suppressed_capture_clients.insert(client);
    } else {
        subsystem->suppressed_capture_clients.erase(client);
    }
    const auto output_clients = static_cast<std::uint32_t>(
        subsystem->capture_clients.size() - subsystem->suppressed_capture_clients.size());
    subsystem->capture_output_client_count.store(output_clients, std::memory_order_release);
    if (subsystem->capture != nullptr) {
        subsystem->capture->set_video_enabled(output_clients != 0);
    }

    if (output_clients == 0) {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    } else if (!had_output_clients) {
        subsystem->force_full_frame.store(true, std::memory_order_release);
    }
    subsystem->capture_clients_condition.notify_all();
    if (output_clients == 0) {
        WLog_INFO(TAG, "Screen video paused: all clients suppressed output");
    } else if (!had_output_clients) {
        WLog_INFO(TAG, "Screen video resumed for an output client");
    }
    return true;
}

void unregister_capture_client(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client) {
    if (subsystem == nullptr || client == nullptr) {
        return;
    }

    std::lock_guard lock(subsystem->capture_clients_mutex);
    const bool had_output_clients = subsystem->suppressed_capture_clients.size()
        < subsystem->capture_clients.size();
    if (subsystem->capture_clients.erase(client) == 0) {
        return;
    }
    subsystem->suppressed_capture_clients.erase(client);
    subsystem->capture_client_count.store(
        static_cast<std::uint32_t>(subsystem->capture_clients.size()),
        std::memory_order_release);
    const auto output_clients = static_cast<std::uint32_t>(
        subsystem->capture_clients.size() - subsystem->suppressed_capture_clients.size());
    subsystem->capture_output_client_count.store(output_clients, std::memory_order_release);
    if (!subsystem->capture_clients.empty()) {
        if (subsystem->capture != nullptr) {
            subsystem->capture->set_video_enabled(output_clients != 0);
        }
        if (had_output_clients && output_clients == 0) {
            std::lock_guard frame_lock(subsystem->pending_frame_mutex);
            subsystem->pending_frame.reset();
            WLog_INFO(TAG, "Screen video paused: remaining clients suppressed output");
        }
        return;
    }

    if (subsystem->capture != nullptr) {
        subsystem->capture->stop();
    }
    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    }
    subsystem->capture_clients_condition.notify_all();
    WLog_INFO(TAG, "Screen capture paused: no active clients");
}

bool capture_has_clients(const MacShadowSubsystem* subsystem) {
    return subsystem != nullptr
        && subsystem->capture_client_count.load(std::memory_order_acquire) != 0;
}

bool capture_has_output_clients(const MacShadowSubsystem* subsystem) {
    return subsystem != nullptr
        && subsystem->capture_output_client_count.load(std::memory_order_acquire) != 0;
}

std::uint16_t keyboard_key_identity(UINT16 flags, UINT8 code) noexcept {
    return static_cast<std::uint16_t>(code)
        | ((flags & KBD_FLAGS_EXTENDED) != 0 ? kExtendedKeyIdentityBit : 0U)
        | ((flags & KBD_FLAGS_EXTENDED1) != 0 ? kExtended1KeyIdentityBit : 0U);
}

const char* keyboard_action(UINT16 flags) noexcept {
    return (flags & KBD_FLAGS_RELEASE) != 0 ? "up" : "down";
}

void record_atomic_max(
    std::atomic<std::uint64_t>& target,
    std::uint64_t value) noexcept {
    auto current = target.load(std::memory_order_relaxed);
    while (value > current
           && !target.compare_exchange_weak(
               current,
               value,
               std::memory_order_relaxed,
               std::memory_order_relaxed)) {
    }
}

macrdp::InputClientId register_input_client(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client) {
    if (subsystem == nullptr || client == nullptr) {
        return 0;
    }

    std::lock_guard lock(subsystem->client_ids_mutex);
    const auto existing = subsystem->client_ids.find(client);
    if (existing != subsystem->client_ids.end()) {
        return existing->second;
    }

    auto id = subsystem->next_client_id++;
    if (id == 0) {
        id = subsystem->next_client_id++;
    }
    subsystem->client_ids.emplace(client, id);
    return id;
}

macrdp::InputClientId input_client_id(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client) {
    if (subsystem == nullptr || client == nullptr) {
        return 0;
    }

    // Only ClientConnect creates ownership. A callback racing teardown must
    // not recreate state for a client that ClientDisconnect already removed.
    std::lock_guard lock(subsystem->client_ids_mutex);
    const auto existing = subsystem->client_ids.find(client);
    return existing == subsystem->client_ids.end() ? 0 : existing->second;
}

macrdp::InputClientId unregister_input_client(
    MacShadowSubsystem* subsystem,
    const rdpShadowClient* client) {
    if (subsystem == nullptr || client == nullptr) {
        return 0;
    }

    std::lock_guard lock(subsystem->client_ids_mutex);
    const auto existing = subsystem->client_ids.find(client);
    if (existing == subsystem->client_ids.end()) {
        return 0;
    }
    const auto id = existing->second;
    subsystem->client_ids.erase(existing);
    return id;
}

void free_pointer_position_message(UINT32, SHADOW_MSG_OUT* message) {
    std::free(message);
}

void publish_pointer_position(
    MacShadowSubsystem* subsystem,
    rdpShadowClient* source_client,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr || subsystem->common.server == nullptr) {
        return;
    }

    subsystem->common.pointerX = x;
    subsystem->common.pointerY = y;

    auto* server = subsystem->common.server;
    if (server->clients == nullptr) {
        return;
    }

    ArrayList_Lock(server->clients);
    for (std::size_t index = 0; index < ArrayList_Count(server->clients); ++index) {
        auto* client = static_cast<rdpShadowClient*>(ArrayList_GetItem(server->clients, index));
        if (client == nullptr || client == source_client) {
            continue;
        }

        auto* message = static_cast<SHADOW_MSG_OUT_POINTER_POSITION_UPDATE*>(
            std::calloc(1, sizeof(SHADOW_MSG_OUT_POINTER_POSITION_UPDATE)));
        if (message == nullptr) {
            WLog_WARN(TAG, "Unable to allocate RDP pointer position update");
            break;
        }

        message->common.Free = free_pointer_position_message;
        message->xPos = x;
        message->yPos = y;
        if (!shadow_client_post_msg(
                client,
                nullptr,
                SHADOW_MSG_OUT_POINTER_POSITION_UPDATE_ID,
                &message->common,
                nullptr)) {
            WLog_WARN(TAG, "Unable to post RDP pointer position update");
        }
    }
    ArrayList_Unlock(server->clients);
}

std::optional<DisplaySessionGeometry> display_session_geometry(
    const macrdp::DisplayTopologySnapshot& topology,
    const CaptureConfig& capture_config) {
    const auto* selected = macrdp::display_topology_select(
        topology,
        capture_config.display_id);
    if (selected == nullptr) {
        return std::nullopt;
    }
    const auto [surface_width, surface_height] = macrdp::display_capture_output_size(
        selected->pixel_width,
        selected->pixel_height,
        capture_config.max_width,
        capture_config.max_height);
    if (surface_width == 0 || surface_height == 0
        || surface_width > UINT16_MAX || surface_height > UINT16_MAX) {
        return std::nullopt;
    }
    return DisplaySessionGeometry{
        *selected,
        topology.generation,
        surface_width,
        surface_height,
    };
}

bool monitor_for_geometry(
    const DisplaySessionGeometry& geometry,
    MONITOR_DEF& monitor) {
    if (geometry.surface_width == 0 || geometry.surface_height == 0) {
        return false;
    }
    monitor.left = 0;
    monitor.top = 0;
    // FreeRDP monitor rectangles are inclusive; surface dimensions add 1.
    monitor.right = static_cast<INT32>(geometry.surface_width - 1);
    monitor.bottom = static_cast<INT32>(geometry.surface_height - 1);
    monitor.flags = 1;
    return true;
}

UINT32 mac_shadow_enum_monitors(MONITOR_DEF* monitors, UINT32 max_monitors) {
    CaptureConfig capture_config;
    {
        std::lock_guard lock(g_capture_config_mutex);
        capture_config = g_capture_config;
    }
    macrdp::DisplayTopology topology;
    if (!topology.start()) {
        return 0;
    }
    const auto snapshot = topology.snapshot();
    if (!snapshot.has_value()) {
        return 0;
    }
    const auto geometry = display_session_geometry(*snapshot, capture_config);
    if (!geometry.has_value()) {
        return 0;
    }

    if (monitors != nullptr && max_monitors > 0) {
        if (!monitor_for_geometry(*geometry, monitors[0])) {
            return 0;
        }
    }
    return 1;
}

std::pair<std::uint32_t, std::uint32_t> shadow_surface_dimensions(
    const MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || subsystem->common.server->surface == nullptr) {
        return {0, 0};
    }

    auto* surface = subsystem->common.server->surface;
    EnterCriticalSection(&surface->lock);
    const auto dimensions = std::pair{surface->width, surface->height};
    LeaveCriticalSection(&surface->lock);
    return dimensions;
}

macrdp::DisplayCaptureOptions capture_options_for_geometry(
    const MacShadowSubsystem* subsystem,
    const DisplaySessionGeometry& geometry) {
    macrdp::DisplayCaptureOptions options;
    options.display_id = geometry.display.id;
    options.display_generation = geometry.generation;
    options.native_width = geometry.display.pixel_width;
    options.native_height = geometry.display.pixel_height;
    options.max_width = geometry.surface_width;
    options.max_height = geometry.surface_height;
    options.frame_rate = subsystem->capture_config.frame_rate;
    options.show_cursor = false;
    options.capture_audio = subsystem->capture_config.audio_enabled;
    return options;
}

std::optional<CGPoint> display_point(
    MacShadowSubsystem* subsystem,
    UINT16 x,
    UINT16 y,
    bool allow_stale_geometry = false) {
    if (subsystem == nullptr) {
        return std::nullopt;
    }
    DisplaySessionGeometry geometry;
    {
        std::lock_guard lock(subsystem->display_geometry_mutex);
        if (!subsystem->display_geometry.has_value()
            || (!allow_stale_geometry
                && (subsystem->display_transitioning
                    || !subsystem->selected_display_available))) {
            return std::nullopt;
        }
        geometry = *subsystem->display_geometry;
    }
    const auto [point_x, point_y] = macrdp::display_capture_input_point(
        geometry.display.bounds,
        geometry.surface_width,
        geometry.surface_height,
        x,
        y);
    return CGPointMake(point_x, point_y);
}

std::optional<std::uint64_t> active_display_generation(
    MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr) {
        return std::nullopt;
    }
    std::lock_guard lock(subsystem->display_geometry_mutex);
    if (subsystem->display_transitioning
        || !subsystem->selected_display_available
        || !subsystem->display_geometry.has_value()) {
        return std::nullopt;
    }
    return subsystem->display_geometry->generation;
}

std::optional<CGKeyCode> mac_modifier_key_code(UINT16 flags, UINT8 code) {
    const bool extended = (flags & KBD_FLAGS_EXTENDED) != 0;
    const bool extended1 = (flags & KBD_FLAGS_EXTENDED1) != 0;

    // WinPR's generic Apple table has no reliable distinct entry for every
    // right-side modifier (notably right Control). These keys are physical
    // modifiers on macOS, so map their RDP scan-code locations explicitly.
    switch (code) {
        case 0x1D: // left/right Control
            if (!extended1) {
                return extended ? kVK_RightControl : kVK_Control;
            }
            break;
        case 0x2A: // left Shift
            if (!extended1) {
                return kVK_Shift;
            }
            break;
        case 0x36: // right Shift (and a few clients' extended variant)
            if (!extended1) {
                return kVK_RightShift;
            }
            break;
        case 0x38: // left/right Alt
            if (!extended1) {
                return extended ? kVK_RightOption : kVK_Option;
            }
            break;
        case 0x5B: // left Windows logo
            if (extended && !extended1) {
                return kVK_Command;
            }
            break;
        case 0x5C: // right Windows logo
            if (extended && !extended1) {
                return kVK_RightCommand;
            }
            break;
        default:
            break;
    }
    return std::nullopt;
}

std::optional<CGKeyCode> mac_key_code(UINT16 flags, UINT8 code) {
    if (const auto modifier = mac_modifier_key_code(flags, code);
        modifier.has_value()) {
        return modifier;
    }

    const bool extended = (flags & KBD_FLAGS_EXTENDED) != 0;
    UINT32 scan_code = code;
    if (extended) {
        scan_code |= KBDEXT;
    }

    UINT32 virtual_key = GetVirtualKeyCodeFromVirtualScanCode(scan_code, 4);
    if (virtual_key == VK_NONE) {
        return std::nullopt;
    }
    if (extended) {
        virtual_key |= KBDEXT;
    }
    const auto key_code = static_cast<CGKeyCode>(GetKeycodeFromVirtualKeyCode(
        virtual_key,
        WINPR_KEYCODE_TYPE_APPLE));
    // Apple keycode zero is the A key. A zero result for any other virtual
    // key means WinPR has no usable Apple mapping, not that the client sent A.
    if (key_code == 0 && virtual_key != VK_KEY_A) {
        return std::nullopt;
    }
    return key_code;
}

CGEventFlags remote_modifier_flags(const macrdp::InputOwnership& ownership) {
    CGEventFlags flags = 0;
    if (ownership.is_key_code_active(0x1DU)) {
        flags |= kCGEventFlagMaskControl;
    }
    if (ownership.is_key_code_active(0x2AU)
        || ownership.is_key_code_active(0x36U)) {
        flags |= kCGEventFlagMaskShift;
    }
    if (ownership.is_key_code_active(0x38U)) {
        flags |= kCGEventFlagMaskAlternate;
    }
    if (ownership.is_key_code_active(0x5BU)
        || ownership.is_key_code_active(0x5CU)) {
        flags |= kCGEventFlagMaskCommand;
    }
    return flags;
}

bool post_keyboard_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT8 code,
    bool autorepeat = false) {
    if (subsystem == nullptr) {
        return false;
    }

    const auto key_code = mac_key_code(flags, code);
    if (!key_code.has_value()) {
        WLog_WARN(TAG, "Ignoring unmapped keyboard event flags=0x%04" PRIx16
                       " code=0x%02" PRIx8,
                  flags,
                  code);
        return false;
    }

    // A missing RELEASE bit represents a key press, including the initial
    // press where KBD_FLAGS_DOWN is not set.
    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    // Reusing one private source across clients can leave its internal key
    // state latched even after CoreGraphics accepts the matching key-up. A
    // fresh private source preserves local-HID isolation without carrying
    // synthetic modifier state into the next keyboard event or client.
    CGEventSourceRef event_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (event_source == nullptr) {
        return false;
    }
    CGEventRef event = CGEventCreateKeyboardEvent(event_source, *key_code, key_down);
    if (event == nullptr) {
        CFRelease(event_source);
        return false;
    }

    // A private CoreGraphics source can retain stale device-dependent flags,
    // including SecondaryFn after a function-key release. Rebuild the remote
    // modifier flags from the ownership ledger so one key-up cannot reassert
    // a modifier released by an earlier event. Local physical modifiers remain
    // in the combined hardware state and are not part of this private source.
    const CGEventFlags source_event_flags = CGEventGetFlags(event);
    const CGEventFlags preserved_source_flags = source_event_flags
        & (kCGEventFlagMaskAlphaShift
           | kCGEventFlagMaskHelp
           | kCGEventFlagMaskNumericPad
           | kCGEventFlagMaskNonCoalesced);
    const CGEventFlags owned_modifier_flags =
        remote_modifier_flags(subsystem->input_ownership);
    const CGEventFlags posted_event_flags =
        preserved_source_flags | owned_modifier_flags;
    CGEventSetFlags(event, posted_event_flags);

    CGEventSetIntegerValueField(
        event,
        kCGKeyboardEventAutorepeat,
        autorepeat ? 1 : 0);
    WLog_DBG(TAG, "Keyboard event flags=0x%04" PRIx16 " code=0x%02" PRIx8
             " keycode=%u action=%s repeat=%u source_flags=0x%016" PRIx64
             " owned_modifier_flags=0x%016" PRIx64
             " posted_flags=0x%016" PRIx64,
             flags,
             code,
             static_cast<unsigned>(*key_code),
             key_down ? "down" : "up",
             autorepeat ? 1U : 0U,
             static_cast<std::uint64_t>(source_event_flags),
             static_cast<std::uint64_t>(owned_modifier_flags),
             static_cast<std::uint64_t>(posted_event_flags));
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    CFRelease(event_source);
    return true;
}

UINT16 release_flags_for_key_identity(std::uint16_t key_identity) {
    UINT16 flags = KBD_FLAGS_RELEASE;
    if ((key_identity & kExtendedKeyIdentityBit) != 0) {
        flags |= KBD_FLAGS_EXTENDED;
    }
    if ((key_identity & kExtended1KeyIdentityBit) != 0) {
        flags |= KBD_FLAGS_EXTENDED1;
    }
    return flags;
}

bool synchronize_toggle_keys(MacShadowSubsystem* subsystem, UINT32 flags) {
    if (subsystem == nullptr || subsystem->input_event_source == nullptr) {
        return false;
    }

    // Lock state is session-wide even though remote modifier and button state
    // remains isolated in the private event source.
    const CGEventFlags current_flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    bool success = true;

    const auto synchronize_key = [subsystem, &success](
                                    bool desired,
                                    bool current,
                                    UINT16 key_flags,
                                    UINT8 code) {
        if (desired == current) {
            return;
        }
        if (!post_keyboard_event(subsystem, key_flags, code)
            || !post_keyboard_event(
                subsystem,
                key_flags | KBD_FLAGS_RELEASE,
                code)) {
            success = false;
        }
    };

    synchronize_key(
        (flags & KBD_SYNC_CAPS_LOCK) != 0,
        (current_flags & kCGEventFlagMaskAlphaShift) != 0,
        0,
        RDP_SCANCODE_CODE(RDP_SCANCODE_CAPSLOCK));
    // CoreGraphics exposes no public Num Lock or Scroll Lock toggle-state
    // bits. kCGEventFlagMaskNumericPad only identifies keypad-originated
    // events; it is not Num Lock state. Synthesizing Keypad Clear from that
    // flag can toggle Fn on external Windows keyboards. Normal Num Lock and
    // Scroll Lock key events still pass through the keyboard path below.
    return success;
}

bool inject_keyboard_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT8 code) {
    if (subsystem == nullptr) {
        return false;
    }

    const auto key_identity = keyboard_key_identity(flags, code);
    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    WLog_DBG(TAG,
             "RDP keyboard dispatch: client=%" PRIu64
             " flags=0x%04" PRIx16 " code=0x%02" PRIx8
             " identity=0x%04" PRIx16 " action=%s repeat_flag=%u"
             " extended=%u extended1=%u",
             client_id,
             flags,
             code,
             key_identity,
             keyboard_action(flags),
             (flags & KBD_FLAGS_DOWN) != 0 ? 1U : 0U,
             (flags & KBD_FLAGS_EXTENDED) != 0 ? 1U : 0U,
             (flags & KBD_FLAGS_EXTENDED1) != 0 ? 1U : 0U);
    if (subsystem->input_ownership.consume_pause_sequence_event(
            client_id,
            key_identity,
            key_down)) {
        WLog_DBG(TAG,
                 "Suppressing RDP Pause sequence constituent: client=%" PRIu64
                 " identity=0x%04" PRIx16 " action=%s",
                 client_id,
                 key_identity,
                 keyboard_action(flags));
        return true;
    }
    if (!key_down) {
        // Match a release to the identity recorded for the key-down. Some
        // clients lose the E0/E1 marker while forwarding a key-up; dropping
        // that event leaves Command, Control, or Alt physically held.
        std::vector<std::uint16_t> release_candidates;
        if (const auto tracked_key = subsystem->input_ownership.find_key(
                client_id,
                key_identity);
            tracked_key.has_value()) {
            release_candidates.push_back(*tracked_key);
        } else {
            release_candidates = subsystem->input_ownership.find_keys_by_code(
                client_id,
                code);
        }

        if (release_candidates.empty()) {
            WLog_DBG(TAG, "Ignoring unmatched keyboard release client=%" PRIu64
                     " flags=0x%04" PRIx16 " code=0x%02" PRIx8,
                     client_id,
                     flags,
                     code);
            subsystem->input_keyboard_unmatched_releases.fetch_add(
                1,
                std::memory_order_relaxed);
            return true;
        }

        if (release_candidates.size() != 1 || release_candidates.front() != key_identity) {
            subsystem->input_keyboard_release_recoveries.fetch_add(
                1,
                std::memory_order_relaxed);
            WLog_DBG(TAG,
                     "Recovered keyboard release client=%" PRIu64
                     " flags=0x%04" PRIx16 " code=0x%02" PRIx8
                     " candidates=%zu",
                     client_id,
                     flags,
                     code,
                     release_candidates.size());
        }

        // If the E0/E1 prefix is ambiguous, release every matching identity
        // owned by this client. Releasing both sides is preferable to leaving
        // one global modifier held indefinitely.
        bool success = true;
        for (const auto release_identity : release_candidates) {
            if (!subsystem->input_ownership.release_key(client_id, release_identity)) {
                continue;
            }
            const auto release_code = static_cast<UINT8>(
                release_identity & UINT8_MAX);
            const bool posted = post_keyboard_event(
                subsystem,
                release_flags_for_key_identity(release_identity),
                release_code);
            if (!posted) {
                // Keep the ownership entry when the platform rejected the
                // key-up. The next matching release or client reset can then
                // retry the cleanup instead of losing the only recovery path.
                (void)subsystem->input_ownership.acquire_key(client_id, release_identity);
                success = false;
            }
        }
        return success;
    }

    if (subsystem->input_ownership.find_key(client_id, key_identity).has_value()) {
        if (!subsystem->input_ownership.is_key_exclusive(client_id, key_identity)) {
            return true;
        }
        // Slow-path input may mark a held key with KBD_FLAGS_DOWN, but
        // FastPath has no repeat bit and delivers another key-down instead.
        // Ownership makes that distinction without relying on the transport
        // encoding, so macOS can generate key repeat for both paths.
        subsystem->input_keyboard_repeats.fetch_add(1, std::memory_order_relaxed);
        return post_keyboard_event(subsystem, flags, code, true);
    }

    if (!subsystem->input_ownership.acquire_key(client_id, key_identity)) {
        return true;
    }
    const bool posted = post_keyboard_event(subsystem, flags, code);
    if (!posted) {
        // The ownership transition must describe the physical event state. If
        // CoreGraphics rejects the event, undo the transition so a later
        // retry is still allowed to post it.
        (void)subsystem->input_ownership.release_key(client_id, key_identity);
    }
    return posted;
}

bool post_unicode_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT16 code) {
    if (subsystem == nullptr || subsystem->input_event_source == nullptr) {
        return false;
    }

    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    CGEventRef event = CGEventCreateKeyboardEvent(
        subsystem->input_event_source,
        0,
        key_down);
    if (event == nullptr) {
        return false;
    }

    const UniChar character = static_cast<UniChar>(code);
    CGEventKeyboardSetUnicodeString(event, 1, &character);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    return true;
}

bool inject_unicode_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 code) {
    if (subsystem == nullptr) {
        return false;
    }

    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    const bool should_post = key_down
        ? subsystem->input_ownership.acquire_unicode(client_id, code)
        : subsystem->input_ownership.release_unicode(client_id, code);
    if (!should_post) {
        return true;
    }
    const bool posted = post_unicode_event(subsystem, flags, code);
    if (!posted) {
        if (key_down) {
            (void)subsystem->input_ownership.release_unicode(client_id, code);
        } else {
            (void)subsystem->input_ownership.acquire_unicode(client_id, code);
        }
    }
    return posted;
}

bool post_mouse_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr || subsystem->input_event_source == nullptr) {
        return false;
    }

    constexpr UINT16 button_mask = PTR_FLAGS_BUTTON1
        | PTR_FLAGS_BUTTON2 | PTR_FLAGS_BUTTON3;
    const bool button_release = (flags & button_mask) != 0
        && (flags & PTR_FLAGS_DOWN) == 0;
    const auto point = display_point(subsystem, x, y, button_release);
    if (!point.has_value()) {
        return false;
    }
    if ((flags & PTR_FLAGS_WHEEL) != 0 || (flags & PTR_FLAGS_HWHEEL) != 0) {
        const int signed_rotation = macrdp::decode_rdp_wheel_delta(flags) / 120;
        const int horizontal = (flags & PTR_FLAGS_HWHEEL) != 0
            ? signed_rotation
            : 0;
        const int vertical = (flags & PTR_FLAGS_HWHEEL) != 0
            ? 0
            : signed_rotation;
        CGEventRef event = CGEventCreateScrollWheelEvent(
            subsystem->input_event_source,
            kCGScrollEventUnitLine,
            2,
            vertical,
            horizontal);
        if (event == nullptr) {
            return false;
        }
        CGEventSetLocation(event, *point);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        return true;
    }

    if ((flags & PTR_FLAGS_MOVE) != 0) {
        CGMouseButton drag_button = kCGMouseButtonLeft;
        CGEventType move_type = kCGEventMouseMoved;
        if (subsystem->left_button_down) {
            move_type = kCGEventLeftMouseDragged;
            drag_button = kCGMouseButtonLeft;
        } else if (subsystem->right_button_down) {
            move_type = kCGEventRightMouseDragged;
            drag_button = kCGMouseButtonRight;
        } else if (subsystem->other_button_down) {
            move_type = kCGEventOtherMouseDragged;
            drag_button = kCGMouseButtonCenter;
        }

        CGEventRef event = CGEventCreateMouseEvent(
            subsystem->input_event_source,
            move_type,
            *point,
            drag_button);
        if (event != nullptr) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            return false;
        }
    }

    CGEventType button_type = kCGEventNull;
    CGMouseButton button = kCGMouseButtonLeft;
    if ((flags & PTR_FLAGS_BUTTON1) != 0) {
        button = kCGMouseButtonLeft;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventLeftMouseDown
            : kCGEventLeftMouseUp;
    } else if ((flags & PTR_FLAGS_BUTTON2) != 0) {
        button = kCGMouseButtonRight;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventRightMouseDown
            : kCGEventRightMouseUp;
    } else if ((flags & PTR_FLAGS_BUTTON3) != 0) {
        button = kCGMouseButtonCenter;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventOtherMouseDown
            : kCGEventOtherMouseUp;
    }

    if (button_type != kCGEventNull) {
        CGEventRef event = CGEventCreateMouseEvent(
            subsystem->input_event_source,
            button_type,
            *point,
            button);
        if (event == nullptr) {
            return false;
        }
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    return true;
}

bool inject_mouse_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr || subsystem->input_event_source == nullptr) {
        return false;
    }

    bool success = true;
    if ((flags & (PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL)) != 0) {
        return post_mouse_event(subsystem, flags, x, y);
    }
    if ((flags & PTR_FLAGS_MOVE) != 0) {
        const bool dragging = subsystem->left_button_down
            || subsystem->right_button_down
            || subsystem->other_button_down;
        if (!post_mouse_event(subsystem, PTR_FLAGS_MOVE, x, y)) {
            success = false;
        } else if (dragging) {
            subsystem->input_drag_events.fetch_add(1, std::memory_order_relaxed);
        }
    }

    macrdp::InputButton button = macrdp::InputButton::left;
    bool has_button = false;
    if ((flags & PTR_FLAGS_BUTTON1) != 0) {
        button = macrdp::InputButton::left;
        has_button = true;
    } else if ((flags & PTR_FLAGS_BUTTON2) != 0) {
        button = macrdp::InputButton::right;
        has_button = true;
    } else if ((flags & PTR_FLAGS_BUTTON3) != 0) {
        button = macrdp::InputButton::other;
        has_button = true;
    }
    if (!has_button) {
        return success;
    }

    const bool down = (flags & PTR_FLAGS_DOWN) != 0;
    const bool should_post = down
        ? subsystem->input_ownership.acquire_button(client_id, button)
        : subsystem->input_ownership.release_button(client_id, button);
    if (should_post) {
        if (button == macrdp::InputButton::left) {
            subsystem->left_button_down = down;
        } else if (button == macrdp::InputButton::right) {
            subsystem->right_button_down = down;
        } else {
            subsystem->other_button_down = down;
        }
        const auto button_flags = static_cast<UINT16>(flags & ~PTR_FLAGS_MOVE);
        if (!post_mouse_event(subsystem, button_flags, x, y)) {
            if (down) {
                (void)subsystem->input_ownership.release_button(client_id, button);
            } else {
                (void)subsystem->input_ownership.acquire_button(client_id, button);
            }
            if (button == macrdp::InputButton::left) {
                subsystem->left_button_down = !down;
            } else if (button == macrdp::InputButton::right) {
                subsystem->right_button_down = !down;
            } else {
                subsystem->other_button_down = !down;
            }
            success = false;
        }
    }
    return success;
}

bool post_extended_mouse_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr || subsystem->input_event_source == nullptr) {
        return false;
    }

    const bool button_release = (flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2)) != 0
        && (flags & PTR_XFLAGS_DOWN) == 0;
    const auto point = display_point(subsystem, x, y, button_release);
    if (!point.has_value()) {
        return false;
    }
    const bool down = (flags & PTR_XFLAGS_DOWN) != 0;
    const UINT16 button_flags = flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2);
    if (button_flags == 0) {
        return true;
    }

    const bool button_1 = (button_flags & PTR_XFLAGS_BUTTON1) != 0;
    const CGMouseButton button = static_cast<CGMouseButton>(button_1 ? 3 : 4);
    CGEventRef event = CGEventCreateMouseEvent(
        subsystem->input_event_source,
        down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp,
        *point,
        button);
    if (event == nullptr) {
        return false;
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    return true;
}

bool inject_extended_mouse_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
        return false;
    }

    const UINT16 button_flags = flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2);
    if (button_flags == 0) {
        return true;
    }

    const bool button_1 = (button_flags & PTR_XFLAGS_BUTTON1) != 0;
    const auto button = button_1
        ? macrdp::InputButton::x1
        : macrdp::InputButton::x2;
    const bool down = (flags & PTR_XFLAGS_DOWN) != 0;
    const bool should_post = down
        ? subsystem->input_ownership.acquire_button(client_id, button)
        : subsystem->input_ownership.release_button(client_id, button);
    if (!should_post) {
        return true;
    }

    if (button_1) {
        subsystem->x_button_1_down = down;
    } else {
        subsystem->x_button_2_down = down;
    }
    const bool posted = post_extended_mouse_event(subsystem, flags, x, y);
    if (!posted) {
        if (down) {
            (void)subsystem->input_ownership.release_button(client_id, button);
        } else {
            (void)subsystem->input_ownership.acquire_button(client_id, button);
        }
        if (button_1) {
            subsystem->x_button_1_down = !down;
        } else {
            subsystem->x_button_2_down = !down;
        }
    }
    return posted;
}

bool is_coalescible_mouse_move(const InputEvent& event) {
    constexpr UINT16 non_move_flags = PTR_FLAGS_BUTTON1 | PTR_FLAGS_BUTTON2
        | PTR_FLAGS_BUTTON3 | PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL;
    return event.kind == InputEventKind::mouse
        && (event.flags & PTR_FLAGS_MOVE) != 0
        && (event.flags & non_move_flags) == 0;
}

bool enqueue_input_event(MacShadowSubsystem* subsystem, InputEvent event) {
    if (subsystem == nullptr) {
        return false;
    }

    std::unique_lock lock(subsystem->input_queue_mutex);
    if (subsystem->input_stop_requested.load()) {
        return false;
    }

    // Mouse motion is the only input that is safe to discard. Replace a
    // pending motion with the newest point instead of letting it build
    // latency behind clicks and keystrokes.
    if (is_coalescible_mouse_move(event)) {
        event.enqueued_at = std::chrono::steady_clock::now();
        if (macrdp::replace_trailing_coalescible(
                subsystem->input_queue,
                event,
                is_coalescible_mouse_move)) {
            subsystem->input_motion_coalesced.fetch_add(1, std::memory_order_relaxed);
            lock.unlock();
            subsystem->input_queue_condition.notify_one();
            return true;
        }
        if (subsystem->input_queue.size() >= kInputQueueLimit) {
            subsystem->input_motion_dropped.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
    } else {
        // Motion is disposable, so remove queued motion before applying
        // backpressure to a click, wheel, keyboard, or reset event. This keeps
        // control input responsive when the platform injector is temporarily
        // slower than the RDP client.
        if (subsystem->input_queue.size() >= kInputQueueLimit) {
            const auto discarded = macrdp::discard_coalescible(
                subsystem->input_queue,
                is_coalescible_mouse_move);
            if (discarded > 0) {
                subsystem->input_motion_dropped.fetch_add(
                    discarded,
                    std::memory_order_relaxed);
            }
        }

        // Preserve clicks, button transitions, wheel events, and keyboard
        // input. Under pathological input pressure, briefly apply backpressure
        // to the protocol callback instead of silently losing a user action.
        const auto wait_started = std::chrono::steady_clock::now();
        const auto was_full = subsystem->input_queue.size() >= kInputQueueLimit;
        subsystem->input_queue_space_condition.wait(lock, [subsystem] {
            return subsystem->input_stop_requested.load()
                || subsystem->input_queue.size() < kInputQueueLimit;
        });
        if (subsystem->input_stop_requested.load()) {
            return false;
        }
        if (was_full) {
            const auto wait_elapsed_us = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - wait_started)
                    .count());
            subsystem->input_queue_wait_events.fetch_add(1, std::memory_order_relaxed);
            subsystem->input_queue_wait_time_us_total.fetch_add(
                wait_elapsed_us,
                std::memory_order_relaxed);
            record_atomic_max(subsystem->input_queue_wait_time_us_max, wait_elapsed_us);
        }
    }
    event.enqueued_at = std::chrono::steady_clock::now();
    subsystem->input_queue.push_back(event);
    record_atomic_max(
        subsystem->input_queue_max_depth,
        static_cast<std::uint64_t>(subsystem->input_queue.size()));
    lock.unlock();
    subsystem->input_queue_condition.notify_one();
    return true;
}

bool queue_keyboard_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT8 code) {
    if (subsystem == nullptr) {
        return false;
    }
    if (client_id == 0) {
        return true;
    }
    InputEvent event;
    event.kind = InputEventKind::keyboard;
    event.client_id = client_id;
    event.flags = flags;
    event.code = code;
    WLog_DBG(TAG,
             "RDP keyboard received: client=%" PRIu64
             " flags=0x%04" PRIx16 " code=0x%02" PRIx8
             " identity=0x%04" PRIx16 " action=%s repeat_flag=%u"
             " extended=%u extended1=%u",
             client_id,
             flags,
             code,
             keyboard_key_identity(flags, code),
             keyboard_action(flags),
             (flags & KBD_FLAGS_DOWN) != 0 ? 1U : 0U,
             (flags & KBD_FLAGS_EXTENDED) != 0 ? 1U : 0U,
             (flags & KBD_FLAGS_EXTENDED1) != 0 ? 1U : 0U);
    subsystem->input_keyboard_events.fetch_add(1, std::memory_order_relaxed);
    return enqueue_input_event(subsystem, event);
}

bool queue_unicode_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 code) {
    if (subsystem == nullptr) {
        return false;
    }
    if (client_id == 0) {
        return true;
    }
    InputEvent event;
    event.kind = InputEventKind::unicode;
    event.client_id = client_id;
    event.flags = flags;
    event.code = code;
    subsystem->input_unicode_events.fetch_add(1, std::memory_order_relaxed);
    return enqueue_input_event(subsystem, event);
}

bool queue_synchronize_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT32 flags) {
    if (subsystem == nullptr) {
        return false;
    }
    if (client_id == 0) {
        return true;
    }
    InputEvent event;
    event.kind = InputEventKind::synchronize;
    event.client_id = client_id;
    event.synchronize_flags = flags;
    subsystem->input_synchronize_events.fetch_add(1, std::memory_order_relaxed);
    return enqueue_input_event(subsystem, event);
}

bool queue_mouse_event(
    MacShadowSubsystem* subsystem,
    rdpShadowClient* source_client,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
        return false;
    }
    if (client_id == 0) {
        return true;
    }
    {
        std::lock_guard lock(subsystem->input_mutex);
        subsystem->pointer_x = x;
        subsystem->pointer_y = y;
    }
    publish_pointer_position(subsystem, source_client, x, y);

    constexpr UINT16 button_mask = PTR_FLAGS_BUTTON1
        | PTR_FLAGS_BUTTON2 | PTR_FLAGS_BUTTON3;
    const bool button_release = (flags & button_mask) != 0
        && (flags & PTR_FLAGS_DOWN) == 0;
    const auto display_generation = active_display_generation(subsystem);
    if (!display_generation.has_value() && !button_release) {
        subsystem->input_stale_pointer_events.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    InputEvent event;
    event.kind = InputEventKind::mouse;
    event.client_id = client_id;
    event.flags = flags;
    event.x = x;
    event.y = y;
    event.display_generation = display_generation.value_or(0);
    subsystem->input_mouse_events.fetch_add(1, std::memory_order_relaxed);
    if ((flags & (PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL)) != 0) {
        subsystem->input_wheel_events.fetch_add(1, std::memory_order_relaxed);
    }
    if ((flags & PTR_FLAGS_BUTTON1) != 0) {
        subsystem->input_left_button_events.fetch_add(1, std::memory_order_relaxed);
    }
    if ((flags & PTR_FLAGS_BUTTON2) != 0) {
        subsystem->input_right_button_events.fetch_add(1, std::memory_order_relaxed);
    }
    if ((flags & PTR_FLAGS_BUTTON3) != 0) {
        subsystem->input_middle_button_events.fetch_add(1, std::memory_order_relaxed);
    }
    return enqueue_input_event(subsystem, event);
}

bool queue_extended_mouse_event(
    MacShadowSubsystem* subsystem,
    rdpShadowClient* source_client,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
        return false;
    }
    if (client_id == 0) {
        return true;
    }
    {
        std::lock_guard lock(subsystem->input_mutex);
        subsystem->pointer_x = x;
        subsystem->pointer_y = y;
    }
    publish_pointer_position(subsystem, source_client, x, y);

    const bool button_release = (flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2)) != 0
        && (flags & PTR_XFLAGS_DOWN) == 0;
    const auto display_generation = active_display_generation(subsystem);
    if (!display_generation.has_value() && !button_release) {
        subsystem->input_stale_pointer_events.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    InputEvent event;
    event.kind = InputEventKind::extended_mouse;
    event.client_id = client_id;
    event.flags = flags;
    event.x = x;
    event.y = y;
    event.display_generation = display_generation.value_or(0);
    subsystem->input_extended_mouse_events.fetch_add(1, std::memory_order_relaxed);
    return enqueue_input_event(subsystem, event);
}

bool queue_input_reset(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id) {
    if (subsystem == nullptr) {
        return false;
    }

    InputEvent event;
    event.kind = InputEventKind::reset;
    event.client_id = client_id;

    std::unique_lock lock(subsystem->input_queue_mutex);
    if (subsystem->input_stop_requested.load()) {
        return false;
    }

    macrdp::prioritize_client_reset(subsystem->input_queue, client_id, event);
    lock.unlock();
    subsystem->input_queue_condition.notify_one();
    subsystem->input_queue_space_condition.notify_all();
    return true;
}

void emit_release_state(
    MacShadowSubsystem* subsystem,
    const macrdp::InputReleaseState& released) {
    if (subsystem == nullptr) {
        return;
    }

    UINT16 pointer_x = 0;
    UINT16 pointer_y = 0;
    {
        std::lock_guard lock(subsystem->input_mutex);
        pointer_x = static_cast<UINT16>(std::clamp<std::int32_t>(
            subsystem->pointer_x,
            0,
            UINT16_MAX));
        pointer_y = static_cast<UINT16>(std::clamp<std::int32_t>(
            subsystem->pointer_y,
            0,
            UINT16_MAX));
    }

    for (const auto key_identity : released.keys) {
        (void)post_keyboard_event(
            subsystem,
            release_flags_for_key_identity(key_identity),
            static_cast<UINT8>(key_identity & UINT8_MAX));
    }
    for (const auto code : released.unicode) {
        (void)post_unicode_event(subsystem, KBD_FLAGS_RELEASE, code);
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::left)]) {
        (void)post_mouse_event(subsystem, PTR_FLAGS_BUTTON1, pointer_x, pointer_y);
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::right)]) {
        (void)post_mouse_event(subsystem, PTR_FLAGS_BUTTON2, pointer_x, pointer_y);
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::other)]) {
        (void)post_mouse_event(subsystem, PTR_FLAGS_BUTTON3, pointer_x, pointer_y);
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::x1)]) {
        (void)post_extended_mouse_event(
            subsystem, PTR_XFLAGS_BUTTON1, pointer_x, pointer_y);
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::x2)]) {
        (void)post_extended_mouse_event(
            subsystem, PTR_XFLAGS_BUTTON2, pointer_x, pointer_y);
    }
}

void release_input_state_for_client(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id) {
    if (subsystem == nullptr) {
        return;
    }
    const auto released = subsystem->input_ownership.release_client(client_id);
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::left)]) {
        subsystem->left_button_down = false;
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::right)]) {
        subsystem->right_button_down = false;
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::other)]) {
        subsystem->other_button_down = false;
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::x1)]) {
        subsystem->x_button_1_down = false;
    }
    if (released.buttons[static_cast<std::size_t>(macrdp::InputButton::x2)]) {
        subsystem->x_button_2_down = false;
    }
    const auto released_buttons = static_cast<unsigned>(std::count(
        released.buttons.begin(),
        released.buttons.end(),
        true));
    WLog_INFO(TAG,
              "Input state reset: client=%" PRIu64 " keys=%zu unicode=%zu buttons=%u",
              client_id,
              released.keys.size(),
              released.unicode.size(),
              released_buttons);
    emit_release_state(subsystem, released);
}

void release_input_state(MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr) {
        return;
    }
    const auto released = subsystem->input_ownership.release_all();
    subsystem->left_button_down = false;
    subsystem->right_button_down = false;
    subsystem->other_button_down = false;
    subsystem->x_button_1_down = false;
    subsystem->x_button_2_down = false;
    const auto released_buttons = static_cast<unsigned>(std::count(
        released.buttons.begin(),
        released.buttons.end(),
        true));
    WLog_INFO(TAG,
              "Input state reset: client=all keys=%zu unicode=%zu buttons=%u",
              released.keys.size(),
              released.unicode.size(),
              released_buttons);
    emit_release_state(subsystem, released);
}

void log_input_pipeline(MacShadowSubsystem* subsystem, bool force) {
    if (subsystem == nullptr) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    if (!force
        && subsystem->last_input_pipeline_log
                != std::chrono::steady_clock::time_point{}
        && now - subsystem->last_input_pipeline_log < std::chrono::seconds(1)) {
        return;
    }
    subsystem->last_input_pipeline_log = now;
    std::size_t input_queue_depth = 0;
    {
        std::lock_guard lock(subsystem->input_queue_mutex);
        input_queue_depth = subsystem->input_queue.size();
    }
    const auto queue_wait_events = subsystem->input_queue_wait_events.load(
        std::memory_order_relaxed);
    const auto queue_wait_average_us = queue_wait_events == 0
        ? 0
        : subsystem->input_queue_wait_time_us_total.load(std::memory_order_relaxed)
            / queue_wait_events;
    const auto events_processed = subsystem->input_events_processed.load(
        std::memory_order_relaxed);
    const auto event_queue_delay_average_us = events_processed == 0
        ? 0
        : subsystem->input_event_queue_delay_us_total.load(std::memory_order_relaxed)
            / events_processed;
    const auto keyboard_events_processed = subsystem->input_keyboard_events_processed.load(
        std::memory_order_relaxed);
    const auto keyboard_queue_delay_average_us = keyboard_events_processed == 0
        ? 0
        : subsystem->input_keyboard_queue_delay_us_total.load(std::memory_order_relaxed)
            / keyboard_events_processed;
    WLog_INFO(
        TAG,
        "Input pipeline: synchronize=%" PRIu64 " keyboard=%" PRIu64
        " keyboard_repeats=%" PRIu64
        " keyboard_release_recoveries=%" PRIu64
        " keyboard_unmatched_releases=%" PRIu64 " unicode=%" PRIu64
        " mouse=%" PRIu64 " wheel=%" PRIu64
        " left_button=%" PRIu64 " right_button=%" PRIu64
        " middle_button=%" PRIu64 " drag=%" PRIu64
        " extended_mouse=%" PRIu64 " injection_failures=%" PRIu64
        " queue_depth=%" PRIuz " queue_max=%" PRIu64
        " motion_coalesced=%" PRIu64 " motion_dropped=%" PRIu64
        " stale_pointer=%" PRIu64
        " queue_wait_events=%" PRIu64 " queue_wait_avg_us=%" PRIu64
        " queue_wait_max_us=%" PRIu64
        " processed=%" PRIu64
        " event_queue_delay_avg_us=%" PRIu64
        " event_queue_delay_max_us=%" PRIu64
        " keyboard_queue_delay_avg_us=%" PRIu64
        " keyboard_queue_delay_max_us=%" PRIu64,
        subsystem->input_synchronize_events.load(std::memory_order_relaxed),
        subsystem->input_keyboard_events.load(std::memory_order_relaxed),
        subsystem->input_keyboard_repeats.load(std::memory_order_relaxed),
        subsystem->input_keyboard_release_recoveries.load(std::memory_order_relaxed),
        subsystem->input_keyboard_unmatched_releases.load(std::memory_order_relaxed),
        subsystem->input_unicode_events.load(std::memory_order_relaxed),
        subsystem->input_mouse_events.load(std::memory_order_relaxed),
        subsystem->input_wheel_events.load(std::memory_order_relaxed),
        subsystem->input_left_button_events.load(std::memory_order_relaxed),
        subsystem->input_right_button_events.load(std::memory_order_relaxed),
        subsystem->input_middle_button_events.load(std::memory_order_relaxed),
        subsystem->input_drag_events.load(std::memory_order_relaxed),
        subsystem->input_extended_mouse_events.load(std::memory_order_relaxed),
        subsystem->input_injection_failures.load(std::memory_order_relaxed),
        input_queue_depth,
        subsystem->input_queue_max_depth.load(std::memory_order_relaxed),
        subsystem->input_motion_coalesced.load(std::memory_order_relaxed),
        subsystem->input_motion_dropped.load(std::memory_order_relaxed),
        subsystem->input_stale_pointer_events.load(std::memory_order_relaxed),
        queue_wait_events,
        queue_wait_average_us,
        subsystem->input_queue_wait_time_us_max.load(std::memory_order_relaxed),
        events_processed,
        event_queue_delay_average_us,
        subsystem->input_event_queue_delay_us_max.load(std::memory_order_relaxed),
        keyboard_queue_delay_average_us,
        subsystem->input_keyboard_queue_delay_us_max.load(std::memory_order_relaxed));
}

void input_loop(MacShadowSubsystem* subsystem) {
    while (true) {
        InputEvent event;
        {
            std::unique_lock lock(subsystem->input_queue_mutex);
            subsystem->input_queue_condition.wait(lock, [subsystem] {
                return subsystem->input_stop_requested.load()
                    || !subsystem->input_queue.empty();
            });
            if (subsystem->input_queue.empty()) {
                if (subsystem->input_stop_requested.load()) {
                    break;
                }
                continue;
            }
            event = subsystem->input_queue.front();
            subsystem->input_queue.pop_front();
        }
        subsystem->input_queue_space_condition.notify_one();

        const auto dequeued_at = std::chrono::steady_clock::now();
        std::uint64_t queue_delay_us = 0;
        if (event.enqueued_at != std::chrono::steady_clock::time_point{}) {
            queue_delay_us = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    dequeued_at - event.enqueued_at)
                    .count());
            subsystem->input_events_processed.fetch_add(1, std::memory_order_relaxed);
            subsystem->input_event_queue_delay_us_total.fetch_add(
                queue_delay_us,
                std::memory_order_relaxed);
            record_atomic_max(subsystem->input_event_queue_delay_us_max, queue_delay_us);
            if (event.kind == InputEventKind::keyboard) {
                subsystem->input_keyboard_events_processed.fetch_add(
                    1,
                    std::memory_order_relaxed);
                subsystem->input_keyboard_queue_delay_us_total.fetch_add(
                    queue_delay_us,
                    std::memory_order_relaxed);
                record_atomic_max(
                    subsystem->input_keyboard_queue_delay_us_max,
                    queue_delay_us);
                WLog_DBG(TAG,
                         "RDP keyboard queued delay: client=%" PRIu64
                         " flags=0x%04" PRIx16 " code=0x%02" PRIx16
                         " action=%s queue_delay_us=%" PRIu64,
                         event.client_id,
                         event.flags,
                         event.code,
                         keyboard_action(event.flags),
                         queue_delay_us);
            }
        }

        const bool pointer_event = event.kind == InputEventKind::mouse
            || event.kind == InputEventKind::extended_mouse;
        const bool pointer_release = event.kind == InputEventKind::mouse
            ? (event.flags & (PTR_FLAGS_BUTTON1 | PTR_FLAGS_BUTTON2 | PTR_FLAGS_BUTTON3)) != 0
                && (event.flags & PTR_FLAGS_DOWN) == 0
            : event.kind == InputEventKind::extended_mouse
                && (event.flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2)) != 0
                && (event.flags & PTR_XFLAGS_DOWN) == 0;
        const auto current_display_generation = pointer_event
            ? active_display_generation(subsystem)
            : std::nullopt;
        if (pointer_event && !pointer_release
            && (!current_display_generation.has_value()
                || event.display_generation != *current_display_generation)) {
            subsystem->input_stale_pointer_events.fetch_add(1, std::memory_order_relaxed);
            log_input_pipeline(subsystem, false);
            continue;
        }

        bool injected = false;
        switch (event.kind) {
            case InputEventKind::synchronize:
                injected = synchronize_toggle_keys(
                    subsystem,
                    event.synchronize_flags);
                break;
            case InputEventKind::keyboard:
                injected = inject_keyboard_event(
                    subsystem,
                    event.client_id,
                    event.flags,
                    static_cast<UINT8>(event.code));
                break;
            case InputEventKind::unicode:
                injected = inject_unicode_event(
                    subsystem, event.client_id, event.flags, event.code);
                break;
            case InputEventKind::mouse:
                injected = inject_mouse_event(
                    subsystem, event.client_id, event.flags, event.x, event.y);
                break;
            case InputEventKind::extended_mouse:
                injected = inject_extended_mouse_event(
                    subsystem, event.client_id, event.flags, event.x, event.y);
                break;
            case InputEventKind::reset:
                release_input_state_for_client(subsystem, event.client_id);
                injected = true;
                break;
        }
        if (!injected) {
            subsystem->input_injection_failures.fetch_add(1, std::memory_order_relaxed);
            WLog_WARN(TAG, "Failed to inject queued macOS input event");
        }
        log_input_pipeline(subsystem, false);
    }
    release_input_state(subsystem);
    log_input_pipeline(subsystem, true);
}

bool copy_frame_to_surface(MacShadowSubsystem* subsystem, const macrdp::Frame& frame) {
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || subsystem->common.server->surface == nullptr || !frame.valid()) {
        return false;
    }
    std::lock_guard commit_lock(subsystem->display_commit_mutex);
    {
        std::lock_guard lock(subsystem->display_geometry_mutex);
        if (subsystem->display_transitioning
            || !subsystem->display_geometry.has_value()
            || frame.display_generation != subsystem->display_geometry->generation) {
            // A topology transition can leave one old frame in the downstream
            // newest-frame slot. It is valid capture data, but no longer valid
            // for the committed RDP surface and input geometry.
            return true;
        }
    }

    rdpShadowSurface* surface = subsystem->common.server->surface;
    const auto copy_started = std::chrono::steady_clock::now();
    EnterCriticalSection(&surface->lock);
    const auto surface_width = surface->width;
    const auto surface_height = surface->height;
    if (surface_width == 0 || surface_height == 0
        || surface_width > UINT16_MAX || surface_height > UINT16_MAX
        || surface->data == nullptr
        || surface->scanline < static_cast<UINT32>(surface_width) * 4) {
        LeaveCriticalSection(&surface->lock);
        return false;
    }
    if (frame.width != subsystem->last_frame_width
        || frame.height != subsystem->last_frame_height
        || surface_width != subsystem->last_surface_width
        || surface_height != subsystem->last_surface_height) {
        WLog_INFO(TAG, "Capture frame %ux%u, RDP surface %ux%u",
                  frame.width, frame.height, surface_width, surface_height);
        subsystem->last_frame_width = frame.width;
        subsystem->last_frame_height = frame.height;
        subsystem->last_surface_width = surface_width;
        subsystem->last_surface_height = surface_height;
    }

    bool changed = false;
    bool copy_succeeded = true;
    std::uint64_t copied_bytes = 0;
    std::uint64_t copied_dirty_rects = 0;
    bool used_dirty_regions = false;
    bool full_copy_forced = false;
    bool full_copy_no_metadata = false;
    bool full_copy_scaled = false;
    bool full_scan = false;
    const bool matching_dimensions = frame.width == surface->width
        && frame.height == surface->height;
    const bool force_full_copy = subsystem->force_full_frame.load(std::memory_order_acquire);
    if (matching_dimensions && !force_full_copy && !frame.dirty_rects.empty()) {
        used_dirty_regions = true;
        // ScreenCaptureKit supplies complete frames but also identifies the
        // portions that changed. Keep the surface copy proportional to that
        // metadata and let the RDP layer carry the exact invalid region.
        for (const auto& frame_rect : frame.dirty_rects) {
            const auto left = std::min(frame_rect.left, surface->width);
            const auto top = std::min(frame_rect.top, surface->height);
            const auto right = std::min(frame_rect.right, surface->width);
            const auto bottom = std::min(frame_rect.bottom, surface->height);
            if (left >= right || top >= bottom) {
                continue;
            }

            for (std::uint32_t y = top; y < bottom; ++y) {
                auto* destination = surface->data
                    + static_cast<std::size_t>(y) * surface->scanline
                    + static_cast<std::size_t>(left) * 4;
                const auto* source = frame.bgra.data()
                    + static_cast<std::size_t>(y) * frame.stride
                    + static_cast<std::size_t>(left) * 4;
                std::memcpy(
                    destination,
                    source,
                    static_cast<std::size_t>(right - left) * 4);
                copied_bytes += static_cast<std::uint64_t>(right - left) * 4;
            }
            ++copied_dirty_rects;

            RECTANGLE_16 dirty{};
            dirty.left = static_cast<UINT16>(left);
            dirty.top = static_cast<UINT16>(top);
            dirty.right = static_cast<UINT16>(right);
            dirty.bottom = static_cast<UINT16>(bottom);
            if (!region16_union_rect(
                    &surface->invalidRegion,
                    &surface->invalidRegion,
                    &dirty)) {
                copy_succeeded = false;
                break;
            }
            changed = true;
        }
    } else if (matching_dimensions) {
        if (force_full_copy) {
            changed = true;
            full_copy_forced = true;
        } else {
            full_scan = true;
            for (std::uint32_t y = 0; y < surface->height; ++y) {
                auto* destination = surface->data + y * surface->scanline;
                const auto* source = frame.bgra.data() + y * frame.stride;
                if (std::memcmp(destination, source, static_cast<std::size_t>(surface->width) * 4)
                    != 0) {
                    changed = true;
                    break;
                }
            }
        }
        if (changed) {
            full_copy_no_metadata = !force_full_copy;
            for (std::uint32_t y = 0; y < surface->height; ++y) {
                auto* destination = surface->data + y * surface->scanline;
                const auto* source = frame.bgra.data() + y * frame.stride;
                std::memcpy(
                    destination,
                    source,
                    static_cast<std::size_t>(surface->width) * 4);
            }
            copied_bytes = static_cast<std::uint64_t>(surface->width) * surface->height * 4;
        }
    } else {
        full_copy_scaled = true;
        // ScreenCaptureKit and RDP may use different Retina coordinate spaces.
        // Resample into the framebuffer dimensions instead of rejecting a valid
        // capture when the display mode changes.
        changed = force_full_copy;
        for (std::uint32_t y = 0; y < surface->height; ++y) {
            const auto source_y = std::min<std::uint32_t>(
                frame.height - 1,
                static_cast<std::uint64_t>(y) * frame.height / surface->height);
            auto* destination = surface->data + y * surface->scanline;
            const auto* source_row = frame.bgra.data() + source_y * frame.stride;
            for (std::uint32_t x = 0; x < surface->width; ++x) {
                const auto source_x = std::min<std::uint32_t>(
                    frame.width - 1,
                    static_cast<std::uint64_t>(x) * frame.width / surface->width);
                const auto* source = source_row + source_x * 4;
                auto* pixel = destination + x * 4;
                if (std::memcmp(pixel, source, 4) != 0) {
                    changed = true;
                }
                std::memcpy(pixel, source, 4);
            }
        }
        copied_bytes = static_cast<std::uint64_t>(surface->width) * surface->height * 4;
    }

    if (changed && (force_full_copy || !matching_dimensions || frame.dirty_rects.empty())) {
        RECTANGLE_16 dirty{};
        dirty.right = static_cast<UINT16>(surface->width);
        dirty.bottom = static_cast<UINT16>(surface->height);
        copy_succeeded = region16_union_rect(
            &surface->invalidRegion,
            &surface->invalidRegion,
            &dirty);
    }
    if (!copy_succeeded) {
        LeaveCriticalSection(&surface->lock);
        return false;
    }
    if (changed) {
        surface->macrdpFrameGeneration++;
    }
    LeaveCriticalSection(&surface->lock);

    const auto copy_finished = std::chrono::steady_clock::now();
    const auto copy_elapsed_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            copy_finished - copy_started)
            .count());
    subsystem->surface_copy_time_us_total.fetch_add(
        copy_elapsed_us,
        std::memory_order_relaxed);
    record_atomic_max(subsystem->surface_copy_time_us_max, copy_elapsed_us);

    subsystem->published_frames.fetch_add(1, std::memory_order_relaxed);
    subsystem->copied_bytes.fetch_add(copied_bytes, std::memory_order_relaxed);
    if (full_scan) {
        subsystem->full_scan_frames.fetch_add(1, std::memory_order_relaxed);
    }
    if (used_dirty_regions && changed) {
        subsystem->dirty_region_frames.fetch_add(1, std::memory_order_relaxed);
        subsystem->dirty_region_rects.fetch_add(copied_dirty_rects, std::memory_order_relaxed);
    } else if (copied_bytes != 0) {
        subsystem->full_copy_frames.fetch_add(1, std::memory_order_relaxed);
        if (full_copy_forced) {
            subsystem->full_copy_forced_frames.fetch_add(1, std::memory_order_relaxed);
        } else if (full_copy_no_metadata) {
            subsystem->full_copy_no_metadata_frames.fetch_add(1, std::memory_order_relaxed);
        } else if (full_copy_scaled) {
            subsystem->full_copy_scaled_frames.fetch_add(1, std::memory_order_relaxed);
        }
    }
    if (changed) {
        subsystem->changed_frames.fetch_add(1, std::memory_order_relaxed);
    }
    subsystem->force_full_frame.store(false, std::memory_order_release);

    if (!changed) {
        return true;
    }

    // The surface lock must be released before this barrier: clients take
    // the same lock while consuming the published frame.
    shadow_subsystem_frame_update(&subsystem->common);
    const auto update_finished = std::chrono::steady_clock::now();

    const auto copy_time = std::chrono::duration_cast<std::chrono::milliseconds>(
        copy_finished - copy_started);
    const auto publish_wait = std::chrono::duration_cast<std::chrono::milliseconds>(
        update_finished - copy_finished);
    const auto publish_wait_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            update_finished - copy_finished)
            .count());
    subsystem->publish_wait_time_us_total.fetch_add(
        publish_wait_us,
        std::memory_order_relaxed);
    record_atomic_max(subsystem->publish_wait_time_us_max, publish_wait_us);
    if (copy_time >= std::chrono::milliseconds{100}
        || publish_wait >= std::chrono::milliseconds{200}) {
        const auto now = std::chrono::steady_clock::now();
        if (subsystem->last_slow_frame_log.time_since_epoch().count() == 0
            || now - subsystem->last_slow_frame_log >= std::chrono::seconds{1}) {
            WLog_WARN(TAG, "Slow frame update: copy=%" PRId64 "ms publish_wait=%" PRId64
                           "ms capture=%ux%u surface=%ux%u",
                      copy_time.count(), publish_wait.count(), frame.width, frame.height,
                      surface_width, surface_height);
            subsystem->last_slow_frame_log = now;
        }
    }
    return true;
}

void request_capture_stop(MacShadowSubsystem* subsystem, const char* error) {
    if (error != nullptr && error[0] != '\0') {
        WLog_ERR(TAG, "Screen capture stopped: %s", error);
    }
    subsystem->stop_requested.store(true);
    subsystem->pending_frame_condition.notify_all();
    if (subsystem->common.server != nullptr) {
        (void)SetEvent(subsystem->common.server->StopEvent);
    }
}

enum class DisplayRefreshResult {
    ready,
    waiting_for_display,
    fatal,
};

DisplayRefreshResult refresh_display_surface(MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || subsystem->common.server->screen == nullptr || subsystem->capture == nullptr
        || subsystem->display_topology == nullptr) {
        return DisplayRefreshResult::fatal;
    }

    const auto now = std::chrono::steady_clock::now();
    const bool force_poll = subsystem->last_topology_poll.time_since_epoch().count() == 0
        || now - subsystem->last_topology_poll >= std::chrono::seconds{2};
    if (force_poll) {
        subsystem->last_topology_poll = now;
    }
    if (!subsystem->display_topology->refresh(force_poll)) {
        WLog_WARN(TAG, "Unable to refresh display topology: %s",
                  subsystem->display_topology->last_error().c_str());
        // Retain the last committed geometry while CoreGraphics is transiently
        // unable to provide a complete replacement snapshot.
        return active_display_generation(subsystem).has_value()
            ? DisplayRefreshResult::ready
            : DisplayRefreshResult::waiting_for_display;
    }

    const auto topology = subsystem->display_topology->snapshot();
    if (!topology.has_value()) {
        return DisplayRefreshResult::waiting_for_display;
    }
    const auto next_geometry = display_session_geometry(
        *topology,
        subsystem->capture_config);
    if (!next_geometry.has_value()) {
        std::lock_guard commit_lock(subsystem->display_commit_mutex);
        bool was_available = false;
        {
            std::lock_guard lock(subsystem->display_geometry_mutex);
            was_available = subsystem->selected_display_available;
            subsystem->display_transitioning = true;
            subsystem->selected_display_available = false;
        }
        if (was_available) {
            subsystem->capture->stop();
            std::lock_guard frame_lock(subsystem->pending_frame_mutex);
            subsystem->pending_frame.reset();
        }
        if (subsystem->last_missing_display_log.time_since_epoch().count() == 0
            || now - subsystem->last_missing_display_log >= std::chrono::seconds{5}) {
            WLog_WARN(TAG,
                      "Selected display %u is unavailable; waiting for the same display ID",
                      subsystem->capture_config.display_id);
            subsystem->last_missing_display_log = now;
        }
        return DisplayRefreshResult::waiting_for_display;
    }

    std::lock_guard commit_lock(subsystem->display_commit_mutex);
    {
        std::lock_guard lock(subsystem->display_geometry_mutex);
        if (!subsystem->display_transitioning
            && subsystem->selected_display_available
            && subsystem->display_geometry.has_value()
            && subsystem->display_geometry->generation == next_geometry->generation) {
            return DisplayRefreshResult::ready;
        }
        subsystem->display_transitioning = true;
    }

    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    }

    MONITOR_DEF next_monitor{};
    if (!monitor_for_geometry(*next_geometry, next_monitor)) {
        return DisplayRefreshResult::fatal;
    }
    if (subsystem->common.macrdpMonitorLockInitialized) {
        EnterCriticalSection(&subsystem->common.macrdpMonitorLock);
    }
    const auto& current_monitor = subsystem->common.monitors[0];
    const bool changed = current_monitor.left != next_monitor.left
        || current_monitor.top != next_monitor.top
        || current_monitor.right != next_monitor.right
        || current_monitor.bottom != next_monitor.bottom
        || current_monitor.flags != next_monitor.flags;
    if (!changed) {
        if (subsystem->common.macrdpMonitorLockInitialized) {
            LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
        }
    } else {
        subsystem->common.monitors[0] = next_monitor;
        subsystem->common.numMonitors = 1;
        const bool resized = shadow_screen_resize(subsystem->common.server->screen) != 0;
        if (subsystem->common.macrdpMonitorLockInitialized) {
            LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
        }
        if (!resized) {
            return DisplayRefreshResult::fatal;
        }
    }

    const auto options = capture_options_for_geometry(subsystem, *next_geometry);
    subsystem->force_full_frame.store(true, std::memory_order_release);
    if (!subsystem->capture->reconfigure(options)) {
        WLog_WARN(TAG, "Display capture reconfiguration failed: %s",
                  subsystem->capture->last_error().c_str());
        std::lock_guard lock(subsystem->display_geometry_mutex);
        subsystem->selected_display_available = false;
        return DisplayRefreshResult::waiting_for_display;
    }

    {
        std::lock_guard lock(subsystem->display_geometry_mutex);
        subsystem->display_geometry = *next_geometry;
        subsystem->selected_display_available = true;
        subsystem->display_transitioning = false;
    }
    subsystem->last_missing_display_log = {};
    const auto [surface_width, surface_height] = shadow_surface_dimensions(subsystem);
    WLog_INFO(TAG,
              "Display topology generation %" PRIu64
              " committed for display %u; RDP surface is now %ux%u",
              next_geometry->generation,
              next_geometry->display.id,
              surface_width,
              surface_height);
    return DisplayRefreshResult::ready;
}

void capture_loop(MacShadowSubsystem* subsystem) {
    auto retry_delay = std::chrono::milliseconds{250};
    while (!subsystem->stop_requested.load()) {
        {
            std::unique_lock lock(subsystem->capture_clients_mutex);
            subsystem->capture_clients_condition.wait(lock, [subsystem] {
                return subsystem->stop_requested.load()
                    || capture_has_output_clients(subsystem);
            });
        }
        if (subsystem->stop_requested.load()) {
            break;
        }

        const auto display_status = refresh_display_surface(subsystem);
        if (display_status == DisplayRefreshResult::fatal) {
            request_capture_stop(
                subsystem,
                "Unable to resize the RDP surface after a display mode change");
            break;
        }
        if (display_status == DisplayRefreshResult::waiting_for_display) {
            std::this_thread::sleep_for(std::chrono::milliseconds{250});
            continue;
        }

        auto frame = subsystem->capture->next_frame(std::chrono::milliseconds{250});
        if (frame.has_value()) {
            if (!capture_has_output_clients(subsystem)) {
                subsystem->capture->recycle_frame(std::move(*frame));
                continue;
            }
            subsystem->captured_frames.fetch_add(1, std::memory_order_relaxed);
            subsystem->capture_copy_time_us_total.fetch_add(
                frame->capture_copy_time_us,
                std::memory_order_relaxed);
            subsystem->capture_copied_bytes.fetch_add(
                frame->capture_copy_bytes,
                std::memory_order_relaxed);
            record_atomic_max(
                subsystem->capture_copy_time_us_max,
                frame->capture_copy_time_us);
            {
                std::lock_guard lock(subsystem->pending_frame_mutex);
                if (subsystem->stop_requested.load()) {
                    break;
                }
                // A slow RDP client must never turn capture into an unbounded
                // queue. Preserve the skipped frame's dirty area before
                // replacing its pixels with the newest frame.
                if (subsystem->pending_frame.has_value()) {
                    subsystem->coalesced_frames.fetch_add(1, std::memory_order_relaxed);
                    macrdp::coalesce_dropped_frame_dirty_regions(
                        *subsystem->pending_frame,
                        *frame);
                }
                subsystem->pending_frame = std::move(frame);
            }
            subsystem->pending_frame_condition.notify_one();
            retry_delay = std::chrono::milliseconds{250};
            continue;
        }

        const std::string error = subsystem->capture->last_error();
        if (!error.empty() && !subsystem->stop_requested.load()
            && capture_has_output_clients(subsystem)) {
            WLog_WARN(TAG, "Screen capture stream stopped: %s; attempting restart",
                      error.c_str());
            subsystem->capture->stop();
            if (subsystem->stop_requested.load()) {
                break;
            }
            if (!capture_has_output_clients(subsystem)) {
                continue;
            }
            std::this_thread::sleep_for(retry_delay);
            if (subsystem->stop_requested.load()) {
                break;
            }
            if (!capture_has_output_clients(subsystem)) {
                continue;
            }
            if (!subsystem->capture->start()) {
                WLog_WARN(TAG, "Screen capture restart failed: %s",
                          subsystem->capture->last_error().c_str());
                retry_delay = std::min(
                    retry_delay * 2,
                    std::chrono::milliseconds{2000});
            } else {
                retry_delay = std::chrono::milliseconds{250};
            }
        }
    }
    subsystem->pending_frame_condition.notify_all();
}

void publish_loop(MacShadowSubsystem* subsystem) {
    while (true) {
        std::optional<macrdp::Frame> frame;
        {
            std::unique_lock lock(subsystem->pending_frame_mutex);
            subsystem->pending_frame_condition.wait(lock, [subsystem] {
                return subsystem->stop_requested.load()
                    || subsystem->pending_frame.has_value();
            });
            if (!subsystem->pending_frame.has_value()) {
                break;
            }
            frame = std::move(subsystem->pending_frame);
            subsystem->pending_frame.reset();
        }

        const bool copy_succeeded = copy_frame_to_surface(subsystem, *frame);
        subsystem->capture->recycle_frame(std::move(*frame));
        if (!copy_succeeded) {
            request_capture_stop(subsystem, "Could not copy ScreenCaptureKit frame to RDP surface");
            break;
        }

        const auto now = std::chrono::steady_clock::now();
        if (subsystem->last_pipeline_log.time_since_epoch().count() == 0
            || now - subsystem->last_pipeline_log >= std::chrono::seconds{5}) {
            const auto captured = subsystem->captured_frames.load(std::memory_order_relaxed);
            const auto published = subsystem->published_frames.load(std::memory_order_relaxed);
            const auto changed = subsystem->changed_frames.load(std::memory_order_relaxed);
            const auto capture_total_us = subsystem->capture_copy_time_us_total.load(
                std::memory_order_relaxed);
            const auto surface_total_us = subsystem->surface_copy_time_us_total.load(
                std::memory_order_relaxed);
            const auto publish_total_us = subsystem->publish_wait_time_us_total.load(
                std::memory_order_relaxed);
            WLog_INFO(TAG,
                      "Frame pipeline: captured=%" PRIu64 " published=%" PRIu64
                      " changed=%" PRIu64 " coalesced=%" PRIu64 " copied=%" PRIu64
                      " bytes capture_copied=%" PRIu64
                      " dirty_frames=%" PRIu64 " dirty_rects=%" PRIu64
                      " full_frames=%" PRIu64 " full_forced=%" PRIu64
                      " full_no_metadata=%" PRIu64 " full_scaled=%" PRIu64
                      " full_scans=%" PRIu64 " video_suppressed=%" PRIu64
                      " capture_copy_avg=%" PRIu64 "ms capture_copy_max=%" PRIu64
                      "ms surface_copy_avg=%" PRIu64 "ms surface_copy_max=%" PRIu64
                      "ms publish_wait_avg=%" PRIu64 "ms publish_wait_max=%" PRIu64 "ms",
                      captured,
                      published,
                      changed,
                      subsystem->coalesced_frames.load(std::memory_order_relaxed),
                      subsystem->copied_bytes.load(std::memory_order_relaxed),
                      subsystem->capture_copied_bytes.load(std::memory_order_relaxed),
                      subsystem->dirty_region_frames.load(std::memory_order_relaxed),
                      subsystem->dirty_region_rects.load(std::memory_order_relaxed),
                      subsystem->full_copy_frames.load(std::memory_order_relaxed),
                      subsystem->full_copy_forced_frames.load(std::memory_order_relaxed),
                      subsystem->full_copy_no_metadata_frames.load(std::memory_order_relaxed),
                      subsystem->full_copy_scaled_frames.load(std::memory_order_relaxed),
                      subsystem->full_scan_frames.load(std::memory_order_relaxed),
                      subsystem->capture == nullptr
                          ? 0
                          : subsystem->capture->suppressed_video_frames(),
                      captured == 0 ? 0 : capture_total_us / captured / 1000,
                      subsystem->capture_copy_time_us_max.load(std::memory_order_relaxed) / 1000,
                      published == 0 ? 0 : surface_total_us / published / 1000,
                      subsystem->surface_copy_time_us_max.load(std::memory_order_relaxed) / 1000,
                      changed == 0 ? 0 : publish_total_us / changed / 1000,
                      subsystem->publish_wait_time_us_max.load(std::memory_order_relaxed) / 1000);
            subsystem->last_pipeline_log = now;
        }
    }
}

// Keep this format alive for the lifetime of the process. The FreeRDP shadow
// audio message stores a pointer to the source format after processing it.
AUDIO_FORMAT g_macrdp_pcm_audio_format = {
    WAVE_FORMAT_PCM,
    2,
    48'000,
    192'000,
    4,
    16,
    0,
    nullptr,
};

void free_audio_samples_message(UINT32, SHADOW_MSG_OUT* message) {
    auto* audio_message = reinterpret_cast<SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES*>(message);
    if (audio_message == nullptr) {
        return;
    }
    std::free(audio_message->buf);
    std::free(audio_message);
}

int broadcast_audio_samples(
    MacShadowSubsystem* subsystem,
    const std::vector<std::int16_t>& pcm,
    UINT16 timestamp) {
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || pcm.empty() || pcm.size() % g_macrdp_pcm_audio_format.nChannels != 0
        || pcm.size() > std::numeric_limits<std::size_t>::max() / sizeof(pcm[0])) {
        return 0;
    }

    auto* audio_message = static_cast<SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES*>(
        std::calloc(1, sizeof(SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES)));
    if (audio_message == nullptr) {
        return 0;
    }
    const auto byte_size = pcm.size() * sizeof(pcm[0]);
    audio_message->buf = std::malloc(byte_size);
    if (audio_message->buf == nullptr) {
        std::free(audio_message);
        return 0;
    }

    audio_message->common.Free = free_audio_samples_message;
    audio_message->audio_format = &g_macrdp_pcm_audio_format;
    audio_message->nFrames = pcm.size() / g_macrdp_pcm_audio_format.nChannels;
    audio_message->wTimestamp = timestamp;
    std::memcpy(audio_message->buf, pcm.data(), byte_size);

    const int delivered = shadow_client_boardcast_msg(
        subsystem->common.server,
        nullptr,
        SHADOW_MSG_OUT_AUDIO_OUT_SAMPLES_ID,
        &audio_message->common,
        nullptr);
    subsystem->audio_delivered_clients.fetch_add(
        delivered > 0 ? static_cast<std::uint64_t>(delivered) : 0,
        std::memory_order_relaxed);
    return delivered;
}

void audio_loop(MacShadowSubsystem* subsystem) {
    constexpr std::uint32_t sample_rate = 48'000;
    constexpr std::uint16_t channels = 2;
    constexpr std::size_t chunk_frames = 960; // 20 ms at 48 kHz.
    constexpr std::size_t chunk_samples = chunk_frames * channels;
    constexpr std::size_t max_pending_samples = chunk_samples * 4;
    constexpr double pi = 3.14159265358979323846;
    constexpr double test_tone_frequency = 440.0;
    constexpr double test_tone_amplitude = 0.20;

    const char* test_tone_value = std::getenv("MACRDP_AUDIO_TEST_TONE");
    const bool test_tone_enabled = test_tone_value != nullptr
        && *test_tone_value != '\0'
        && *test_tone_value != '0'
        && *test_tone_value != 'n'
        && *test_tone_value != 'N';
    if (test_tone_enabled) {
        WLog_INFO(TAG, "Audio test tone enabled (440Hz, 48kHz, stereo)");
    }

    std::deque<std::int16_t> pending;
    std::optional<std::uint64_t> pending_display_generation;
    std::uint64_t timestamp_ms = 0;
    std::uint64_t test_tone_frame = 0;
    while (!subsystem->stop_requested.load(std::memory_order_acquire)) {
        if (!capture_has_clients(subsystem)) {
            pending.clear();
            pending_display_generation.reset();
            std::this_thread::sleep_for(std::chrono::milliseconds{50});
            continue;
        }
        std::optional<macrdp::AudioFrame> audio;
        if (test_tone_enabled) {
            const auto display_generation = active_display_generation(subsystem);
            if (!display_generation.has_value()) {
                pending.clear();
                pending_display_generation.reset();
                std::this_thread::sleep_for(std::chrono::milliseconds{50});
                continue;
            }
            macrdp::AudioFrame frame;
            frame.sample_rate = sample_rate;
            frame.channels = channels;
            frame.display_generation = *display_generation;
            frame.pcm.resize(chunk_samples);
            for (std::size_t index = 0; index < chunk_frames; ++index) {
                const double phase = static_cast<double>(test_tone_frame + index)
                    * test_tone_frequency * 2.0 * pi / static_cast<double>(sample_rate);
                const auto sample = static_cast<std::int16_t>(
                    std::sin(phase) * test_tone_amplitude * 32767.0);
                frame.pcm[index * channels] = sample;
                frame.pcm[index * channels + 1] = sample;
            }
            test_tone_frame += chunk_frames;
            audio = std::move(frame);
            std::this_thread::sleep_for(std::chrono::milliseconds{20});
        } else {
            if (!active_display_generation(subsystem).has_value()) {
                pending.clear();
                pending_display_generation.reset();
                std::this_thread::sleep_for(std::chrono::milliseconds{50});
                continue;
            }
            audio = subsystem->capture->next_audio(std::chrono::milliseconds{250});
        }
        if (!audio.has_value()) {
            pending.clear();
            pending_display_generation.reset();
            std::this_thread::sleep_for(std::chrono::milliseconds{10});
            continue;
        }
        const auto display_generation = active_display_generation(subsystem);
        if (!macrdp::audio_frame_matches_display_generation(
                *audio,
                display_generation)) {
            pending.clear();
            pending_display_generation.reset();
            subsystem->audio_dropped_frames.fetch_add(
                audio->frames(),
                std::memory_order_relaxed);
            continue;
        }
        if (!audio->valid() || audio->sample_rate != sample_rate
            || audio->channels != channels) {
            subsystem->audio_dropped_frames.fetch_add(
                audio->frames(),
                std::memory_order_relaxed);
            continue;
        }

        if (pending_display_generation != audio->display_generation) {
            pending.clear();
            pending_display_generation = audio->display_generation;
        }

        subsystem->audio_captured_frames.fetch_add(
            audio->frames(),
            std::memory_order_relaxed);
        pending.insert(pending.end(), audio->pcm.begin(), audio->pcm.end());
        while (pending.size() > max_pending_samples) {
            pending.pop_front();
            if (pending.size() > max_pending_samples) {
                pending.pop_front();
            }
            subsystem->audio_dropped_frames.fetch_add(
                1,
                std::memory_order_relaxed);
        }

        while (pending.size() >= chunk_samples
               && !subsystem->stop_requested.load(std::memory_order_acquire)) {
            std::vector<std::int16_t> chunk;
            {
                std::lock_guard commit_lock(subsystem->display_commit_mutex);
                const auto committed_generation = active_display_generation(subsystem);
                if (!committed_generation.has_value()
                    || pending_display_generation != committed_generation) {
                    subsystem->audio_dropped_frames.fetch_add(
                        pending.size() / channels,
                        std::memory_order_relaxed);
                    pending.clear();
                    pending_display_generation.reset();
                    break;
                }

                chunk.reserve(chunk_samples);
                for (std::size_t index = 0; index < chunk_samples; ++index) {
                    chunk.push_back(pending.front());
                    pending.pop_front();
                }
                (void)broadcast_audio_samples(
                    subsystem,
                    chunk,
                    static_cast<UINT16>(timestamp_ms & UINT16_MAX));
            }
            timestamp_ms += (chunk_frames * 1000U) / sample_rate;
            subsystem->audio_published_chunks.fetch_add(
                1,
                std::memory_order_relaxed);
        }

        const auto now = std::chrono::steady_clock::now();
        if (subsystem->last_audio_log.time_since_epoch().count() == 0
            || now - subsystem->last_audio_log >= std::chrono::seconds{5}) {
            WLog_INFO(
                TAG,
                "Audio pipeline: captured_frames=%" PRIu64
                " published_chunks=%" PRIu64
                " delivered_clients=%" PRIu64
                " dropped_frames=%" PRIu64,
                subsystem->audio_captured_frames.load(std::memory_order_relaxed),
                subsystem->audio_published_chunks.load(std::memory_order_relaxed),
                subsystem->audio_delivered_clients.load(std::memory_order_relaxed),
                subsystem->audio_dropped_frames.load(std::memory_order_relaxed));
            subsystem->last_audio_log = now;
        }
    }
}

int mac_shadow_subsystem_init(rdpShadowSubsystem* base) {
    auto* subsystem = reinterpret_cast<MacShadowSubsystem*>(base);
    if (subsystem == nullptr) {
        return -1;
    }

    if (subsystem->display_topology == nullptr) {
        subsystem->display_topology = std::make_unique<macrdp::DisplayTopology>();
    }
    if (!subsystem->display_topology->start()) {
        WLog_ERR(TAG, "Unable to initialize display topology: %s",
                 subsystem->display_topology->last_error().c_str());
        return -1;
    }
    const auto topology = subsystem->display_topology->snapshot();
    const auto geometry = topology.has_value()
        ? display_session_geometry(*topology, subsystem->capture_config)
        : std::nullopt;
    if (!geometry.has_value()) {
        WLog_ERR(TAG, "Selected display %u is not active during initialization",
                 subsystem->capture_config.display_id);
        subsystem->display_topology->stop();
        return -1;
    }
    {
        std::lock_guard lock(subsystem->display_geometry_mutex);
        subsystem->display_geometry = *geometry;
        subsystem->display_transitioning = false;
        subsystem->selected_display_available = true;
    }

    MONITOR_DEF monitor{};
    if (!monitor_for_geometry(*geometry, monitor)) {
        subsystem->display_topology->stop();
        return -1;
    }
    if (subsystem->common.macrdpMonitorLockInitialized) {
        EnterCriticalSection(&subsystem->common.macrdpMonitorLock);
    }
    if (subsystem->common.selectedMonitor != 0) {
        if (subsystem->common.macrdpMonitorLockInitialized) {
            LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
        }
        subsystem->display_topology->stop();
        return -1;
    }
    subsystem->common.monitors[0] = monitor;
    subsystem->common.numMonitors = 1;
    if (subsystem->common.macrdpMonitorLockInitialized) {
        LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
    }
    return 1;
}

int mac_shadow_subsystem_start(rdpShadowSubsystem* base) {
    auto* subsystem = reinterpret_cast<MacShadowSubsystem*>(base);
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || subsystem->common.server->surface == nullptr) {
        return -1;
    }

    std::lock_guard lock(subsystem->lifecycle_mutex);
    if (subsystem->capture != nullptr) {
        return 1;
    }

    DisplaySessionGeometry geometry;
    {
        std::lock_guard geometry_lock(subsystem->display_geometry_mutex);
        if (subsystem->display_transitioning
            || !subsystem->selected_display_available
            || !subsystem->display_geometry.has_value()) {
            return -1;
        }
        geometry = *subsystem->display_geometry;
    }
    const auto options = capture_options_for_geometry(subsystem, geometry);
    subsystem->capture = std::make_unique<macrdp::DisplayCapture>(options);
    if (subsystem->input_enabled) {
        subsystem->input_event_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        if (subsystem->input_event_source == nullptr) {
            WLog_ERR(TAG, "Unable to create private CoreGraphics input event source");
            subsystem->capture.reset();
            return -1;
        }
    }

    subsystem->stop_requested.store(false);
    subsystem->input_stop_requested.store(false);
    subsystem->common.captureFrameRate = options.frame_rate;
    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    }
    subsystem->force_full_frame.store(true, std::memory_order_release);
    subsystem->captured_frames.store(0, std::memory_order_relaxed);
    subsystem->coalesced_frames.store(0, std::memory_order_relaxed);
    subsystem->published_frames.store(0, std::memory_order_relaxed);
    subsystem->changed_frames.store(0, std::memory_order_relaxed);
    subsystem->copied_bytes.store(0, std::memory_order_relaxed);
    subsystem->capture_copied_bytes.store(0, std::memory_order_relaxed);
    subsystem->dirty_region_frames.store(0, std::memory_order_relaxed);
    subsystem->dirty_region_rects.store(0, std::memory_order_relaxed);
    subsystem->full_copy_frames.store(0, std::memory_order_relaxed);
    subsystem->full_copy_forced_frames.store(0, std::memory_order_relaxed);
    subsystem->full_copy_no_metadata_frames.store(0, std::memory_order_relaxed);
    subsystem->full_copy_scaled_frames.store(0, std::memory_order_relaxed);
    subsystem->full_scan_frames.store(0, std::memory_order_relaxed);
    subsystem->capture_copy_time_us_total.store(0, std::memory_order_relaxed);
    subsystem->capture_copy_time_us_max.store(0, std::memory_order_relaxed);
    subsystem->surface_copy_time_us_total.store(0, std::memory_order_relaxed);
    subsystem->surface_copy_time_us_max.store(0, std::memory_order_relaxed);
    subsystem->publish_wait_time_us_total.store(0, std::memory_order_relaxed);
    subsystem->publish_wait_time_us_max.store(0, std::memory_order_relaxed);
    subsystem->audio_captured_frames.store(0, std::memory_order_relaxed);
    subsystem->audio_published_chunks.store(0, std::memory_order_relaxed);
    subsystem->audio_delivered_clients.store(0, std::memory_order_relaxed);
    subsystem->audio_dropped_frames.store(0, std::memory_order_relaxed);
    subsystem->input_synchronize_events.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_events.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_repeats.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_release_recoveries.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_unmatched_releases.store(0, std::memory_order_relaxed);
    subsystem->input_unicode_events.store(0, std::memory_order_relaxed);
    subsystem->input_mouse_events.store(0, std::memory_order_relaxed);
    subsystem->input_wheel_events.store(0, std::memory_order_relaxed);
    subsystem->input_left_button_events.store(0, std::memory_order_relaxed);
    subsystem->input_right_button_events.store(0, std::memory_order_relaxed);
    subsystem->input_middle_button_events.store(0, std::memory_order_relaxed);
    subsystem->input_drag_events.store(0, std::memory_order_relaxed);
    subsystem->input_extended_mouse_events.store(0, std::memory_order_relaxed);
    subsystem->input_injection_failures.store(0, std::memory_order_relaxed);
    subsystem->input_events_processed.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_events_processed.store(0, std::memory_order_relaxed);
    subsystem->input_event_queue_delay_us_total.store(0, std::memory_order_relaxed);
    subsystem->input_event_queue_delay_us_max.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_queue_delay_us_total.store(0, std::memory_order_relaxed);
    subsystem->input_keyboard_queue_delay_us_max.store(0, std::memory_order_relaxed);
    subsystem->input_motion_coalesced.store(0, std::memory_order_relaxed);
    subsystem->input_motion_dropped.store(0, std::memory_order_relaxed);
    subsystem->input_stale_pointer_events.store(0, std::memory_order_relaxed);
    subsystem->input_queue_wait_events.store(0, std::memory_order_relaxed);
    subsystem->input_queue_wait_time_us_total.store(0, std::memory_order_relaxed);
    subsystem->input_queue_wait_time_us_max.store(0, std::memory_order_relaxed);
    subsystem->input_queue_max_depth.store(0, std::memory_order_relaxed);
    subsystem->last_pipeline_log = {};
    subsystem->last_audio_log = {};
    subsystem->last_input_pipeline_log = {};
    {
        std::lock_guard input_lock(subsystem->input_queue_mutex);
        subsystem->input_queue.clear();
    }
    {
        std::lock_guard client_lock(subsystem->client_ids_mutex);
        subsystem->client_ids.clear();
        subsystem->next_client_id = 1;
    }
    {
        std::lock_guard client_lock(subsystem->capture_clients_mutex);
        subsystem->capture_clients.clear();
        subsystem->suppressed_capture_clients.clear();
        subsystem->capture_client_count.store(0, std::memory_order_release);
        subsystem->capture_output_client_count.store(0, std::memory_order_release);
    }
    try {
        if (subsystem->input_enabled) {
            subsystem->input_thread = std::thread(input_loop, subsystem);
        }
        subsystem->publish_thread = std::thread(publish_loop, subsystem);
        subsystem->capture_thread = std::thread(capture_loop, subsystem);
        if (options.capture_audio) {
            subsystem->audio_thread = std::thread(audio_loop, subsystem);
        }
    } catch (...) {
        subsystem->stop_requested.store(true);
        subsystem->input_stop_requested.store(true);
        subsystem->capture->stop();
        subsystem->capture_clients_condition.notify_all();
        subsystem->pending_frame_condition.notify_all();
        subsystem->input_queue_condition.notify_all();
        subsystem->input_queue_space_condition.notify_all();
        if (subsystem->capture_thread.joinable()) {
            subsystem->capture_thread.join();
        }
        if (subsystem->audio_thread.joinable()) {
            subsystem->audio_thread.join();
        }
        if (subsystem->publish_thread.joinable()) {
            subsystem->publish_thread.join();
        }
        if (subsystem->input_thread.joinable()) {
            subsystem->input_thread.join();
        }
        if (subsystem->input_event_source != nullptr) {
            CFRelease(subsystem->input_event_source);
            subsystem->input_event_source = nullptr;
        }
        {
            std::lock_guard input_lock(subsystem->input_queue_mutex);
            subsystem->input_queue.clear();
        }
        subsystem->capture.reset();
        return -1;
    }
    return 1;
}

int mac_shadow_subsystem_stop(rdpShadowSubsystem* base) {
    auto* subsystem = reinterpret_cast<MacShadowSubsystem*>(base);
    if (subsystem == nullptr) {
        return -1;
    }

    std::lock_guard lock(subsystem->lifecycle_mutex);
    subsystem->stop_requested.store(true);
    subsystem->input_stop_requested.store(true);
    subsystem->capture_clients_condition.notify_all();
    subsystem->input_queue_condition.notify_all();
    subsystem->input_queue_space_condition.notify_all();
    if (subsystem->capture != nullptr) {
        subsystem->capture->stop();
    }
    subsystem->pending_frame_condition.notify_all();
    if (subsystem->capture_thread.joinable()) {
        subsystem->capture_thread.join();
    }
    if (subsystem->audio_thread.joinable()) {
        subsystem->audio_thread.join();
    }
    if (subsystem->publish_thread.joinable()) {
        subsystem->publish_thread.join();
    }
    if (subsystem->input_thread.joinable()) {
        subsystem->input_thread.join();
    }
    if (subsystem->input_event_source != nullptr) {
        CFRelease(subsystem->input_event_source);
        subsystem->input_event_source = nullptr;
    }
    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    }
    {
        std::lock_guard input_lock(subsystem->input_queue_mutex);
        subsystem->input_queue.clear();
    }
    {
        std::lock_guard client_lock(subsystem->client_ids_mutex);
        subsystem->client_ids.clear();
    }
    {
        std::lock_guard client_lock(subsystem->capture_clients_mutex);
        subsystem->capture_clients.clear();
        subsystem->suppressed_capture_clients.clear();
        subsystem->capture_client_count.store(0, std::memory_order_release);
        subsystem->capture_output_client_count.store(0, std::memory_order_release);
    }
    subsystem->capture.reset();
    if (subsystem->display_topology != nullptr) {
        subsystem->display_topology->stop();
    }
    {
        std::lock_guard geometry_lock(subsystem->display_geometry_mutex);
        subsystem->display_transitioning = true;
        subsystem->selected_display_available = false;
    }
    return 1;
}

int mac_shadow_subsystem_uninit(rdpShadowSubsystem* base) {
    return mac_shadow_subsystem_stop(base);
}

void mac_shadow_subsystem_free(rdpShadowSubsystem* base) {
    auto* subsystem = reinterpret_cast<MacShadowSubsystem*>(base);
    if (subsystem == nullptr) {
        return;
    }
    (void)mac_shadow_subsystem_stop(base);
    clear_secret(subsystem->password);
    if (subsystem->common.macrdpMonitorLockInitialized) {
        DeleteCriticalSection(&subsystem->common.macrdpMonitorLock);
        subsystem->common.macrdpMonitorLockInitialized = FALSE;
    }
    delete subsystem;
}

rdpShadowSubsystem* mac_shadow_subsystem_new() {
    auto* subsystem = new MacShadowSubsystem{};
    if (!InitializeCriticalSectionAndSpinCount(
            &subsystem->common.macrdpMonitorLock,
            4000)) {
        delete subsystem;
        return nullptr;
    }
    subsystem->common.macrdpMonitorLockInitialized = TRUE;
    {
        std::lock_guard lock(g_credentials_mutex);
        subsystem->username = g_credentials.username;
        subsystem->domain = g_credentials.domain;
        subsystem->password = g_credentials.password;
    }
    {
        std::lock_guard lock(g_capture_config_mutex);
        subsystem->capture_config = g_capture_config;
    }
    subsystem->input_enabled = g_input_enabled.load(std::memory_order_acquire);

    subsystem->common.SynchronizeEvent = [](rdpShadowSubsystem* base, rdpShadowClient* client,
                                            UINT32 flags) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        if (mac == nullptr || !mac->input_enabled) {
            return mac != nullptr;
        }
        return queue_synchronize_event(mac, input_client_id(mac, client), flags)
            ? true
            : false;
    };
    subsystem->common.KeyboardEvent = [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags,
                                         UINT8 code) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        if (mac == nullptr || !mac->input_enabled) {
            return mac != nullptr;
        }
        return queue_keyboard_event(mac, input_client_id(mac, client), flags, code)
            ? true
            : false;
    };
    subsystem->common.UnicodeKeyboardEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 code) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            if (mac == nullptr || !mac->input_enabled) {
                return mac != nullptr;
            }
            return queue_unicode_event(mac, input_client_id(mac, client), flags, code)
                ? true
                : false;
        };
    subsystem->common.MouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 x, UINT16 y) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            if (mac == nullptr || !mac->input_enabled) {
                return mac != nullptr;
            }
            return queue_mouse_event(mac, client, input_client_id(mac, client), flags, x, y)
            ? true
            : false;
        };
    subsystem->common.ExtendedMouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 x, UINT16 y) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            if (mac == nullptr || !mac->input_enabled) {
                return mac != nullptr;
            }
            return queue_extended_mouse_event(
                       mac, client, input_client_id(mac, client), flags, x, y)
                ? true
                : false;
        };
    subsystem->common.RelMouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, INT16 x_delta, INT16 y_delta) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            if (mac == nullptr) {
                return false;
            }
            if (!mac->input_enabled) {
                return true;
            }
            std::int32_t pointer_x = 0;
            std::int32_t pointer_y = 0;
            {
                std::lock_guard input_lock(mac->input_mutex);
                pointer_x = mac->pointer_x;
                pointer_y = mac->pointer_y;
            }
            const auto [surface_width, surface_height] = shadow_surface_dimensions(mac);
            const auto width = surface_width == 0 ? UINT16_MAX : surface_width;
            const auto height = surface_height == 0 ? UINT16_MAX : surface_height;
            const auto x = static_cast<UINT16>(std::clamp<std::int32_t>(
                pointer_x + x_delta,
                0,
                static_cast<std::int32_t>(width > 0 ? width - 1 : 0)));
            const auto y = static_cast<UINT16>(std::clamp<std::int32_t>(
                pointer_y + y_delta,
                0,
                static_cast<std::int32_t>(height > 0 ? height - 1 : 0)));
            return queue_mouse_event(
                       mac,
                       client,
                       input_client_id(mac, client),
                       flags | PTR_FLAGS_MOVE,
                       x,
                       y)
                ? true
                : false;
        };
    subsystem->common.Authenticate = [](rdpShadowSubsystem* base, rdpShadowClient*, const char* user,
                                        const char* domain, const char* password) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        if (mac == nullptr || mac->username.empty() || mac->password.empty()
            || user == nullptr || password == nullptr) {
            return -1;
        }
        if (!constant_time_equal(mac->username, user)
            || !constant_time_equal(mac->password, password)) {
            return -1;
        }
        if (!mac->domain.empty() && !constant_time_equal(mac->domain, domain)) {
            return -1;
        }
        return 1;
    };
    subsystem->common.ClientConnect = [](rdpShadowSubsystem* base, rdpShadowClient* client) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        if (mac == nullptr || !register_capture_client(mac, client)) {
            return false;
        }
        if (mac->input_enabled && register_input_client(mac, client) == 0) {
            unregister_capture_client(mac, client);
            return false;
        }
        return true;
    };
    subsystem->common.ClientDisconnect = [](rdpShadowSubsystem* base, rdpShadowClient* client) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        if (mac == nullptr) {
            return;
        }
        unregister_capture_client(mac, client);
        if (!mac->input_enabled) {
            return;
        }
        const auto client_id = unregister_input_client(mac, client);
        if (client_id != 0) {
            (void)queue_input_reset(mac, client_id);
        }
    };
    subsystem->common.ClientCapabilities = [](rdpShadowSubsystem*, rdpShadowClient*) {
        return true;
    };
    subsystem->common.ClientSuppressOutput = [](
        rdpShadowSubsystem* base,
        rdpShadowClient* client,
        BOOL suppressed) {
        return set_capture_client_suppressed(
            reinterpret_cast<MacShadowSubsystem*>(base),
            client,
            suppressed != FALSE);
    };
    return &subsystem->common;
}

} // namespace

extern "C" int macrdp_shadow_subsystem_entry(RDP_SHADOW_ENTRY_POINTS* entry_points) {
    if (entry_points == nullptr) {
        return -1;
    }
    entry_points->New = mac_shadow_subsystem_new;
    entry_points->Free = mac_shadow_subsystem_free;
    entry_points->Init = mac_shadow_subsystem_init;
    entry_points->Uninit = mac_shadow_subsystem_uninit;
    entry_points->Start = mac_shadow_subsystem_start;
    entry_points->Stop = mac_shadow_subsystem_stop;
    entry_points->EnumMonitors = mac_shadow_enum_monitors;
    return 1;
}

extern "C" void macrdp_shadow_set_credentials(
    const char* username,
    const char* domain,
    const char* password) {
    std::lock_guard lock(g_credentials_mutex);
    g_credentials.username = username == nullptr ? std::string{} : username;
    g_credentials.domain = domain == nullptr ? std::string{} : domain;
    clear_secret(g_credentials.password);
    g_credentials.password = password == nullptr ? std::string{} : password;
}

extern "C" void macrdp_shadow_set_capture_options(
    std::uint32_t display_id,
    std::uint32_t max_width,
    std::uint32_t max_height,
    std::uint32_t frame_rate,
    bool audio_enabled) {
    std::lock_guard lock(g_capture_config_mutex);
    g_capture_config.display_id = display_id;
    g_capture_config.max_width = max_width;
    g_capture_config.max_height = max_height;
    g_capture_config.frame_rate = std::clamp(frame_rate, std::uint32_t{1}, std::uint32_t{60});
    g_capture_config.audio_enabled = audio_enabled;
    g_audio_enabled.store(audio_enabled, std::memory_order_release);
}

extern "C" int macrdp_shadow_audio_is_enabled(void) {
    return g_audio_enabled.load(std::memory_order_acquire) ? 1 : 0;
}

extern "C" void macrdp_shadow_set_input_enabled(bool enabled) {
    g_input_enabled.store(enabled, std::memory_order_release);
}

extern "C" std::uint32_t macrdp_shadow_capture_client_count(
    rdpShadowSubsystem* subsystem) {
    auto* mac = reinterpret_cast<MacShadowSubsystem*>(subsystem);
    return mac == nullptr
        ? 0
        : mac->capture_client_count.load(std::memory_order_acquire);
}

extern "C" std::uint32_t macrdp_shadow_capture_output_client_count(
    rdpShadowSubsystem* subsystem) {
    auto* mac = reinterpret_cast<MacShadowSubsystem*>(subsystem);
    return mac == nullptr
        ? 0
        : mac->capture_output_client_count.load(std::memory_order_acquire);
}

bool macrdp_shadow_enumerate_displays(
    std::vector<MacrdpDisplayInfo>& displays,
    std::string& error) {
    displays.clear();
    error.clear();

    macrdp::DisplayTopology topology;
    if (!topology.start()) {
        error = topology.last_error();
        return false;
    }
    const auto snapshot = topology.snapshot();
    if (!snapshot.has_value() || snapshot->displays.empty()) {
        error = "CoreGraphics returned no active displays";
        return false;
    }

    for (const auto& display : snapshot->displays) {
        displays.push_back({
            display.id,
            display.pixel_width,
            display.pixel_height,
            display.bounds.width,
            display.bounds.height,
            display.bounds.origin_x,
            display.bounds.origin_y,
            display.main,
        });
    }
    return true;
}

bool macrdp_shadow_resolve_display_id(
    std::uint32_t requested_display_id,
    std::uint32_t& resolved_display_id,
    std::string& error) {
    std::vector<MacrdpDisplayInfo> displays;
    if (!macrdp_shadow_enumerate_displays(displays, error)) {
        return false;
    }

    std::vector<std::uint32_t> display_ids;
    display_ids.reserve(displays.size());
    std::uint32_t main_display_id = 0;
    for (const auto& display : displays) {
        display_ids.push_back(display.id);
        if (display.main) {
            main_display_id = display.id;
        }
    }
    const auto selected = macrdp::display_capture_select_id(
        requested_display_id,
        main_display_id,
        display_ids);
    if (!selected.has_value()) {
        error = "Requested display ID " + std::to_string(requested_display_id)
            + " is not active";
        return false;
    }

    resolved_display_id = *selected;
    error.clear();
    return true;
}

bool macrdp_shadow_preflight_capture(std::string& error) {
    CaptureConfig capture_config;
    {
        std::lock_guard lock(g_capture_config_mutex);
        capture_config = g_capture_config;
    }

    macrdp::DisplayTopology topology;
    if (!topology.start()) {
        error = topology.last_error();
        return false;
    }
    const auto snapshot = topology.snapshot();
    const auto* display = snapshot.has_value()
        ? macrdp::display_topology_select(*snapshot, capture_config.display_id)
        : nullptr;
    if (display == nullptr) {
        error = "Selected display is not active during capture preflight";
        return false;
    }

    macrdp::DisplayCaptureOptions options;
    options.display_id = display->id;
    options.display_generation = snapshot->generation;
    options.native_width = display->pixel_width;
    options.native_height = display->pixel_height;
    options.max_width = 64;
    options.max_height = 64;
    options.frame_rate = 1;
    options.show_cursor = false;
    options.capture_audio = capture_config.audio_enabled;

    macrdp::DisplayCapture capture(options);
    if (!capture.start()) {
        error = capture.last_error();
        if (error.empty()) {
            error = "ScreenCaptureKit refused to start";
        }
        return false;
    }

    const auto frame = capture.next_frame(std::chrono::milliseconds{2500});
    if (!frame.has_value()) {
        error = capture.last_error();
        if (error.empty()) {
            error = "ScreenCaptureKit did not deliver a complete frame";
        }
        capture.stop();
        return false;
    }

    capture.stop();
    return true;
}

bool macrdp_shadow_preflight_input(std::string& error) {
    if (CGPreflightPostEventAccess()) {
        return true;
    }

    error = "Accessibility permission is required to inject keyboard and mouse events";
    return false;
}
