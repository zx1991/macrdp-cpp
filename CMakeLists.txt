cmake_minimum_required(VERSION 3.25)

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")

project(macrdp_cpp
    VERSION 0.1.0
    LANGUAGES C CXX OBJC OBJCXX
)

include(FetchContent)

enable_testing()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(CORE_GRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(CORE_MEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(CORE_VIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(SCREEN_CAPTURE_KIT_FRAMEWORK ScreenCaptureKit REQUIRED)
find_library(VIDEO_TOOLBOX_FRAMEWORK VideoToolbox REQUIRED)

# macOS-specific code is isolated behind a C++ interface. The rest of the
# application can remain ordinary C++ and does not need Objective-C headers.
add_library(macrdp_macos STATIC
    src/macos/display_capture.mm
    src/macos/h264_encoder.mm
    src/macos/videotoolbox_h264.mm
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
set(WITH_DSP_FFMPEG OFF CACHE BOOL "Do not build FFmpeg audio DSP support" FORCE)
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
    CLIPRDR
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
foreach(MACRDP_REQUIRED_CHANNEL IN ITEMS DRDYNVC ENCOMSP RDPGFX RDPSND REMDESK)
    set(CHANNEL_${MACRDP_REQUIRED_CHANNEL} ON CACHE BOOL "Enable required FreeRDP channel" FORCE)
endforeach()

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
FetchContent_MakeAvailable(freerdp)

# FreeRDP source adaptations are kept as one checked-in patch against the
# pinned 3.30.0 tree. CMake only modifies the generated FetchContent copy.
set(MACRDP_FREERDP_PATCH
    "${CMAKE_CURRENT_SOURCE_DIR}/patches/freerdp-macrdp-adaptations.patch")
set(MACRDP_FREERDP_SHADOW_HEADER
    "${freerdp_SOURCE_DIR}/include/freerdp/server/shadow.h")
set(MACRDP_FREERDP_SHADOW_CLIENT
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_client.c")
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
set(MACRDP_FREERDP_TRANSPORT_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/core/transport.c")

foreach(MACRDP_REQUIRED_PATCH_FILE IN ITEMS
    "${MACRDP_FREERDP_PATCH}"
    "${MACRDP_FREERDP_SHADOW_HEADER}"
    "${MACRDP_FREERDP_SHADOW_CLIENT}"
    "${MACRDP_FREERDP_H264_SOURCE}"
    "${MACRDP_FREERDP_H264_CORE_SOURCE}"
    "${MACRDP_FREERDP_CHANNEL_SERVER_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_MCEVENT_SOURCE}"
    "${MACRDP_FREERDP_SHADOW_SUBSYSTEM_SOURCE}"
    "${MACRDP_FREERDP_TRANSPORT_SOURCE}")
    if(NOT EXISTS "${MACRDP_REQUIRED_PATCH_FILE}")
        message(FATAL_ERROR
            "Missing FreeRDP source or checked-in macrdp adaptation patch: "
            "${MACRDP_REQUIRED_PATCH_FILE}")
    endif()
endforeach()

file(READ "${MACRDP_FREERDP_SHADOW_HEADER}" MACRDP_SHADOW_HEADER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_CLIENT}" MACRDP_SHADOW_CLIENT_CONTENT)
file(READ "${MACRDP_FREERDP_H264_SOURCE}" MACRDP_FREERDP_H264_CONTENT)
file(READ "${MACRDP_FREERDP_H264_CORE_SOURCE}" MACRDP_FREERDP_H264_CORE_CONTENT)
file(READ "${MACRDP_FREERDP_CHANNEL_SERVER_SOURCE}" MACRDP_FREERDP_CHANNEL_SERVER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}" MACRDP_SHADOW_SURFACE_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}" MACRDP_SHADOW_SERVER_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_MCEVENT_SOURCE}" MACRDP_SHADOW_MCEVENT_CONTENT)
file(READ "${MACRDP_FREERDP_SHADOW_SUBSYSTEM_SOURCE}" MACRDP_SHADOW_SUBSYSTEM_CONTENT)
file(READ "${MACRDP_FREERDP_TRANSPORT_SOURCE}" MACRDP_FREERDP_TRANSPORT_CONTENT)

string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_CLIENT_FRAME_SNAPSHOT"
    MACRDP_SHADOW_HEADER_PATCH_OFFSET)
string(FIND "${MACRDP_SHADOW_HEADER_CONTENT}" "MACRDP_SURFACE_FRAME_GENERATION"
    MACRDP_SURFACE_GENERATION_OFFSET)
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
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_NONBLOCKING_WRITE_QUEUE"
    MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_WRITE_CHUNK"
    MACRDP_FREERDP_WRITE_CHUNK_OFFSET)
string(FIND "${MACRDP_FREERDP_TRANSPORT_CONTENT}" "MACRDP_WRITE_BUDGET"
    MACRDP_FREERDP_WRITE_BUDGET_OFFSET)
string(FIND "${MACRDP_FREERDP_CHANNEL_SERVER_CONTENT}" "MACRDP_CHANNEL_MESSAGE_BUDGET"
    MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET)

if(MACRDP_SHADOW_HEADER_PATCH_OFFSET EQUAL -1
   AND MACRDP_SURFACE_GENERATION_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SNAPSHOT_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_INCREMENTAL_SNAPSHOT_OFFSET EQUAL -1
   AND MACRDP_NONBLOCKING_OUTPUT_OFFSET EQUAL -1
   AND MACRDP_SKIP_BLOCKED_FRAME_OFFSET EQUAL -1
   AND MACRDP_SHADOW_CLIENT_PATCH_OFFSET EQUAL -1
   AND MACRDP_FRAME_STAGE_DIAGNOSTICS_OFFSET EQUAL -1
   AND MACRDP_MESSAGE_BUDGET_OFFSET EQUAL -1
   AND MACRDP_H264_PATCH_OFFSET EQUAL -1
   AND MACRDP_H264_GOP_PATCH_OFFSET EQUAL -1
   AND MACRDP_H264_REGION_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SURFACE_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SERVER_PATCH_OFFSET EQUAL -1
   AND MACRDP_SHADOW_MCEVENT_PATCH_OFFSET EQUAL -1
   AND MACRDP_PENDING_FRAME_EVENT_OFFSET EQUAL -1
   AND MACRDP_SHADOW_SUBSYSTEM_PATCH_OFFSET EQUAL -1
   AND MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET EQUAL -1
   AND MACRDP_FREERDP_WRITE_CHUNK_OFFSET EQUAL -1
   AND MACRDP_FREERDP_WRITE_BUDGET_OFFSET EQUAL -1
   AND MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET EQUAL -1)
    find_program(MACRDP_PATCH_EXECUTABLE patch)
    if(NOT MACRDP_PATCH_EXECUTABLE)
        message(FATAL_ERROR
            "The 'patch' utility is required to patch the pinned FreeRDP source")
    endif()

    execute_process(
        COMMAND "${MACRDP_PATCH_EXECUTABLE}" -N -t -p1
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
       AND NOT MACRDP_SHADOW_SNAPSHOT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_INCREMENTAL_SNAPSHOT_OFFSET EQUAL -1
       AND NOT MACRDP_NONBLOCKING_OUTPUT_OFFSET EQUAL -1
       AND NOT MACRDP_SKIP_BLOCKED_FRAME_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_CLIENT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FRAME_STAGE_DIAGNOSTICS_OFFSET EQUAL -1
       AND NOT MACRDP_MESSAGE_BUDGET_OFFSET EQUAL -1
       AND NOT MACRDP_H264_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_H264_GOP_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_H264_REGION_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SURFACE_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SERVER_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_MCEVENT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_PENDING_FRAME_EVENT_OFFSET EQUAL -1
       AND NOT MACRDP_SHADOW_SUBSYSTEM_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_TRANSPORT_PATCH_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_WRITE_CHUNK_OFFSET EQUAL -1
       AND NOT MACRDP_FREERDP_WRITE_BUDGET_OFFSET EQUAL -1
       AND NOT MACRDP_CHANNEL_MESSAGE_BUDGET_OFFSET EQUAL -1)
    # The generated FetchContent tree already contains the complete patch.
else()
    message(FATAL_ERROR
        "Pinned FreeRDP has a partial macrdp adaptation patch; "
        "remove the generated FetchContent source and reconfigure")
endif()

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

target_include_directories(macrdp_freerdp_shadow
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/server/shadow
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
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

target_link_libraries(macrdp-server PRIVATE macrdp_freerdp_shadow)

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
