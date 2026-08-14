cmake_minimum_required(VERSION 3.25)

# The release dependency set and current Homebrew development dependencies are
# built for macOS 15. Keep the default honest; a separately built compatible
# dependency set can still override this cache value for older targets.
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

option(MACRDP_ENABLE_SANITIZERS
    "Build with AddressSanitizer and UndefinedBehaviorSanitizer"
    OFF
)

if(MACRDP_ENABLE_SANITIZERS)
    if(NOT CMAKE_C_COMPILER_ID MATCHES "Clang"
       OR NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR
            "MACRDP_ENABLE_SANITIZERS requires Clang-compatible C and C++ compilers"
        )
    endif()

    add_compile_options(
        "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fsanitize=address,undefined>"
        "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fno-omit-frame-pointer>"
        "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fno-sanitize-recover=all>"
    )
    add_link_options(-fsanitize=address,undefined)
endif()

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
    src/macos/display_topology.mm
    src/macos/h264_encoder.mm
    src/macos/videotoolbox_h264.mm
)

add_library(macrdp_config STATIC
    src/config_permissions.cpp
    src/preset_config.cpp
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

add_executable(macrdp-display-topology-test
    src/display_topology_test.cpp
)

target_compile_options(macrdp-display-dimensions-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-display-dimensions-test PRIVATE macrdp_macos)

target_compile_options(macrdp-display-topology-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-display-topology-test PRIVATE macrdp_macos)

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

set(MACRDP_FFMPEG_ROOT "" CACHE PATH
    "Prefix of the purpose-built FFmpeg release dependency"
)
set(MACRDP_FFMPEG_PROVENANCE "" CACHE FILEPATH
    "Generated provenance.json for MACRDP_FFMPEG_ROOT"
)

set(MACRDP_MANAGED_FFMPEG OFF)
if(MACRDP_FREERDP_WITH_FFMPEG AND NOT MACRDP_FFMPEG_ROOT STREQUAL "")
    file(REAL_PATH "${MACRDP_FFMPEG_ROOT}" MACRDP_FFMPEG_ROOT_REAL)
    if(MACRDP_FFMPEG_PROVENANCE STREQUAL "")
        get_filename_component(MACRDP_FFMPEG_BUILD_ROOT
            "${MACRDP_FFMPEG_ROOT_REAL}" DIRECTORY)
        set(MACRDP_FFMPEG_PROVENANCE
            "${MACRDP_FFMPEG_BUILD_ROOT}/provenance.json" CACHE FILEPATH
            "Generated provenance.json for MACRDP_FFMPEG_ROOT" FORCE)
    endif()
    if(NOT EXISTS "${MACRDP_FFMPEG_PROVENANCE}")
        message(FATAL_ERROR
            "MACRDP_FFMPEG_PROVENANCE is missing: ${MACRDP_FFMPEG_PROVENANCE}"
        )
    endif()

    file(READ "${MACRDP_FFMPEG_PROVENANCE}" MACRDP_FFMPEG_PROVENANCE_JSON)
    string(JSON MACRDP_FFMPEG_VERSION GET
        "${MACRDP_FFMPEG_PROVENANCE_JSON}" version)
    string(JSON MACRDP_FFMPEG_LICENSE GET
        "${MACRDP_FFMPEG_PROVENANCE_JSON}" licenseExpression)
    string(JSON MACRDP_FFMPEG_PROVENANCE_PREFIX GET
        "${MACRDP_FFMPEG_PROVENANCE_JSON}" build installPrefix)
    string(JSON MACRDP_FFMPEG_MINIMUM_MACOS GET
        "${MACRDP_FFMPEG_PROVENANCE_JSON}" build minimumMacOS)
    file(REAL_PATH "${MACRDP_FFMPEG_PROVENANCE_PREFIX}"
        MACRDP_FFMPEG_PROVENANCE_PREFIX_REAL)
    if(NOT MACRDP_FFMPEG_PROVENANCE_PREFIX_REAL STREQUAL MACRDP_FFMPEG_ROOT_REAL)
        message(FATAL_ERROR
            "FFmpeg provenance prefix does not match MACRDP_FFMPEG_ROOT"
        )
    endif()
    if(NOT MACRDP_FFMPEG_LICENSE STREQUAL "LGPL-2.1-or-later")
        message(FATAL_ERROR
            "Release FFmpeg must be LGPL-2.1-or-later, got ${MACRDP_FFMPEG_LICENSE}"
        )
    endif()
    if(NOT MACRDP_FFMPEG_MINIMUM_MACOS VERSION_EQUAL CMAKE_OSX_DEPLOYMENT_TARGET)
        message(FATAL_ERROR
            "FFmpeg targets macOS ${MACRDP_FFMPEG_MINIMUM_MACOS}, but macrdp targets ${CMAKE_OSX_DEPLOYMENT_TARGET}"
        )
    endif()

    set(MACRDP_FFMPEG_INCLUDE_DIR "${MACRDP_FFMPEG_ROOT_REAL}/include")
    set(MACRDP_FFMPEG_LIBRARIES "")
    foreach(MACRDP_FFMPEG_COMPONENT IN ITEMS AVCODEC AVUTIL SWSCALE SWRESAMPLE)
        string(TOLOWER "${MACRDP_FFMPEG_COMPONENT}" MACRDP_FFMPEG_COMPONENT_LOWER)
        set(MACRDP_FFMPEG_LIBRARY
            "${MACRDP_FFMPEG_ROOT_REAL}/lib/lib${MACRDP_FFMPEG_COMPONENT_LOWER}.dylib")
        set(MACRDP_FFMPEG_PC_FILE
            "${MACRDP_FFMPEG_ROOT_REAL}/lib/pkgconfig/lib${MACRDP_FFMPEG_COMPONENT_LOWER}.pc")
        if(NOT EXISTS "${MACRDP_FFMPEG_LIBRARY}"
           OR NOT EXISTS "${MACRDP_FFMPEG_PC_FILE}")
            message(FATAL_ERROR
                "Purpose-built FFmpeg component is missing: ${MACRDP_FFMPEG_COMPONENT_LOWER}"
            )
        endif()
        file(STRINGS "${MACRDP_FFMPEG_PC_FILE}" MACRDP_FFMPEG_PC_VERSION_LINE
            REGEX "^Version: *")
        string(REGEX REPLACE "^Version: *" "" MACRDP_FFMPEG_COMPONENT_VERSION
            "${MACRDP_FFMPEG_PC_VERSION_LINE}")
        set(${MACRDP_FFMPEG_COMPONENT}_LIBRARIES
            "${MACRDP_FFMPEG_LIBRARY}" CACHE FILEPATH
            "The ${MACRDP_FFMPEG_COMPONENT} library" FORCE)
        set(${MACRDP_FFMPEG_COMPONENT}_INCLUDE_DIRS
            "${MACRDP_FFMPEG_INCLUDE_DIR}" CACHE PATH
            "The ${MACRDP_FFMPEG_COMPONENT} include directory" FORCE)
        set(${MACRDP_FFMPEG_COMPONENT}_VERSION
            "${MACRDP_FFMPEG_COMPONENT_VERSION}" CACHE STRING
            "The ${MACRDP_FFMPEG_COMPONENT} version number" FORCE)
        list(APPEND MACRDP_FFMPEG_LIBRARIES "${MACRDP_FFMPEG_LIBRARY}")
    endforeach()
    foreach(MACRDP_UNUSED_FFMPEG_COMPONENT IN ITEMS
        AVDEVICE AVFILTER AVFORMAT POSTPROCESS)
        foreach(MACRDP_UNUSED_FFMPEG_SUFFIX IN ITEMS
            LIBRARIES INCLUDE_DIRS DEFINITIONS VERSION)
            unset(${MACRDP_UNUSED_FFMPEG_COMPONENT}_${MACRDP_UNUSED_FFMPEG_SUFFIX})
            unset(${MACRDP_UNUSED_FFMPEG_COMPONENT}_${MACRDP_UNUSED_FFMPEG_SUFFIX} CACHE)
        endforeach()
    endforeach()
    set(FFMPEG_LIBRARIES "${MACRDP_FFMPEG_LIBRARIES}" CACHE STRING
        "The FFmpeg release libraries" FORCE)
    set(FFMPEG_INCLUDE_DIRS "${MACRDP_FFMPEG_INCLUDE_DIR}" CACHE STRING
        "The FFmpeg release include directory" FORCE)
    set(FFMPEG_DEFINITIONS "" CACHE STRING "The FFmpeg release cflags" FORCE)
    set(MACRDP_MANAGED_FFMPEG_CACHE ON CACHE INTERNAL
        "Purpose-built FFmpeg populated the discovery cache" FORCE)
    set(MACRDP_MANAGED_FFMPEG ON)
elseif(MACRDP_MANAGED_FFMPEG_CACHE)
    foreach(MACRDP_FFMPEG_CACHE_PREFIX IN ITEMS
        FFMPEG AVCODEC AVDEVICE AVFILTER AVFORMAT AVUTIL POSTPROCESS SWSCALE SWRESAMPLE)
        foreach(MACRDP_FFMPEG_CACHE_SUFFIX IN ITEMS
            LIBRARIES INCLUDE_DIRS DEFINITIONS VERSION)
            unset(${MACRDP_FFMPEG_CACHE_PREFIX}_${MACRDP_FFMPEG_CACHE_SUFFIX} CACHE)
        endforeach()
    endforeach()
    set(MACRDP_MANAGED_FFMPEG_CACHE OFF CACHE INTERNAL
        "Purpose-built FFmpeg populated the discovery cache" FORCE)
endif()

set(MACRDP_CODESIGN_IDENTITY "" CACHE STRING
    "macOS code-signing identity for macrdp-server (empty disables signing)"
)
set(MACRDP_CODESIGN_IDENTIFIER "io.github.zx1991.macrdp.server" CACHE STRING
    "Stable code-signing identifier for macrdp-server"
)
set(MACRDP_PACKAGE_SIGN_IDENTITY "-" CACHE STRING
    "Code-signing identity for packaged Mach-O files (- uses ad-hoc signing)"
)
set(MACRDP_RELEASE_CODESIGN_EXECUTABLE "codesign" CACHE STRING
    "codesign command or local unlocking wrapper used for release artifacts"
)
set(MACRDP_PACKAGE_SIGN_IDENTIFIER "io.github.zx1991.macrdp.server" CACHE STRING
    "Code-signing identifier for the packaged macrdp-server"
)
option(MACRDP_PACKAGE_HARDENED_RUNTIME
    "Enable hardened runtime on packaged Mach-O files"
    OFF
)
option(MACRDP_PACKAGE_TIMESTAMP
    "Request a trusted timestamp for packaged Mach-O signatures"
    OFF
)
set(MACRDP_DISTRIBUTION_SIGN_IDENTITY "-" CACHE STRING
    "Code-signing identity for the macOS DMG (- uses ad-hoc signing)"
)
set(MACRDP_DISTRIBUTION_SIGN_IDENTIFIER
    "io.github.zx1991.macrdp.distribution" CACHE STRING
    "Code-signing identifier for the macOS DMG"
)
option(MACRDP_DISTRIBUTION_TIMESTAMP
    "Request a trusted timestamp for the macOS DMG signature"
    OFF
)
option(MACRDP_REQUIRE_DEVELOPER_ID
    "Require Developer ID-compatible signing settings for release artifacts"
    OFF
)
set(MACRDP_NOTARY_KEYCHAIN_PROFILE "" CACHE STRING
    "notarytool Keychain profile name (empty disables the notarization target)"
)

if(MACRDP_REQUIRE_DEVELOPER_ID)
    if(MACRDP_PACKAGE_SIGN_IDENTITY STREQUAL "-"
       OR MACRDP_DISTRIBUTION_SIGN_IDENTITY STREQUAL "-")
        message(FATAL_ERROR
            "Developer ID release mode requires package and DMG signing identities"
        )
    endif()
    if(NOT MACRDP_PACKAGE_HARDENED_RUNTIME
       OR NOT MACRDP_PACKAGE_TIMESTAMP
       OR NOT MACRDP_DISTRIBUTION_TIMESTAMP)
        message(FATAL_ERROR
            "Developer ID release mode requires hardened runtime and trusted timestamps"
        )
    endif()
endif()

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
set(WITH_OPENH264 ON CACHE BOOL "Build the independent OpenH264 AVC420 backend" FORCE)
set(WITH_OPENH264_LOADING OFF CACHE BOOL "Link the detected OpenH264 library" FORCE)
set(WITH_OPUS OFF CACHE BOOL "Do not build Opus audio support" FORCE)
set(WITH_DSP_FFMPEG ON CACHE BOOL "Use FFmpeg audio DSP for RDPSND resampling" FORCE)
set(WITH_MANPAGES OFF CACHE BOOL "Do not build FreeRDP manpages" FORCE)
set(WITH_CLANG_FORMAT OFF CACHE BOOL "Do not configure clang-format" FORCE)
set(WITH_SERVER_INTERFACE ON CACHE BOOL "Build FreeRDP server interface" FORCE)
set(WITH_AAD OFF CACHE BOOL "Do not build unused Azure AD client support" FORCE)
set(WITH_JSON_DISABLED ON CACHE BOOL "Build FreeRDP without optional JSON backends" FORCE)
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

set(MACRDP_FREERDP_MANIFEST
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/freerdp/manifest.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${MACRDP_FREERDP_MANIFEST}")
file(READ "${MACRDP_FREERDP_MANIFEST}" MACRDP_FREERDP_MANIFEST_JSON)
string(JSON MACRDP_FREERDP_MANIFEST_SCHEMA
    GET "${MACRDP_FREERDP_MANIFEST_JSON}" schemaVersion)
if(NOT MACRDP_FREERDP_MANIFEST_SCHEMA EQUAL 1)
    message(FATAL_ERROR "Unsupported FreeRDP source manifest schema")
endif()
string(JSON MACRDP_FREERDP_SOURCE_URL
    GET "${MACRDP_FREERDP_MANIFEST_JSON}" source url)
string(JSON MACRDP_FREERDP_SOURCE_SHA256
    GET "${MACRDP_FREERDP_MANIFEST_JSON}" source sha256)

FetchContent_Declare(
    freerdp
    URL "${MACRDP_FREERDP_SOURCE_URL}"
    URL_HASH "SHA256=${MACRDP_FREERDP_SOURCE_SHA256}"
)
FetchContent_MakeAvailable(freerdp)

# FreeRDP 3.30.0's FindFFmpeg module collects every FFmpeg component installed
# on the host, even though this build only uses codec, utility, scaling, and
# resampling APIs. Remove the unused components from the static target's link
# interface so a full Homebrew FFmpeg installation does not pull its device,
# filter, format, and post-processing dependency trees into the package.
if(MACRDP_FREERDP_WITH_FFMPEG AND TARGET freerdp)
    foreach(MACRDP_FREERDP_LINK_PROPERTY IN ITEMS
        LINK_LIBRARIES
        INTERFACE_LINK_LIBRARIES)
        get_target_property(MACRDP_FREERDP_LINK_ITEMS
            freerdp ${MACRDP_FREERDP_LINK_PROPERTY})
        if(MACRDP_FREERDP_LINK_ITEMS)
            list(FILTER MACRDP_FREERDP_LINK_ITEMS EXCLUDE REGEX
                "lib(avdevice|avfilter|avformat|postproc)(\\.[0-9]+)*\\.dylib")
            set_property(TARGET freerdp PROPERTY
                ${MACRDP_FREERDP_LINK_PROPERTY} "${MACRDP_FREERDP_LINK_ITEMS}")
        endif()
    endforeach()
endif()

foreach(MACRDP_FREERDP_CODEC_TARGET IN ITEMS freerdp-codecs freerdp)
    if(TARGET ${MACRDP_FREERDP_CODEC_TARGET})
        target_include_directories(${MACRDP_FREERDP_CODEC_TARGET} PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
        )
    endif()
endforeach()

add_library(macrdp_rdpgfx_capabilities STATIC
    src/rdpgfx_capabilities.c
)

add_library(macrdp_rdpgfx_frame_flow STATIC
    src/rdpgfx_frame_flow.c
)

add_library(macrdp_video_adaptation STATIC
    src/video_adaptation.c
)

target_include_directories(macrdp_rdpgfx_capabilities
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
)

target_compile_options(macrdp_rdpgfx_capabilities PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp_rdpgfx_frame_flow
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
)

target_compile_options(macrdp_rdpgfx_frame_flow PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp_video_adaptation PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp_video_adaptation PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp_rdpgfx_frame_flow PUBLIC
    macrdp_video_adaptation
)

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

target_link_libraries(macrdp_freerdp_shadow PRIVATE
    macrdp_rdpgfx_frame_flow
    macrdp_video_adaptation
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
        macrdp_rdpgfx_capabilities
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
        COMMAND ${CMAKE_COMMAND} -E env
            "MACRDP_PACKAGE_CODESIGN_COMMAND=${MACRDP_RELEASE_CODESIGN_EXECUTABLE}"
            "MACRDP_PACKAGE_SIGN_IDENTITY=${MACRDP_PACKAGE_SIGN_IDENTITY}"
            "MACRDP_PACKAGE_SIGN_IDENTIFIER=${MACRDP_PACKAGE_SIGN_IDENTIFIER}"
            "MACRDP_PACKAGE_HARDENED_RUNTIME=${MACRDP_PACKAGE_HARDENED_RUNTIME}"
            "MACRDP_PACKAGE_TIMESTAMP=${MACRDP_PACKAGE_TIMESTAMP}"
            bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/package_macos.sh"
            "$<TARGET_FILE:macrdp-server>"
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-dist"
            "${CMAKE_CURRENT_SOURCE_DIR}"
            "${freerdp_SOURCE_DIR}"
            "${PROJECT_VERSION}"
            "${MACRDP_FFMPEG_PROVENANCE}"
        DEPENDS macrdp-server
        USES_TERMINAL
    )

    if(MACRDP_MANAGED_FFMPEG)
        set(MACRDP_FFMPEG_SOURCE_ARCHIVE
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-ffmpeg-sources-${MACRDP_FFMPEG_VERSION}.tar.gz")
        add_custom_target(macrdp-ffmpeg-source-package
            COMMAND ${CMAKE_COMMAND} -E env bash
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/package_ffmpeg_source.sh"
                "${MACRDP_FFMPEG_PROVENANCE}"
                "${CMAKE_CURRENT_SOURCE_DIR}"
                "${MACRDP_FFMPEG_SOURCE_ARCHIVE}"
            BYPRODUCTS "${MACRDP_FFMPEG_SOURCE_ARCHIVE}"
            USES_TERMINAL
        )
    endif()

    add_custom_target(macrdp-package-validate
        COMMAND ${CMAKE_COMMAND} -E env bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/validate_macos_package.sh"
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-dist"
            "${CMAKE_OSX_ARCHITECTURES}"
            "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        DEPENDS macrdp-package
        USES_TERMINAL
    )
    if(MACRDP_MANAGED_FFMPEG)
        add_dependencies(macrdp-package-validate macrdp-ffmpeg-source-package)
    endif()

    if(CMAKE_OSX_ARCHITECTURES STREQUAL "")
        set(MACRDP_DISTRIBUTION_ARCHITECTURE "${CMAKE_SYSTEM_PROCESSOR}")
    else()
        set(MACRDP_DISTRIBUTION_ARCHITECTURE "${CMAKE_OSX_ARCHITECTURES}")
    endif()
    if(MACRDP_DISTRIBUTION_ARCHITECTURE STREQUAL "arm64;x86_64"
       OR MACRDP_DISTRIBUTION_ARCHITECTURE STREQUAL "x86_64;arm64")
        set(MACRDP_DISTRIBUTION_ARCHITECTURE "universal2")
    elseif(MACRDP_DISTRIBUTION_ARCHITECTURE MATCHES ";")
        message(FATAL_ERROR
            "Unsupported distribution architecture set: ${CMAKE_OSX_ARCHITECTURES}"
        )
    endif()
    if(MACRDP_REQUIRE_DEVELOPER_ID)
        set(MACRDP_DISTRIBUTION_SIGN_MODE developer-id)
    else()
        set(MACRDP_DISTRIBUTION_SIGN_MODE development)
    endif()
    set(MACRDP_DISTRIBUTION_DMG
        "${CMAKE_CURRENT_BINARY_DIR}/macrdp-cpp-${PROJECT_VERSION}-macos-${MACRDP_DISTRIBUTION_ARCHITECTURE}.dmg"
    )

    add_custom_target(macrdp-distribution
        COMMAND ${CMAKE_COMMAND} -E env
            "MACRDP_DISTRIBUTION_CODESIGN_COMMAND=${MACRDP_RELEASE_CODESIGN_EXECUTABLE}"
            "MACRDP_DISTRIBUTION_SIGN_IDENTITY=${MACRDP_DISTRIBUTION_SIGN_IDENTITY}"
            "MACRDP_DISTRIBUTION_SIGN_IDENTIFIER=${MACRDP_DISTRIBUTION_SIGN_IDENTIFIER}"
            "MACRDP_DISTRIBUTION_TIMESTAMP=${MACRDP_DISTRIBUTION_TIMESTAMP}"
            bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/create_macos_distribution.sh"
            "${CMAKE_CURRENT_BINARY_DIR}/macrdp-dist"
            "${MACRDP_DISTRIBUTION_DMG}"
            "${PROJECT_VERSION}"
            "${MACRDP_DISTRIBUTION_ARCHITECTURE}"
            "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        DEPENDS macrdp-package-validate
        BYPRODUCTS "${MACRDP_DISTRIBUTION_DMG}"
        USES_TERMINAL
    )

    add_custom_target(macrdp-distribution-validate
        COMMAND bash
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/validate_macos_distribution.sh"
            "${MACRDP_DISTRIBUTION_DMG}"
            "${PROJECT_VERSION}"
            "${MACRDP_DISTRIBUTION_ARCHITECTURE}"
            "${CMAKE_OSX_DEPLOYMENT_TARGET}"
            "${MACRDP_DISTRIBUTION_SIGN_MODE}"
        DEPENDS macrdp-distribution
        USES_TERMINAL
    )

    if(NOT MACRDP_NOTARY_KEYCHAIN_PROFILE STREQUAL "")
        if(NOT MACRDP_REQUIRE_DEVELOPER_ID)
            message(FATAL_ERROR
                "The notarization target requires MACRDP_REQUIRE_DEVELOPER_ID=ON"
            )
        endif()
        add_custom_target(macrdp-notarize
            COMMAND bash
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/notarize_macos_distribution.sh"
                "${MACRDP_DISTRIBUTION_DMG}"
                "${MACRDP_NOTARY_KEYCHAIN_PROFILE}"
            COMMAND bash
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/validate_macos_distribution.sh"
                "${MACRDP_DISTRIBUTION_DMG}"
                "${PROJECT_VERSION}"
                "${MACRDP_DISTRIBUTION_ARCHITECTURE}"
                "${CMAKE_OSX_DEPLOYMENT_TARGET}"
                developer-id
                --require-notarized
            DEPENDS macrdp-distribution-validate
            USES_TERMINAL
        )
    endif()
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
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/include
        ${freerdp_SOURCE_DIR}/winpr/include
        ${freerdp_BINARY_DIR}/include
        ${freerdp_BINARY_DIR}/winpr/include
    )

    target_link_libraries(macrdp-freerdp-h264-test PRIVATE
        macrdp_freerdp_shadow
    )

    if(MACRDP_MANAGED_FFMPEG)
        add_executable(macrdp-ffmpeg-build-probe
            tools/ffmpeg_build_probe.c
        )
        target_compile_options(macrdp-ffmpeg-build-probe PRIVATE
            -Wall
            -Wextra
            -Wpedantic
        )
        target_include_directories(macrdp-ffmpeg-build-probe PRIVATE
            "${MACRDP_FFMPEG_INCLUDE_DIR}"
        )
        target_link_libraries(macrdp-ffmpeg-build-probe PRIVATE
            "${AVCODEC_LIBRARIES}"
            "${AVUTIL_LIBRARIES}"
            "${SWRESAMPLE_LIBRARIES}"
            "${SWSCALE_LIBRARIES}"
        )
    endif()
endif()

add_executable(macrdp-h264-worker-test
    src/rdp_h264_worker_test.cpp
)

add_executable(macrdp-input-ownership-test
    src/input_ownership_test.cpp
)

add_executable(macrdp-clipboard-transfer-test
    src/clipboard_transfer_test.cpp
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

add_executable(macrdp-preset-config-test
    src/preset_config_test.cpp
)

add_executable(macrdp-access-policy-test
    src/access_policy_test.cpp
)

add_executable(macrdp-client-session-lifecycle-test
    src/client_session_lifecycle_test.cpp
)

add_executable(macrdp-rdpgfx-capabilities-test
    src/rdpgfx_capabilities_test.cpp
)

add_executable(macrdp-rdpgfx-frame-flow-test
    src/rdpgfx_frame_flow_test.cpp
)

add_executable(macrdp-video-adaptation-test
    src/video_adaptation_test.cpp
)

target_compile_options(macrdp-access-policy-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_compile_options(macrdp-client-session-lifecycle-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_compile_options(macrdp-rdpgfx-capabilities-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_compile_options(macrdp-rdpgfx-frame-flow-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_compile_options(macrdp-video-adaptation-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-rdpgfx-capabilities-test PRIVATE
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_include_directories(macrdp-rdpgfx-frame-flow-test PRIVATE
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_link_libraries(macrdp-rdpgfx-capabilities-test PRIVATE
    macrdp_rdpgfx_capabilities
)

target_link_libraries(macrdp-rdpgfx-frame-flow-test PRIVATE
    macrdp_rdpgfx_frame_flow
)

target_link_libraries(macrdp-video-adaptation-test PRIVATE
    macrdp_video_adaptation
)

target_include_directories(macrdp-access-policy-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src/macos
    ${freerdp_SOURCE_DIR}/include
    ${freerdp_SOURCE_DIR}/winpr/include
    ${freerdp_BINARY_DIR}/include
    ${freerdp_BINARY_DIR}/winpr/include
)

target_include_directories(macrdp-client-session-lifecycle-test PRIVATE
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

target_link_libraries(macrdp-client-session-lifecycle-test PRIVATE
    macrdp_freerdp_shadow
)

target_compile_options(macrdp-config-permissions-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-config-permissions-test PRIVATE macrdp_config)

target_compile_options(macrdp-preset-config-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(macrdp-preset-config-test PRIVATE macrdp_config)

target_compile_options(macrdp-input-ownership-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-input-ownership-test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(macrdp-clipboard-transfer-test PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

target_include_directories(macrdp-clipboard-transfer-test PRIVATE
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
    NAME rdpgfx_frame_flow
    COMMAND macrdp-rdpgfx-frame-flow-test
)

add_test(
    NAME video_adaptation
    COMMAND macrdp-video-adaptation-test
)

add_test(
    NAME display_dimensions
    COMMAND macrdp-display-dimensions-test
)

add_test(
    NAME display_topology
    COMMAND macrdp-display-topology-test
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
    if(MACRDP_MANAGED_FFMPEG)
        add_test(
            NAME ffmpeg_release_configuration
            COMMAND macrdp-ffmpeg-build-probe
                "${MACRDP_FFMPEG_VERSION}"
                "LGPL version 2.1 or later"
        )
    endif()
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
    NAME clipboard_transfer
    COMMAND macrdp-clipboard-transfer-test
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
    NAME preset_config
    COMMAND macrdp-preset-config-test
)

add_test(
    NAME preset_cli
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/preset_cli_test.sh
        $<TARGET_FILE:macrdp-server>
)

add_test(
    NAME access_policy
    COMMAND macrdp-access-policy-test
)

add_test(
    NAME client_session_lifecycle
    COMMAND macrdp-client-session-lifecycle-test
)

add_test(
    NAME rdpgfx_capabilities
    COMMAND macrdp-rdpgfx-capabilities-test
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
    NAME server_invalid_h264_keyint
    COMMAND macrdp-server
        --h264-keyint 0
        --user macrdp-test-user
        --password test
)
set_tests_properties(server_invalid_h264_keyint PROPERTIES WILL_FAIL TRUE)

add_test(
    NAME server_invalid_display_id
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "--display-id must be between 1 and 4294967295"
        $<TARGET_FILE:macrdp-server>
        --display-id 0
        --preflight
)

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
    NAME server_invalid_preset
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "Invalid preset name"
        $<TARGET_FILE:macrdp-server>
        --preset ../invalid
)

add_test(
    NAME server_standard_preset_requires_password_without_tty
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/expect_command_failure.sh
        "NLA requires --sam-file or non-empty --user and --password"
        $<TARGET_FILE:macrdp-server>
        --preset standard
)

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

add_test(
    NAME manage_macos_install
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/manage_macos_install_test.sh
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/manage_macos_install.sh
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/install_launch_agent.sh
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify_macos_package.rb
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/rotate_launch_agent_password.sh
)

add_test(
    NAME notarize_macos_distribution
    COMMAND bash
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/notarize_macos_distribution_test.sh
        ${CMAKE_CURRENT_SOURCE_DIR}/scripts/notarize_macos_distribution.sh
)

set_tests_properties(
    access_policy
    async_completion
    client_session_lifecycle
    clipboard_transfer
    display_capture_lifecycle
    display_topology
    h264_worker
    input_ownership
    rdpgfx_capabilities
    PROPERTIES
        LABELS deterministic-stress
        TIMEOUT 30
)
