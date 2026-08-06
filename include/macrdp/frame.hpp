#pragma once

#include <algorithm>
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

// When a producer coalesces frames, the newest pixel buffer must carry the
// dirty regions from every skipped frame. An empty result deliberately means
// that the metadata is no longer sufficient and the consumer should use a
// full-frame update.
inline void coalesce_dropped_frame_dirty_regions(
    const Frame& previous,
    Frame& newest) {
    if (previous.width != newest.width || previous.height != newest.height
        || previous.dirty_rects.empty() || newest.dirty_rects.empty()) {
        newest.dirty_rects.clear();
        return;
    }

    FrameRect bounds{};
    bool has_bounds = false;
    const auto include = [&bounds, &has_bounds](const FrameRect& rect) {
        if (!rect.valid()) {
            return;
        }
        if (!has_bounds) {
            bounds = rect;
            has_bounds = true;
            return;
        }
        bounds.left = std::min(bounds.left, rect.left);
        bounds.top = std::min(bounds.top, rect.top);
        bounds.right = std::max(bounds.right, rect.right);
        bounds.bottom = std::max(bounds.bottom, rect.bottom);
    };

    for (const auto& rect : previous.dirty_rects) {
        include(rect);
    }
    for (const auto& rect : newest.dirty_rects) {
        include(rect);
    }

    newest.dirty_rects.clear();
    if (has_bounds) {
        newest.dirty_rects.push_back(bounds);
    }
}

} // namespace macrdp
