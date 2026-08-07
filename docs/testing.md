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
FreeRDP H.264 paths, the asynchronous encoder worker, input ownership,
configuration permissions, and server argument validation. It does not require
Screen Recording permission for the synthetic encoder tests.

## Loopback client

The normal build disables FreeRDP's client targets. Build the test client from a
separate FreeRDP client build:

```bash
tools/build_loopback_client.sh \
  /path/to/freerdp-client-build \
  /path/to/FreeRDP-3.30.0 \
  /tmp/macrdp-loopback-client
```

The smoke script uses a real TCP connection to the server and checks:

- GFX/AVC420 and classic SurfaceBits frame delivery;
- first-frame and inter-frame timing;
- NLA failure with an incorrect password;
- mouse buttons, drag, wheel, keyboard, Unicode, and synchronization input;
- bidirectional text clipboard traffic;
- PCM RDPSND negotiation and delivery;
- reconnect, requested sizes, and an intentionally slow client event loop.

Run the direct profile with:

```bash
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
tools/run_loopback_smoke.sh
```

The server still needs Screen Recording and Accessibility permission because
the loopback test exercises the actual macOS capture and input paths.

For an opt-in live keyboard check, set `MACRDP_LOOPBACK_PROBE_F=1`. The client
then sends one ordinary `F` key-down/key-up pair to the active macOS
application, so use it only when typing one `f` there is acceptable. The
default smoke test keeps this disabled and validates the scan-code path through
the server counters instead.

## Network profiles

The optional C proxy shapes each TCP direction independently. It adds delay,
deterministic jitter, a byte-rate limit, and periodic forwarding stalls. It does
not model packet loss, packet reordering, NAT, UDP, or a real Wi-Fi radio.

| Profile | Delay | Jitter | Bandwidth | Stall | Purpose |
| --- | ---: | ---: | ---: | ---: | --- |
| `direct` | 0 ms | 0 ms | unlimited | none | baseline, reconnect, resize, slow client |
| `wan` | 50 ms | 10 ms | 5 Mbps | none | ordinary remote link |
| `wifi` | 75 ms | 40 ms | 1 Mbps | 300 ms / 5 s | variable consumer link |
| `outage` | 50 ms | 50 ms | 5 Mbps | 500 ms / 3 s | stalled forwarding and recovery |
| `bad` | 150 ms | 100 ms | 256 Kbps | 1 s / 4 s | extreme backpressure |

Build and run a shaped profile:

```bash
tools/build_loopback_proxy.sh /tmp/macrdp-loopback-proxy
MACRDP_SERVER=./build/macrdp-server \
MACRDP_LOOPBACK_CLIENT=/tmp/macrdp-loopback-client \
MACRDP_LOOPBACK_PROXY=/tmp/macrdp-loopback-proxy \
MACRDP_LOOPBACK_NETWORK_PROFILE=wifi \
tools/run_loopback_smoke.sh
```

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
pipeline`/`Slow client frame handling` lines. A subjective report such as
"the screen is slow" is not enough to distinguish capture, encoding, network,
client decode, and output backpressure.
