# Contributing

Thank you for helping improve macrdp-cpp. The project is experimental, so
small, reviewable changes and reproducible measurements are more useful than
large feature drops.

## Before you start

Read the [architecture](docs/architecture.md), [testing](docs/testing.md),
[roadmap](docs/roadmap.md), and [security](SECURITY.md) documents. Check open
issues before starting work that changes protocol behavior or the FreeRDP
integration boundary.

## Development environment

The supported development environment is a logged-in macOS 15 session with
CMake, Apple Clang, FFmpeg, and OpenSSL 3. Homebrew is the simplest way to
install the non-system dependencies:

```bash
brew install cmake ffmpeg openssl@3
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8
```

The first configure downloads a hash-pinned FreeRDP 3.30.0 archive. Do not
edit files under `build/_deps`; update the checked-in patch under `patches/`
instead.

## Tests

Run the local test suite before opening a pull request:

```bash
ctest --test-dir build --output-on-failure
```

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
