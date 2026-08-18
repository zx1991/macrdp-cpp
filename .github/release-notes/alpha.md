# macrdp-cpp Alpha

This is a source-only Alpha release of macrdp-cpp, an experimental native
macOS RDP server for sharing the logged-in Mac desktop with Windows Remote
Desktop (`mstsc`) or a FreeRDP client.

## Highlights

- ScreenCaptureKit display capture with display-topology recovery.
- H.264 AVC420 through OpenH264, VideoToolbox, or FFmpeg, with per-client
  adaptive pacing.
- Keyboard, pointer, text clipboard, and RDPSND speaker output paths.
- NLA authentication, loopback-safe defaults, view-only and clipboard controls.
- Deterministic lifecycle, protocol, reconnect, and package-validation tests.

## Requirements

- macOS 15 or newer on Apple Silicon.
- A logged-in graphical macOS session.
- Homebrew, CMake, OpenSSL 3, FFmpeg, and OpenH264 for the documented
  development build.

## Important

- This release contains source only. No signed or notarized DMG is attached.
- Use it for development or trusted LAN/VPN testing. Do not expose port 3389
  to the public internet.
- The Windows `mstsc` hardware matrix, real Developer ID notarization, and
  clean-machine release validation remain open gates.

Build instructions are in the [README](../../README.md#quick-start).
