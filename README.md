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

For an installed binary, grant TCC permissions to the exact executable at
`build/macrdp-dist/bin/macrdp-server` (or to the terminal used to launch it).
The package script rewrites non-system dependencies to package-relative paths
and rejects leftover build-machine paths; it is still ad-hoc signed. Developer
ID signing and notarization remain deployment tasks for distributing the
install to other Macs.

## Layout

- `include/macrdp/`: C++ interfaces and data types; no Objective-C types.
- `src/`: portable C++ application logic.
- `src/macos/`: Objective-C++ adapters for Apple frameworks.
- `CMakeLists.txt`: manages C, C++, Objective-C, Objective-C++, FreeRDP, and
  Apple framework dependencies.

## Remaining work

The local unit tests cover frame coalescing, display-size calculation, H.264,
the asynchronous encoder worker, and multi-client input ownership. The highest
priority validation still requires a graphical macOS session and a Windows
`mstsc` client:

1. Run a current-build matrix for NLA, keyboard, Unicode input, left/right and
   side buttons, drag, wheel, text clipboard in both directions, reconnect,
   window resize, and a slow client.
2. Collect fresh `Slow client frame handling` and `Frame barrier` logs. Logs
   from before the asynchronous worker and non-blocking output changes are not
   evidence about the current build.
3. Verify Retina coordinate mapping and display-mode changes on the hardware
   used for deployment. The server still captures only the main display and
   does not offer multi-monitor selection.
4. Add a repeatable protocol smoke test. No FreeRDP client binary is built by
   this repository, and `mstsc` remains the compatibility target.
5. Validate the text-only clipboard implementation with current Windows
   `mstsc`, then add image/file redirection only if the use case requires it.
6. Add a macOS microphone/AUDIN implementation if microphone redirection is
   required. The current server supports audio output through RDPSND only.
7. Add Developer ID signing and notarization for distribution. The local
   package now carries its non-system runtime dependency closure, but it still
   includes the full FFmpeg dependency graph and needs a distribution identity.

## Encoder test

The encoder can be tested without Screen Recording permission using synthetic
BGRA frames:

```bash
./build/macrdp-cpp-encoder-test /tmp/macrdp-cpp-test.h264
```
