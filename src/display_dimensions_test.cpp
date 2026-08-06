#include "macrdp/display_capture.hpp"

#include <cstdint>
#include <iostream>

namespace {

bool expect_dimensions(
    std::uint32_t native_width,
    std::uint32_t native_height,
    std::uint32_t max_width,
    std::uint32_t max_height,
    std::uint32_t expected_width,
    std::uint32_t expected_height) {
    const auto actual = macrdp::display_capture_output_size(
        native_width,
        native_height,
        max_width,
        max_height);
    if (actual.first == expected_width && actual.second == expected_height) {
        return true;
    }

    std::cerr << "Unexpected dimensions: got " << actual.first << 'x' << actual.second
              << ", expected " << expected_width << 'x' << expected_height << '\n';
    return false;
}

} // namespace

int main() {
    return expect_dimensions(1984, 1116, 0, 0, 1984, 1116)
            && expect_dimensions(1984, 1116, 1280, 720, 1280, 720)
            && expect_dimensions(1920, 1080, 1280, 0, 1280, 720)
            && expect_dimensions(1920, 1080, 0, 720, 1280, 720)
            && expect_dimensions(1920, 1080, 4000, 4000, 1920, 1080)
            && expect_dimensions(1919, 1079, 1280, 720, 1280, 718)
            && expect_dimensions(3, 3, 0, 0, 2, 2)
        ? 0
        : 1;
}
