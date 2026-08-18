# macrdp-cpp Alpha

This is an Alpha developer preview of macrdp-cpp, an experimental native
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

- The attached DMG is a complete arm64 runtime package, ad-hoc signed and not
  notarized. macOS may require right-click -> Open on first launch.
- Use it for development or trusted LAN/VPN testing. Do not expose port 3389
  to the public internet.
- The Windows `mstsc` hardware matrix, real Developer ID notarization, and
  clean-machine release validation remain open gates.

## Artifacts

- `macrdp-cpp-0.1.0-macos-arm64-developer-preview.dmg`: complete runtime
  package for macOS 15+ on Apple Silicon.
- `macrdp-ffmpeg-sources-7.1.1.tar.gz`: corresponding source for the pinned
  LGPL FFmpeg build.
- `SHA256SUMS`: checksums for the downloadable artifacts.

Build instructions are in the [README](../../README.md#quick-start).
