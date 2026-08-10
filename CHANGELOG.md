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
