cmake_minimum_required(VERSION 3.25)

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")

project(macrdp_cpp
    VERSION 0.1.0
    LANGUAGES CXX OBJCXX
)

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

add_test(
    NAME h264_encoder
    COMMAND macrdp-cpp-encoder-test
        ${CMAKE_CURRENT_BINARY_DIR}/encoder-test.h264
)
