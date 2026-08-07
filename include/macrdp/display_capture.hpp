#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "macrdp/frame.hpp"

namespace macrdp {

struct DisplayCaptureOptions {
    // Zero means the native pixel dimensions of the selected display.
    std::uint32_t max_width = 0;
    std::uint32_t max_height = 0;
    std::uint32_t frame_rate = 30;
    bool show_cursor = false;
    bool capture_audio = true;
};

// ScreenCaptureKit audio normalized to interleaved signed 16-bit PCM. The
// capture implementation requests 48 kHz stereo and resamples unexpected
// linear-PCM input before publishing it.
struct AudioFrame {
    std::uint32_t sample_rate = 0;
    std::uint16_t channels = 0;
    std::uint64_t timestamp_us = 0;
    std::vector<std::int16_t> pcm;

    [[nodiscard]] bool valid() const noexcept {
        return sample_rate > 0 && channels > 0 && !pcm.empty()
            && pcm.size() % channels == 0;
    }

    [[nodiscard]] std::size_t frames() const noexcept {
        return channels == 0 ? 0 : pcm.size() / channels;
    }
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

    // Returns the newest normalized audio block. Audio is intentionally kept
    // on a separate bounded path so a slow RDP client cannot stall capture.
    [[nodiscard]] std::optional<AudioFrame> next_audio(
        std::chrono::milliseconds timeout = std::chrono::milliseconds{1000});

    // Returns a consumed frame's allocated pixel storage to the capture
    // callback. The frame may be dropped when the stream is stopping.
    void recycle_frame(Frame frame) noexcept;

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
