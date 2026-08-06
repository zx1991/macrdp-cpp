# macrdp-cpp

An experimental C++/Objective-C++ implementation of the macOS remote desktop
building blocks. This is intentionally separate from the existing Rust
implementation in `../macrdp`.

## Current state

The project captures the main display as a real-time ScreenCaptureKit stream,
keeps only the newest BGRA frame, and encodes received frames with
VideoToolbox H.264. Public interfaces are pure C++; Apple framework adapters
are implemented in `src/macos/*.mm`.

This is not an RDP server yet.

## Build

```bash
cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build
```

## Run

Run from the macOS graphical session, then inspect `capture.ppm` and the
generated `capture.h264`. The example collects frames for two seconds, writes
the newest PPM frame, and encodes every received frame with VideoToolbox:

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

## Layout

- `include/macrdp/`: C++ interfaces and data types; no Objective-C types.
- `src/`: portable C++ application logic.
- `src/macos/`: Objective-C++ adapters for Apple frameworks.
- `CMakeLists.txt`: builds `.cpp` and `.mm` in separate targets.

## Next milestones

1. Add a small loopback transport for testing latency and dropped frames.
2. Evaluate an existing RDP server library before implementing RDP protocol
   handling from scratch.

## Encoder test

The encoder can be tested without Screen Recording permission using synthetic
BGRA frames:

```bash
./build/macrdp-cpp-encoder-test /tmp/macrdp-cpp-test.h264
```
