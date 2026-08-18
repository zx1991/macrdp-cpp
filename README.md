# macrdp-cpp

[![macOS build](https://github.com/zx1991/macrdp-cpp/actions/workflows/macos.yml/badge.svg)](https://github.com/zx1991/macrdp-cpp/actions/workflows/macos.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20%7C%20Apple%20Silicon-lightgrey.svg)](docs/hardware-matrix.md)

Native macOS RDP server for connecting to the logged-in Mac desktop from
Windows Remote Desktop (`mstsc`) or a FreeRDP client. It combines
ScreenCaptureKit, CoreGraphics, VideoToolbox, and a pinned macrdp FreeRDP
3.30.0 fork.

[Quick start](#quick-start) · [Capabilities](#capabilities) · [Current limits](#current-limits) · [Releases](https://github.com/zx1991/macrdp-cpp/releases) · [Roadmap](docs/roadmap.md)

> **Project status: Alpha.** The server is useful for development and trusted
> network/VPN testing, but it is not yet a production-ready or officially
> released remote desktop product. Read the [security policy](SECURITY.md) and
> [release gates](docs/roadmap.md) before exposing a listener.

## At a glance

| | | | |
| --- | --- | --- | --- |
| **Target** | macOS 15+ on Apple Silicon | **Client** | Windows Remote Desktop or FreeRDP |
| **Transport** | RDP with NLA by default | **License** | Apache-2.0 for project code |
| **Best for** | Development, lab use, and trusted LAN/VPN access | **Distribution** | Build from source; public signed binaries are not available yet |

## Quick start

The shortest path is a local development build. A graphical macOS login is
required; Screen Recording permission is needed for capture, and Accessibility
permission is needed for keyboard and pointer input.

1. Install the [prerequisites](#requirements):

   ```bash
   brew install cmake ffmpeg openh264 openssl@3
   ```

2. Build and run the test suite:

   ```bash
   cmake -S . -B build -G "Unix Makefiles" \
     -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_OSX_ARCHITECTURES=arm64
   cmake --build build --parallel 8
   ctest --test-dir build --output-on-failure
   ```

3. Start the server on a trusted LAN or VPN:

   ```bash
   ./build/macrdp-server --preset standard
   ```

   The server prints the RDP username and prompts for its password without
   echoing it. On Windows, open `mstsc`, connect to the Mac's address on port
   `3389`, and use that username and password. The `standard` preset listens
   on all interfaces; use `--preset local` for loopback-only testing or read
   [Server presets](docs/presets.md) before exposing a listener.

For a remote session, use a trusted LAN/VPN address. Do not forward port 3389
to the public internet. The [security policy](SECURITY.md) explains the
authentication, permissions, and access-policy requirements.

## Capabilities

| Area | Current implementation |
| --- | --- |
| Display | Exact selection of one active display with generation-tagged mode-change recovery and newest-frame coalescing |
| Video | Version-aware GFX/AVC420 through direct VideoToolbox, FFmpeg fallback, optional AVC444, or classic SurfaceBits; default AVC420 uses reference-safe full-frame input and presentation |
| Input | Serialized keyboard, Unicode, pointer, button, drag, and wheel injection through a private CoreGraphics event source |
| Clipboard | Bidirectional `CF_UNICODETEXT` and `CF_TEXT` through `NSPasteboard`, with per-connection request correlation |
| Audio | Generation-isolated screen audio and negotiation-gated RDPSND output; AAC or PCM depends on client formats |
| Security | NLA and loopback-only listening by default, one concurrent client, explicit legacy-security opt-in, view-only and clipboard opt-out controls |
| Reliability | Atomically stopped per-client input, clipboard, audio, and output state, bounded queues, capture restart backoff, and generation-isolated display lifecycles |
| Validation | Local state-machine, 100-cycle reconnect, and injected capture-lifecycle tests, real FreeRDP loopback client, and deterministic shaped-network profiles |

The runtime separates capture, audio, input injection, per-client encoding, and
FreeRDP transport work. See [Architecture](docs/architecture.md) for ownership
and backpressure details.

<details>
<summary>Adaptive video delivery details</summary>

RDPGFX codec support is negotiated per client. Version 8.1 clients enable
AVC420 with `AVC420_ENABLED`, while 10.x clients enable AVC420 and AVC444 by
omitting `AVC_DISABLED`; unknown versions do not enable either codec. Codec
capabilities are not a bandwidth measurement. `--max-bitrate` and `--max-fps`
are ceilings; each H.264 client starts conservatively and independently adapts
its encoder bitrate and send pacing from presentation ACK latency, decoder
queue depth, transport queue pressure, and blocked writes. Brief write stalls
are tolerated; a blocked interval reduces send pacing once after 750 ms, while
bitrate reduction still requires two seconds of continuous pressure. Genuinely
slow or stalled acknowledgements apply stronger reductions. Four healthy
acknowledgements drive fast recovery from the conservative starting targets;
later increases are additive and require a longer healthy interval. Any output
pressure clears pending recovery samples, and queue pressure holds further
increases for five seconds. Client output suppression is excluded from
congestion decisions.
Capture keeps the global maximum rate and newest updates coalesce before each
client's next paced encode. The independent RDPGFX frame window starts at one
and initially probes two after four acknowledgements of 1.25 seconds or less.
A demotion blocks another promotion for five seconds; reopening then requires
six acknowledgements of 750 ms or less. This keeps dependent AVC420 frames
bounded without letting one slow client change another client's delivery
policy.

</details>

## Current limits

- Capture targets one active display at a time; combined-desktop spanning and
  changing the selected display without restarting the server is not implemented.
- Multi-client sessions share one captured display and have not completed the
  supported Windows hardware matrix; keep the concurrent-client limit low.
- Clipboard redirection is text-only. File, image, and directory transfer are
  not implemented.
- RDPSND speaker output is supported, but microphone/AUDIN input is disabled.
- Adaptive send pacing applies to every H.264 backend. OpenH264 and the direct
  VideoToolbox bridge also apply bitrate changes to an open encoder; the
  explicit generic FFmpeg path does not currently guarantee live bitrate
  reconfiguration.
- The pinned release dependency set and current Homebrew development packages
  target macOS 15. Older targets need a separately built compatible set.
- The package and distribution targets create a relocatable, ad-hoc-signed
  developer payload and DMG. The pinned LGPL FFmpeg build, compliance metadata,
  corresponding-source bundle, versioned per-user lifecycle, and gated
  Developer ID/notarization pipeline are implemented; a real Apple notarization
  run and clean-machine release validation remain release work.
- The automated suite verifies display topology transitions and protocol
  delivery, but visual rotation, physical hot-plug, final input, Retina,
  reconnect, and sleep/wake behavior still need a real Windows `mstsc`
  validation matrix on supported hardware.

The prioritized acceptance gates are tracked in [Roadmap](docs/roadmap.md).

## Requirements

- A logged-in graphical macOS session. ScreenCaptureKit generally cannot
  capture the desktop from an SSH-only session.
- macOS 15 and Apple Silicon for the documented development and release builds.
- Xcode Command Line Tools, CMake 3.25 or newer, Ruby, and OpenSSL 3. Homebrew
  FFmpeg is also required for the shortest development build.
- Screen Recording permission for capture. Accessibility permission is required
  for interactive sessions, but not when the server uses `--view-only`.

Install the development dependencies with Homebrew:

```bash
brew install cmake ffmpeg openh264 openssl@3
```

## Build

```bash
cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

The first configure downloads and hash-verifies the macrdp FreeRDP 3.30.0 fork
at an immutable commit. Its repository, commit, archive URL, and SHA-256 are
declared in `third_party/freerdp/manifest.json`. Do not edit generated
dependency sources under `build/_deps` directly.

The command above is the shortest development setup and may use Homebrew's GPL
FFmpeg build. It is not the dependency path used for official binary artifacts.

### Release-equivalent FFmpeg build

Build the pinned minimal FFmpeg 7.1.1 dependency, then point CMake at its
verified prefix and provenance:

```bash
scripts/build_macos_ffmpeg.sh build/third_party/ffmpeg arm64 15.0

cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DMACRDP_FFMPEG_ROOT="$PWD/build/third_party/ffmpeg/prefix" \
  -DMACRDP_FFMPEG_PROVENANCE="$PWD/build/third_party/ffmpeg/provenance.json"
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

This configuration builds only `libavcodec`, `libavutil`, `libswresample`, and
`libswscale`, dynamically linked under LGPL-2.1-or-later. It enables the H.264
VideoToolbox, AAC, and PCM paths used by macrdp and rejects GPL, version3,
nonfree, x264, and x265 options. Homebrew FFmpeg remains supported for local
development only.

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

For the shortest interactive startup, use the balanced OpenH264 preset:

```bash
./build/macrdp-server --preset standard
```

It uses TCP 3389, NLA, the current macOS username, the main display, a 16 Mbps
adaptive bitrate ceiling, a 30 FPS capture/send ceiling, OpenH264, a 10-frame
key-frame interval, one client, and no audio. It
prompts for the RDP password without echoing it. The client must enter the
username shown in that prompt. Override only values that differ, for example
`--user Xian`, `--display-id 5`, or `--audio`. This preset listens on all
interfaces and is therefore appropriate only behind a firewall or on a trusted
LAN/VPN.

The server also includes `local`, `high-quality`, `resource-saving`, and
`view-only` presets. These names describe server resource and access policy,
not an assumed client network. Users can add named preset files without
recompiling the server, inherit another preset, and override any setting on the
command line.
See [Server presets](docs/presets.md) for the built-in values, complete file
format, credential handling, permissions, and LaunchAgent examples. List and
inspect configurations without starting capture or a listener:

```bash
./build/macrdp-server --list-presets
./build/macrdp-server --preset standard --print-effective-config
```

List active displays without credentials, TCC prompts, or a listening socket:

```bash
./build/macrdp-server --list-displays
```

Each row includes the display ID, main-display flag, pixel size, macOS point
size, and global origin. Omit `--display-id` to select the main display at
startup, or pass one listed ID to the server and preflight commands. An exact
ID that is no longer active is rejected instead of falling back to a different
screen; rerun the list command after changing the display arrangement. During
an active session, resolution, scaling, rotation, origin, and main-display
changes create a new atomic geometry generation for the same selected ID. If
that display is detached, capture and pointer injection pause while the server
waits for the same ID to return; it does not switch to another display.

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
| Capture a listed display | `--display-id <id>` |
| Allow up to four concurrent clients | `--max-clients 4` |
| Raise the adaptive AVC420 bitrate ceiling | `--max-bitrate 24M` |
| Limit capture and per-client send rate | `--max-fps 15` |
| Require direct macOS AVC420 | `--h264-encoder videotoolbox` |
| Use FreeRDP's FFmpeg AVC420 path | `--h264-encoder ffmpeg` |
| Force every H.264 frame to IDR for diagnosis | `--h264-keyint 1` |
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
package, and applies an ad-hoc signature by default. The validation target
independently checks load paths, architectures, minimum macOS versions,
signatures, unused FFmpeg components, and a packaged `--help` loader smoke
check. With the pinned release configuration it also creates
`build/macrdp-ffmpeg-sources-7.1.1.tar.gz`, a self-checking corresponding-source
bundle for the distributed FFmpeg libraries.

Create and mount-validate the corresponding developer disk image with:

```bash
cmake --build build --target macrdp-distribution-validate
```

The output is `build/macrdp-cpp-0.1.0-macos-arm64.dmg`. In the default
configuration both the copied Mach-O payload and DMG use ad-hoc signatures;
this exercises the complete image structure without claiming publisher
authenticity. DMG validation mounts the image read-only, repeats the SBOM and
signature checks, checks architecture metadata, and runs the packaged `--help`
loader smoke test. Validation does not start a listener or require TCC
permissions. The developer DMG must not be published as an official release.
See
[Release engineering](docs/release.md#developer-id-and-notarization) for the
credentialed Developer ID and notarization mode.

The package contains the `bin/macrdp-manage` lifecycle command, the offline
`bin/macrdp-verify-package` integrity verifier,
`share/macrdp/sbom.cdx.json`, generated third-party
notices, the exact FFmpeg build configuration and source provenance, and the
license files associated with every copied dependency. Validation recomputes
hashes for every executable, management tool, dynamic library, and compliance
file and checks the dependency references in the SBOM. A future official
release must attach the matching macrdp project source and FFmpeg
corresponding-source archive alongside the binary; the FFmpeg source does not
need to be stored inside the application payload. See
[Release engineering](docs/release.md) for the exact artifact set and
remaining gates.

For a long-running instance, create an owner-only one-line password file and
install the versioned per-user service:

```bash
macrdp_root="$HOME/Library/Application Support/macrdp-cpp"
password_file="$macrdp_root/state/password"
umask 077
mkdir -p "$macrdp_root/state"
read -r -s macrdp_password
printf '\n'
printf '%s\n' "$macrdp_password" > "$password_file"
unset macrdp_password

./build/macrdp-dist/bin/macrdp-manage install \
  --package ./build/macrdp-dist \
  --user example-user \
  --password-file "$password_file"
```

The manager verifies all SBOM hashes and Mach-O signatures before and after
copying the payload. Releases are stored below `releases/<version-sbom-hash>`;
the LaunchAgent always runs the stable `current/bin/macrdp-server` path, while
`previous` records the rollback target. Certificates and generated
configuration live under `state/config` and are not copied into a release.

The service runs in the logged-in Aqua session and writes logs below
`~/Library/Logs/macrdp-cpp`. Grant TCC permissions to the exact `current`
executable used by the LaunchAgent. To apply access controls or other server
options, pass them after `--`. Because the listener defaults to loopback, a
remote service must explicitly append
`-- --bind-address <trusted-interface-address>`. For a screen-only service,
add `--view-only --no-clipboard --no-audio` after the same separator.

Use the manager from a newly validated package for upgrades, and the installed
manager for status, rollback, and removal:

```bash
macrdp_root="$HOME/Library/Application Support/macrdp-cpp"
./new-macrdp-dist/bin/macrdp-manage upgrade \
  --package ./new-macrdp-dist

"$macrdp_root/current/bin/macrdp-manage" status
"$macrdp_root/current/bin/macrdp-manage" rollback
"$macrdp_root/current/bin/macrdp-manage" uninstall
```

Upgrade switches `current` atomically and restarts the service. If that restart
command fails, it restores both release links and restarts the old release.
Rollback exchanges `current` and `previous`, so it can be reversed. Ordinary
uninstall removes the LaunchAgent and all installed releases but preserves the
installation root, certificate, password, configuration, and SAM state. Add
`--purge-state` only when those project-managed files and logs should also be
deleted. Files outside the installation root, including an externally managed
SAM or password file, are never deleted.

When adopting an older manual installation whose default root already contains
`shadow/`, the manager keeps that directory as the certificate/configuration
root. An explicit `--config-dir` always takes precedence.

Rotate the LaunchAgent's RDP password interactively with:

```bash
macrdp_root="$HOME/Library/Application Support/macrdp-cpp"
password_file="$macrdp_root/state/password"
"$macrdp_root/current/bin/macrdp-rotate-password" \
  "$password_file"
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
capability, concurrency, and lifecycle state-machine tests 50 times. This job
does not open an RDP listener, capture the display, or inject input. See
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
- `third_party/freerdp/`: pinned macrdp FreeRDP fork manifest.
- `third_party/ffmpeg/`: pinned LGPL FFmpeg manifest, patches, and build policy.
- `docs/`: architecture, testing, and roadmap documentation.

## Documentation

- [Architecture](docs/architecture.md): runtime pipeline and ownership
  boundaries.
- [Server presets](docs/presets.md): built-in presets, user files, inheritance,
  overrides, and credential handling.
- [Testing](docs/testing.md): local, loopback, and shaped-network validation.
- [Hardware matrix](docs/hardware-matrix.md): P0 lifecycle and real Windows
  acceptance record.
- [Roadmap](docs/roadmap.md): prioritized work and release gates.
- [Changelog](CHANGELOG.md): user-visible changes.
- [Contributing](CONTRIBUTING.md): development and pull request expectations.
- [Security policy](SECURITY.md): deployment warnings and private reporting.

## Contributing and security

Keep changes focused, update tests and documentation together, and never commit
generated `build/_deps` content. FreeRDP changes belong on the
`zx1991/FreeRDP` `macrdp-3.30` branch; update its pinned commit, archive URL,
SHA-256, and dependency documentation in this repository together.

This software exposes the desktop and, unless disabled, clipboard, audio, and
input injection. Treat every listener and credential as security-sensitive,
grant only the capabilities needed for the deployment, and report
vulnerabilities through the repository's private security reporting channel,
not a public issue.

## License

Project-owned code and documentation are licensed under Apache License 2.0.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). FreeRDP and bundled runtime
dependencies retain their own upstream licenses and notices. The managed
release build dynamically links a pinned LGPL-2.1-or-later FFmpeg; Homebrew
development builds may include GPL components and must not be substituted into
an Apache-only official artifact. See [Release engineering](docs/release.md)
before distributing binaries.
