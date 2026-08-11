# FreeRDP adaptation patch

The checked-in patches are applied by CMake, in order, to the generated FreeRDP
3.30.0 source tree. The exact archive URL, SHA-256, patch order, and combined
patch stamp are declared in the top-level `CMakeLists.txt`.

The patches are kept in this repository so changes to the upstream boundary are
reviewable without committing a vendor tree. They add the small hooks needed by
the macOS shadow subsystem: frame snapshots, bounded output/message handling,
H.264 integration, audio message coalescing, diagnostics, and the atomic client
session boundary used during disconnect and reconnect. The final capability
policy patch also keeps RDPGFX 8.1 and 10.x H.264 flag semantics separate so a
modern client cannot lose AVC420 during capability confirmation. AVC420 and
AVC444 convert a complete desktop frame for every H.264 submission because the
codec uses full-frame inter-frame references; RDPGFX metadata still limits the
client update to tiles whose decoded pixels changed.

Do not edit `build/_deps/freerdp-src` directly. When the FreeRDP version
changes, review every hunk against the new upstream source, update the archive
hash, run a clean configure, and run the full test suite. FreeRDP remains a
separate Apache-2.0 project with its own notices.
