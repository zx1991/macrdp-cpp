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

if(MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING)
    foreach(MACRDP_FREERDP_CODEC_TARGET IN ITEMS freerdp-codecs freerdp)
        if(TARGET ${MACRDP_FREERDP_CODEC_TARGET})
            target_include_directories(${MACRDP_FREERDP_CODEC_TARGET} PRIVATE
                ${CMAKE_CURRENT_SOURCE_DIR}/include
            )
        endif()
    endforeach()
endif()

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

    if(APPLE AND MACRDP_FREERDP_WITH_FFMPEG AND MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING)
        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "#include <winpr/synch.h>"
            MACRDP_SYNCH_INCLUDE_OFFSET)
        if(MACRDP_SYNCH_INCLUDE_OFFSET EQUAL -1)
            string(REPLACE
                "#include <winpr/wlog.h>"
                "#include <winpr/wlog.h>\n#include <winpr/synch.h>"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE"
            MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE_OFFSET EQUAL -1)
            string(REPLACE
                "#include <winpr/synch.h>"
                "#include <winpr/synch.h>\n#include <macrdp/videotoolbox_h264.h>\n/* MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE */"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE"
                MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_INCLUDE_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the macOS VideoToolbox bridge include")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD"
            MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD_OFFSET EQUAL -1)
            string(REPLACE
                "\tAVPacket* packet;\n"
                "\tAVPacket* packet;\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\tmacrdp_vt_h264_encoder* macrdpVideoToolboxEncoder;\n#endif\n/* MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD */\n"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD"
                MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_FIELD_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the macOS VideoToolbox bridge state")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY"
            MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY_OFFSET EQUAL -1)
            string(REPLACE
                "\tif (sys->codecEncoderContext)\n\t{\n#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(55, 69, 100)"
                "#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\tif (sys->macrdpVideoToolboxEncoder)\n\t{\n\t\tmacrdp_vt_h264_encoder_free(sys->macrdpVideoToolboxEncoder);\n\t\tsys->macrdpVideoToolboxEncoder = nullptr;\n\t}\n#endif\n\t/* MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY */\n\tif (sys->codecEncoderContext)\n\t{\n#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(55, 69, 100)"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY"
                MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_DESTROY_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the macOS VideoToolbox bridge cleanup")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE"
            MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE_OFFSET EQUAL -1)
            string(REPLACE
                "\tif (!sys || !sys->codecEncoder)\n\t\treturn FALSE;\n"
                "\tif (!sys || !sys->codecEncoder)\n\t\treturn FALSE;\n\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\tif (sys->macrdpVideoToolboxEncoder)\n\t\treturn TRUE;\n\n\tif (sys->codecEncoder == avcodec_find_encoder_by_name(\"h264_videotoolbox\"))\n\t{\n\t\t/* MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE */\n\t\tsys->macrdpVideoToolboxEncoder = macrdp_vt_h264_encoder_new(\n\t\t\th264->width, h264->height, h264->BitRate, h264->FrameRate, 60);\n\t\tif (sys->macrdpVideoToolboxEncoder)\n\t\t\treturn TRUE;\n\n\t\tWLog_Print(h264->log, WLOG_WARN,\n\t\t           \"Direct VideoToolbox H264 encoder unavailable, falling back to FFmpeg\");\n\t\tsys->codecEncoder = avcodec_find_encoder(AV_CODEC_ID_H264);\n\t\tif (!sys->codecEncoder)\n\t\t\treturn FALSE;\n\t}\n#endif\n"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE"
                MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_CREATE_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the macOS VideoToolbox bridge creation")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}"
            "MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2"
            MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2_OFFSET EQUAL -1)
            # Migrate the first version, which was intentionally placed after
            # the encoder fast path and would have logged on every frame.
            string(REPLACE
                "\tif (sys->macrdpVideoToolboxEncoder)\n\t{\n\t\tWLog_Print(h264->log, WLOG_INFO,\n\t\t           \"Using direct macOS VideoToolbox H264 bridge (%ux%u @ %u fps)\",\n\t\t           h264->width, h264->height, h264->FrameRate);\n\t\treturn TRUE;\n\t}\n\t/* MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG */"
                "\tif (sys->macrdpVideoToolboxEncoder)\n\t\treturn TRUE;"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(REPLACE
                "\t\tif (sys->macrdpVideoToolboxEncoder)\n\t\t\treturn TRUE;\n\n\t\tWLog_Print(h264->log, WLOG_WARN,"
                "\t\tif (sys->macrdpVideoToolboxEncoder)\n\t\t{\n\t\t\tWLog_Print(h264->log, WLOG_INFO,\n\t\t\t           \"Using direct macOS VideoToolbox H264 bridge (%ux%u @ %u fps)\",\n\t\t\t           h264->width, h264->height, h264->FrameRate);\n\t\t\t/* MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2 */\n\t\t\treturn TRUE;\n\t\t}\n\n\t\tWLog_Print(h264->log, WLOG_WARN,"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}"
                "MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2"
                MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_ACTIVE_LOG_V2_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the direct VideoToolbox activation log")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS"
            MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS_OFFSET EQUAL -1)
            string(REPLACE
                "\tif (!libavcodec_create_encoder_context(h264))\n\t\treturn -1;\n"
                "\tif (!libavcodec_create_encoder_context(h264))\n\t\treturn -1;\n\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\tif (sys->macrdpVideoToolboxEncoder)\n\t{\n\t\t/* MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS */\n\t\t*ppDstData = nullptr;\n\t\t*pDstSize = 0;\n\t\tconst uint64_t frameIndex = sys->videoFrame->pts > 0\n\t\t                                 ? (uint64_t)(sys->videoFrame->pts - 1)\n\t\t                                 : 0;\n\t\tsys->videoFrame->pts++;\n\t\tconst int directStatus = macrdp_vt_h264_encoder_encode(\n\t\t\tsys->macrdpVideoToolboxEncoder, pSrcYuv[0], pSrcYuv[1], pSrcYuv[2],\n\t\t\tpStride, frameIndex, ppDstData, pDstSize);\n\t\tif (directStatus < 0)\n\t\t{\n\t\t\tconst char* error = macrdp_vt_h264_encoder_last_error(\n\t\t\t\tsys->macrdpVideoToolboxEncoder);\n\t\t\tWLog_Print(h264->log, WLOG_ERROR, \"Direct VideoToolbox H264 encode failed: %s\",\n\t\t\t           error ? error : \"unknown error\");\n\t\t}\n\t\treturn directStatus;\n\t}\n#endif\n"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS"
                MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_BRIDGE_COMPRESS_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add the macOS VideoToolbox bridge compression path")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_ENCODER"
            MACRDP_VIDEOTOOLBOX_ENCODER_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_ENCODER_OFFSET EQUAL -1)
            string(REPLACE
                "\t{\n#ifdef WITH_VAAPI_H264_ENCODING"
                "\t{\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\t\t/* MACRDP_VIDEOTOOLBOX_ENCODER */\n\t\tsys->codecEncoder = avcodec_find_encoder_by_name(\"h264_videotoolbox\");\n\t\tif (sys->codecEncoder)\n\t\t\tWLog_Print(h264->log, WLOG_INFO, \"Using VideoToolbox H264 encoder\");\n\t\telse\n\t\t\tWLog_Print(h264->log, WLOG_WARN, \"VideoToolbox H264 encoder not found, falling back to software\");\n#endif\n#ifdef WITH_VAAPI_H264_ENCODING"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_ENCODER"
                MACRDP_VIDEOTOOLBOX_ENCODER_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_ENCODER_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to patch FreeRDP's pinned H.264 encoder selection")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_OPTIONS"
            MACRDP_VIDEOTOOLBOX_OPTIONS_OFFSET)
        if(MACRDP_VIDEOTOOLBOX_OPTIONS_OFFSET EQUAL -1)
            string(REPLACE
                "\tav_opt_set(sys->codecEncoderContext, \"tune\", \"zerolatency\", AV_OPT_SEARCH_CHILDREN);"
                "\tav_opt_set(sys->codecEncoderContext, \"tune\", \"zerolatency\", AV_OPT_SEARCH_CHILDREN);\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\t\tif (sys->codecEncoder == avcodec_find_encoder_by_name(\"h264_videotoolbox\"))\n\t\t{\n\t\t\t/* MACRDP_VIDEOTOOLBOX_OPTIONS */\n\t\t\t(void)av_opt_set(sys->codecEncoderContext, \"realtime\", \"1\", AV_OPT_SEARCH_CHILDREN);\n\t\t\t(void)av_opt_set(sys->codecEncoderContext, \"prio_speed\", \"1\", AV_OPT_SEARCH_CHILDREN);\n\t\t\t(void)av_opt_set_int(sys->codecEncoderContext, \"max_ref_frames\", 1, AV_OPT_SEARCH_CHILDREN);\n\t\t}\n#endif"
                "\tav_opt_set(sys->codecEncoderContext, \"tune\", \"zerolatency\", AV_OPT_SEARCH_CHILDREN);\n#ifdef MACRDP_USE_VIDEOTOOLBOX_H264_ENCODING\n\t\tif (sys->codecEncoder == avcodec_find_encoder_by_name(\"h264_videotoolbox\"))\n\t\t{\n\t\t\t/* MACRDP_VIDEOTOOLBOX_OPTIONS */\n\t\t\t(void)av_opt_set(sys->codecEncoderContext, \"realtime\", \"1\", AV_OPT_SEARCH_CHILDREN);\n\t\t\t(void)av_opt_set(sys->codecEncoderContext, \"prio_speed\", \"1\", AV_OPT_SEARCH_CHILDREN);\n\t\t}\n#endif"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_VIDEOTOOLBOX_OPTIONS"
                MACRDP_VIDEOTOOLBOX_OPTIONS_OFFSET)
            if(MACRDP_VIDEOTOOLBOX_OPTIONS_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to patch FreeRDP's pinned VideoToolbox encoder options")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        # Migrate an older configured build that briefly used the unsupported
        # max_ref_frames option. Keep reconfiguration idempotent.
        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "max_ref_frames"
            MACRDP_VIDEOTOOLBOX_MAX_REF_OFFSET)
        if(NOT MACRDP_VIDEOTOOLBOX_MAX_REF_OFFSET EQUAL -1)
            string(REPLACE
                "\n\t\t\t(void)av_opt_set_int(sys->codecEncoderContext, \"max_ref_frames\", 1, AV_OPT_SEARCH_CHILDREN);"
                ""
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_EAGAIN_FIX"
            MACRDP_EAGAIN_FIX_OFFSET)
        if(MACRDP_EAGAIN_FIX_OFFSET EQUAL -1)
            string(REPLACE
                "\tstatus = avcodec_receive_packet(sys->codecEncoderContext, sys->packet);\n\n\tif (status < 0)"
                "\tstatus = avcodec_receive_packet(sys->codecEncoderContext, sys->packet);\n\n\tif (status == AVERROR(EAGAIN))\n\t{\n\t\t/* MACRDP_EAGAIN_FIX: VideoToolbox can emit a packet one input later. */\n\t\t*ppDstData = nullptr;\n\t\t*pDstSize = 0;\n\t\trc = 0;\n\t\tgoto fail;\n\t}\n\n\tif (status < 0)"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_EAGAIN_FIX"
                MACRDP_EAGAIN_FIX_OFFSET)
            if(MACRDP_EAGAIN_FIX_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to patch FreeRDP's asynchronous H.264 output handling")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_EAGAIN_POLL"
            MACRDP_EAGAIN_POLL_OFFSET)
        if(MACRDP_EAGAIN_POLL_OFFSET EQUAL -1)
            string(REPLACE
                "\tif (status == AVERROR(EAGAIN))\n\t{\n\t\t/* MACRDP_EAGAIN_FIX: VideoToolbox can emit a packet one input later. */\n\t\t*ppDstData = nullptr;\n\t\t*pDstSize = 0;\n\t\trc = 0;\n\t\tgoto fail;\n\t}"
                "\tif (status == AVERROR(EAGAIN))\n\t{\n\t\t/* MACRDP_EAGAIN_POLL: let asynchronous VideoToolbox output settle. */\n\t\tfor (int attempt = 0; attempt < 8 && status == AVERROR(EAGAIN); ++attempt)\n\t\t{\n\t\t\tUSleep(1000);\n\t\t\tstatus = avcodec_receive_packet(sys->codecEncoderContext, sys->packet);\n\t\t}\n\t}\n\n\tif (status == AVERROR(EAGAIN))\n\t{\n\t\t/* MACRDP_EAGAIN_FIX: no packet is ready for this input yet. */\n\t\t*ppDstData = nullptr;\n\t\t*pDstSize = 0;\n\t\trc = 0;\n\t\tgoto fail;\n\t}"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_EAGAIN_POLL"
                MACRDP_EAGAIN_POLL_OFFSET)
            if(MACRDP_EAGAIN_POLL_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to add asynchronous FreeRDP H.264 output polling")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()

        string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_INITIAL_FRAME_POLL"
            MACRDP_INITIAL_FRAME_POLL_OFFSET)
        if(MACRDP_INITIAL_FRAME_POLL_OFFSET EQUAL -1)
            string(REPLACE
                "\t\tfor (int attempt = 0; attempt < 8 && status == AVERROR(EAGAIN); ++attempt)"
                "\t\t/* MACRDP_INITIAL_FRAME_POLL: guarantee a visible first frame. */\n\t\tconst int max_attempts = sys->videoFrame->pts <= 1 ? 50 : 8;\n\t\tfor (int attempt = 0; attempt < max_attempts && status == AVERROR(EAGAIN); ++attempt)"
                MACRDP_FREERDP_H264_CONTENT
                "${MACRDP_FREERDP_H264_CONTENT}")

            string(FIND "${MACRDP_FREERDP_H264_CONTENT}" "MACRDP_INITIAL_FRAME_POLL"
                MACRDP_INITIAL_FRAME_POLL_OFFSET)
            if(MACRDP_INITIAL_FRAME_POLL_OFFSET EQUAL -1)
                message(FATAL_ERROR
                    "Unable to configure the FreeRDP first-frame H.264 wait")
            endif()
            file(WRITE "${MACRDP_FREERDP_H264_SOURCE}" "${MACRDP_FREERDP_H264_CONTENT}")
        endif()
    endif()
endif()

# The shadow client can resize the primary surface while the macOS capture
# thread is copying a frame. Upstream's resize helper does not take the
# surface lock, so patch the pinned source to share the same synchronization.
set(MACRDP_FREERDP_SHADOW_SURFACE_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_surface.c")
if(EXISTS "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}")
    file(READ "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}" MACRDP_SHADOW_SURFACE_CONTENT)
    string(FIND "${MACRDP_SHADOW_SURFACE_CONTENT}" "MACRDP_SURFACE_RESIZE_LOCK"
        MACRDP_SURFACE_RESIZE_LOCK_OFFSET)
    if(MACRDP_SURFACE_RESIZE_LOCK_OFFSET EQUAL -1)
        string(REPLACE
            "\tif (!surface)\n\t\treturn FALSE;\n\n\tif ((width == surface->width) && (height == surface->height))"
            "\tif (!surface)\n\t\treturn FALSE;\n\n\tEnterCriticalSection(&(surface->lock));\n\n\tif ((width == surface->width) && (height == surface->height))"
            MACRDP_SHADOW_SURFACE_CONTENT
            "${MACRDP_SHADOW_SURFACE_CONTENT}")
        string(REPLACE
            "\t\tsurface->y = y;\n\t\treturn TRUE;"
            "\t\tsurface->y = y;\n\t\tLeaveCriticalSection(&(surface->lock));\n\t\treturn TRUE;"
            MACRDP_SHADOW_SURFACE_CONTENT
            "${MACRDP_SHADOW_SURFACE_CONTENT}")
        string(REPLACE
            "\t\tsurface->data = buffer;\n\t\treturn TRUE;"
            "\t\tsurface->data = buffer;\n\t\tLeaveCriticalSection(&(surface->lock));\n\t\treturn TRUE;"
            MACRDP_SHADOW_SURFACE_CONTENT
            "${MACRDP_SHADOW_SURFACE_CONTENT}")
        string(REPLACE
            "\t}\n\n\treturn FALSE;\n}"
            "\t}\n\n\tLeaveCriticalSection(&(surface->lock));\n\treturn FALSE;\n}\n\n/* MACRDP_SURFACE_RESIZE_LOCK */"
            MACRDP_SHADOW_SURFACE_CONTENT
            "${MACRDP_SHADOW_SURFACE_CONTENT}")

        string(FIND "${MACRDP_SHADOW_SURFACE_CONTENT}" "MACRDP_SURFACE_RESIZE_LOCK"
            MACRDP_SURFACE_RESIZE_LOCK_OFFSET)
        if(MACRDP_SURFACE_RESIZE_LOCK_OFFSET EQUAL -1)
            message(FATAL_ERROR
                "Unable to add the shadow surface resize lock")
        endif()
        file(WRITE "${MACRDP_FREERDP_SHADOW_SURFACE_SOURCE}"
            "${MACRDP_SHADOW_SURFACE_CONTENT}")
    endif()
endif()

# FreeRDP stops the shadow subsystem before notifying clients to quit. A
# publishing capture thread can be waiting for those clients at the frame
# barrier, so the server cannot reach the quit broadcast. Notify clients first
# and only then join the subsystem threads.
set(MACRDP_FREERDP_SHADOW_SERVER_SOURCE
    "${freerdp_SOURCE_DIR}/server/shadow/shadow_server.c")
if(EXISTS "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}")
    file(READ "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}" MACRDP_SHADOW_SERVER_CONTENT)
    string(FIND "${MACRDP_SHADOW_SERVER_CONTENT}" "MACRDP_SHADOW_STOP_ORDER"
        MACRDP_SHADOW_STOP_ORDER_OFFSET)
    if(MACRDP_SHADOW_STOP_ORDER_OFFSET EQUAL -1)
        string(REPLACE
            "\tlistener->Close(listener);\n\tshadow_subsystem_stop(server->subsystem);\n\n\t/* Signal to the clients that server is being stopped and wait for them\n\t * to disconnect. */\n\tif (shadow_client_boardcast_quit(server, 0))"
            "\tlistener->Close(listener);\n\n\t/* Signal to the clients before stopping the subsystem. The publisher may\n\t * be waiting for this client's frame barrier. */\n\tif (shadow_client_boardcast_quit(server, 0))"
            MACRDP_SHADOW_SERVER_CONTENT
            "${MACRDP_SHADOW_SERVER_CONTENT}")
        string(REPLACE
            "\t\t}\n\t}\n\n\tExitThread(0);"
            "\t\t}\n\t}\n\n\tshadow_subsystem_stop(server->subsystem);\n\n\t/* MACRDP_SHADOW_STOP_ORDER */\n\tExitThread(0);"
            MACRDP_SHADOW_SERVER_CONTENT
            "${MACRDP_SHADOW_SERVER_CONTENT}")

        string(FIND "${MACRDP_SHADOW_SERVER_CONTENT}" "MACRDP_SHADOW_STOP_ORDER"
            MACRDP_SHADOW_STOP_ORDER_OFFSET)
        if(MACRDP_SHADOW_STOP_ORDER_OFFSET EQUAL -1)
            message(FATAL_ERROR
                "Unable to reorder FreeRDP shadow server shutdown")
        endif()
        file(WRITE "${MACRDP_FREERDP_SHADOW_SERVER_SOURCE}"
            "${MACRDP_SHADOW_SERVER_CONTENT}")
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

if(MACRDP_FREERDP_WITH_FFMPEG)
    add_test(
        NAME freerdp_h264_encoder
        COMMAND macrdp-freerdp-h264-test
    )
endif()
