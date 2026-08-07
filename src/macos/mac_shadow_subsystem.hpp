#pragma once

#include <freerdp/server/shadow.h>

#ifdef __cplusplus
#include <cstdint>
#include <string>
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
    std::uint32_t max_width,
    std::uint32_t max_height,
    std::uint32_t frame_rate,
    bool audio_enabled);

#ifdef __cplusplus
}

// Validate ScreenCaptureKit before opening the RDP listener. The check uses a
// tiny stream and waits for one complete frame, so TCC and GUI-session errors
// are reported at startup instead of after the listener is already advertised.
bool macrdp_shadow_preflight_capture(std::string& error);

// Validate Accessibility permission before accepting a client. CoreGraphics
// event injection otherwise fails silently when TCC has not granted access.
bool macrdp_shadow_preflight_input(std::string& error);
#endif
