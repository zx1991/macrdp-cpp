# Roadmap

macrdp-cpp is a usable Alpha prototype, not yet a public binary release. It has
real capture, H.264 transport, input, text clipboard, and audio paths, backed by
local tests and a FreeRDP loopback harness. The remaining work is ordered by
release risk first, then compatibility, distribution, and performance. These
are acceptance gates rather than promised dates.

## Recently completed

- Correctly decode RDP's signed 9-bit vertical and horizontal wheel deltas.
- Separate ScreenCaptureKit audio and video consumer wakeups.
- Bound capture discovery/start to 15 seconds and stop to 5 seconds. Timed-out
  attempts request cleanup, and generation tokens isolate their late callbacks.
- Add deterministic coverage for completion, timeout, late-result rejection,
  and cleanup-handler races that do not require Apple framework callbacks.
- Isolate remote keyboard and pointer state in a lifetime-scoped private
  CoreGraphics event source. Startup no longer releases local HID modifiers,
  and disconnect/shutdown cleanup is bounded by the remote ownership ledger.

## P0: correctness and lifecycle

- Add an injectable ScreenCaptureKit boundary to test capture-state wakeups,
  generation isolation, and stop/reconfigure races without TCC or a display.
- Validate the bounded start/stop paths under permission denial, display sleep,
  session lock, and rapid reconfiguration on supported hardware.
- Run the current `mstsc` matrix on supported macOS hardware: NLA/TLS failure,
  vertical and horizontal wheel direction, FastPath and classic input,
  clipboard, audio, resize, reconnect, and sleep/wake recovery.

P0 is complete when the server cannot hang during ordinary start, stop, or
reconfigure failures, the Apple callback races have deterministic coverage,
and the Windows matrix has recorded results for every interactive path.

## P1: deployment safety

- Add explicit `--no-clipboard` and view-only modes, and enforce a configurable
  concurrent-client limit before accepting interactive sessions.
- Document listener exposure and credential rotation. Keep NLA as the default
  and make insecure combinations difficult to select accidentally.
- Add sanitizer builds and lifecycle-focused stress tests. Keep the real
  loopback test opt-in because it changes the system clipboard and injects
  keyboard and pointer events.
- Add CI jobs that build the distributable bundle and validate its load paths,
  architectures, minimum macOS version, and launch behavior rather than testing
  only the build tree.

P1 is complete when an operator can deliberately grant view-only, clipboard,
and input capabilities, bound session concurrency, and reproduce the package
validation in CI.

## P2: release engineering

- Make the executable and every bundled dynamic library agree on the supported
  macOS deployment target. Fail packaging when a dependency requires a newer
  system than the advertised target.
- Reduce the current Homebrew-derived FFmpeg dependency closure or replace it
  with a purpose-built codec configuration. Record the exact build options and
  verify GPL implications before distributing binaries.
- Bundle third-party notices and license texts and generate an SBOM for FreeRDP,
  FFmpeg, OpenSSL, and transitive libraries.
- Build, sign, and notarize a Developer ID package. Define upgrade and rollback
  behavior for generated certificates, configuration, and SAM files.

P2 is complete when a clean machine can install, launch, verify, and uninstall
a signed artifact whose minimum OS, dependencies, and licensing are explicit.

## P3: compatibility and features

- Add multi-monitor selection and robust Retina/display-mode handling.
- Add richer clipboard formats only after text transfer remains reliable under
  reconnect and shaped-link tests.
- Evaluate microphone/AUDIN separately from speaker/RDPSND output.
- Decide whether a supported client should receive adaptive defaults based on
  negotiated capabilities or measured transport behavior.

## P4: performance

- Compare direct AVC420, FFmpeg AVC420, AVC444, and SurfaceBits with the same
  resolution, frame rate, bitrate, audio mode, and network profiles.
- Exercise the longer `wifi` and `bad` reconnect matrices and decide which
  bounded subset belongs in regular CI.
- Tune capture, encoder, and output scheduling from recorded pipeline metrics;
  retain input-first behavior and bounded queues as invariants.

Performance work starts after the release-safety gates because benchmark wins
do not offset an unbounded shutdown, ambiguous access policy, or an artifact
whose platform and license requirements are unclear.
