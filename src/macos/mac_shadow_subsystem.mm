#include <freerdp/config.h>

#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>

#include <freerdp/input.h>
#include <freerdp/log.h>
#include <freerdp/server/shadow.h>
#include <winpr/input.h>
#include <winpr/synch.h>

#include "macrdp/display_capture.hpp"
#include "macrdp/input_ownership.hpp"
#include "macrdp/input_queue.hpp"
#include "macrdp/input_translation.hpp"
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
    std::uint32_t max_width = 0;
    std::uint32_t max_height = 0;
    std::uint32_t frame_rate = 30;
    bool audio_enabled = true;
};

std::mutex g_capture_config_mutex;
CaptureConfig g_capture_config;

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
    std::chrono::steady_clock::time_point enqueued_at{};
};

struct mac_shadow_subsystem {
    rdpShadowSubsystem common{};
    std::unique_ptr<macrdp::DisplayCapture> capture;
    std::thread capture_thread;
    std::thread publish_thread;
    std::thread audio_thread;
    std::atomic_bool stop_requested{false};
    std::mutex lifecycle_mutex;
    std::mutex input_mutex;
    std::mutex input_queue_mutex;
    std::condition_variable input_queue_condition;
    std::condition_variable input_queue_space_condition;
    std::deque<InputEvent> input_queue;
    std::thread input_thread;
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
    std::atomic<std::uint64_t> input_queue_wait_events{0};
    std::atomic<std::uint64_t> input_queue_wait_time_us_total{0};
    std::atomic<std::uint64_t> input_queue_wait_time_us_max{0};
    std::atomic<std::uint64_t> input_queue_max_depth{0};
};

using MacShadowSubsystem = struct mac_shadow_subsystem;

constexpr std::size_t kInputQueueLimit = 4096;
constexpr std::uint16_t kExtendedKeyIdentityBit = 0x0100U;
constexpr std::uint16_t kExtended1KeyIdentityBit = 0x0200U;

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
    return register_input_client(subsystem, client);
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

bool display_dimensions(std::uint32_t& width, std::uint32_t& height) {
    const auto display = CGMainDisplayID();
    const auto display_width = CGDisplayPixelsWide(display);
    const auto display_height = CGDisplayPixelsHigh(display);
    if (display_width == 0 || display_height == 0
        || display_width > UINT16_MAX || display_height > UINT16_MAX) {
        return false;
    }

    width = static_cast<std::uint32_t>(display_width);
    height = static_cast<std::uint32_t>(display_height);
    return true;
}

UINT32 mac_shadow_enum_monitors(MONITOR_DEF* monitors, UINT32 max_monitors) {
    std::uint32_t native_width = 0;
    std::uint32_t native_height = 0;
    if (!display_dimensions(native_width, native_height)) {
        return 0;
    }

    CaptureConfig capture_config;
    {
        std::lock_guard lock(g_capture_config_mutex);
        capture_config = g_capture_config;
    }
    const auto [width, height] = macrdp::display_capture_output_size(
        native_width,
        native_height,
        capture_config.max_width,
        capture_config.max_height);
    if (width == 0 || height == 0) {
        return 0;
    }

    if (monitors != nullptr && max_monitors > 0) {
        monitors[0].left = 0;
        monitors[0].top = 0;
        // FreeRDP monitor rectangles are inclusive; surface dimensions add 1.
        monitors[0].right = static_cast<INT32>(width - 1);
        monitors[0].bottom = static_cast<INT32>(height - 1);
        monitors[0].flags = 1;
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

std::optional<macrdp::DisplayCaptureOptions> capture_options_for_surface(
    const MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr) {
        return std::nullopt;
    }

    const auto [surface_width, surface_height] = shadow_surface_dimensions(subsystem);
    if (surface_width == 0 || surface_height == 0) {
        return std::nullopt;
    }

    macrdp::DisplayCaptureOptions options;
    options.max_width = subsystem->capture_config.max_width == 0
        ? surface_width
        : std::min(subsystem->capture_config.max_width, surface_width);
    options.max_height = subsystem->capture_config.max_height == 0
        ? surface_height
        : std::min(subsystem->capture_config.max_height, surface_height);
    options.frame_rate = subsystem->capture_config.frame_rate;
    options.show_cursor = false;
    options.capture_audio = subsystem->capture_config.audio_enabled;
    return options;
}

CGPoint display_point(const MacShadowSubsystem* subsystem, UINT16 x, UINT16 y) {
    const CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    const auto [surface_width, surface_height] = shadow_surface_dimensions(subsystem);
    const double width = surface_width == 0
        ? std::max(1.0, bounds.size.width - 1.0)
        : std::max(1.0, static_cast<double>(surface_width) - 1.0);
    const double height = surface_height == 0
        ? std::max(1.0, bounds.size.height - 1.0)
        : std::max(1.0, static_cast<double>(surface_height) - 1.0);
    const double normalized_x = std::clamp(static_cast<double>(x) / width, 0.0, 1.0);
    const double normalized_y = std::clamp(static_cast<double>(y) / height, 0.0, 1.0);
    return CGPointMake(
        bounds.origin.x + normalized_x * std::max(0.0, bounds.size.width - 1.0),
        bounds.origin.y + normalized_y * std::max(0.0, bounds.size.height - 1.0));
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

bool post_keyboard_event(UINT16 flags, UINT8 code, bool autorepeat = false) {
    const auto key_code = mac_key_code(flags, code);
    if (!key_code.has_value()) {
        WLog_WARN(TAG, "Ignoring unmapped keyboard event flags=0x%04" PRIx16
                       " code=0x%02" PRIx8,
                  flags,
                  code);
        return false;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }

    // A missing RELEASE bit represents a key press, including the initial
    // press where KBD_FLAGS_DOWN is not set.
    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    CGEventRef event = CGEventCreateKeyboardEvent(
        source,
        *key_code,
        key_down);
    if (event == nullptr) {
        CFRelease(source);
        return false;
    }

    CGEventSetIntegerValueField(
        event,
        kCGKeyboardEventAutorepeat,
        autorepeat ? 1 : 0);
    WLog_DBG(TAG, "Keyboard event flags=0x%04" PRIx16 " code=0x%02" PRIx8
             " keycode=%u action=%s repeat=%u",
             flags,
             code,
             static_cast<unsigned>(*key_code),
             key_down ? "down" : "up",
             autorepeat ? 1U : 0U);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    CFRelease(source);
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

void release_stale_modifier_state(const char* reason) {
    // A previous server process can terminate after posting a modifier-down
    // event. The ownership ledger cannot survive that process boundary, so
    // clear only RDP modifiers that CoreGraphics still reports as held. The
    // aggregate flags are logged for diagnosis, but cannot decide which side
    // of a modifier is safe to release and may include physical user input.
    struct Modifier {
        UINT16 flags;
        UINT8 code;
    };
    constexpr Modifier modifiers[] = {
        {0, 0x1D},       // left Control
        {KBD_FLAGS_EXTENDED, 0x1D},       // right Control
        {0, 0x2A},       // left Shift
        {0, 0x36},       // right Shift
        {0, 0x38},       // left Alt/Option
        {KBD_FLAGS_EXTENDED, 0x38},       // right Alt/Option
        {KBD_FLAGS_EXTENDED, 0x5B},       // left Windows/Command
        {KBD_FLAGS_EXTENDED, 0x5C},       // right Windows/Command
    };

    const auto hid_flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    unsigned attempted = 0;
    unsigned skipped = 0;
    unsigned failures = 0;
    for (const auto& modifier : modifiers) {
        const auto key_code = mac_key_code(modifier.flags, modifier.code);
        if (!key_code.has_value()) {
            ++skipped;
            continue;
        }
        const bool hid_key_down = CGEventSourceKeyState(
            kCGEventSourceStateHIDSystemState,
            *key_code);
        if (!hid_key_down) {
            ++skipped;
            continue;
        }
        ++attempted;
        if (!post_keyboard_event(
                modifier.flags | KBD_FLAGS_RELEASE,
                modifier.code)) {
            ++failures;
        }
    }
    WLog_INFO(TAG,
              "Reset stale macOS modifier state (%s): attempted=%u skipped=%u failures=%u "
              "hid_flags=0x%" PRIx64,
              reason == nullptr ? "unspecified" : reason,
              attempted,
              skipped,
              failures,
              static_cast<std::uint64_t>(hid_flags));
}

bool synchronize_toggle_keys(UINT32 flags) {
    const CGEventFlags current_flags =
        CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    bool success = true;

    const auto synchronize_key = [&success](
                                    bool desired,
                                    bool current,
                                    UINT16 key_flags,
                                    UINT8 code) {
        if (desired == current) {
            return;
        }
        if (!post_keyboard_event(key_flags, code)
            || !post_keyboard_event(key_flags | KBD_FLAGS_RELEASE, code)) {
            success = false;
        }
    };

    synchronize_key(
        (flags & KBD_SYNC_CAPS_LOCK) != 0,
        (current_flags & kCGEventFlagMaskAlphaShift) != 0,
        0,
        RDP_SCANCODE_CODE(RDP_SCANCODE_CAPSLOCK));
    synchronize_key(
        (flags & KBD_SYNC_NUM_LOCK) != 0,
        (current_flags & kCGEventFlagMaskNumericPad) != 0,
        0,
        RDP_SCANCODE_CODE(RDP_SCANCODE_NUMLOCK));

    // CoreGraphics exposes no public Scroll Lock toggle-state bit. Its
    // CGEventSourceKeyState API reports only whether the key is physically
    // held, so treating it as a lock state would toggle Scroll Lock again on
    // every focus synchronization. Normal Scroll Lock key events still pass
    // through the keyboard path below.
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
            // The ledger may be empty after a server restart even though the
            // old process left a platform key-down behind. Forward the
            // release as a best-effort recovery signal instead of silently
            // discarding it.
            WLog_DBG(TAG, "Forwarding unknown keyboard release client=%" PRIu64
                     " flags=0x%04" PRIx16 " code=0x%02" PRIx8,
                     client_id,
                     flags,
                     code);
            subsystem->input_keyboard_release_recoveries.fetch_add(
                1,
                std::memory_order_relaxed);
            subsystem->input_keyboard_unmatched_releases.fetch_add(
                1,
                std::memory_order_relaxed);
            return post_keyboard_event(flags | KBD_FLAGS_RELEASE, code);
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
        return post_keyboard_event(flags, code, true);
    }

    if (!subsystem->input_ownership.acquire_key(client_id, key_identity)) {
        return true;
    }
    const bool posted = post_keyboard_event(flags, code);
    if (!posted) {
        // The ownership transition must describe the physical event state. If
        // CoreGraphics rejects the event, undo the transition so a later
        // retry is still allowed to post it.
        (void)subsystem->input_ownership.release_key(client_id, key_identity);
    }
    return posted;
}

bool post_unicode_event(UINT16 flags, UINT16 code) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }

    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    CGEventRef event = CGEventCreateKeyboardEvent(source, 0, key_down);
    if (event == nullptr) {
        CFRelease(source);
        return false;
    }

    const UniChar character = static_cast<UniChar>(code);
    CGEventKeyboardSetUnicodeString(event, 1, &character);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    CFRelease(source);
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
    const bool posted = post_unicode_event(flags, code);
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
    if (subsystem == nullptr) {
        return false;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }

    const CGPoint point = display_point(subsystem, x, y);
    if ((flags & PTR_FLAGS_WHEEL) != 0 || (flags & PTR_FLAGS_HWHEEL) != 0) {
        const int signed_rotation = macrdp::decode_rdp_wheel_delta(flags) / 120;
        const int horizontal = (flags & PTR_FLAGS_HWHEEL) != 0
            ? signed_rotation
            : 0;
        const int vertical = (flags & PTR_FLAGS_HWHEEL) != 0
            ? 0
            : signed_rotation;
        CGEventRef event = CGEventCreateScrollWheelEvent(
            source,
            kCGScrollEventUnitLine,
            2,
            vertical,
            horizontal);
        if (event == nullptr) {
            CFRelease(source);
            return false;
        }
        CGEventSetLocation(event, point);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        CFRelease(source);
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

        CGEventRef event = CGEventCreateMouseEvent(source, move_type, point, drag_button);
        if (event != nullptr) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            CFRelease(source);
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
        CGEventRef event = CGEventCreateMouseEvent(source, button_type, point, button);
        if (event == nullptr) {
            CFRelease(source);
            return false;
        }
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }

    CFRelease(source);
    return true;
}

bool inject_mouse_event(
    MacShadowSubsystem* subsystem,
    macrdp::InputClientId client_id,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
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
    if (subsystem == nullptr) {
        return false;
    }

    const CGPoint point = display_point(subsystem, x, y);
    const bool down = (flags & PTR_XFLAGS_DOWN) != 0;
    const UINT16 button_flags = flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2);
    if (button_flags == 0) {
        return true;
    }

    const bool button_1 = (button_flags & PTR_XFLAGS_BUTTON1) != 0;
    const CGMouseButton button = static_cast<CGMouseButton>(button_1 ? 3 : 4);
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }
    CGEventRef event = CGEventCreateMouseEvent(
        source,
        down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp,
        point,
        button);
    if (event == nullptr) {
        CFRelease(source);
        return false;
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    CFRelease(source);
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

    {
        std::lock_guard lock(subsystem->input_mutex);
        subsystem->pointer_x = x;
        subsystem->pointer_y = y;
    }
    publish_pointer_position(subsystem, source_client, x, y);

    InputEvent event;
    event.kind = InputEventKind::mouse;
    event.client_id = client_id;
    event.flags = flags;
    event.x = x;
    event.y = y;
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

    {
        std::lock_guard lock(subsystem->input_mutex);
        subsystem->pointer_x = x;
        subsystem->pointer_y = y;
    }
    publish_pointer_position(subsystem, source_client, x, y);

    InputEvent event;
    event.kind = InputEventKind::extended_mouse;
    event.client_id = client_id;
    event.flags = flags;
    event.x = x;
    event.y = y;
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
            release_flags_for_key_identity(key_identity),
            static_cast<UINT8>(key_identity & UINT8_MAX));
    }
    for (const auto code : released.unicode) {
        (void)post_unicode_event(KBD_FLAGS_RELEASE, code);
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
    release_stale_modifier_state("input worker start");
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

        bool injected = false;
        switch (event.kind) {
            case InputEventKind::synchronize:
                injected = synchronize_toggle_keys(event.synchronize_flags);
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
    const bool matching_dimensions = frame.width == surface->width
        && frame.height == surface->height;
    const bool force_full_copy = subsystem->force_full_frame.load(std::memory_order_acquire);
    if (matching_dimensions && !force_full_copy && !frame.dirty_rects.empty()) {
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
        } else {
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

bool refresh_display_surface(MacShadowSubsystem* subsystem) {
    if (subsystem == nullptr || subsystem->common.server == nullptr
        || subsystem->common.server->screen == nullptr || subsystem->capture == nullptr) {
        return false;
    }

    MONITOR_DEF next_monitor{};
    if (mac_shadow_enum_monitors(&next_monitor, 1) != 1) {
        return false;
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
        return true;
    }

    subsystem->common.monitors[0] = next_monitor;
    subsystem->common.numMonitors = 1;
    const bool resized = shadow_screen_resize(subsystem->common.server->screen) != 0;
    if (subsystem->common.macrdpMonitorLockInitialized) {
        LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
    }
    if (!resized) {
        return false;
    }

    const auto options = capture_options_for_surface(subsystem);
    if (!options.has_value()) {
        return false;
    }
    subsystem->force_full_frame.store(true, std::memory_order_release);
    if (!subsystem->capture->reconfigure(*options)) {
        WLog_WARN(TAG, "Display capture reconfiguration failed: %s",
                  subsystem->capture->last_error().c_str());
    }

    const auto [surface_width, surface_height] = shadow_surface_dimensions(subsystem);
    WLog_INFO(TAG, "Display mode changed; RDP surface is now %ux%u",
              surface_width, surface_height);
    return true;
}

void capture_loop(MacShadowSubsystem* subsystem) {
    auto retry_delay = std::chrono::milliseconds{250};
    while (!subsystem->stop_requested.load()) {
        if (!refresh_display_surface(subsystem)) {
            request_capture_stop(
                subsystem,
                "Unable to resize the RDP surface after a display mode change");
            break;
        }

        auto frame = subsystem->capture->next_frame(std::chrono::milliseconds{250});
        if (frame.has_value()) {
            subsystem->captured_frames.fetch_add(1, std::memory_order_relaxed);
            subsystem->capture_copy_time_us_total.fetch_add(
                frame->capture_copy_time_us,
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
        if (!error.empty() && !subsystem->stop_requested.load()) {
            WLog_WARN(TAG, "Screen capture stream stopped: %s; attempting restart",
                      error.c_str());
            subsystem->capture->stop();
            if (subsystem->stop_requested.load()) {
                break;
            }
            std::this_thread::sleep_for(retry_delay);
            if (subsystem->stop_requested.load()) {
                break;
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
                      " bytes capture_copy_avg=%" PRIu64 "ms capture_copy_max=%" PRIu64
                      "ms surface_copy_avg=%" PRIu64 "ms surface_copy_max=%" PRIu64
                      "ms publish_wait_avg=%" PRIu64 "ms publish_wait_max=%" PRIu64 "ms",
                      captured,
                      published,
                      changed,
                      subsystem->coalesced_frames.load(std::memory_order_relaxed),
                      subsystem->copied_bytes.load(std::memory_order_relaxed),
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
    std::uint64_t timestamp_ms = 0;
    std::uint64_t test_tone_frame = 0;
    while (!subsystem->stop_requested.load(std::memory_order_acquire)) {
        std::optional<macrdp::AudioFrame> audio;
        if (test_tone_enabled) {
            macrdp::AudioFrame frame;
            frame.sample_rate = sample_rate;
            frame.channels = channels;
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
            audio = subsystem->capture->next_audio(std::chrono::milliseconds{250});
        }
        if (!audio.has_value()) {
            continue;
        }
        if (!audio->valid() || audio->sample_rate != sample_rate
            || audio->channels != channels) {
            subsystem->audio_dropped_frames.fetch_add(
                audio->frames(),
                std::memory_order_relaxed);
            continue;
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
            chunk.reserve(chunk_samples);
            for (std::size_t index = 0; index < chunk_samples; ++index) {
                chunk.push_back(pending.front());
                pending.pop_front();
            }
            (void)broadcast_audio_samples(
                subsystem,
                chunk,
                static_cast<UINT16>(timestamp_ms & UINT16_MAX));
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

    if (subsystem->common.macrdpMonitorLockInitialized) {
        EnterCriticalSection(&subsystem->common.macrdpMonitorLock);
    }
    const UINT32 monitor_count = mac_shadow_enum_monitors(subsystem->common.monitors, 16);
    if (monitor_count == 0 || subsystem->common.selectedMonitor >= monitor_count) {
        if (subsystem->common.macrdpMonitorLockInitialized) {
            LeaveCriticalSection(&subsystem->common.macrdpMonitorLock);
        }
        return -1;
    }
    subsystem->common.numMonitors = monitor_count;
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

    const auto options = capture_options_for_surface(subsystem);
    if (!options.has_value()) {
        return -1;
    }
    subsystem->capture = std::make_unique<macrdp::DisplayCapture>(*options);
    if (!subsystem->capture->start()) {
        WLog_ERR(TAG, "Unable to start ScreenCaptureKit: %s",
                 subsystem->capture->last_error().c_str());
        subsystem->capture.reset();
        return -1;
    }

    subsystem->stop_requested.store(false);
    subsystem->input_stop_requested.store(false);
    subsystem->common.captureFrameRate = options->frame_rate;
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
    try {
        subsystem->input_thread = std::thread(input_loop, subsystem);
        subsystem->publish_thread = std::thread(publish_loop, subsystem);
        subsystem->capture_thread = std::thread(capture_loop, subsystem);
        if (options->capture_audio) {
            subsystem->audio_thread = std::thread(audio_loop, subsystem);
        }
    } catch (...) {
        subsystem->stop_requested.store(true);
        subsystem->input_stop_requested.store(true);
        subsystem->capture->stop();
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
    subsystem->input_queue_condition.notify_all();
    subsystem->input_queue_space_condition.notify_all();
    const bool input_was_running = subsystem->input_thread.joinable();
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
    if (input_was_running) {
        // The input worker releases everything in its ownership ledger. This
        // second pass also clears a modifier left by an earlier process whose
        // ledger no longer exists.
        release_stale_modifier_state("subsystem stop");
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
    subsystem->capture.reset();
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

    subsystem->common.SynchronizeEvent = [](rdpShadowSubsystem* base, rdpShadowClient* client,
                                            UINT32 flags) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        return queue_synchronize_event(mac, input_client_id(mac, client), flags)
            ? true
            : false;
    };
    subsystem->common.KeyboardEvent = [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags,
                                         UINT8 code) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        return queue_keyboard_event(mac, input_client_id(mac, client), flags, code)
            ? true
            : false;
    };
    subsystem->common.UnicodeKeyboardEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 code) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            return queue_unicode_event(mac, input_client_id(mac, client), flags, code)
                ? true
                : false;
        };
    subsystem->common.MouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 x, UINT16 y) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
            return queue_mouse_event(mac, client, input_client_id(mac, client), flags, x, y)
            ? true
            : false;
        };
    subsystem->common.ExtendedMouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient* client, UINT16 flags, UINT16 x, UINT16 y) {
            auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
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
        return register_input_client(mac, client) != 0;
    };
    subsystem->common.ClientDisconnect = [](rdpShadowSubsystem* base, rdpShadowClient* client) {
        auto* mac = reinterpret_cast<MacShadowSubsystem*>(base);
        const auto client_id = unregister_input_client(mac, client);
        if (client_id != 0) {
            (void)queue_input_reset(mac, client_id);
        }
    };
    subsystem->common.ClientCapabilities = [](rdpShadowSubsystem*, rdpShadowClient*) {
        return true;
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
    std::uint32_t max_width,
    std::uint32_t max_height,
    std::uint32_t frame_rate,
    bool audio_enabled) {
    std::lock_guard lock(g_capture_config_mutex);
    g_capture_config.max_width = max_width;
    g_capture_config.max_height = max_height;
    g_capture_config.frame_rate = std::clamp(frame_rate, std::uint32_t{1}, std::uint32_t{60});
    g_capture_config.audio_enabled = audio_enabled;
}

bool macrdp_shadow_preflight_capture(std::string& error) {
    macrdp::DisplayCaptureOptions options;
    options.max_width = 64;
    options.max_height = 64;
    options.frame_rate = 1;
    options.show_cursor = false;
    {
        std::lock_guard lock(g_capture_config_mutex);
        options.capture_audio = g_capture_config.audio_enabled;
    }

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
