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
- Add an injectable capture backend and deterministic coverage for separate
  frame/audio wakeups, generation isolation, start/stop transitions, and
  concurrent stop/reconfigure serialization without TCC or a display.
- Add independent `--view-only` and `--no-clipboard` policies, default the
  listener to one concurrent client, and enforce a configurable 1-64 client
  limit before accepting a new shadow session.
- Add an exact-server permission preflight, an owner-only hardware diagnostic
  bundle, and a repeatable P0 acceptance matrix whose built-in probes do not
  query hardware serial numbers, network addresses, credentials, or keychain
  contents.
- Prevent private CoreGraphics keyboard state from crossing events or clients,
  require clean modifier probes after loopback profiles, and provide an
  Aqua-capable harness for at least 20 bounded real server start/stop cycles.
- Default the listener to loopback, require explicit acknowledgement for
  non-NLA compatibility modes, and provide atomic LaunchAgent credential
  rotation with exact password-file validation.
- Build and validate the relocatable developer payload in CI, including its
  load paths, architectures, minimum macOS versions, signatures, and loader
  behavior.
- Instrument the complete static build with AddressSanitizer and
  UndefinedBehaviorSanitizer in CI, run the deterministic suite, and repeat
  lifecycle-focused state-machine tests without TCC or input side effects.
- Remove unused FFmpeg device, filter, format, and post-processing components
  from FreeRDP's static link interface and reject them during package
  validation, reducing the Homebrew-derived runtime dependency closure.
- Bundle project, FreeRDP, and Homebrew formula license texts with generated
  third-party notices and a CycloneDX 1.6 SBOM whose payload, compliance-file,
  and dependency references are validated during packaging.
- Add a pinned, minimal FFmpeg 7.1.1 release build that produces only the four
  required shared libraries, reports LGPL-2.1-or-later at runtime, rejects GPL
  and nonfree options, and verifies AVC420, AVC444, AAC, and PCM capabilities.
- Generate and self-validate an FFmpeg corresponding-source archive containing
  the pristine upstream source, applied patches, manifest, build driver, probe,
  rebuild instructions, and checksums for publication beside a binary release.
- Add a versioned per-user installation manager with complete package hash and
  signature checks, stable LaunchAgent paths, atomic upgrade, failed-restart
  recovery, one-command rollback, state-preserving uninstall, and explicit
  state purge behavior.
- Add a read-only DMG release carrier with post-signing SBOM generation,
  Developer ID and hardened-runtime gates, notarytool submission, explicit
  acceptance checks, stapling, Gatekeeper validation, and credential-free CI
  coverage of the development image.
- Add active-display discovery and exact startup selection, and use the same
  display ID for ScreenCaptureKit, RDP surface dimensions, preflight, and input
  mapping with deterministic negative-origin and Retina geometry coverage.
- Put CoreGraphics topology behind an injectable backend and atomically commit
  generation-tagged surface, capture, and input geometry. Deterministic tests
  cover main-display, resolution/scaling, rotation, negative-origin, Retina,
  detach/reconnect, and stale-callback transitions; exact IDs never fall back.
- Gate clipboard publication on client capabilities, correlate ordered remote
  responses with a bounded per-connection request queue, and stop monitor and
  callback side effects before releasing a disconnected channel. Deterministic
  tests cover queue bounds, rollback, unsolicited responses, and reconnect
  isolation without touching `NSPasteboard`.
- Isolate audio across display generations and RDPSND connection lifetimes.
  Topology changes and capture restarts clear pending PCM, stopped streams use
  bounded polling, clients receive no audio work before successful format
  selection, and teardown clears negotiation state before releasing the
  channel; deterministic tests require neither capture nor a listener.
- Atomically gate the complete FreeRDP client session lifecycle. Teardown
  rejects new output before releasing channels, invokes subsystem disconnect
  after every successful connect even when the socket is already closed, and
  prevents late input callbacks from recreating old ownership. A 100-cycle
  deterministic reconnect test covers input, clipboard, and RDPSND together.
- Make RDPGFX H.264 capability handling version-aware. Version 8.1 uses
  `AVC420_ENABLED`, 10.x uses `AVC_DISABLED`, the 10.6 errata value is covered,
  and unknown versions fail closed. Codec negotiation remains per client while
  bitrate and capture rate stay explicit until transport measurements justify
  a stable control loop.

## P0: correctness and lifecycle

- Record the bounded start/stop paths under permission denial, display sleep,
  session lock, and rapid reconfiguration in the
  [supported-hardware matrix](hardware-matrix.md).
- Complete the `mstsc` rows on supported macOS hardware: NLA/TLS failure,
  vertical and horizontal wheel direction, FastPath and classic input,
  clipboard, audio, resize, reconnect, and sleep/wake recovery.

P0 is complete when the server cannot hang during ordinary start, stop, or
reconfigure failures, the Apple callback races have deterministic coverage,
and the Windows matrix has recorded results for every interactive path.

## P1: deployment safety

The planned deployment-safety implementation is complete. The real loopback
test remains opt-in because it changes the system clipboard and injects
keyboard and pointer events.

P1 is complete when an operator can deliberately grant view-only, clipboard,
and input capabilities, bound session concurrency, and reproduce the package
validation in CI.

## P2: release engineering

- Run the implemented signing and notarization pipeline with a real Developer
  ID identity, then exercise install, upgrade, rollback, and uninstall on a
  clean supported Mac.
- Automate publication of the binary, tagged project source, FFmpeg
  corresponding-source archive, checksums, SBOM, and release notes as one
  versioned release set.

P2 is complete when a clean machine can install, launch, verify, and uninstall
a signed artifact whose minimum OS, dependencies, and licensing are explicit.

## P3: compatibility and features

- Validate the implemented Retina/display-mode lifecycle on selected external
  displays, including rotation, hot-plug recovery, and main-display changes.
- Add richer clipboard formats only after text transfer remains reliable under
  reconnect and shaped-link tests.
- Evaluate microphone/AUDIN separately from speaker/RDPSND output.

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
