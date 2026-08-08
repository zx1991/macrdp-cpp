# Changelog

This project has not published a stable release yet.

## Unreleased

- Experimental macOS RDP shadow server with NLA authentication.
- ScreenCaptureKit display capture and VideoToolbox AVC420 encoding.
- CoreGraphics keyboard and mouse injection with per-client input ownership.
- Text clipboard redirection and RDPSND audio output.
- Local unit tests, FreeRDP loopback validation, and deterministic network
  stress profiles.
- Explicit H.264 encoder selection for VideoToolbox, FFmpeg, and AVC444
  loopback comparisons.
- Serialized macOS pasteboard access and expanded shaped-link reconnect,
  resize, and clipboard-change validation.
- Added explicit `--reconnect` and `--no-reconnect` controls for running the
  long-budget Wi-Fi and bad-link reconnect profiles.
- Added raw keyboard-path diagnostics, queue-delay metrics, and loopback
  coverage for FastPath, classic input, Pause/E1, and modifier-release recovery.
