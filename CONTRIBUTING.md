# Contributing

Thank you for helping improve macrdp-cpp. The project is experimental, so
small, reviewable changes and reproducible measurements are more useful than
large feature drops.

## Before you start

Read the [architecture](docs/architecture.md), [testing](docs/testing.md),
[roadmap](docs/roadmap.md), [release engineering](docs/release.md), and
[security](SECURITY.md) documents. Check open issues before starting work that
changes protocol behavior or the FreeRDP integration boundary.

## Development environment

The supported development environment is a logged-in macOS 15 session with
CMake, Apple Clang, Ruby, FFmpeg, and OpenSSL 3. Homebrew is the simplest way
to install the non-system dependencies for local development:

```bash
brew install cmake ffmpeg openssl@3
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8
```

Homebrew FFmpeg is a development convenience and is not the dependency used
for official binary artifacts. Changes to packaging, FFmpeg integration, or
release compliance must also build the pinned LGPL dependency and configure
CMake with it:

```bash
scripts/build_macos_ffmpeg.sh build/third_party/ffmpeg arm64 15.0
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DMACRDP_FFMPEG_ROOT="$PWD/build/third_party/ffmpeg/prefix" \
  -DMACRDP_FFMPEG_PROVENANCE="$PWD/build/third_party/ffmpeg/provenance.json"
```

The first configure downloads a hash-pinned FreeRDP 3.30.0 archive. Do not
edit files under `build/_deps`; update the checked-in patch under `patches/`
instead.

## Tests

Run the local test suite before opening a pull request:

```bash
ctest --test-dir build --output-on-failure
```

Changes to packaging, dependencies, deployment targets, or startup options
should also build and validate the developer payload from the pinned FFmpeg
configuration above:

```bash
cmake --build build --target macrdp-package-validate
```

This target must regenerate and validate the CycloneDX SBOM, dependency graph,
third-party notices, FFmpeg build configuration and provenance, license texts,
and `build/macrdp-ffmpeg-sources-7.1.1.tar.gz`. Do not manually edit or commit
generated package, dependency, provenance, or source-archive files under
`build/`.

Changes to installation management must preserve the separation between
immutable `releases/` payloads and persistent certificate/credential state.
They must extend `manage_macos_install_test.sh` for both the success path and
transactional failure recovery; tests must use directory overrides and a fake
`launchctl`, never the developer's real LaunchAgent.

Memory-safety, ownership, and lifecycle changes should also use the isolated
sanitizer build and deterministic stress command documented in
[docs/testing.md](docs/testing.md#sanitizers-and-deterministic-stress). Do not
replace a signed TCC-authorized development server with a sanitizer binary.

Protocol changes should also use the separate FreeRDP loopback client and the
network profiles described in [docs/testing.md](docs/testing.md). Keep smoke
test artifacts when diagnosing a failure:

```bash
MACRDP_LOOPBACK_KEEP_TEMP=1 tools/run_loopback_smoke.sh
```

To create the compatible client build from the main build's pinned source:

```bash
tools/build_loopback_freerdp.sh build/_deps/freerdp-src build/freerdp-client
tools/build_loopback_client.sh \
  build/freerdp-client build/_deps/freerdp-src /tmp/macrdp-loopback-client
```

Do not include screen captures, credentials, pasteboard contents, or generated
build trees in a pull request.

## Code changes

- Keep public headers in `include/macrdp/` free of Objective-C types.
- Put Apple framework code in `src/macos/` and keep portable logic in `src/`.
- Preserve per-client ownership and shutdown behavior when changing input or
  transport code.
- Treat frame queues as real-time data paths: document whether a queue keeps
  the newest value, preserves every value, or applies backpressure.
- Update README/docs and focused tests when behavior or a command changes.
- Keep FFmpeg source hashes, patches, configure flags, runtime probes, package
  allowlists, and source-distribution instructions consistent as one change.
- Keep FreeRDP changes in the pinned patch and update patch markers in
  `CMakeLists.txt` when the adaptation surface changes.

## Pull requests

Describe the user-visible behavior, the macOS version and architecture used,
the exact build/test commands, and any test that still requires a Windows
`mstsc` client or TCC permission. Include relevant log metrics rather than a
subjective statement such as "it feels faster".

Use focused commits with imperative subjects, for example:

```text
Improve frame pacing under a blocked RDP client
```

By submitting a contribution, you agree that it may be distributed under the
Apache License 2.0 in this repository.
