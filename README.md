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
a fallback. H.264 encoding runs on a per-client worker. FreeRDP receives input
on its client thread, then a separate macOS input worker performs CoreGraphics
injection; pure mouse motion is coalesced while clicks and keyboard events are
preserved in order. Synchronization events keep Caps Lock and Num Lock aligned,
and wheel events are posted at the remote pointer position. Scroll Lock key
events are forwarded normally; macOS does not expose a reliable public toggle
state for focus synchronization. Input state is owned per RDP client, so
disconnecting one client releases only the keys and buttons still owned by that
client. Pointer-position updates are sent to the other connected RDP clients,
so the client that generated the input event does not receive a redundant
echo. A stopped ScreenCaptureKit stream is restarted with bounded backoff
while the server is running. AVC444 remains available for clients that need higher chroma
fidelity; it uses the FFmpeg path because the direct bridge currently accepts
I420/AVC420 input.

The server keeps its configuration root private and only changes permissions on
the root, the FreeRDP `shadow` directory, `shadow.crt`, `shadow.key`, and the
generated `macrdp.sam`. Other files supplied under `--config-dir` are left
untouched; the known paths are rejected if they are symbolic links.

The server currently does not expose a macOS microphone. FreeRDP's AUDIN input
channel is disabled, so Windows audio output can still be used without an
unused microphone channel affecting connection setup.

The clipboard channel supports bidirectional text redirection through macOS
`NSPasteboard`. It advertises and transfers `CF_UNICODETEXT` and `CF_TEXT`.
Images, files, and directory data are intentionally not redirected yet.

## Build

```bash
cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

To create a relocatable package containing the server and its non-system
FFmpeg/OpenSSL/cJSON runtime libraries:

```bash
cmake --build build --target macrdp-package
```

Run the installed binary from the logged-in graphical macOS session:

```bash
read -r -s macrdp_password
printf '\n'
printf '%s\n' "$macrdp_password" | \
  ./build/macrdp-dist/bin/macrdp-server --user Xian --password-stdin
unset macrdp_password
```

The backslash must be the final character on a continued shell line. A
single-line command is equivalent and avoids shell continuation mistakes.

CMake downloads and builds FreeRDP 3.30.0. FFmpeg and OpenSSL are required by
the selected FreeRDP configuration; Homebrew is the simplest way to provide
them on Apple Silicon:

```bash
brew install cmake ffmpeg openssl@3
```

The default deployment target is macOS 15 because the current Homebrew
FFmpeg/OpenSSL arm64 binaries require macOS 15. To support an older macOS,
build compatible FFmpeg and OpenSSL binaries yourself and pass an explicit
`-DCMAKE_OSX_DEPLOYMENT_TARGET` value.

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

For a long-running server, store the password in an owner-only file and use
the supplied LaunchAgent installer. The file must be a regular file with no
group/other permissions, owned by the current user, and must contain one line:

```bash
umask 077
mkdir -p "$HOME/Library/Application Support/macrdp-cpp"
read -r -s macrdp_password
printf '\n'
printf '%s\n' "$macrdp_password" \
  > "$HOME/Library/Application Support/macrdp-cpp/password"
unset macrdp_password

./scripts/install_launch_agent.sh \
  ./build/macrdp-dist/bin/macrdp-server \
  Xian \
  "$HOME/Library/Application Support/macrdp-cpp/password"
```

The installer writes `~/Library/LaunchAgents/com.macrdp.cpp.server.plist`,
starts the service in the logged-in Aqua session, and writes logs below
`~/Library/Logs/macrdp-cpp`. Grant Screen Recording and Accessibility to the
exact server executable used by the LaunchAgent. The same mechanism can be
used manually with `--password-file` when LaunchAgent is not desired.

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

The default listener binds all local addresses. Restrict it when the server
should only be reachable through one interface:

```bash
printf '%s\n' 'change-this-password' | \
  ./build/macrdp-server --bind-address 127.0.0.1 --user Xian --password-stdin
```

For a remote RDP client, replace `127.0.0.1` with the Mac's address on the
network used by that client. The address must belong to a local interface on
the Mac; it is not the Windows client's address.

For an IPv6 address, include brackets, for example `--bind-address [::1]`.

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
scaled to the RDP surface. `Frame pipeline` reports capture-copy time,
surface-copy time, the number of coalesced frames, and the time spent waiting
for the client publish barrier. A `Slow frame update` warning reports the same
surface-copy and publish-wait stages for an individual slow update.
`Slow client frame handling` reports time spent in the FreeRDP client loop,
including protocol output and completion delivery.
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

For an installed binary, grant TCC permissions to the exact executable at
`build/macrdp-dist/bin/macrdp-server` (or to the terminal used to launch it).
The package script rewrites non-system dependencies to package-relative paths
and rejects leftover build-machine paths; it is still ad-hoc signed. Developer
ID signing and notarization remain deployment tasks for distributing the
install to other Macs.

### Automated loopback smoke test

The repository includes a small FreeRDP client used only for protocol testing.
It connects over `127.0.0.1`, records decoded frame timing and negotiated GFX
codec counts, sends mouse clicks plus harmless keyboard, Unicode, and vertical/
horizontal wheel events, checks the server's aggregated input counters, verifies
bidirectional text clipboard transfer, tests a wrong NLA password, and compares
GFX/AVC420 with the `--no-gfx` SurfaceBits path. The direct profile also checks
reconnects, requested desktop sizes, and a deliberately slow client event loop.
The client-reported frame pacing is the primary slow-client metric; server slow
stage diagnostics are supplementary observations. The server logs an `Input
pipeline` line with received event counts and platform injection failures. No
third-party source is copied or modified by this test.

The normal macrdp build intentionally does not build a FreeRDP client, so
build the test client against a separate FreeRDP client build:

```bash
tools/build_loopback_client.sh \
  /path/to/freerdp-client-build \
  /path/to/FreeRDP-3.30.0 \
  /tmp/macrdp-loopback-client
```

Run it from the logged-in graphical session using the current server binary:

```bash
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
tools/run_loopback_smoke.sh
```

The script uses TCP port 3390 by default and refuses to touch an existing
listener. Set `MACRDP_LOOPBACK_PORT` to use another port. Set
`MACRDP_LOOPBACK_KEEP_TEMP=1` to retain logs, or use
`MACRDP_LOOPBACK_DURATION_MS`, `MACRDP_LOOPBACK_MAX_INTERVAL_MS`, and
`MACRDP_LOOPBACK_INPUT_SETTLE_SECONDS` to adjust the sampling duration, timing
threshold, and post-client input drain wait. Set
`MACRDP_LOOPBACK_NOGFX_DURATION_MS` when the classic SurfaceBits path needs a
different observation window; the Wi-Fi profile defaults this to 30 seconds
because its 1 Mbps link can take several seconds per full-screen update.
Screen Recording and Accessibility permissions are still required because the
server captures and injects real macOS desktop events; the test verifies
protocol delivery, not the visual effect of a click in an arbitrary foreground
application.

The optional C TCP proxy applies deterministic one-way delay, jitter, per-
direction bandwidth shaping, and periodic forwarding outages. Build it once:

```bash
tools/build_loopback_proxy.sh /tmp/macrdp-loopback-proxy
```

Then select a profile:

```bash
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
MACRDP_LOOPBACK_PROXY=/tmp/macrdp-loopback-proxy \
MACRDP_LOOPBACK_NETWORK_PROFILE=wifi \
tools/run_loopback_smoke.sh
```

Available profiles are `direct` (no proxy), `wan` (50 ms one-way delay,
10 ms jitter, 5 Mbps), `wifi` (75 ms delay, 40 ms jitter, 1 Mbps, and a
300 ms outage every 5 seconds), `outage` (50 ms delay, 50 ms jitter, 5 Mbps,
and a 500 ms outage every 3 seconds), and `bad` (150 ms delay, 100 ms jitter,
256 Kbps, and a 1 second outage every 4 seconds). The bandwidth is applied
independently in each direction. The `wifi` classic path gets a longer default
window so the test checks eventual delivery under low bandwidth; the `bad`
profile intentionally runs the GFX path only. Frame thresholds are
mode-specific so a low-bandwidth test checks delivery and recovery without
requiring the same frame rate as a direct connection. An outage pauses
forwarding without discarding TCP bytes, so it models a stalled link and
recovery rather than packet loss or a dropped connection.

## Layout

- `include/macrdp/`: C++ interfaces and data types; no Objective-C types.
- `src/`: portable C++ application logic.
- `src/macos/`: Objective-C++ adapters for Apple frameworks.
- `CMakeLists.txt`: manages C, C++, Objective-C, Objective-C++, FreeRDP, and
  Apple framework dependencies.

## Remaining work

The local unit tests and loopback smoke test cover frame coalescing,
display-size calculation, H.264, the asynchronous encoder worker, multi-client
input ownership, NLA failure handling, keyboard/Unicode/mouse/wheel input,
bidirectional text clipboard, reconnects, requested sizes, slow clients, and
deterministic delay/bandwidth/outage profiles. The remaining validation that
requires a graphical macOS session and a Windows `mstsc` client is:

1. Verify NLA, keyboard, Unicode input, left/right and side buttons, drag,
   wheel, text clipboard in both directions, reconnect, window resize, and
   behavior after a current-build connection is interrupted.
2. Verify Retina coordinate mapping and display-mode changes on the hardware
   used for deployment. The server still captures only the main display and
   does not offer multi-monitor selection.
3. Validate the text-only clipboard implementation with current Windows
   `mstsc`, then add image/file redirection only if the use case requires it.
4. Add a macOS microphone/AUDIN implementation if microphone redirection is
   required. The current server supports audio output through RDPSND only.
5. Add Developer ID signing and notarization for distribution. The local
   package now carries its non-system runtime dependency closure, but it still
   includes the full FFmpeg dependency graph and needs a distribution identity.

## Encoder test

The encoder can be tested without Screen Recording permission using synthetic
BGRA frames:

```bash
./build/macrdp-cpp-encoder-test /tmp/macrdp-cpp-test.h264
```
