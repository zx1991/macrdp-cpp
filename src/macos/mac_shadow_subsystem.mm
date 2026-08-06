#include <freerdp/config.h>

#import <CoreGraphics/CoreGraphics.h>

#include <freerdp/input.h>
#include <freerdp/log.h>
#include <freerdp/server/shadow.h>
#include <winpr/input.h>
#include <winpr/synch.h>

#include "macrdp/display_capture.hpp"
#include "mac_shadow_subsystem.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>

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

struct mac_shadow_subsystem {
    rdpShadowSubsystem common{};
    std::unique_ptr<macrdp::DisplayCapture> capture;
    std::thread capture_thread;
    std::thread publish_thread;
    std::atomic_bool stop_requested{false};
    std::mutex lifecycle_mutex;
    std::mutex input_mutex;
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
    std::int32_t pointer_x = 0;
    std::int32_t pointer_y = 0;
    std::uint32_t last_frame_width = 0;
    std::uint32_t last_frame_height = 0;
    std::uint32_t last_surface_width = 0;
    std::uint32_t last_surface_height = 0;
    std::chrono::steady_clock::time_point last_slow_frame_log{};
};

using MacShadowSubsystem = struct mac_shadow_subsystem;

void free_pointer_position_message(UINT32, SHADOW_MSG_OUT* message) {
    std::free(message);
}

void publish_pointer_position(
    MacShadowSubsystem* subsystem,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr || subsystem->common.server == nullptr) {
        return;
    }

    subsystem->common.pointerX = x;
    subsystem->common.pointerY = y;

    auto* message = static_cast<SHADOW_MSG_OUT_POINTER_POSITION_UPDATE*>(
        std::calloc(1, sizeof(SHADOW_MSG_OUT_POINTER_POSITION_UPDATE)));
    if (message == nullptr) {
        WLog_WARN(TAG, "Unable to allocate RDP pointer position update");
        return;
    }

    message->common.Free = free_pointer_position_message;
    message->xPos = x;
    message->yPos = y;
    (void)shadow_client_boardcast_msg(
        subsystem->common.server,
        nullptr,
        SHADOW_MSG_OUT_POINTER_POSITION_UPDATE_ID,
        &message->common,
        nullptr);
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

bool post_keyboard_event(MacShadowSubsystem* subsystem, UINT16 flags, UINT8 code) {
    if (subsystem == nullptr) {
        return false;
    }

    bool extended = (flags & KBD_FLAGS_EXTENDED) != 0;
    UINT32 scan_code = code;
    if (extended) {
        scan_code |= KBDEXT;
    }

    UINT32 virtual_key = GetVirtualKeyCodeFromVirtualScanCode(scan_code, 4);
    if (extended) {
        virtual_key |= KBDEXT;
    }
    const UINT32 key_code = GetKeycodeFromVirtualKeyCode(
        virtual_key,
        WINPR_KEYCODE_TYPE_APPLE);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }

    // A missing RELEASE bit represents a key press, including the initial
    // press where KBD_FLAGS_DOWN is not set.
    const bool key_down = (flags & KBD_FLAGS_RELEASE) == 0;
    CGEventRef event = CGEventCreateKeyboardEvent(
        source,
        static_cast<CGKeyCode>(key_code),
        key_down);
    if (event == nullptr) {
        CFRelease(source);
        return false;
    }

    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    CFRelease(source);
    return true;
}

bool post_unicode_event(MacShadowSubsystem* subsystem, UINT16 flags, UINT16 code) {
    if (subsystem == nullptr) {
        return false;
    }

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

bool post_mouse_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
        return false;
    }

    std::lock_guard lock(subsystem->input_mutex);
    subsystem->pointer_x = x;
    subsystem->pointer_y = y;
    publish_pointer_position(subsystem, x, y);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return false;
    }

    const CGPoint point = display_point(subsystem, x, y);
    if ((flags & PTR_FLAGS_WHEEL) != 0 || (flags & PTR_FLAGS_HWHEEL) != 0) {
        const int rotation = static_cast<int>(flags & WheelRotationMask) / 120;
        const int signed_rotation = (flags & PTR_FLAGS_WHEEL_NEGATIVE) != 0
            ? -std::abs(rotation)
            : rotation;
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
        }
    }

    CGEventType button_type = kCGEventNull;
    CGMouseButton button = kCGMouseButtonLeft;
    bool* button_state = nullptr;
    if ((flags & PTR_FLAGS_BUTTON1) != 0) {
        button = kCGMouseButtonLeft;
        button_state = &subsystem->left_button_down;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventLeftMouseDown
            : kCGEventLeftMouseUp;
    } else if ((flags & PTR_FLAGS_BUTTON2) != 0) {
        button = kCGMouseButtonRight;
        button_state = &subsystem->right_button_down;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventRightMouseDown
            : kCGEventRightMouseUp;
    } else if ((flags & PTR_FLAGS_BUTTON3) != 0) {
        button = kCGMouseButtonCenter;
        button_state = &subsystem->other_button_down;
        button_type = (flags & PTR_FLAGS_DOWN) != 0
            ? kCGEventOtherMouseDown
            : kCGEventOtherMouseUp;
    }

    if (button_state != nullptr) {
        *button_state = (flags & PTR_FLAGS_DOWN) != 0;
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

bool post_extended_mouse_event(
    MacShadowSubsystem* subsystem,
    UINT16 flags,
    UINT16 x,
    UINT16 y) {
    if (subsystem == nullptr) {
        return false;
    }

    std::lock_guard lock(subsystem->input_mutex);
    subsystem->pointer_x = x;
    subsystem->pointer_y = y;
    publish_pointer_position(subsystem, x, y);
    const CGPoint point = display_point(subsystem, x, y);
    const bool down = (flags & PTR_XFLAGS_DOWN) != 0;
    const UINT16 button_flags = flags & (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_BUTTON2);
    if (button_flags == 0) {
        return true;
    }

    const CGMouseButton button = static_cast<CGMouseButton>(
        (button_flags & PTR_XFLAGS_BUTTON1) != 0 ? 3 : 4);
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
    const bool matching_dimensions = frame.width == surface->width
        && frame.height == surface->height;
    if (matching_dimensions && !frame.dirty_rects.empty()) {
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
        for (std::uint32_t y = 0; y < surface->height; ++y) {
            auto* destination = surface->data + y * surface->scanline;
            const auto* source = frame.bgra.data() + y * frame.stride;
            if (std::memcmp(destination, source, static_cast<std::size_t>(surface->width) * 4)
                != 0) {
                changed = true;
                break;
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
        }
    } else {
        // ScreenCaptureKit and RDP may use different Retina coordinate spaces.
        // Resample into the framebuffer dimensions instead of rejecting a valid
        // capture when the display mode changes.
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
    }

    if (changed && (!matching_dimensions || frame.dirty_rects.empty())) {
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
    LeaveCriticalSection(&surface->lock);

    if (!changed) {
        return true;
    }

    const auto copy_finished = std::chrono::steady_clock::now();
    // The surface lock must be released before this barrier: clients take
    // the same lock while consuming the published frame.
    shadow_subsystem_frame_update(&subsystem->common);
    const auto update_finished = std::chrono::steady_clock::now();

    const auto copy_time = std::chrono::duration_cast<std::chrono::milliseconds>(
        copy_finished - copy_started);
    const auto publish_wait = std::chrono::duration_cast<std::chrono::milliseconds>(
        update_finished - copy_finished);
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

void capture_loop(MacShadowSubsystem* subsystem) {
    while (!subsystem->stop_requested.load()) {
        auto frame = subsystem->capture->next_frame(std::chrono::milliseconds{250});
        if (frame.has_value()) {
            {
                std::lock_guard lock(subsystem->pending_frame_mutex);
                if (subsystem->stop_requested.load()) {
                    break;
                }
                // A slow RDP client must never turn capture into an unbounded queue.
                subsystem->pending_frame = std::move(frame);
            }
            subsystem->pending_frame_condition.notify_one();
            continue;
        }

        const std::string error = subsystem->capture->last_error();
        if (!error.empty() && !subsystem->stop_requested.load()) {
            request_capture_stop(subsystem, error.c_str());
            break;
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

        if (!copy_frame_to_surface(subsystem, *frame)) {
            request_capture_stop(subsystem, "Could not copy ScreenCaptureKit frame to RDP surface");
            break;
        }
    }
}

int mac_shadow_subsystem_init(rdpShadowSubsystem* base) {
    auto* subsystem = reinterpret_cast<MacShadowSubsystem*>(base);
    if (subsystem == nullptr) {
        return -1;
    }

    const UINT32 monitor_count = mac_shadow_enum_monitors(subsystem->common.monitors, 16);
    if (monitor_count == 0 || subsystem->common.selectedMonitor >= monitor_count) {
        return -1;
    }
    subsystem->common.numMonitors = monitor_count;
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

    auto options = macrdp::DisplayCaptureOptions{};
    const auto [surface_width, surface_height] = shadow_surface_dimensions(subsystem);
    if (surface_width == 0 || surface_height == 0) {
        return -1;
    }
    options.max_width = subsystem->capture_config.max_width == 0
        ? surface_width
        : std::min(
              subsystem->capture_config.max_width,
              surface_width);
    options.max_height = subsystem->capture_config.max_height == 0
        ? surface_height
        : std::min(
              subsystem->capture_config.max_height,
              surface_height);
    options.frame_rate = subsystem->capture_config.frame_rate;
    options.show_cursor = false;
    subsystem->capture = std::make_unique<macrdp::DisplayCapture>(options);
    if (!subsystem->capture->start()) {
        WLog_ERR(TAG, "Unable to start ScreenCaptureKit: %s",
                 subsystem->capture->last_error().c_str());
        subsystem->capture.reset();
        return -1;
    }

    subsystem->stop_requested.store(false);
    subsystem->common.captureFrameRate = options.frame_rate;
    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
    }
    try {
        subsystem->publish_thread = std::thread(publish_loop, subsystem);
        subsystem->capture_thread = std::thread(capture_loop, subsystem);
    } catch (...) {
        subsystem->stop_requested.store(true);
        subsystem->capture->stop();
        subsystem->pending_frame_condition.notify_all();
        if (subsystem->capture_thread.joinable()) {
            subsystem->capture_thread.join();
        }
        if (subsystem->publish_thread.joinable()) {
            subsystem->publish_thread.join();
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
    if (subsystem->capture != nullptr) {
        subsystem->capture->stop();
    }
    subsystem->pending_frame_condition.notify_all();
    if (subsystem->capture_thread.joinable()) {
        subsystem->capture_thread.join();
    }
    if (subsystem->publish_thread.joinable()) {
        subsystem->publish_thread.join();
    }
    {
        std::lock_guard frame_lock(subsystem->pending_frame_mutex);
        subsystem->pending_frame.reset();
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
    delete subsystem;
}

rdpShadowSubsystem* mac_shadow_subsystem_new() {
    auto* subsystem = new MacShadowSubsystem{};
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

    subsystem->common.SynchronizeEvent = [](rdpShadowSubsystem*, rdpShadowClient*, UINT32) {
        return true;
    };
    subsystem->common.KeyboardEvent = [](rdpShadowSubsystem* base, rdpShadowClient*, UINT16 flags,
                                         UINT8 code) {
        return post_keyboard_event(reinterpret_cast<MacShadowSubsystem*>(base), flags, code)
            ? true
            : false;
    };
    subsystem->common.UnicodeKeyboardEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient*, UINT16 flags, UINT16 code) {
            return post_unicode_event(reinterpret_cast<MacShadowSubsystem*>(base), flags, code)
                ? true
                : false;
        };
    subsystem->common.MouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient*, UINT16 flags, UINT16 x, UINT16 y) {
            return post_mouse_event(reinterpret_cast<MacShadowSubsystem*>(base), flags, x, y)
            ? true
            : false;
        };
    subsystem->common.ExtendedMouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient*, UINT16 flags, UINT16 x, UINT16 y) {
            return post_extended_mouse_event(
                       reinterpret_cast<MacShadowSubsystem*>(base), flags, x, y)
                ? true
                : false;
        };
    subsystem->common.RelMouseEvent =
        [](rdpShadowSubsystem* base, rdpShadowClient*, UINT16 flags, INT16 x_delta, INT16 y_delta) {
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
            return post_mouse_event(mac, flags | PTR_FLAGS_MOVE, x, y) ? true : false;
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
    subsystem->common.ClientConnect = [](rdpShadowSubsystem*, rdpShadowClient*) {
        return true;
    };
    subsystem->common.ClientDisconnect = [](rdpShadowSubsystem*, rdpShadowClient*) {};
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
    std::uint32_t frame_rate) {
    std::lock_guard lock(g_capture_config_mutex);
    g_capture_config.max_width = max_width;
    g_capture_config.max_height = max_height;
    g_capture_config.frame_rate = std::clamp(frame_rate, std::uint32_t{1}, std::uint32_t{60});
}

bool macrdp_shadow_preflight_capture(std::string& error) {
    macrdp::DisplayCaptureOptions options;
    options.max_width = 64;
    options.max_height = 64;
    options.frame_rate = 1;
    options.show_cursor = false;

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
