# macrdp-cpp

[![macOS build](https://github.com/zx1991/macrdp-cpp/actions/workflows/macos.yml/badge.svg)](https://github.com/zx1991/macrdp-cpp/actions/workflows/macos.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

An experimental C++/Objective-C++ RDP server for sharing the logged-in macOS
desktop with a Windows Remote Desktop (`mstsc`) client. It combines
ScreenCaptureKit, CoreGraphics, VideoToolbox, and a pinned FreeRDP 3.30.0
shadow server.

> **Project status: Alpha.** The server is useful for development and trusted
> network testing, but it is not yet a production-ready or publicly
> distributable remote desktop product. Read the [security policy](SECURITY.md)
> and [release gates](docs/roadmap.md) before exposing a listener.

## What works

| Area | Current implementation |
| --- | --- |
| Display | Main-display ScreenCaptureKit capture with newest-frame coalescing |
| Video | GFX/AVC420 through direct VideoToolbox, FFmpeg fallback, optional AVC444, or classic SurfaceBits |
| Input | Serialized keyboard, Unicode, pointer, button, drag, and wheel injection through a private CoreGraphics event source |
| Clipboard | Bidirectional `CF_UNICODETEXT` and `CF_TEXT` through `NSPasteboard` |
| Audio | Screen audio capture and RDPSND output; AAC or PCM depends on negotiation |
| Security | NLA and loopback-only listening by default, one concurrent client, explicit legacy-security opt-in, view-only and clipboard opt-out controls |
| Reliability | Per-client input ownership isolated from local HID state, bounded queues, capture restart backoff, and generation-isolated capture lifecycle |
| Validation | Local state-machine and injected capture-lifecycle tests, real FreeRDP loopback client, and deterministic shaped-network profiles |

The runtime separates capture, audio, input injection, per-client encoding, and
FreeRDP transport work. See [Architecture](docs/architecture.md) for ownership
and backpressure details.

## Current limits

- The main display is the only capture target; there is no monitor picker.
- Multi-client sessions share one captured display and have not completed the
  supported Windows hardware matrix; keep the concurrent-client limit low.
- Clipboard redirection is text-only. File, image, and directory transfer are
  not implemented.
- RDPSND speaker output is supported, but microphone/AUDIN input is disabled.
- Current Homebrew FFmpeg and OpenSSL arm64 packages require macOS 15. Older
  targets need a separately built compatible dependency set.
- The package target creates a relocatable, ad-hoc-signed developer payload.
  Developer ID signing, notarization, third-party license collection, SBOM
  generation, and deployment-target enforcement are still release work.
- The automated loopback client verifies protocol delivery, but final input,
  Retina, reconnect, and sleep/wake behavior still needs a real Windows
  `mstsc` validation matrix on supported hardware.

The prioritized acceptance gates are tracked in [Roadmap](docs/roadmap.md).

## Requirements

- A logged-in graphical macOS session. ScreenCaptureKit generally cannot
  capture the desktop from an SSH-only session.
- macOS 15 and Apple Silicon for the currently documented Homebrew build.
- Xcode Command Line Tools, CMake 3.25 or newer, FFmpeg, and OpenSSL 3.
- Screen Recording permission for capture. Accessibility permission is required
  for interactive sessions, but not when the server uses `--view-only`.

Install the development dependencies with Homebrew:

```bash
brew install cmake ffmpeg openssl@3
```

## Build

```bash
cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

The first configure downloads and hash-verifies FreeRDP 3.30.0. Project
adaptations are applied from
`patches/freerdp-macrdp-adaptations.patch` to the generated `build/_deps`
tree. Do not edit generated dependency sources directly.

To use dependencies built for an older macOS version, configure with a matching
`-DCMAKE_OSX_DEPLOYMENT_TARGET` and ensure every linked library supports that
same target.

### Optional local code signing

An exact-executable macOS TCC grant can stop matching when an ad-hoc-signed
binary is rebuilt. Developers can set `MACRDP_CODESIGN_IDENTITY` to a persistent
Code Signing identity and optionally override `MACRDP_CODESIGN_IDENTIFIER`;
the `macrdp-server` target is then signed after each link. The identity and its
private key must remain in the developer's keychain and must never be stored in
the repository. This option is disabled by default and does not replace
Developer ID signing and notarization for public releases.

## Run the server

Grant Screen Recording permission to the terminal or exact server executable
before starting it. For an SSH-launched process, grant the persistently signed
server executable rather than an unrelated local terminal application.
Interactive sessions also require Accessibility permission.
The server checks every permission required by the selected access policy before
opening the RDP listener.

Check the exact signed executable without credential input, configuration
changes, or a listening socket:

```bash
./build/macrdp-server --preflight --no-audio
```

When working through SSH, use the temporary Aqua preflight and owner-only
diagnostic bundle described in the [hardware validation matrix](docs/hardware-matrix.md).

Use a placeholder account name such as `example-user` only in documentation;
the client must enter the same name supplied to the server. Read the password
from standard input so it is not exposed in the process list:

```bash
read -r -s macrdp_password
printf '\n'
printf '%s\n' "$macrdp_password" | \
  ./build/macrdp-server \
    --bind-address 127.0.0.1 \
    --user example-user \
    --password-stdin
unset macrdp_password
```

This local-only example requires a tunnel or a client on the same Mac. Omitting
`--bind-address` has the same loopback-only behavior. For a remote client,
explicitly set the Mac's address on the trusted network used by that client;
avoid wildcard addresses such as `0.0.0.0` unless a firewall or VPN restricts
reachability. The default port is TCP 3389; use `--port 3390` and connect to
`host:3390` when needed. IPv6 literals must include brackets, for example
`[::1]`.

NLA is the default and recommended security mode. `--security tls` and
`--security rdp` exist only for compatibility testing, disable NLA, and are
rejected unless `--allow-insecure-security` is also supplied. Empty passwords
are rejected. An existing FreeRDP SAM can be supplied with `--sam-file`.

Access and media controls can be appended to the server command above:

| Goal | Option |
| --- | --- |
| Disable remote keyboard and pointer input | `--view-only` |
| Disable clipboard redirection | `--no-clipboard` |
| Allow up to four concurrent clients | `--max-clients 4` |
| Higher AVC420 bitrate | `--bitrate 24M` |
| Require direct macOS AVC420 | `--h264-encoder videotoolbox` |
| Force software AVC420 | `--h264-encoder ffmpeg` |
| Higher chroma fidelity through FFmpeg | `--avc444` |
| Classic incremental updates | `--no-gfx` |
| Disable screen audio and RDPSND | `--no-audio` |

The concurrent-client limit defaults to one and accepts values from 1 through
64. `--view-only` disables only remote keyboard and pointer input; clipboard and
audio remain independent capabilities. For a screen-only session, combine
`--view-only --no-clipboard --no-audio`. Run `./build/macrdp-server --help` for
the complete option list.

## Package and LaunchAgent

Create the relocatable developer payload with:

```bash
cmake --build build --target macrdp-package-validate
```

The output is `build/macrdp-dist`. The packaging script copies non-system
dynamic libraries, rewrites load paths, rejects references that escape the
package, and applies an ad-hoc signature. The validation target independently
checks load paths, architectures, minimum macOS versions, signatures, and a
packaged `--help` loader smoke check. It does not start a listener or require
TCC permissions. The payload is not a notarized installer and should not be
published as a release artifact yet.

For a long-running instance, create an owner-only one-line password file and
install the supplied per-user LaunchAgent:

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
  example-user \
  "$HOME/Library/Application Support/macrdp-cpp/password"
```

The service runs in the logged-in Aqua session and writes logs below
`~/Library/Logs/macrdp-cpp`. Grant TCC permissions to the exact packaged
executable used by the LaunchAgent. To apply access controls or other server
options, pass them after `--`. Because the listener defaults to loopback, a
remote service must explicitly append
`-- --bind-address <trusted-interface-address>`.
For a screen-only service, add `--view-only --no-clipboard --no-audio` after
the same `--` separator.

Rotate the LaunchAgent's RDP password interactively with:

```bash
./scripts/rotate_launch_agent_password.sh \
  "$HOME/Library/Application Support/macrdp-cpp/password"
```

The helper verifies that the loaded LaunchAgent uses that exact owner-only
password file, atomically replaces it, and restarts the service. Existing
sessions are terminated by the restart; verify a new connection with the new
password and confirm the old password no longer works. A secret manager can
pipe exactly one password line with `--stdin`. This workflow does not rotate an
externally managed `--sam-file`; replace that SAM through its own provisioning
process and restart the service instead.

## Tests

The local suite uses synthetic frames and state-machine tests, so it does not
need Screen Recording permission:

```bash
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

CI also builds the full static dependency graph with AddressSanitizer and
UndefinedBehaviorSanitizer, runs the deterministic suite, and repeats the
concurrency and lifecycle state-machine tests 50 times. This job does not open
an RDP listener, capture the display, or inject input. See
[Testing](docs/testing.md) for the equivalent isolated build and runtime
options.

The real loopback smoke test builds a separate FreeRDP client, starts the
server, changes the logged-in user's clipboard, and injects actual keyboard and
pointer events. Run it only in a controlled graphical session. It covers NLA,
GFX and SurfaceBits, input paths, text clipboard, audio, reconnects, requested
sizes, slow clients, and shaped network profiles.

See [Testing](docs/testing.md) for build commands, safety notes, profile
parameters, expected metrics, and failure diagnosis.

The view-only hardware lifecycle harness can exercise 20 bounded server
start/stop cycles without connecting a client. From SSH, run
`tools/run_hardware_lifecycle.sh --aqua`; its owner-only evidence includes
per-cycle listener, shutdown, and modifier-state checks.

The standalone capture/encoder example remains available:

```bash
./build/macrdp-cpp capture.ppm capture.h264
./build/macrdp-cpp-encoder-test /tmp/macrdp-cpp-test.h264
```

## Repository layout

- `include/macrdp/`: portable C++ interfaces and state helpers.
- `src/`: portable applications and deterministic tests.
- `src/macos/`: Objective-C++ adapters for Apple frameworks and FreeRDP.
- `tools/`: loopback client, network shaper, and smoke-test scripts.
- `scripts/`: packaging and LaunchAgent helpers.
- `patches/`: version-pinned FreeRDP adaptations.
- `docs/`: architecture, testing, and roadmap documentation.

## Documentation

- [Architecture](docs/architecture.md): runtime pipeline and ownership
  boundaries.
- [Testing](docs/testing.md): local, loopback, and shaped-network validation.
- [Hardware matrix](docs/hardware-matrix.md): P0 lifecycle and real Windows
  acceptance record.
- [Roadmap](docs/roadmap.md): prioritized work and release gates.
- [Changelog](CHANGELOG.md): user-visible changes.
- [Contributing](CONTRIBUTING.md): development and pull request expectations.
- [Security policy](SECURITY.md): deployment warnings and private reporting.

## Contributing and security

Keep changes focused, update tests and documentation together, and never commit
generated `build/_deps` content. Changes to the FreeRDP boundary must update the
checked-in patch and its pinned-version assumptions together.

This software exposes the desktop and, unless disabled, clipboard, audio, and
input injection. Treat every listener and credential as security-sensitive,
grant only the capabilities needed for the deployment, and report
vulnerabilities through the repository's private security reporting channel,
not a public issue.

## License

Project-owned code and documentation are licensed under Apache License 2.0.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). FreeRDP and bundled runtime
dependencies retain their own upstream licenses and notices.
