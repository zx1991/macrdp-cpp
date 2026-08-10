#pragma once

#include <freerdp/server/shadow.h>

#ifdef __cplusplus
#include <cstdint>
#include <string>
#include <vector>
#endif

#ifdef __cplusplus
extern "C"
{
#endif

int macrdp_shadow_subsystem_entry(RDP_SHADOW_ENTRY_POINTS* entry_points);

void macrdp_shadow_set_credentials(
    const char* username,
    const char* domain,
    const char* password);

void macrdp_shadow_set_capture_options(
    std::uint32_t display_id,
    std::uint32_t max_width,
    std::uint32_t max_height,
    std::uint32_t frame_rate,
    bool audio_enabled);

void macrdp_shadow_set_input_enabled(bool enabled);

#ifdef __cplusplus
}

struct MacrdpDisplayInfo {
    std::uint32_t id = 0;
    std::uint32_t pixel_width = 0;
    std::uint32_t pixel_height = 0;
    double point_width = 0.0;
    double point_height = 0.0;
    double origin_x = 0.0;
    double origin_y = 0.0;
    bool main = false;
};

// Enumerate active displays without starting ScreenCaptureKit or requesting
// Screen Recording permission.
bool macrdp_shadow_enumerate_displays(
    std::vector<MacrdpDisplayInfo>& displays,
    std::string& error);

// Resolve zero to the current main display and validate exact non-zero IDs.
bool macrdp_shadow_resolve_display_id(
    std::uint32_t requested_display_id,
    std::uint32_t& resolved_display_id,
    std::string& error);

// Validate ScreenCaptureKit before opening the RDP listener. The check uses a
// tiny stream and waits for one complete frame, so TCC and GUI-session errors
// are reported at startup instead of after the listener is already advertised.
bool macrdp_shadow_preflight_capture(std::string& error);

// Validate Accessibility permission before accepting a client. CoreGraphics
// event injection otherwise fails silently when TCC has not granted access.
bool macrdp_shadow_preflight_input(std::string& error);
#endif
