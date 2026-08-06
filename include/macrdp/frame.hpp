#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace macrdp {

struct FrameRect {
    // Coordinates are half-open: [left, right) x [top, bottom).
    std::uint32_t left = 0;
    std::uint32_t top = 0;
    std::uint32_t right = 0;
    std::uint32_t bottom = 0;

    [[nodiscard]] bool valid() const noexcept {
        return left < right && top < bottom;
    }
};

struct Frame {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::size_t stride = 0;
    std::uint64_t timestamp_us = 0;
    // Pixels are tightly represented as BGRA rows with `stride` bytes per row.
    std::vector<std::uint8_t> bgra;
    // ScreenCaptureKit reports the portions redrawn for this frame. An empty
    // list means that the producer did not provide usable dirty-rect metadata.
    std::vector<FrameRect> dirty_rects;

    [[nodiscard]] bool valid() const noexcept {
        return width > 0
            && height > 0
            && stride >= static_cast<std::size_t>(width) * 4
            && height <= std::numeric_limits<std::size_t>::max() / stride
            && bgra.size() >= stride * static_cast<std::size_t>(height);
    }
};

} // namespace macrdp
