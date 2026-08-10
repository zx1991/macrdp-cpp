# Testing

The project has two validation layers: deterministic local tests and a real
FreeRDP loopback smoke test. Neither replaces a Windows `mstsc` session on the
target Mac, but together they make frame and protocol regressions measurable.

## Local tests

Configure and build the project, then run:

```bash
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
```

The local suite covers display dimensions, frame coalescing, VideoToolbox and
FreeRDP H.264 paths, the asynchronous encoder worker, input ownership and queue
behavior, ledger-bounded modifier cleanup, signed 9-bit RDP wheel-delta
translation, asynchronous completion and timeout cleanup semantics, injected
capture lifecycle races, configuration permissions, and server argument
validation. It does not require Screen Recording permission for the synthetic
encoder and state-machine tests.

The access-policy test instantiates the real macOS shadow subsystem without
starting ScreenCaptureKit. It verifies that view-only synchronize, keyboard,
Unicode, absolute, relative, and extended-pointer callbacks do not mutate the
shadow input state; it also confirms that interactive pointer callbacks remain
active and disabled clipboard initialization does not create a channel context.
Server argument tests reject concurrent-client limits outside 1 through 64.

The asynchronous completion test covers completion, duplicate and late result
rejection, timeout cleanup installed both before and after a timeout, and
explicit failure cleanup. The injected capture-backend test exercises separate
frame/audio stop wakeups, old-generation frame/audio/error rejection, a stream
stopping during start, finite timeout propagation, and concurrent stop versus
reconfigure serialization. It does not call ScreenCaptureKit; permission
denial, display sleep, session lock, and framework-specific behavior remain in
the supported-hardware matrix.

Wheel translation tests cover positive and negative deltas, both pointer event
types, and the signed field boundaries. The loopback smoke test confirms that
wheel callbacks reach the server's real input path, but it cannot observe the
resulting macOS scroll distance or direction directly. A release candidate
therefore still needs a manual vertical and horizontal wheel check from the
supported Windows client matrix.

## Loopback client

The normal build disables FreeRDP's client targets. Configure a separate
shared client build from the generated pinned source, then compile the small
loopback client:

```bash
tools/build_loopback_freerdp.sh \
  build/_deps/freerdp-src \
  build/freerdp-client

tools/build_loopback_client.sh \
  build/freerdp-client \
  build/_deps/freerdp-src \
  /tmp/macrdp-loopback-client
```

The configuration uses Release, shared libraries, FFmpeg H.264 support, and
only the client channels exercised by the loopback test. Set
`MACRDP_FREERDP_CLIENT_JOBS`, `MACRDP_FREERDP_CLIENT_ARCH`, or
`MACRDP_FREERDP_CLIENT_DEPLOYMENT_TARGET` to override the local developer
defaults. The existing client build helper still accepts any compatible
preconfigured FreeRDP build.

The smoke script uses a real TCP connection to the server and checks:

- GFX/AVC420 by default, optional AVC444, selectable H.264 encoder paths, and
  classic SurfaceBits frame delivery;
- first-frame and inter-frame timing;
- NLA failure with an incorrect password;
- mouse buttons, drag, wheel, keyboard, Unicode, and synchronization input;
- initial, repeated, and released keyboard events, including modifier cleanup,
  the mstsc-style Pause/E1 sequence, and both FastPath and classic slow-path
  keyboard delivery;
- bidirectional text clipboard traffic;
- PCM and compressed RDPSND negotiation and delivery;
- reconnect, requested sizes, and changing bidirectional clipboard content;
- an intentionally slow client event loop on the direct profile.

The server's `Input pipeline` diagnostics also report the current and maximum
input queue depth, coalesced or discarded pointer motion, time spent waiting
for queue capacity, and the average/maximum delay from RDP callback enqueue to
the macOS input worker. A nonzero critical-event wait is input backpressure; it
is distinct from a macOS injection failure. With `--log-level DEBUG`, keyboard
diagnostics include the client id, raw flags, scan code, E0/E1 markers, resolved
macOS key code, and whether the event was recovered or treated as autorepeat.
The `H.264
pipeline` diagnostic reports encoder time, coalesced frames, and
`output_deferred`, the number of completed encodes held until the transport
became writable. The regular `Output pipeline` diagnostic reports the current
and maximum FreeRDP message-queue depth and capacity, the current and maximum
bytes in the non-blocking transport queue, deferred/coalesced video updates,
audio queue state, output-blocked intervals, drain attempts, and recovery.
`Output pipeline final` repeats the counters when a client disconnects, so
short sessions still leave a usable summary. A normal disconnect while
draining is logged as transport closure, not as a server-internal drain
failure.

Run the direct profile with:

```bash
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
tools/run_loopback_smoke.sh
```

The server still needs Screen Recording and Accessibility permission because
the loopback test exercises the actual macOS capture and interactive input
paths. The deterministic access-policy test is the non-invasive coverage for
view-only and clipboard-disabled behavior.

The harness waits for the server's listening log instead of opening a TCP
readiness connection, because the default one-client policy treats even a probe
as a transient shadow client. It starts the reconnect matrix with
`--max-clients 2` so a replacement connection can overlap bounded cleanup of the
previous client.

The direct profile requests AVC420 unless `--gfx-codec AVC444` is supplied:

```bash
tools/run_loopback_smoke.sh --gfx-codec AVC444
```

AVC420 requests the direct macOS VideoToolbox bridge when it is available.
AVC444 uses the server's FFmpeg path because the direct bridge currently
accepts I420/AVC420 input. To force a particular AVC420 encoder, pass the
server option through the smoke script:

```bash
tools/run_loopback_smoke.sh --gfx-codec AVC420 --h264-encoder ffmpeg
tools/run_loopback_smoke.sh --gfx-codec AVC420 --h264-encoder videotoolbox
```

`auto` is the default. `ffmpeg` disables the direct bridge; `videotoolbox`
requires it and the smoke test fails if it is unavailable. The script checks
both the server's selected encoder marker and the client's decoded codec
counters, so a run cannot pass merely because an unrelated encoder or GFX
codec was used. The profile's separate `nogfx` phase uses classic SurfaceBits
and is unaffected by `--gfx-codec`.

The smoke script runs normal GFX clients with FastPath input enabled and uses
the `nogfx` client phase to force classic slow-path input. To select a path for
an individual loopback client invocation, set
`MACRDP_LOOPBACK_FASTPATH_INPUT=1` or `MACRDP_LOOPBACK_FASTPATH_INPUT=0`.

Clipboard verification uses a profile-specific wait after the client exits so
low-bandwidth runs are not mistaken for protocol failures. Override it with
`MACRDP_LOOPBACK_CLIPBOARD_WAIT_SECONDS` when testing a slower or faster custom
profile.

Remote input uses a lifetime-scoped private CoreGraphics event source. Startup
does not inspect or release keys held by the local user. The client-disconnect
path logs the number of keyboard, Unicode, and mouse button states released for
that client; shutdown releases the remaining ownership ledger before discarding
the private source.

For an opt-in live keyboard check, set `MACRDP_LOOPBACK_PROBE_F=1`. The client
then sends one ordinary `F` key-down/key-up pair to the active macOS
application, so use it only when typing one `f` there is acceptable. The
default smoke test keeps this disabled and validates the scan-code path through
the server counters instead. With the probe enabled, keep
`MACRDP_LOOPBACK_SERVER_LOG_LEVEL=DEBUG` (the default) so the smoke test also
checks the server's `0x21 -> macOS keycode 3` down/up mapping.

The first input batch also sends two repeated key-down events for F17. The
server reports them as `keyboard_repeats` and marks the injected macOS events
with the autorepeat flag. This covers both slow-path `KBD_FLAGS_DOWN` input and
FastPath input, where the repeat bit is not carried on the wire.

It also sends a left Windows key-up without its E0 prefix after a matching
key-down. The server must count this as `keyboard_release_recoveries` and
release the tracked macOS Command key by its scan-code identity. This catches
the modifier-sticking failure mode seen with clients that do not preserve the
extended flag on key-up. The same recovery is checked for right Control, and
the four constituent events of the mstsc Pause/E1 sequence are checked for
balanced ownership. `keyboard_unmatched_releases` counts key-up events ignored
because the current client has no corresponding key-down in its ownership
ledger.

## Network profiles

The optional C proxy shapes each TCP direction independently. It adds delay,
deterministic jitter, a byte-rate limit, and periodic forwarding stalls. It does
not model packet loss, packet reordering, NAT, UDP, or a real Wi-Fi radio.

The smoke script keeps one proxy alive across the primary session and the
reconnect checks. By default, `direct`, `wan`, and `outage` run two additional
connections using 1280x720 and 1024x768 and change the expected text on both
sides of the clipboard channel between connections. The `wifi` and `bad`
profiles reserve their longer link budget for the primary session and skip that
phase by default. Pass `--reconnect` to run it for either profile, or
`--no-reconnect` to skip it for a shorter run. The per-connection budget is
controlled by `MACRDP_LOOPBACK_RECONNECT_DURATION_MS`; the default is 15 seconds
for `wifi` and 30 seconds for `bad`.

| Profile | Delay | Jitter | Bandwidth | Stall | Purpose |
| --- | ---: | ---: | ---: | ---: | --- |
| `direct` | 0 ms | 0 ms | unlimited | none | baseline, reconnect, resize, slow client |
| `wan` | 50 ms | 10 ms | 5 Mbps | none | ordinary remote link, reconnect, resize, clipboard changes |
| `wifi` | 75 ms | 40 ms | 1 Mbps | 300 ms / 5 s | variable consumer link, optional reconnect |
| `outage` | 50 ms | 50 ms | 5 Mbps | 500 ms / 3 s | stalled forwarding, reconnect, resize, clipboard changes |
| `bad` | 150 ms | 100 ms | 256 Kbps | 1 s / 4 s | extreme backpressure, optional reconnect |

Build and run a shaped profile:

```bash
tools/build_loopback_proxy.sh /tmp/macrdp-loopback-proxy
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
MACRDP_LOOPBACK_PROXY=/tmp/macrdp-loopback-proxy \
tools/run_loopback_smoke.sh --profile wifi
```

Run the longer profile's reconnect phase explicitly:

```bash
tools/run_loopback_smoke.sh --profile wifi --reconnect
tools/run_loopback_smoke.sh --profile bad --reconnect
```

The smoke script can pass the server's video settings through unchanged so
different quality profiles use the same network conditions:

```bash
tools/run_loopback_smoke.sh --profile wifi --bitrate 4M --fps 20
```

The same settings can be supplied with `MACRDP_LOOPBACK_SERVER_BITRATE` and
`MACRDP_LOOPBACK_SERVER_FPS`. The script prints the selected values in its
header; this makes low-bandwidth comparisons reproducible instead of relying
on the server's default 16 Mbps/30 FPS configuration.

Audio is enabled by default. Use `--no-audio` on the server, or
`MACRDP_LOOPBACK_DISABLE_AUDIO=1` with the smoke script, to measure video without
RDPSND consuming the shaped link. The loopback client auto-negotiates the
server's preferred audio format by default; with the current FFmpeg build this
is AAC (`0xA106`), so compressed audio does not consume PCM bandwidth. To test
the raw PCM worst case explicitly, run:

```bash
MACRDP_LOOPBACK_AUDIO_FORMAT=1 \
MACRDP_LOOPBACK_EXPECT_AUDIO_FORMAT=1 \
tools/run_loopback_smoke.sh --profile wifi --bitrate 4M --fps 20
```

The equivalent command-line form is:

```bash
tools/run_loopback_smoke.sh --profile wifi --bitrate 4M --fps 20 \
  --audio-format 1 --expect-audio-format 1
```

Use `--audio-format 0xA106 --expect-audio-format 0xA106` to force AAC in a
reproducible comparison. `audio_format_tag`, `audio_non_pcm`, and the audio
payload counters in the loopback summary show what was actually delivered.

During shaped-link backpressure, the server's `Output pipeline` diagnostics
include `audio_dropped`. A nonzero value means stale per-client audio messages
were rejected before entering the message queue; it is expected for the Wi-Fi,
outage, and bad profiles with audio enabled. The shaped `nogfx` phase therefore
requires RDPSND negotiation and callback delivery, but permits all audio payload
bytes to be dropped when classic full-screen updates consume the output budget.
`Audio pipeline`'s
`dropped_frames` measures capture-side loss and is independent of this queue
bound.

In the checked-in Wi-Fi profile (1 Mbps, 75 ms delay, 40 ms jitter), a current
10-second comparison of `4M/20FPS` produced 89 frames with auto-negotiated AAC
(83 ms average interval), 40 frames with explicitly selected PCM (177 ms), and
94 frames with audio disabled (82 ms). First-frame latency in that run was
2473 ms, 3012 ms, and 2208 ms respectively. These are tuning observations for
this deterministic proxy profile, not an automatic bitrate-selection rule or a
guarantee of a particular Windows client's negotiation; jitter and the proxy's
scheduled outage can change individual runs.

The `bad` profile intentionally allows a 30-second GFX window. A full-screen
keyframe can take roughly 20 seconds at 256 Kbps before later frames can be
observed. Passing this profile demonstrates eventual TCP/RDP progress and
recovery; it does not mean the interactive experience is acceptable. A failure
should be interpreted with `server.log`, `client.log`, and `proxy.log` from a
run with `MACRDP_LOOPBACK_KEEP_TEMP=1`. Because clipboard assertions use the
macOS general pasteboard, unrelated clipboard managers can make an isolated
run nondeterministic.

## Metrics to record

For a performance report, include the profile, requested size, `frames`,
`first_frame_ms`, `avg_interval_ms`, `max_interval_ms`, GFX codec counters,
input failure counters, audio callback counters, and the server's `Frame
pipeline`, `H.264 pipeline`, `Output pipeline`, and `Slow client frame handling`
lines. A subjective report such as
"the screen is slow" is not enough to distinguish capture, encoding, network,
client decode, and output backpressure.
