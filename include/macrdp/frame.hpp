#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace macrdp {

struct Frame {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::size_t stride = 0;
    std::uint64_t timestamp_us = 0;
    // Pixels are tightly represented as BGRA rows with `stride` bytes per row.
    std::vector<std::uint8_t> bgra;

    [[nodiscard]] bool valid() const noexcept {
        return width > 0
            && height > 0
            && stride >= static_cast<std::size_t>(width) * 4
            && bgra.size() >= stride * static_cast<std::size_t>(height);
    }
};

} // namespace macrdp

