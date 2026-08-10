#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "macrdp/display_topology.hpp"
#include "macrdp/frame.hpp"

namespace macrdp {

namespace detail {
class DisplayCaptureBackend;
}

struct DisplayCaptureOptions {
    // Zero selects the current main display. A non-zero value is an exact
    // CGDirectDisplayID and must not silently fall back to another display.
    std::uint32_t display_id = 0;
    // A topology snapshot supplies these dimensions and generation together.
    // Zero dimensions ask the platform backend to resolve a fresh snapshot.
    std::uint64_t display_generation = 0;
    std::uint32_t native_width = 0;
    std::uint32_t native_height = 0;
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
    // Identifies the display topology snapshot that produced this block.
    std::uint64_t display_generation = 0;
    std::vector<std::int16_t> pcm;

    [[nodiscard]] bool valid() const noexcept {
        return sample_rate > 0 && channels > 0 && !pcm.empty()
            && pcm.size() % channels == 0;
    }

    [[nodiscard]] std::size_t frames() const noexcept {
        return channels == 0 ? 0 : pcm.size() / channels;
    }
};

// Audio captured before a display transition must not be published against the
// replacement topology. A missing active generation also rejects the block.
[[nodiscard]] bool audio_frame_matches_display_generation(
    const AudioFrame& frame,
    std::optional<std::uint64_t> active_generation) noexcept;

// Return the native display size reduced to fit both optional limits while
// preserving aspect ratio. A zero limit means that dimension is unbounded.
[[nodiscard]] std::pair<std::uint32_t, std::uint32_t> display_capture_output_size(
    std::uint32_t native_width,
    std::uint32_t native_height,
    std::uint32_t max_width,
    std::uint32_t max_height) noexcept;

// Resolve an exact requested display, or the main/first available display
// when requested_display_id is zero. Exact requests never fall back.
[[nodiscard]] std::optional<std::uint32_t> display_capture_select_id(
    std::uint32_t requested_display_id,
    std::uint32_t main_display_id,
    const std::vector<std::uint32_t>& available_display_ids) noexcept;

// Map an RDP surface coordinate into the selected display's global macOS
// point coordinates. Display bounds are expressed in points, while the RDP
// surface may use Retina pixel dimensions.
[[nodiscard]] std::pair<double, double> display_capture_input_point(
    DisplayBounds bounds,
    std::uint32_t surface_width,
    std::uint32_t surface_height,
    std::uint16_t x,
    std::uint16_t y) noexcept;

// C++-only interface for the macOS capture implementation. The implementation
// uses ScreenCaptureKit, but no Apple framework types cross this boundary.
class DisplayCapture final {
public:
    explicit DisplayCapture(DisplayCaptureOptions options = {});
    // Project-internal injection seam for deterministic platform lifecycle tests.
    DisplayCapture(
        DisplayCaptureOptions options,
        std::unique_ptr<detail::DisplayCaptureBackend> backend);
    ~DisplayCapture();

    DisplayCapture(const DisplayCapture&) = delete;
    DisplayCapture& operator=(const DisplayCapture&) = delete;
    DisplayCapture(DisplayCapture&&) noexcept;
    DisplayCapture& operator=(DisplayCapture&&) noexcept;

    // Starts an asynchronous stream for the selected display. This method
    // waits for ScreenCaptureKit to start or report an error, with a finite
    // internal deadline. A true return means next_frame() can be used
    // immediately.
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

    // Stops capture with a finite internal wait for ScreenCaptureKit. Late
    // callbacks are isolated from any later stream generation.
    void stop() noexcept;

    [[nodiscard]] std::string last_error() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace macrdp
