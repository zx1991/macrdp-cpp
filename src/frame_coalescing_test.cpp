#include "macrdp/frame.hpp"

#include <iostream>

namespace {

bool expect_rect(
    const macrdp::FrameRect& actual,
    std::uint32_t left,
    std::uint32_t top,
    std::uint32_t right,
    std::uint32_t bottom) {
    return actual.left == left && actual.top == top
        && actual.right == right && actual.bottom == bottom;
}

} // namespace

int main() {
    macrdp::Frame previous;
    previous.width = 1920;
    previous.height = 1080;
    previous.dirty_rects.push_back({10, 20, 30, 40});

    macrdp::Frame newest;
    newest.width = 1920;
    newest.height = 1080;
    newest.dirty_rects.push_back({100, 200, 120, 220});
    macrdp::coalesce_dropped_frame_dirty_regions(previous, newest);
    if (newest.dirty_rects.size() != 1
        || !expect_rect(newest.dirty_rects.front(), 10, 20, 120, 220)) {
        std::cerr << "Dropped frame dirty regions were not coalesced\n";
        return 1;
    }

    macrdp::Frame without_metadata;
    without_metadata.width = newest.width;
    without_metadata.height = newest.height;
    macrdp::Frame with_metadata = newest;
    macrdp::coalesce_dropped_frame_dirty_regions(without_metadata, with_metadata);
    if (!with_metadata.dirty_rects.empty()) {
        std::cerr << "Unknown dirty metadata must trigger a full update\n";
        return 1;
    }

    macrdp::Frame resized = newest;
    resized.width = 1280;
    macrdp::coalesce_dropped_frame_dirty_regions(newest, resized);
    if (!resized.dirty_rects.empty()) {
        std::cerr << "Dimension changes must trigger a full update\n";
        return 1;
    }

    macrdp::Frame replaced_generation = newest;
    newest.display_generation = 4;
    replaced_generation.display_generation = 5;
    macrdp::coalesce_dropped_frame_dirty_regions(newest, replaced_generation);
    if (!replaced_generation.dirty_rects.empty()) {
        std::cerr << "Display generation changes must trigger a full update\n";
        return 1;
    }

    return 0;
}
