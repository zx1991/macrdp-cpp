# Architecture

macrdp-cpp is a macOS host-side RDP server built around FreeRDP's server and
shadow protocol core. Project code owns the macOS capture, input, clipboard,
audio, and H.264 integration. The implementation is intentionally split so
portable C++ code does not depend on Objective-C headers.

## Runtime pipeline

```text
ScreenCaptureKit
        |
        v
capture thread -> newest-frame buffer -> per-client frame/encode worker
                                                   |
                                      VideoToolbox AVC420 or FFmpeg
                                                   |
                                             FreeRDP shadow
                                                   |
                                                TCP/TLS/NLA
```

Input travels in the opposite direction:

```text
FreeRDP client callback -> per-client input queue -> macOS input worker
                                                   |
                                      CoreGraphics event injection
```

Audio and clipboard have separate service paths. Audio capture/pacing runs in
its own loop and publishes bounded PCM chunks to the FreeRDP shadow clients.
The clipboard monitor observes `NSPasteboard`, while channel callbacks perform
format negotiation and data transfer under a channel lock.

## Concurrency boundaries

- Screen capture is isolated from protocol callbacks. A capture failure can
  restart with bounded backoff without making the RDP listener thread own
  ScreenCaptureKit state.
- A client receives the newest useful video state. Old video work may be
  coalesced when the client is slower than the capture rate.
- H.264 work is per client, so a slow encoder or blocked client does not make
  the capture thread wait for every connection.
- Input ownership is per RDP client. Disconnect cleanup releases only keys and
  buttons owned by that client; platform injection is serialized in the input
  worker.
- Shutdown joins capture, audio, publish, input, and encoder workers in a
  defined order before FreeRDP state is released.

The exact backpressure behavior is part of the protocol adaptation patch. The
patch adds bounded message budgets and a non-blocking output queue to the
generated FreeRDP tree. It is kept as a source patch rather than a fork so the
upstream version and the local adaptation remain reviewable.

## C++ and Objective-C++

`include/macrdp/` exposes C++ data types and interfaces. `src/` contains
portable C++ and C tests. `src/macos/` contains `.mm` adapters for
ScreenCaptureKit, CoreGraphics, CoreAudio/AudioToolbox, AppKit, and
VideoToolbox. CMake enables C, C++, Objective-C, and Objective-C++ in one
target and links Apple frameworks only at the platform boundary.

## Security boundary

The server uses FreeRDP NLA by default and creates its certificate/SAM files in
a private configuration directory. macOS TCC permissions remain enforced by
the operating system: Screen Recording is required for capture and Accessibility
is required for input injection. The server does not bypass those controls.

## Design constraints

The implementation keeps protocol handling, platform capture, input injection,
audio, clipboard, and media encoding as separate ownership domains. Changes at
the FreeRDP boundary must remain compatible with the pinned upstream API and
must preserve the upstream license and attribution.
