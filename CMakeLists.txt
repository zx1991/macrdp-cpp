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

option(MACRDP_FREERDP_WITH_FFMPEG
    "Build FreeRDP's GFX H.264 path with FFmpeg"
    ON
)

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
set(WITH_VAAPI_H264_ENCODING OFF CACHE BOOL "Do not configure VAAPI H.264 encoding" FORCE)

# The upstream shadow implementation references these channel contexts even
# when a client does not join the corresponding channel. Keep the server
# channel set intentionally small for this first macOS server milestone.
foreach(MACRDP_DISABLED_CHANNEL IN ITEMS
    AINPUT
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
foreach(MACRDP_REQUIRED_CHANNEL IN ITEMS AUDIN DRDYNVC ENCOMSP RDPGFX RDPSND REMDESK)
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

# FreeRDP's FFmpeg H.264 wrapper leaves AVCodecContext::gop_size at zero.
# FFmpeg defines zero as intra-only encoding, which makes every desktop frame
# an expensive I-frame. Apply the small real-time streaming fix after
# FetchContent has populated the pinned source tree so clean builds retain it.
set(MACRDP_FREERDP_H264_SOURCE
    "${freerdp_SOURCE_DIR}/libfreerdp/codec/h264_ffmpeg.c")
if(EXISTS "${MACRDP_FREERDP_H264_SOURCE}")
    file(READ "${MACRDP_FREERDP_H264_SOURCE}" MACRDP_FREERDP_H264_CONTENT)
    string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_GOP_FIX" MACRDP_GOP_FIX_OFFSET)
    if(MACRDP_GOP_FIX_OFFSET EQUAL -1)
        string(REPLACE
            "\tsys->codecEncoderContext->delay = 0;"
            "\tsys->codecEncoderContext->delay = 0;\n\t/* MACRDP_GOP_FIX: allow P-frames for interactive desktop streaming. */\n\tsys->codecEncoderContext->gop_size = 60;\n\tsys->codecEncoderContext->max_b_frames = 0;"
            MACRDP_FREERDP_H264_CONTENT
            "${MACRDP_FREERDP_H264_CONTENT}")
        file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
    endif()
endif()

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
    ${freerdp_SOURCE_DIR}/server/shadow/shadow_audin.c
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
    ${CMAKE_CURRENT_SOURCE_DIR}/src/macos
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_link_libraries(macrdp-server PRIVATE macrdp_freerdp_shadow)

add_test(
    NAME h264_encoder
    COMMAND macrdp-cpp-encoder-test
        ${CMAKE_CURRENT_BINARY_DIR}/encoder-test.h264
)
