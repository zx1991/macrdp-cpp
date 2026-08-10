# Changelog

This project has not published a stable release yet.

## Unreleased

- Experimental macOS RDP shadow server with NLA authentication.
- ScreenCaptureKit display capture and VideoToolbox AVC420 encoding.
- CoreGraphics keyboard and mouse injection with per-client input ownership.
- Text clipboard redirection and RDPSND audio output.
- Local unit tests, FreeRDP loopback validation, and deterministic network
  stress profiles.
- Explicit H.264 encoder selection for VideoToolbox, FFmpeg, and AVC444
  loopback comparisons.
- Serialized macOS pasteboard access and expanded shaped-link reconnect,
  resize, and clipboard-change validation.
- Added explicit `--reconnect` and `--no-reconnect` controls for running the
  long-budget Wi-Fi and bad-link reconnect profiles.
- Added raw keyboard-path diagnostics, queue-delay metrics, and loopback
  coverage for FastPath, classic input, Pause/E1, and modifier-release recovery.
- Corrected vertical and horizontal negative wheel deltas by decoding RDP's
  signed 9-bit wheel value before converting it to CoreGraphics line units.
- Separated ScreenCaptureKit frame and audio wakeups so one producer cannot
  wake the other path's consumer and leave the intended consumer waiting.
- Reordered the roadmap around lifecycle reliability, remote-control policy,
  release compliance, and deployment-target validation.
- Added finite ScreenCaptureKit discovery/start and stop waits, cleanup for
  timed-out attempts, and generation isolation for late stream callbacks.
- Added deterministic asynchronous completion/timeout tests and rewrote the
  root README around Alpha status, security boundaries, quick start, and
  release blockers.
- Isolated remote input in a private CoreGraphics event source and limited
  release recovery to per-client ownership, so startup and unmatched key-up
  events cannot release modifiers held by the local user.
- Added an injectable capture backend and deterministic tests for consumer
  wakeups, generation isolation, start/stop transitions, and concurrent
  stop/reconfigure lifecycle races without Screen Recording permission.
- Added independent `--view-only` and `--no-clipboard` access policies, a
  configurable 1-64 concurrent-client limit that defaults to one, and
  deterministic policy-gate coverage without macOS TCC permissions.
- Added optional post-build signing with a stable executable identifier so
  SSH-based development builds can retain exact-executable macOS TCC grants
  across relinks when a persistent local signing identity is configured.
- Suppressed the synthetic RDP Pause/E1 scan-code sequence on macOS, where no
  native Pause key exists, so its Control and Keypad Clear constituents cannot
  leave an external keyboard in an incorrect modifier state.
- Stopped inferring Num Lock state from CoreGraphics' NumericPad event flag
  during RDP synchronization, avoiding synthetic Keypad Clear events that can
  toggle Fn on external Windows keyboards.
- Rebuilt posted Control, Shift, Option, and Command flags from the remote input
  ownership ledger, removing CoreGraphics' synthetic SecondaryFn and stale
  device-dependent flags so one key event cannot contaminate later modifiers.
- Created a fresh private CoreGraphics source for every injected keyboard event
  and made loopback profiles fail on active post-run modifiers, preventing
  synthetic key state from leaking across clients.
- Corrected the slow-client loopback warm-up to use the established connection
  timestamp, preserving protocol setup before deliberate event-loop stalls.
- Prevented the loopback clipboard verifier from treating the expected
  client-to-server pasteboard reflection as a second server payload mismatch.
- Added an exact-server `--preflight` mode plus an owner-only, manifest-checked
  macOS diagnostic bundle and a P0 hardware/Windows validation matrix. The SSH
  path can run preflight through a temporary Aqua LaunchAgent without loading
  credentials from stdin, files, or the environment, creating server
  configuration, or opening a listener.
- Added an Aqua-capable hardware lifecycle harness that verifies repeated
  bounded startup, SIGTERM shutdown, listener cleanup, binary identity, and
  modifier cleanup without retaining its ephemeral credentials or config.
- Extended the non-identifying macOS system probe with active, asleep, and
  online display state for observable sleep/wake hardware evidence.
- Defaulted the RDP listener to `127.0.0.1` and required an explicit
  `--allow-insecure-security` acknowledgement before selecting TLS or classic
  RDP compatibility modes without NLA.
- Added atomic LaunchAgent RDP password rotation with owner, permission,
  configured-path, and loaded-service checks.
- Added reproducible package validation for Mach-O load paths, architectures,
  minimum macOS versions, signatures, and packaged loader behavior, and run it
  in macOS CI.
- Added an opt-in AppleClang AddressSanitizer and UndefinedBehaviorSanitizer
  build, plus arm64 CI coverage that runs the deterministic suite and repeats
  lifecycle-focused state-machine tests 50 times without live system input.
- Stopped FreeRDP's broad FFmpeg discovery from directly linking unused device,
  filter, format, and post-processing components into the macOS package, and
  made package validation reject those components if they return.
- Added generated third-party notices, formula license texts, the exact FFmpeg
  build configuration, and a CycloneDX 1.6 SBOM with validated hashes and
  dependency references to the developer package.
- Added a hash-pinned minimal FFmpeg 7.1.1 build for release-equivalent macOS
  packages. It dynamically links only `libavcodec`, `libavutil`,
  `libswresample`, and `libswscale`, reports LGPL-2.1-or-later at runtime, and
  rejects GPL, version3, nonfree, x264, and x265 configurations.
- Added deterministic release probes for AVC420, AVC444, VideoToolbox H.264,
  H.264 decoding, AAC, PCM, scaling, and resampling, plus managed dependency
  provenance in the generated notices and CycloneDX SBOM.
- Added a verified FFmpeg corresponding-source archive containing the pristine
  upstream source, checked-in patch, manifest, build driver, capability probe,
  rebuild instructions, and file checksums for publication with future binary
  releases.
- Disabled unused FreeRDP Azure AD and optional JSON backends so clean release
  builds cannot acquire an opportunistic cJSON runtime dependency from the
  host environment.
- Added a versioned per-user installation manager with complete SBOM hash and
  signature verification, stable LaunchAgent paths, atomic upgrade, automatic
  failed-restart recovery, reversible rollback, state-preserving uninstall,
  and explicit state purge semantics.
- Added deterministic installation lifecycle coverage using temporary package,
  HOME, LaunchAgent, certificate, and credential state without touching a real
  service or macOS TCC permissions.
