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
                              OpenH264, VideoToolbox, or FFmpeg
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

RDPGFX capability interpretation is version-aware and per client. Version 8.1
uses `AVC420_ENABLED`; versions 10 through 10.7 use the inverse
`AVC_DISABLED` flag for both AVC420 and AVC444 availability. Unknown versions
are treated as unsupported. The negotiated result chooses only a codec path;
codec support is not evidence of current transport capacity. The configured
bitrate and FPS are ceilings. Each client owns an adaptive controller and H.264
encoder. It tolerates brief blocked writes, reduces bitrate only after two
seconds of continuous output pressure, and lowers send pacing by one FPS when
a pressure interval lasts 750 ms. The latter applies only once per continuous
interval. ACKs of at least two seconds or a 2.5-second ACK stall apply stronger
send-pacing reductions. Reductions have a cooldown so one congestion interval
cannot repeatedly collapse the targets. Four ACKs of 1.25 seconds or less
trigger fast recovery from the conservative start. Above those
initial targets, recovery becomes additive and requires eight healthy ACKs over
at least three seconds. Any pressure clears accumulated healthy samples; blocked
output holds recovery for two seconds, while transport or client queue pressure
holds it for five. Capture continues at the global FPS ceiling, while bounded
output queues, deferred H.264 completion, and frame coalescing preserve only the
newest update for each client's next paced encode.

FreeRDP suppress-output demand is aggregated across clients. While every
connected client suppresses output, ScreenCaptureKit keeps running for audio
but discards screen samples before the BGRA copy. The capture and publish loops
hold no stale video in that state. Resuming any client reenables video and
forces the next published surface update to cover the full frame.

Per-client pacing applies to every H.264 backend. OpenH264 updates its bitrate
and frame-rate controls before encoding the next frame, and the direct
VideoToolbox bridge updates `AverageBitRate` and `ExpectedFrameRate` on its live
session. The explicit generic FFmpeg encoder path currently receives adaptive
pacing but does not guarantee that a bitrate change takes effect after its
codec context has opened. Completed encodes that intentionally produce no
packet are measured in one-second windows. When at least ten samples contain
ten percent no-output results, the controller reduces FPS without reducing
bitrate and holds recovery for five seconds.

Audio and clipboard have separate service paths. Audio capture/pacing runs in
its own loop and publishes bounded PCM chunks to the FreeRDP shadow clients.
Captured blocks carry the display generation that produced them; a topology
transition rejects stale blocks and clears partially accumulated PCM before the
replacement generation or a restarted capture stream can publish. Empty reads
from a stopped stream use a bounded retry delay instead of spinning. Each
client rejects audio work until RDPSND has successfully selected a compatible
format, and clears that atomic negotiation state before channel teardown.
The clipboard monitor observes `NSPasteboard` after the client capability
exchange, while channel callbacks perform format negotiation and data transfer
under a per-connection operation lock. Ordered remote data responses consume a
bounded FIFO of formats that were actually requested. A remote response that
matches the current macOS text is acknowledged without rewriting the
pasteboard, preventing duplicate clipboard announcements from creating a
synchronization loop. When clipboard redirection is disabled, the adapter
short-circuits before it creates a channel context or monitor thread.

At startup the server resolves the requested display ID against a CoreGraphics
topology snapshot. A generation-tagged geometry for that exact ID supplies the
FreeRDP surface dimensions, ScreenCaptureKit filter and native pixel size, and
pointer mapping. RDP pixel coordinates are normalized into the selected
display's global macOS point bounds, including negative origins and Retina
pixel-to-point scaling. Exact requests never fall back to another screen.

CoreGraphics reconfiguration callbacks mark the topology dirty, while a bounded
periodic read covers missed notifications. Resolution, scaling, rotation,
origin, and main-display changes produce a new immutable generation. The
runtime suspends pointer injection, clears old downstream frames, resizes the
surface, replaces the capture stream, and only then commits the new input
geometry. Frames and queued pointer events carry the generation that created
them, so stale work cannot cross that commit. If the selected display is
removed, capture waits for the same ID to return instead of switching screens.

## Concurrency boundaries

- Each FreeRDP shadow client has an atomic session state. A successful
  subsystem connect moves it from new to active; teardown atomically moves it
  to stopping before any channel resource is released. Broadcast dispatch and
  RDPSND reject stopping clients. The subsystem disconnect callback runs once
  for every successful connect regardless of the socket's final connected
  flag, then channel teardown finishes the stopped state.
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
  wake both consumers. Audio blocks and pending PCM cannot cross the committed
  display generation.
- CoreGraphics topology access also sits behind an injectable C++ backend.
  Observer lifecycle tokens reject callbacks retained by an old registration,
  and invalid or duplicate readings leave the last valid snapshot intact.
  Deterministic tests drive main-display, mode, scaling, rotation, detach, and
  reconnect changes without depending on physical displays.
- A client receives the newest useful video state. Old video work may be
  coalesced when the client is slower than the capture rate.
- H.264 work is per client, so a slow encoder or blocked client does not make
  the capture thread wait for every connection. The client loop handles
  transport input and control-channel events before starting the next frame,
  and keeps completed H.264 output pending until the transport is writable, so
  video backpressure does not delay input or clipboard control traffic.
  AVC420 and AVC444 always convert the complete assembled desktop into the
  encoder's YUV reference frame because alternating partial reference buffers
  can retain stale pixels outside a dirty region. Default AVC420 also presents
  each packet with one full-desktop RDPGFX rectangle; combining a full-frame
  inter-coded packet with partial presentation metadata can otherwise leave
  stale rectangles on `mstsc`. Both VideoToolbox paths use Constrained Baseline
  profile and CAVLC entropy coding so mstsc receives a conservative inter-frame
  stream after the initial IDR. The encoder requests one reference frame where
  the hardware exposes that control. AVC444 retains its codec-produced metadata.
  For negotiated H.264, the scheduler begins with one reserved or sent frame
  beyond the client's latest RDPGFX `FrameAcknowledge`. Four consecutive ACKs
  no slower than 1.25 seconds open the initial two-frame pipeline; this avoids
  treating stop-and-wait latency as insufficient capacity. An ACK of at least
  1.5 seconds, client-reported buffered graphics bytes, transport queue pressure,
  1.5 seconds of continuous blocked writes, or a 2.5-second ACK stall demotes it
  to one. Reopening after a demotion requires a five-second cooldown followed by
  six ACKs no slower than 750 ms. RDPGFX `queueDepth` is measured in unprocessed
  bytes, not frames; diagnostics retain its latest, maximum, and current
  demotion threshold.
  The threshold tracks two average encoded frames with a 16 KiB minimum, so one
  large encoded frame or a transient partial-frame buffer does not collapse a
  healthy two-frame window. After any demotion, promotion remains disabled for
  five seconds to prevent the window oscillating on intermittent queue reports.
  While the window is closed, new capture updates are consumed into the newest
  desktop and marked for retry instead of being encoded. Reservations are made
  before asynchronous encoding, and submissions that produce no packet release
  only their own reservation. Late ACKs cannot move the acknowledged frame ID
  backwards. Clients that explicitly suspend frame acknowledgements retain the
  protocol's ungated behavior.
- Clipboard publication does not begin until FreeRDP receives client
  capabilities. Monitor publications and channel callbacks are serialized per
  connection, and only a response correlated with an outstanding text request
  may mutate `NSPasteboard`. Disconnect marks that transfer state inactive,
  wakes and joins the monitor, then lets FreeRDP stop and join its receive
  thread before the context is released. A reconnect starts with an empty
  request queue and independent publication state. Static virtual channels
  advertise 1600-byte chunks, matching FreeRDP's bounded channel PDU tracker.
- RDPSND publication is per client and begins only after format selection
  succeeds. The negotiation flag is reset before the RDPSND worker stops, so a
  reconnect starts inactive and broadcast dispatch cannot dereference a
  channel context that is being released. At most one audio sample message is
  queued per client, and stale audio remains discardable under backpressure.
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
  sent to CoreGraphics. Pointer events from a superseded display generation are
  discarded, while stale button releases remain permitted so a topology change
  cannot leave remotely owned button state pressed. In view-only mode every
  project-owned input callback is gated before client registration or queueing,
  and the subsystem does not
  create its CoreGraphics event source or input worker. This remains the final
  policy boundary even if a FreeRDP control channel changes a client's
  `mayInteract` flag. Only `ClientConnect` registers an input client ID;
  callbacks racing disconnect are acknowledged and discarded instead of
  recreating ownership for the old pointer value.
- FreeRDP checks the configured concurrent-client limit in its listener accept
  path before allocating a new shadow client. The default limit is one.
- Shutdown rejects new per-client work, clears subsystem ownership, and then
  joins channel, capture, audio, publish, input, and encoder workers in a
  defined order before FreeRDP state is released.

The output scheduler records message-queue depth, transport-queue bytes,
blocked intervals, deferred/coalesced video updates, and drain attempts per
client. This distinguishes network backpressure from capture or encoder delay
without turning a normal client disconnect into an internal-error diagnostic.

The exact backpressure behavior is maintained in the pinned macrdp FreeRDP
fork. It adds bounded message budgets, a non-blocking output queue, and
input-first event scheduling. The H.264 acknowledgement window follows the
same consumer-feedback principle as RustDesk's bounded video delivery and
recovery design, but is implemented independently with RDPGFX frame
acknowledgements; no RustDesk code is reused. The fork keeps each adaptation as
a focused commit on top of FreeRDP 3.30.0 so changes remain reviewable and can
be rebased or proposed upstream independently.

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
