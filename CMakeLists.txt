cmake_minimum_required(VERSION 3.25)

# The current Homebrew FFmpeg/OpenSSL arm64 binaries used by the package are
# built for macOS 15. Keep the default honest; a locally built dependency set
# can still override this cache value for older deployment targets.
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS version")

project(macrdp_cpp
    VERSION 0.1.0
    LANGUAGES C CXX OBJC OBJCXX
)

include(FetchContent)
include(GNUInstallDirs)

enable_testing()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(CORE_GRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(CORE_MEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(CORE_VIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(AUDIO_TOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(SCREEN_CAPTURE_KIT_FRAMEWORK ScreenCaptureKit REQUIRED)
find_library(VIDEO_TOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
find_library(APP_KIT_FRAMEWORK AppKit REQUIRED)

# macOS-specific code is isolated behind a C++ interface. The rest of the
# application can remain ordinary C++ and does not need Objective-C headers.
add_library(macrdp_macos STATIC
    src/macos/display_capture.mm
    src/macos/h264_encoder.mm
    src/macos/videotoolbox_h264.mm
)

add_library(macrdp_config STATIC
    src/config_permissions.cpp
)

target_include_directories(macrdp_config PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp_config PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp_macos
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp_macos PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

target_link_libraries(macrdp_macos
    PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${CORE_GRAPHICS_FRAMEWORK}
        ${CORE_MEDIA_FRAMEWORK}
        ${CORE_VIDEO_FRAMEWORK}
        ${AUDIO_TOOLBOX_FRAMEWORK}
        ${SCREEN_CAPTURE_KIT_FRAMEWORK}
        ${VIDEO_TOOLBOX_FRAMEWORK}
)

add_executable(macrdp-cpp
    src/main.cpp
)

target_compile_options(macrdp-cpp PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-cpp PRIVATE macrdp_macos)

add_executable(macrdp-cpp-encoder-test
    src/encoder_test.cpp
)

target_compile_options(macrdp-cpp-encoder-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-cpp-encoder-test PRIVATE macrdp_macos)

add_executable(macrdp-display-dimensions-test
    src/display_dimensions_test.cpp
)

target_compile_options(macrdp-display-dimensions-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-display-dimensions-test PRIVATE macrdp_macos)

add_executable(macrdp-frame-coalescing-test
    src/frame_coalescing_test.cpp
)

target_compile_options(macrdp-frame-coalescing-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-frame-coalescing-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

option(MACRDP_FREERDP_WITH_FFMPEG
    "Build FreeRDP's GFX H.264 path with FFmpeg"
    ON
)

set(MACRDP_CODESIGN_IDENTITY "" CACHE STRING
    "macOS code-signing identity for macrdp-server (empty disables signing)"
)
set(MACRDP_CODESIGN_IDENTIFIER "io.github.zx1991.macrdp.server" CACHE STRING
    "Stable code-signing identifier for macrdp-server"
)

option(MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING
    "Use direct VideoToolbox H.264 encoding on macOS with FFmpeg fallback"
    ON
)

if(APPLE AND MACRDP_FREERDP_WITH_FFMPEG AND MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING)
    # Keep VideoToolbox decoding enabled for FreeRDP and use the direct bridge
    # below for encoding. The FFmpeg encoder remains a fallback.
    set(WITH_VIDEOTOOLBOX ON CACHE BOOL
        "Use FFmpeg VideoToolbox support for the macOS H.264 path" FORCE)
    add_compile_definitions(MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING)
else()
    set(WITH_VIDEOTOOLBOX OFF CACHE BOOL
        "Use FFmpeg VideoToolbox support for the macOS H.264 path" FORCE)
endif()

# FreeRDP's upstream CMake intentionally skips shadow support on macOS. We
# still reuse its protocol/server core and compile the platform-independent
# shadow sources below with our own ScreenCaptureKit subsystem.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build FreeRDP as static libraries" FORCE)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF CACHE BOOL "Disable IPO for the mixed C/Objective-C++ build" FORCE)
set(WITH_SERVER ON CACHE BOOL "Build FreeRDP server support" FORCE)
set(WITH_SHADOW OFF CACHE BOOL "FreeRDP shadow target is supplied locally" FORCE)
set(WITH_PROXY OFF CACHE BOOL "Do not build the FreeRDP proxy" FORCE)
set(WITH_PLATFORM_SERVER OFF CACHE BOOL "Do not build platform servers" FORCE)
set(WITH_SAMPLE OFF CACHE BOOL "Do not build FreeRDP samples" FORCE)
set(WITH_CLIENT OFF CACHE BOOL "Do not build FreeRDP clients" FORCE)
set(WITH_CLIENT_COMMON OFF CACHE BOOL "Do not build FreeRDP client common" FORCE)
set(WITH_CHANNELS ON CACHE BOOL "Build the server channels required by the shadow core" FORCE)
set(WITH_CLIENT_CHANNELS OFF CACHE BOOL "Do not build client channel plugins" FORCE)
set(WITH_SERVER_CHANNELS ON CACHE BOOL "Build the required server channels" FORCE)
set(WITH_SMARTCARD_EMULATE OFF CACHE BOOL "Do not build smartcard emulation" FORCE)
set(WITH_PCSC OFF CACHE BOOL "Do not build smartcard support" FORCE)
set(WITH_OPENH264 OFF CACHE BOOL "Use FFmpeg instead of OpenH264" FORCE)
set(WITH_OPUS OFF CACHE BOOL "Do not build Opus audio support" FORCE)
set(WITH_DSP_FFMPEG ON CACHE BOOL "Use FFmpeg audio DSP for RDPSND resampling" FORCE)
set(WITH_MANPAGES OFF CACHE BOOL "Do not build FreeRDP manpages" FORCE)
set(WITH_CLANG_FORMAT OFF CACHE BOOL "Do not configure clang-format" FORCE)
set(WITH_SERVER_INTERFACE ON CACHE BOOL "Build FreeRDP server interface" FORCE)
set(WITH_WINPR_JSON OFF CACHE BOOL "Do not build optional WinPR JSON support" FORCE)
set(WITH_WINPR_TOOLS_CLI OFF CACHE BOOL "Do not build WinPR command-line tools" FORCE)
set(WITH_VERBOSE_WINPR_ASSERT OFF CACHE BOOL
    "Disable verbose WinPR runtime assertions in Release builds" FORCE)
set(WITH_VAAPI_H264_ENCODING OFF CACHE BOOL "Do not configure VAAPI H.264 encoding" FORCE)

# The upstream shadow implementation references these channel contexts even
# when a client does not join the corresponding channel. Keep the server
# channel set intentionally small for this first macOS server milestone.
foreach(MACRDP_DISABLED_CHANNEL IN ITEMS
    AINPUT
    AUDIN
    DISP
    DRIVE
    ECHO
    GEOMETRY
    GFXREDIR
    LOCATION
    PARALLEL
    PRINTER
    RAIL
    RDP2TCP
    RDPDR
    RDPEAR
    RDPECAM
    RDPEI
    RDPEMSC
    RDPEWA
    SERIAL
    SMARTCARD
    SSHAGENT
    TELEMETRY
    TSMF
    URBDRC
    VIDEO)
    set(CHANNEL_${MACRDP_DISABLED_CHANNEL} OFF CACHE BOOL "Disable unused FreeRDP channel" FORCE)
endforeach()
foreach(MACRDP_REQUIRED_CHANNEL IN ITEMS CLIPRDR DRDYNVC ENCOMSP RDPGFX RDPSND REMDESK)
    set(CHANNEL_${MACRDP_REQUIRED_CHANNEL} ON CACHE BOOL "Enable required FreeRDP channel" FORCE)
endforeach()
set(CHANNEL_CLIPRDR_CLIENT OFF CACHE BOOL "Disable FreeRDP clipboard client" FORCE)
set(CHANNEL_CLIPRDR_SERVER ON CACHE BOOL "Enable FreeRDP clipboard server" FORCE)

if(MACRDP_FREERDP_WITH_FFMPEG)
    set(WITH_FFMPEG ON CACHE BOOL "Build FreeRDP with FFmpeg" FORCE)
    set(WITH_VIDEO_FFMPEG ON CACHE BOOL "Build FreeRDP video codec support" FORCE)
    set(WITH_SWSCALE ON CACHE BOOL "Build FreeRDP image scaling support" FORCE)
else()
    set(WITH_FFMPEG OFF CACHE BOOL "Build FreeRDP with FFmpeg" FORCE)
    set(WITH_VIDEO_FFMPEG OFF CACHE BOOL "Build FreeRDP video codec support" FORCE)
    set(WITH_SWSCALE OFF CACHE BOOL "Build FreeRDP image scaling support" FORCE)
endif()

FetchContent_Declare(
    freerdp
    URL https://codeload.github.com/FreeRDP/FreeRDP/tar.gz/refs/tags/3.30.0
    URL_HASH SHA256=21b3f72bd688fcd1dbbef37b7129bfc9701906705572fce2a5a80b1e85ecc0ee
)

# FetchContent keeps its extracted source across reconfiguration. Refresh only
# the generated dependency tree when one of the checked-in adaptation patches
# has changed; a caller-provided FETCHCONTENT_SOURCE_DIR_FREERDP is never removed.
set(MACRDP_FREERDP_PATCH
    "${CMAKE_CURRENT_SOURCE_DIR}/patches/freerdp-macrdp-adaptations.patch")
set(MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH
    "${CMAKE_CURRENT_SOURCE_DIR}/patches/freerdp-surface-output-priority.patch")
set(MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH
    "${CMAKE_CURRENT_SOURCE_DIR}/patches/freerdp-audio-queue-bound.patch")
set(MACRDP_FREERDP_OUTPUT_DIAGNOSTICS_PATCH
    "${CMAKE_CURRENT_SOURCE_DIR}/patches/freerdp-output-diagnostics.patch")
file(SHA256 "${MACRDP_FREERDP_PATCH}" MACRDP_FREERDP_PATCH_HASH)
file(SHA256 "${MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH}"
    MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH_HASH)
file(SHA256 "${MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH}"
    MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH_HASH)
file(SHA256 "${MACRDP_FREERDP_OUTPUT_DIAGNOSTICS_PATCH}"
    MACRDP_OUTPUT_DIAGNOSTICS_PATCH_HASH)
string(SHA256 MACRDP_FREERDP_PATCH_HASH
    "${MACRDP_FREERDP_PATCH_HASH}:${MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH_HASH}:${MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH_HASH}:${MACRDP_OUTPUT_DIAGNOSTICS_PATCH_HASH}")
set(MACRDP_FREERDP_PATCH_STAMP
    "${CMAKE_CURRENT_BINARY_DIR}/macrdp-freerdp-patch.sha256")
set(MACRDP_FREERDP_SOURCE_HINT
    "${CMAKE_CURRENT_BINARY_DIR}/_deps/freerdp-src")
set(MACRDP_FREERDP_BUILD_HINT
    "${CMAKE_CURRENT_BINARY_DIR}/_deps/freerdp-build")
set(MACRDP_FREERDP_SUBBUILD_HINT
    "${CMAKE_CURRENT_BINARY_DIR}/_deps/freerdp-subbuild")
set(MACRDP_FREERDP_PATCH_VERSION_MARKER
    "MACRDP_PATCH_VERSION_20260807_INPUT_OUTPUT_GATING_RESET_METRICS_TRANSPORT_ERRORS_CONTROL_OUTPUT_PRIORITY")
set(MACRDP_EXISTING_PATCH_HASH "")
if(EXISTS "${MACRDP_FREERDP_PATCH_STAMP}")
    file(READ "${MACRDP_FREERDP_PATCH_STAMP}" MACRDP_EXISTING_PATCH_HASH)
    string(STRIP "${MACRDP_EXISTING_PATCH_HASH}" MACRDP_EXISTING_PATCH_HASH)
endif()
if(NOT FETCHCONTENT_SOURCE_DIR_FREERDP
   AND EXISTS "${MACRDP_FREERDP_SOURCE_HINT}/server/shadow/shadow_client.c"
   AND EXISTS "${MACRDP_FREERDP_SOURCE_HINT}/include/freerdp/server/shadow.h")
    file(READ
        "${MACRDP_FREERDP_SOURCE_HINT}/server/shadow/shadow_client.c"
        MACRDP_EXISTING_SHADOW_CLIENT_CONTENT)
    file(READ
        "${MACRDP_FREERDP_SOURCE_HINT}/include/freerdp/server/shadow.h"
        MACRDP_EXISTING_SHADOW_HEADER_CONTENT)
    string(FIND
        "${MACRDP_EXISTING_SHADOW_CLIENT_CONTENT}"
        "${MACRDP_FREERDP_PATCH_VERSION_MARKER}"
        MACRDP_EXISTING_PATCH_VERSION_OFFSET)
    string(FIND
        "${MACRDP_EXISTING_SHADOW_CLIENT_CONTENT}"
        "MACRDP_MESSAGE_BUDGET"
        MACRDP_EXISTING_PATCH_OFFSET)
    string(FIND
        "${MACRDP_EXISTING_SHADOW_HEADER_CONTENT}"
        "MACRDP_CLIENT_FRAME_SNAPSHOT"
        MACRDP_EXISTING_HEADER_PATCH_OFFSET)
    if(NOT "${MACRDP_EXISTING_PATCH_HASH}" STREQUAL "${MACRDP_FREERDP_PATCH_HASH}"
       AND (NOT MACRDP_EXISTING_PATCH_OFFSET EQUAL -1
            OR NOT MACRDP_EXISTING_HEADER_PATCH_OFFSET EQUAL -1
            OR NOT MACRDP_EXISTING_PATCH_VERSION_OFFSET EQUAL -1))
        message(STATUS
            "Refreshing generated FreeRDP source because the macrdp adaptation patch changed")
        file(REMOVE_RECURSE
            "${MACRDP_FREERDP_SOURCE_HINT}"
            "${MACRDP_FREERDP_BUILD_HINT}"
            "${MACRDP_FREERDP_SUBBUILD_HINT}")
    endif()
endif()
FetchContent_MakeAvailable(freerdp)

# FreeRDP source adaptations are kept as checked-in patches against the pinned
# 3.30.0 tree. CMake only modifies the generated FetchContent copy.
set(MACRDP_FREERDP_SHADOW_HEADER
    "${freerdp_SOURCE_DIR}/include/freerdp/server/shadow.h")
set(MACRDP_FREERDP_SHADOW_CLIENT
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_client.c")
set(MACRDP_FREERDP_SHADOW_ENCODER_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_encoder.c")
set(MACRDP_FREERDP_SHADOW_SCREEN_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_screen.c")
set(MACRDP_FREERDP_H264_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/codec/h264_ffmpeg.c")
set(MACRDP_FREERDP_H264_CORE_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/codec/h264.c")
set(MACRDP_FREERDP_CHANNEL_SERVER_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/core/server.c")
set(MACRDP_FREERDP_SHADOW_SURFACE_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_surface.c")
set(MACRDP_FREERDP_SHADOW_SERVER_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_server.c")
set(MACRDP_FREERDP_SHADOW_MCEVENT_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_mcevent.c")
set(MACRDP_FREERDP_SHADOW_SUBSYSTEM_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_subsystem.c")
set(MACRDP_FREERDP_SHADOW_CHANNELS_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_channels.c")
set(MACRDP_FREERDP_SHADOW_RDPSND_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_rdpsnd.c")
set(MACRDP_FREERDP_TRANSPORT_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/core/transport.c")

foreach(MACRDP_REQUIRED_PATCH_FILE IN ITEMS
    "${MACRDP_FREERDP_PATCH}"
    "${MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH}"
    "${MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH}"
    "${MACRDP_FREERDP_OUTPUT_DIAGNOSTICS_PATCH}"
    "${MACRDP_FREERDP_SHADOW_HEADER}"
    "${MACRDP_FREERDP_SHADOW_CLIENT}"
    "${MACRDP_FREERDP_SHADOW_ENCODER_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SCREEN_SOURCE}"
    "${MACRDP_FREERDP_H264_SOURCE}"
    "${MACRDP_FREERDP_H264_CORE_SOURCE}"
    "${MACRDP_FREERDP_CHANNEL_SERVER_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_MCEVENT_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SUBSYSTEM_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_CHANNELS_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_RDPSND_SOURCE}"
    "${MACRDP_FREERDP_TRANSPORT_SOURCE}")
    if(NOT EXISTS "${MACRDP_REQUIRED_PATCH_FILE}")
        message(FATAL_ERROR
            "Missing FreeRDP source or checked-in macrdp adaptation patch: "
            "${MACRDP_REQUIRED_PATCH_FILE}")
    endif()
endforeach()

file(READ "${MACRDP_FREERDP_SHADOW_HEADER}" MACRDP_SHADOW_HEADER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_ENCODER_SOURCE}" MACRDP_SHADOW_ENCODER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SCREEN_SOURCE}" MACRDP_SHADOW_SCREEN_CONTENT)
file(READ "${MACRDP_FREERDP_H264_SOURCE}" MACRDP_FREERDP_H264_CONTENT)
file(READ "${MACRDP_FREERDP_H264_CORE_SOURCE}" MACRDP_FREERDP_H264_CORE_CONTENT)
file(READ "${MACRDP_FREERDP_CHANNEL_SERVER_SOURCE}" MACRDP_FREERDP_CHANNEL_SERVER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}" MACRDP_SHADOW_SURFACE_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}" MACRDP_SHADOW_SERVER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_MCEVENT_SOURCE}" MACRDP_SHADOW_MCEVENT_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SUBSYSTEM_SOURCE}" MACRDP_SHADOW_SUBSYSTEM_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_CHANNELS_SOURCE}" MACRDP_SHADOW_CHANNELS_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_RDPSND_SOURCE}" MACRDP_SHADOW_RDPSND_CONTENT)
file(READ "${MACRDP_FREERDP_TRANSPORT_SOURCE}" MACRDP_FREERDP_TRANSPORT_CONTENT)

string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_CLIENT_FRAME_SNAPSHOT"
    MACRDP_SHADOW_HEADER_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_SURFACE_FRAME_GENERATION"
    MACRDP_SURFACE_GENERATION_OFFSET)
string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_MONITOR_STATE_LOCK"
    MACRDP_MONITOR_LOCK_OFFSET)
string(FIND "${MACRDP_SHADOW_SCREEN_CONTENT}" "MACRDP_MONITOR_STATE_READ"
    MACRDP_SHADOW_SCREEN_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "shadow_client_snapshot_surface"
    MACRDP_SHADOW_SNAPSHOT_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_CLIENT_INCREMENTAL_SNAPSHOT"
    MACRDP_SHADOW_INCREMENTAL_SNAPSHOT_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_NONBLOCKING_OUTPUT"
    MACRDP_NONBLOCKING_OUTPUT_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_SKIP_BLOCKED_FRAME"
    MACRDP_SKIP_BLOCKED_FRAME_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_RESIZE_DIMENSIONS_LOCK"
    MACRDP_SHADOW_CLIENT_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_FRAME_STAGE_DIAGNOSTICS"
    MACRDP_FRAME_STAGE_DIAGNOSTICS_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_MESSAGE_BUDGET"
    MACRDP_MESSAGE_BUDGET_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_AUDIO_MESSAGE_COALESCING"
    MACRDP_AUDIO_MESSAGE_COALESCING_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_H264_WORKER_CONTEXT"
    MACRDP_H264_WORKER_CONTEXT_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_SURFACE_OUTPUT_PRIORITY"
    MACRDP_SURFACE_OUTPUT_PRIORITY_OFFSET)
string(FIND
    "${MACRDP_SHADOW_CLIENT_CONTENT}"
    "IFCALLRET(client->rdpgfx->SurfaceFrameCommand, error, client->rdpgfx, cmd"
    MACRDP_SURFACE_FRAME_CALL_OFFSET)
string(FIND "${MACRDP_SHADOW_ENCODER_CONTENT}" "MACRDP_H264_OPTIONS_BEFORE_RESET"
    MACRDP_H264_OPTIONS_ORDER_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}"
    "${MACRDP_FREERDP_PATCH_VERSION_MARKER}"
    MACRDP_PATCH_VERSION_OFFSET)
string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS"
    MACRDP_H264_PATCH_OFFSET)
string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_GOP_FIX"
    MACRDP_H264_GOP_PATCH_OFFSET)
string(FIND "${MACRDP_FREERDP_H264_CORE_CONTENT}" "MACRDP_H264_REGION_FIX"
    MACRDP_H264_REGION_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_SURFACE_CONTENT}" "MACRDP_SURFACE_RESIZE_LOCK"
    MACRDP_SHADOW_SURFACE_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_SERVER_CONTENT}" "MACRDP_SHADOW_STOP_ORDER"
    MACRDP_SHADOW_SERVER_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_MCEVENT_CONTENT}" "MACRDP_FRAME_BARRIER_DIAGNOSTICS"
    MACRDP_SHADOW_MCEVENT_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_MCEVENT_CONTENT}" "MACRDP_PENDING_FRAME_EVENT"
    MACRDP_PENDING_FRAME_EVENT_OFFSET)
string(FIND "${MACRDP_SHADOW_SUBSYSTEM_CONTENT}" "MACRDP_NONBLOCKING_FRAME_UPDATE"
    MACRDP_SHADOW_SUBSYSTEM_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_CHANNELS_CONTENT}" "MACRDP_CLIPRDR_CHANNEL"
    MACRDP_SHADOW_CHANNELS_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_RDPSND_CONTENT}" "MACRDP_RDPSND_PREFER_COMPRESSED"
    MACRDP_SHADOW_RDPSND_PATCH_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_NONBLOCKING_WRITE_QUEUE"
    MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_WRITE_QUEUE_COPY"
    MACRDP_FREERDP_WRITE_QUEUE_COPY_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_WRITE_CHUNK"
    MACRDP_FREERDP_WRITE_CHUNK_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_WRITE_BUDGET"
    MACRDP_FREERDP_WRITE_BUDGET_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "transport_set_output_priority"
    MACRDP_FREERDP_OUTPUT_PRIORITY_OFFSET)
string(FIND "${MACRDP_FREERDP_CHANNEL_SERVER_CONTENT}" "MACRDP_CHANNEL_MESSAGE_BUDGET"
    MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET)

if(MACRDP_SHADOW_HEADER_PATCH_OFFSET EQUAL -1
   AND MACRDP_SURFACE_GENERATION_OFFSET EQUAL -1
   AND MACRDP_MONITOR_LOCK_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SCREEN_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SNAPSHOT_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_INCREMENTAL_SNAPSHOT_OFFSET EQUAL -1
   AND MACRDP_NONBLOCKING_OUTPUT_OFFSET EQUAL -1
   AND MACRDP_SKIP_BLOCKED_FRAME_OFFSET EQUAL -1
   AND MACRDP_SHADOW_CLIENT_PATCH_OFFSET EQUAL -1
   AND MACRDP_FRAME_STAGE_DIAGNOSTICS_OFFSET EQUAL -1
   AND MACRDP_MESSAGE_BUDGET_OFFSET EQUAL -1
   AND MACRDP_AUDIO_MESSAGE_COALESCING_OFFSET EQUAL -1
   AND MACRDP_H264_WORKER_CONTEXT_OFFSET EQUAL -1
   AND MACRDP_SURFACE_OUTPUT_PRIORITY_OFFSET EQUAL -1
   AND MACRDP_H264_OPTIONS_ORDER_OFFSET EQUAL -1
   AND MACRDP_PATCH_VERSION_OFFSET EQUAL -1
   AND MACRDP_H264_PATCH_OFFSET EQUAL -1
   AND MACRDP_H264_GOP_PATCH_OFFSET EQUAL -1
   AND MACRDP_H264_REGION_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SURFACE_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SERVER_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_MCEVENT_PATCH_OFFSET EQUAL -1
   AND MACRDP_PENDING_FRAME_EVENT_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SUBSYSTEM_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_CHANNELS_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_RDPSND_PATCH_OFFSET EQUAL -1
   AND MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET EQUAL -1
   AND MACRDP_FREERDP_WRITE_QUEUE_COPY_OFFSET EQUAL -1
   AND MACRDP_FREERDP_WRITE_CHUNK_OFFSET EQUAL -1
   AND MACRDP_FREERDP_WRITE_BUDGET_OFFSET EQUAL -1
   AND MACRDP_FREERDP_OUTPUT_PRIORITY_OFFSET EQUAL -1
   AND MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET EQUAL -1)
    find_program(MACRDP_PATCH_EXECUTABLE patch)
    if(NOT MACRDP_PATCH_EXECUTABLE)
        message(FATAL_ERROR
            "The 'patch' utility is required to patch the pinned FreeRDP source")
    endif()

    execute_process(
        COMMAND "${MACRDP_PATCH_EXECUTABLE}" -N -t -F 0 -p1
            -i "${MACRDP_FREERDP_PATCH}"
        WORKING_DIRECTORY "${freerdp_SOURCE_DIR}"
        RESULT_VARIABLE MACRDP_PATCH_RESULT
        OUTPUT_VARIABLE MACRDP_PATCH_OUTPUT
        ERROR_VARIABLE MACRDP_PATCH_ERROR
    )
    if(NOT MACRDP_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR
            "Unable to apply the pinned FreeRDP macrdp adaptation patch.\n"
            "stdout: ${MACRDP_PATCH_OUTPUT}\n"
            "stderr: ${MACRDP_PATCH_ERROR}")
    endif()
elseif(NOT MACRDP_SHADOW_HEADER_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SURFACE_GENERATION_OFFSET EQUAL -1
       AND NOT MACRDP_MONITOR_LOCK_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SCREEN_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SNAPSHOT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_INCREMENTAL_SNAPSHOT_OFFSET EQUAL -1
       AND NOT MACRDP_NONBLOCKING_OUTPUT_OFFSET EQUAL -1
       AND NOT MACRDP_SKIP_BLOCKED_FRAME_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_CLIENT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FRAME_STAGE_DIAGNOSTICS_OFFSET EQUAL -1
       AND NOT MACRDP_MESSAGE_BUDGET_OFFSET EQUAL -1
       AND NOT MACRDP_AUDIO_MESSAGE_COALESCING_OFFSET EQUAL -1
       AND NOT MACRDP_H264_WORKER_CONTEXT_OFFSET EQUAL -1
       AND NOT MACRDP_SURFACE_OUTPUT_PRIORITY_OFFSET EQUAL -1
       AND NOT MACRDP_H264_OPTIONS_ORDER_OFFSET EQUAL -1
       AND NOT MACRDP_PATCH_VERSION_OFFSET EQUAL -1
       AND NOT MACRDP_H264_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_H264_GOP_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_H264_REGION_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SURFACE_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SERVER_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_MCEVENT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_PENDING_FRAME_EVENT_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SUBSYSTEM_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_CHANNELS_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_RDPSND_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_WRITE_QUEUE_COPY_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_WRITE_CHUNK_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_WRITE_BUDGET_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_OUTPUT_PRIORITY_OFFSET EQUAL -1
       AND NOT MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET EQUAL -1)
    # The generated FetchContent tree already contains the complete patch.
else()
    message(FATAL_ERROR
        "Pinned FreeRDP has a partial macrdp adaptation patch; "
        "remove the generated FetchContent source and reconfigure")
endif()

file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
string(FIND
    "${MACRDP_SHADOW_CLIENT_CONTENT}"
    "IFCALLRET(client->rdpgfx->SurfaceFrameCommand, error, client->rdpgfx, cmd"
    MACRDP_SURFACE_FRAME_CALL_OFFSET)
if(NOT MACRDP_SURFACE_FRAME_CALL_OFFSET EQUAL -1)
    find_program(MACRDP_PATCH_EXECUTABLE patch)
    if(NOT MACRDP_PATCH_EXECUTABLE)
        message(FATAL_ERROR
            "The 'patch' utility is required to patch the FreeRDP surface output path")
    endif()

    execute_process(
        COMMAND "${MACRDP_PATCH_EXECUTABLE}" -N -t -F 0 -p1
            -i "${MACRDP_FREERDP_SURFACE_OUTPUT_PRIORITY_PATCH}"
        WORKING_DIRECTORY "${freerdp_SOURCE_DIR}"
        RESULT_VARIABLE MACRDP_SURFACE_OUTPUT_PATCH_RESULT
        OUTPUT_VARIABLE MACRDP_SURFACE_OUTPUT_PATCH_OUTPUT
        ERROR_VARIABLE MACRDP_SURFACE_OUTPUT_PATCH_ERROR
    )
    if(NOT MACRDP_SURFACE_OUTPUT_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR
            "Unable to apply the FreeRDP surface output priority patch.\n"
            "stdout: ${MACRDP_SURFACE_OUTPUT_PATCH_OUTPUT}\n"
            "stderr: ${MACRDP_SURFACE_OUTPUT_PATCH_ERROR}")
    endif()

    file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
    string(FIND
        "${MACRDP_SHADOW_CLIENT_CONTENT}"
        "IFCALLRET(client->rdpgfx->SurfaceFrameCommand, error, client->rdpgfx, cmd"
        MACRDP_SURFACE_FRAME_CALL_OFFSET)
endif()
if(NOT MACRDP_SURFACE_FRAME_CALL_OFFSET EQUAL -1)
    message(FATAL_ERROR
        "FreeRDP surface output priority patch did not replace all surface frame calls")
endif()

file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_AUDIO_QUEUE_BOUND"
    MACRDP_AUDIO_QUEUE_BOUND_OFFSET)
if(MACRDP_AUDIO_QUEUE_BOUND_OFFSET EQUAL -1)
    find_program(MACRDP_PATCH_EXECUTABLE patch)
    if(NOT MACRDP_PATCH_EXECUTABLE)
        message(FATAL_ERROR
            "The 'patch' utility is required to bound the FreeRDP audio message queue")
    endif()

    execute_process(
        COMMAND "${MACRDP_PATCH_EXECUTABLE}" -N -t -F 0 -p1
            -i "${MACRDP_FREERDP_AUDIO_QUEUE_BOUND_PATCH}"
        WORKING_DIRECTORY "${freerdp_SOURCE_DIR}"
        RESULT_VARIABLE MACRDP_AUDIO_QUEUE_PATCH_RESULT
        OUTPUT_VARIABLE MACRDP_AUDIO_QUEUE_PATCH_OUTPUT
        ERROR_VARIABLE MACRDP_AUDIO_QUEUE_PATCH_ERROR
    )
    if(NOT MACRDP_AUDIO_QUEUE_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR
            "Unable to apply the FreeRDP audio queue bound patch.\n"
            "stdout: ${MACRDP_AUDIO_QUEUE_PATCH_OUTPUT}\n"
            "stderr: ${MACRDP_AUDIO_QUEUE_PATCH_ERROR}")
    endif()

    file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
    string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_AUDIO_QUEUE_BOUND"
        MACRDP_AUDIO_QUEUE_BOUND_OFFSET)
endif()
if(MACRDP_AUDIO_QUEUE_BOUND_OFFSET EQUAL -1)
    message(FATAL_ERROR
        "FreeRDP audio queue bound patch did not apply completely")
endif()

file(READ "${MACRDP_FREERDP_SHADOW_HEADER}" MACRDP_SHADOW_HEADER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
file(READ "${MACRDP_FREERDP_TRANSPORT_SOURCE}" MACRDP_FREERDP_TRANSPORT_CONTENT)
string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_OUTPUT_DIAGNOSTICS"
    MACRDP_OUTPUT_DIAGNOSTICS_HEADER_OFFSET)
string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_OUTPUT_DIAGNOSTICS"
    MACRDP_OUTPUT_DIAGNOSTICS_CLIENT_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_OUTPUT_QUEUE_DIAGNOSTICS"
    MACRDP_OUTPUT_DIAGNOSTICS_TRANSPORT_OFFSET)
if(MACRDP_OUTPUT_DIAGNOSTICS_HEADER_OFFSET EQUAL -1
   AND MACRDP_OUTPUT_DIAGNOSTICS_CLIENT_OFFSET EQUAL -1
   AND MACRDP_OUTPUT_DIAGNOSTICS_TRANSPORT_OFFSET EQUAL -1)
    find_program(MACRDP_PATCH_EXECUTABLE patch)
    if(NOT MACRDP_PATCH_EXECUTABLE)
        message(FATAL_ERROR
            "The 'patch' utility is required for FreeRDP output diagnostics")
    endif()

    execute_process(
        COMMAND "${MACRDP_PATCH_EXECUTABLE}" -N -t -F 0 -p1
            -i "${MACRDP_FREERDP_OUTPUT_DIAGNOSTICS_PATCH}"
        WORKING_DIRECTORY "${freerdp_SOURCE_DIR}"
        RESULT_VARIABLE MACRDP_OUTPUT_DIAGNOSTICS_PATCH_RESULT
        OUTPUT_VARIABLE MACRDP_OUTPUT_DIAGNOSTICS_PATCH_OUTPUT
        ERROR_VARIABLE MACRDP_OUTPUT_DIAGNOSTICS_PATCH_ERROR
    )
    if(NOT MACRDP_OUTPUT_DIAGNOSTICS_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR
            "Unable to apply the FreeRDP output diagnostics patch.\n"
            "stdout: ${MACRDP_OUTPUT_DIAGNOSTICS_PATCH_OUTPUT}\n"
            "stderr: ${MACRDP_OUTPUT_DIAGNOSTICS_PATCH_ERROR}")
    endif()

    file(READ "${MACRDP_FREERDP_SHADOW_HEADER}" MACRDP_SHADOW_HEADER_CONTENT)
    file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
    file(READ "${MACRDP_FREERDP_TRANSPORT_SOURCE}" MACRDP_FREERDP_TRANSPORT_CONTENT)
    string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_OUTPUT_DIAGNOSTICS"
        MACRDP_OUTPUT_DIAGNOSTICS_HEADER_OFFSET)
    string(FIND "${MACRDP_SHADOW_CLIENT_CONTENT}" "MACRDP_OUTPUT_DIAGNOSTICS"
        MACRDP_OUTPUT_DIAGNOSTICS_CLIENT_OFFSET)
    string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_OUTPUT_QUEUE_DIAGNOSTICS"
        MACRDP_OUTPUT_DIAGNOSTICS_TRANSPORT_OFFSET)
endif()
if(MACRDP_OUTPUT_DIAGNOSTICS_HEADER_OFFSET EQUAL -1
   OR MACRDP_OUTPUT_DIAGNOSTICS_CLIENT_OFFSET EQUAL -1
   OR MACRDP_OUTPUT_DIAGNOSTICS_TRANSPORT_OFFSET EQUAL -1)
    message(FATAL_ERROR
        "FreeRDP output diagnostics patch did not apply completely")
endif()

file(WRITE "${MACRDP_FREERDP_PATCH_STAMP}" "${MACRDP_FREERDP_PATCH_HASH}\n")

foreach(MACRDP_FREERDP_CODEC_TARGET IN ITEMS freerdp-codecs freerdp)
    if(TARGET ${MACRDP_FREERDP_CODEC_TARGET})
        target_include_directories(${MACRDP_FREERDP_CODEC_TARGET} PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
    endif()
endforeach()

set(MACRDP_FREERDP_SHADOW_SOURCES
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_client.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_lobby.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_input.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_screen.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_surface.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_encoder.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_capture.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_channels.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_encomsp.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_remdesk.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_rdpsnd.c
    src/macos/shadow_audin_stub.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_rdpgfx.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_subsystem.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_mcevent.c
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_server.c
    src/macos/mac_shadow_subsystem.mm
)

add_library(macrdp_freerdp_shadow STATIC ${MACRDP_FREERDP_SHADOW_SOURCES})

target_sources(macrdp_freerdp_shadow PRIVATE
    src/macos/rdp_h264_worker.cpp
    src/macos/macrdp_cliprdr.mm
)

target_include_directories(macrdp_freerdp_shadow
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/libfreerdp/core
        ${freerdp_SOURCE_DIR}/server/shadow
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
        ${OPENSSL_INCLUDE_DIR}
)

target_compile_options(macrdp_freerdp_shadow PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

target_link_libraries(macrdp_freerdp_shadow
    PRIVATE
        macrdp_macos
        ${APP_KIT_FRAMEWORK}
        freerdp-server
        freerdp
        winpr
        winpr-tools
)

add_executable(macrdp-server
    src/server_main.cpp
)

target_compile_options(macrdp-server PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src/macos
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_link_libraries(macrdp-server PRIVATE macrdp_freerdp_shadow macrdp_config)

if(APPLE AND NOT MACRDP_CODESIGN_IDENTITY STREQUAL "")
    if(MACRDP_CODESIGN_IDENTIFIER STREQUAL "")
        message(FATAL_ERROR
            "MACRDP_CODESIGN_IDENTIFIER must not be empty when signing is enabled"
        )
    endif()

    find_program(MACRDP_CODESIGN_EXECUTABLE codesign REQUIRED)
    add_custom_command(TARGET macrdp-server POST_BUILD
        COMMAND "${MACRDP_CODESIGN_EXECUTABLE}"
            --force
            --sign "${MACRDP_CODESIGN_IDENTITY}"
            --identifier "${MACRDP_CODESIGN_IDENTIFIER}"
            --timestamp=none
            "$<TARGET_FILE:macrdp-server>"
        COMMENT "Signing macrdp-server as ${MACRDP_CODESIGN_IDENTIFIER}"
        VERBATIM
    )
endif()

if(APPLE)
    add_custom_target(macrdp-package
        COMMAND ${CMAKE_COMMAND} -E env bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/package_macos.sh"
            "$<TARGET_FILE:macrdp-server>"
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-dist"
        DEPENDS macrdp-server
        USES_TERMINAL
    )

    add_custom_target(macrdp-package-validate
        COMMAND ${CMAKE_COMMAND} -E env bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/validate_macos_package.sh"
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-dist"
            "${CMAKE_OSX_ARCHITECTURES}"
            "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        DEPENDS macrdp-package
        USES_TERMINAL
    )
endif()

if(MACRDP_FREERDP_WITH_FFMPEG)
    add_executable(macrdp-freerdp-h264-test
        src/freerdp_h264_test.cpp
    )

    target_compile_options(macrdp-freerdp-h264-test PRIVATE
        -Wall
        -Wextra
        -Wpedantic
    )

    target_include_directories(macrdp-freerdp-h264-test PRIVATE
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
    )

    target_link_libraries(macrdp-freerdp-h264-test PRIVATE
        macrdp_freerdp_shadow
    )
endif()

add_executable(macrdp-h264-worker-test
    src/rdp_h264_worker_test.cpp
)

add_executable(macrdp-input-ownership-test
    src/input_ownership_test.cpp
)

add_executable(macrdp-async-completion-test
    src/async_completion_test.cpp
)

add_executable(macrdp-display-capture-lifecycle-test
    src/display_capture_lifecycle_test.cpp
)

add_executable(macrdp-config-permissions-test
    src/config_permissions_test.cpp
)

add_executable(macrdp-access-policy-test
    src/access_policy_test.cpp
)

target_compile_options(macrdp-access-policy-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-access-policy-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src/macos
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_link_libraries(macrdp-access-policy-test PRIVATE
    macrdp_freerdp_shadow
)

target_compile_options(macrdp-config-permissions-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-config-permissions-test PRIVATE macrdp_config)

target_compile_options(macrdp-input-ownership-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-input-ownership-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp-async-completion-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-async-completion-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp-display-capture-lifecycle-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-display-capture-lifecycle-test PRIVATE
    macrdp_macos
)

target_compile_options(macrdp-h264-worker-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-h264-worker-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/server/shadow
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_link_libraries(macrdp-h264-worker-test PRIVATE
    macrdp_freerdp_shadow
)

add_test(
    NAME h264_encoder
    COMMAND macrdp-cpp-encoder-test
        ${CMAKE_CURRENT_BINARY_DIR}/encoder-test.h264
)

add_test(
    NAME display_dimensions
    COMMAND macrdp-display-dimensions-test
)

add_test(
    NAME frame_coalescing
    COMMAND macrdp-frame-coalescing-test
)

if(MACRDP_FREERDP_WITH_FFMPEG)
    add_test(
        NAME freerdp_h264_encoder
        COMMAND macrdp-freerdp-h264-test
    )
endif()

add_test(
    NAME h264_worker
    COMMAND macrdp-h264-worker-test
)

add_test(
    NAME input_ownership
    COMMAND macrdp-input-ownership-test
)

add_test(
    NAME async_completion
    COMMAND macrdp-async-completion-test
)

add_test(
    NAME display_capture_lifecycle
    COMMAND macrdp-display-capture-lifecycle-test
)

add_test(
    NAME config_permissions
    COMMAND macrdp-config-permissions-test
)

add_test(
    NAME access_policy
    COMMAND macrdp-access-policy-test
)

add_test(
    NAME server_help
    COMMAND macrdp-server --help
)
set_tests_properties(server_help PROPERTIES PASS_REGULAR_EXPRESSION "--preflight")

add_test(
    NAME server_invalid_bind_address
    COMMAND macrdp-server
        --bind-address "127.0.0.1,::1"
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_bind_address PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_missing_password
    COMMAND macrdp-server
        --user macrdp-test-user
)
set_tests_properties(server_missing_password PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_missing_user
    COMMAND macrdp-server
        --password test
)
set_tests_properties(server_missing_user PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_empty_password
    COMMAND macrdp-server
        --user macrdp-test-user
        --password ""
)
set_tests_properties(server_empty_password PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_security
    COMMAND macrdp-server
        --security invalid
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_security PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_tls_requires_insecure_opt_in
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "requires --allow-insecure-security"
        $<TARGET_FILE:macrdp-server>
        --security tls
        --user macrdp-test-user
        --password test
)

add_test(
    NAME server_rdp_requires_insecure_opt_in
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "requires --allow-insecure-security"
        $<TARGET_FILE:macrdp-server>
        --security rdp
        --user macrdp-test-user
        --password test
)

add_test(
    NAME server_insecure_opt_in_requires_compatibility_mode
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "valid only with --security tls or rdp"
        $<TARGET_FILE:macrdp-server>
        --allow-insecure-security
        --user macrdp-test-user
        --password test
)

add_test(
    NAME server_tls_opt_in_reaches_credential_validation
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "TLS/RDP authentication requires non-empty --user and --password"
        $<TARGET_FILE:macrdp-server>
        --security tls
        --allow-insecure-security
)

add_test(
    NAME server_invalid_port
    COMMAND macrdp-server
        --port 0
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_port PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_bitrate
    COMMAND macrdp-server
        --bitrate 0
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_bitrate PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_fps
    COMMAND macrdp-server
        --fps 0
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_fps PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_max_clients_zero
    COMMAND macrdp-server
        --max-clients 0
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_max_clients_zero PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_max_clients_high
    COMMAND macrdp-server
        --max-clients 65
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_max_clients_high PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_h264_encoder
    COMMAND macrdp-server
        --h264-encoder invalid
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_h264_encoder PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_incompatible_h264_encoder
    COMMAND macrdp-server
        --avc444
        --h264-encoder videotoolbox
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_incompatible_h264_encoder PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME rotate_launch_agent_password
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/rotate_launch_agent_password_test.sh
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/rotate_launch_agent_password.sh
)
