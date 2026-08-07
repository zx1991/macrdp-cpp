# FreeRDP adaptation patch

`freerdp-macrdp-adaptations.patch` is applied by CMake to the generated
FreeRDP 3.30.0 source tree. The exact archive URL and SHA-256 are declared in
the top-level `CMakeLists.txt`.

The patch is kept in this repository so changes to the upstream boundary are
reviewable without committing a vendor tree. It adds the small hooks needed by
the macOS shadow subsystem: frame snapshots, bounded output/message handling,
H.264 integration, audio message coalescing, and diagnostics.

Do not edit `build/_deps/freerdp-src` directly. When the FreeRDP version
changes, review every hunk against the new upstream source, update the archive
hash, run a clean configure, and run the full test suite. FreeRDP remains a
separate Apache-2.0 project with its own notices.
