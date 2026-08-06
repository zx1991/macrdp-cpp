# macrdp-cpp

An experimental C++/Objective-C++ implementation of the macOS remote desktop
building blocks. This is intentionally separate from the existing Rust
implementation in `../macrdp`.

## Current state

The project captures the main display as a real-time ScreenCaptureKit stream,
keeps only the newest BGRA frame, and encodes received frames with
VideoToolbox H.264. Public interfaces are pure C++; Apple framework adapters
are implemented in `src/macos/*.mm`.

The project now includes an experimental RDP shadow server. It reuses the
FreeRDP 3.30.0 server/shadow core, captures the macOS main display through
ScreenCaptureKit, and injects keyboard and mouse input through CoreGraphics.
The default security mode is NLA and the default video path uses a direct
VideoToolbox AVC420 H.264 encoder at 16 Mbps, with FreeRDP's FFmpeg encoder as
a fallback. H.264 encoding runs on a per-client worker while FreeRDP keeps
socket writes and input dispatch on its client thread. AVC444 remains available
for clients that need higher chroma fidelity; it uses the FFmpeg path because
the direct bridge currently accepts I420/AVC420 input.

The server currently does not expose a macOS microphone. FreeRDP's AUDIN input
channel is disabled, so Windows audio output can still be used without an
unused microphone channel affecting connection setup.

## Build

```bash
cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

CMake downloads and builds FreeRDP 3.30.0. FFmpeg and OpenSSL are required by
the selected FreeRDP configuration; Homebrew is the simplest way to provide
them on Apple Silicon:

```bash
brew install cmake ffmpeg openssl@3
```

The pinned FreeRDP archive is hash-verified. macrdp-specific FreeRDP changes
are kept in `patches/freerdp-macrdp-adaptations.patch` and applied only to the
generated `build/_deps` tree during configuration; no third-party source is
committed to this repository.

## Run

The standalone capture example still writes `capture.ppm` and
`capture.h264`:

```bash
./build/macrdp-cpp
open capture.ppm
```

An alternate H.264 output path can be supplied as the second argument:

```bash
./build/macrdp-cpp capture.ppm capture.h264
```

The first run requires Screen Recording permission. Grant it to the terminal
or executable in System Settings > Privacy & Security > Screen Recording.
Running from an SSH-only session will generally fail because ScreenCaptureKit
needs the logged-in graphical session and its TCC authorization.

### RDP server

Start the server from the logged-in macOS graphical session. The password is
read from standard input so it does not appear in the process list:

```bash
printf '%s\n' 'change-this-password' | \
  ./build/macrdp-server --user Xian --password-stdin
```

For a fast local connection, the default VideoToolbox AVC420/16 Mbps profile
is a good starting point. You can raise the bitrate or explicitly enable the
more expensive AVC444 path:

```bash
printf '%s\n' 'change-this-password' | \
  ./build/macrdp-server --user Xian --password-stdin --bitrate 24M

printf '%s\n' 'change-this-password' | \
  ./build/macrdp-server --user Xian --password-stdin --bitrate 24M --avc444
```

Then connect from Windows Remote Desktop (`mstsc`) to the Mac's IP address.
Use the same username and password. The server listens on TCP port 3389 by
default; use `--port 3390` and connect to `host:3390` when another service
already occupies that port.

If GFX/H.264 updates are slow on a high-latency or bandwidth-limited link,
try the incremental SurfaceBits path:

```bash
printf '%s\n' 'change-this-password' | \
  ./build/macrdp-server --user Xian --password-stdin --no-gfx
```

This path sends changed rectangles with the classic RDP update channel instead
of encoding every desktop update as a full-screen GFX/H.264 frame.

For an existing FreeRDP NTLM SAM file, use `--sam-file path/to/file.sam`.
`--security tls` and `--security rdp` are available for compatibility testing,
but NLA is the default and recommended mode. Empty passwords are rejected.

The server logs the captured frame size and RDP surface size once per change.
They should normally match; a difference means the captured image is being
scaled to the RDP surface. A `Slow frame update` warning reports capture-copy
and frame-publish time. `Slow client frame handling` reports time spent in the
FreeRDP client loop, including protocol output and completion delivery.
When the direct encoder is active, the log also contains `Using direct macOS
VideoToolbox H264 bridge`. If that line is replaced by a fallback warning,
the session is using software H.264 encoding.

The first server start requires Screen Recording permission. Grant it to the
terminal or executable in System Settings > Privacy & Security > Screen
Recording. ScreenCaptureKit generally cannot capture the desktop from an
SSH-only session; start the server inside the logged-in graphical session.
Keyboard and mouse injection also requires Accessibility permission. Grant it
to the terminal or executable in System Settings > Privacy & Security >
Accessibility. The server checks both permissions before it opens the RDP
listener.

## Layout

- `include/macrdp/`: C++ interfaces and data types; no Objective-C types.
- `src/`: portable C++ application logic.
- `src/macos/`: Objective-C++ adapters for Apple frameworks.
- `CMakeLists.txt`: manages C, C++, Objective-C, Objective-C++, FreeRDP, and
  Apple framework dependencies.

## Remaining milestones

1. Add automated protocol smoke tests with a FreeRDP client, including input,
   reconnect, resize, NLA, and slow-reader cases.
2. Verify input coordinates and display scaling across Retina and multi-monitor
   layouts, then add multi-monitor and display-mode change handling.
3. Package the server with its FFmpeg/OpenSSL runtime dependencies and document
   code-signing and TCC permission requirements.

## Encoder test

The encoder can be tested without Screen Recording permission using synthetic
BGRA frames:

```bash
./build/macrdp-cpp-encoder-test /tmp/macrdp-cpp-test.h264
```
