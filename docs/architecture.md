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
format negotiation and data transfer under a channel lock. When clipboard
redirection is disabled, the adapter short-circuits before it creates a channel
context or monitor thread.

## Concurrency boundaries

- Screen capture is isolated from protocol callbacks. A capture failure can
  restart with bounded backoff without making the RDP listener thread own
  ScreenCaptureKit state. Content discovery and stream start share a 15-second
  deadline; stream stop waits at most 5 seconds before detaching its outputs.
  Each start has a generation token, so frames and delegate callbacks from a
  timed-out or replaced stream cannot mutate the active stream's state. Apple
  operations sit behind a C++ backend contract; production uses
  ScreenCaptureKit while lifecycle tests inject a fake backend that can retain
  old generations and pause stop operations without TCC or a display.
- ScreenCaptureKit keeps independent newest-frame and newest-audio slots. Each
  slot has its own condition variable, so video and audio callbacks wake only
  their corresponding consumer. Stop, reconfigure, and capture-error paths
  wake both consumers.
- A client receives the newest useful video state. Old video work may be
  coalesced when the client is slower than the capture rate.
- H.264 work is per client, so a slow encoder or blocked client does not make
  the capture thread wait for every connection. The client loop handles
  transport input and control-channel events before starting the next frame,
  and keeps completed H.264 output pending until the transport is writable, so
  video backpressure does not delay input or clipboard control traffic.
- Input ownership is per RDP client. Keyboard, Unicode, and pointer events share
  one lifetime-scoped private CoreGraphics event source, keeping remote
  modifier and button state independent from local hardware input. Disconnect
  cleanup releases only state owned by that client; shutdown releases the
  remaining ledger before destroying the private source. Unmatched key-up
  events are counted and ignored, while a key-up that lost its E0/E1 marker can
  still be matched to the current client's ledger. Platform injection is
  serialized in the input worker. When the bounded queue is full, obsolete
  pointer motion is discarded before critical keyboard, button, wheel, and
  reset events are allowed to wait for capacity. RDP wheel rotation is decoded
  from its signed 9-bit field before vertical or horizontal line events are
  sent to CoreGraphics. In view-only mode every project-owned input callback is
  gated before client registration or queueing, and the subsystem does not
  create its CoreGraphics event source or input worker. This remains the final
  policy boundary even if a FreeRDP control channel changes a client's
  `mayInteract` flag.
- FreeRDP checks the configured concurrent-client limit in its listener accept
  path before allocating a new shadow client. The default limit is one.
- Shutdown joins capture, audio, publish, input, and encoder workers in a
  defined order before FreeRDP state is released.

The output scheduler records message-queue depth, transport-queue bytes,
blocked intervals, deferred/coalesced video updates, and drain attempts per
client. This distinguishes network backpressure from capture or encoder delay
without turning a normal client disconnect into an internal-error diagnostic.

The exact backpressure behavior is part of the protocol adaptation patch. The
patch adds bounded message budgets, a non-blocking output queue, and input-first
event scheduling to the generated FreeRDP tree. It is kept as a source patch
rather than a fork so the upstream version and the local adaptation remain
reviewable.

## C++ and Objective-C++

`include/macrdp/` exposes C++ data types and interfaces. `src/` contains
portable C++ and C tests. `src/macos/` contains `.mm` adapters for
ScreenCaptureKit, CoreGraphics, CoreAudio/AudioToolbox, AppKit, and
VideoToolbox. CMake enables C, C++, Objective-C, and Objective-C++ in one
target and links Apple frameworks only at the platform boundary.

## Security boundary

The server listens on loopback and uses FreeRDP NLA by default. Selecting
another interface is explicit, and non-NLA compatibility modes require a
separate risk acknowledgement. Certificate and SAM files are created in a
private configuration directory. macOS TCC permissions remain enforced by the
operating system: Screen Recording is required for capture and Accessibility
is required for input injection. The server does not bypass those controls.

The per-user installation keeps immutable, SBOM-verified payloads under
`releases/` and selects one through a stable `current` link. `previous` is the
rollback target. Certificates, credentials, configuration, and external SAM
files are not part of a release switch, so binary rollback cannot silently
roll back security state. Ordinary uninstall preserves that state; explicit
purge removes only state inside the managed installation root and its log
directory.

An authenticated client receives screen and audio by default, with interactive
keyboard/pointer input and text clipboard synchronization. Operators can remove
input with `--view-only`, remove clipboard access with `--no-clipboard`, and
bound concurrent clients with `--max-clients` (default one, maximum 64). The
input and clipboard controls are independent: view-only still exposes the
clipboard unless both options are selected. These controls reduce session
capabilities; they do not make an Internet-exposed listener safe.

## Design constraints

The implementation keeps protocol handling, platform capture, input injection,
audio, clipboard, and media encoding as separate ownership domains. Changes at
the FreeRDP boundary must remain compatible with the pinned upstream API and
must preserve the upstream license and attribution.
