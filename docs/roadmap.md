# Roadmap

The repository is intentionally useful before it is feature-complete. The
following order reflects current risk and user value rather than a promise of
release dates.

## Near term

- Make the output scheduler and per-client media queues observable with stable
  counters for queue depth, dropped video, write stalls, and recovery time.
- Compare direct AVC420, FFmpeg AVC420, AVC444, and SurfaceBits using the same
  measured test matrix.
- Improve automated tests for repeated reconnects, resolution changes, and
  clipboard changes while the network is shaped.
- Add a reproducible developer build configuration for the FreeRDP client used
  by the loopback tests.

## Protocol and platform work

- Validate current Windows `mstsc` behavior across NLA, TLS, clipboard, audio,
  resize, and input scenarios.
- Add multi-monitor selection and robust Retina/display-mode handling.
- Add richer clipboard formats only after text transfer remains reliable.
- Evaluate microphone/AUDIN support separately from speaker/RDPSND output.
- Improve input and output scheduling so control events remain responsive when
  a video client is blocked.

## Distribution

- Build and document a signed, notarized Developer ID package.
- Define upgrade and rollback behavior for generated configuration and SAM
  files.
- Publish release artifacts only after the security and Windows validation
  gates are explicit.
