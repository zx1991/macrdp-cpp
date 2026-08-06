#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "macrdp/frame.hpp"

namespace macrdp {

struct DisplayCaptureOptions {
    // Zero means the native pixel dimensions of the selected display.
    std::uint32_t max_width = 0;
    std::uint32_t max_height = 0;
    std::uint32_t frame_rate = 30;
    bool show_cursor = false;
};

// Return the native display size reduced to fit both optional limits while
// preserving aspect ratio. A zero limit means that dimension is unbounded.
[[nodiscard]] std::pair<std::uint32_t, std::uint32_t> display_capture_output_size(
    std::uint32_t native_width,
    std::uint32_t native_height,
    std::uint32_t max_width,
    std::uint32_t max_height) noexcept;

// C++-only interface for the macOS capture implementation. The implementation
// uses ScreenCaptureKit, but no Apple framework types cross this boundary.
class DisplayCapture final {
public:
    explicit DisplayCapture(DisplayCaptureOptions options = {});
    ~DisplayCapture();

    DisplayCapture(const DisplayCapture&) = delete;
    DisplayCapture& operator=(const DisplayCapture&) = delete;
    DisplayCapture(DisplayCapture&&) noexcept;
    DisplayCapture& operator=(DisplayCapture&&) noexcept;

    // Starts an asynchronous stream for the main display. This method waits
    // until ScreenCaptureKit has either started the stream or reported an
    // error, so a true return means next_frame() can be used immediately.
    [[nodiscard]] bool start();

    // Returns the newest available frame. Older pending frames are discarded
    // deliberately to keep capture latency bounded.
    [[nodiscard]] std::optional<Frame> next_frame(
        std::chrono::milliseconds timeout = std::chrono::milliseconds{1000});

    // Rebuilds the ScreenCaptureKit stream with new output limits. This is
    // used when macOS changes the selected display's pixel dimensions.
    [[nodiscard]] bool reconfigure(DisplayCaptureOptions options);

    void stop() noexcept;

    [[nodiscard]] std::string last_error() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace macrdp
