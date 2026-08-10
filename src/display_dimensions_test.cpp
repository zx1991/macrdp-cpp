#include "macrdp/display_capture.hpp"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <optional>
#include <utility>
#include <vector>

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

bool expect_display_id(
    std::uint32_t requested,
    std::uint32_t main,
    std::vector<std::uint32_t> available,
    std::optional<std::uint32_t> expected) {
    const auto actual = macrdp::display_capture_select_id(
        requested,
        main,
        available);
    if (actual == expected) {
        return true;
    }
    std::cerr << "Unexpected display selection\n";
    return false;
}

bool expect_input_point(
    macrdp::DisplayBounds bounds,
    std::uint32_t surface_width,
    std::uint32_t surface_height,
    std::uint16_t x,
    std::uint16_t y,
    double expected_x,
    double expected_y) {
    const auto actual = macrdp::display_capture_input_point(
        bounds,
        surface_width,
        surface_height,
        x,
        y);
    if (std::abs(actual.first - expected_x) < 0.0001
        && std::abs(actual.second - expected_y) < 0.0001) {
        return true;
    }
    std::cerr << "Unexpected input point: got " << actual.first << ',' << actual.second
              << ", expected " << expected_x << ',' << expected_y << '\n';
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
            && expect_display_id(7, 9, {9, 7}, 7)
            && expect_display_id(0, 9, {9, 7}, 9)
            && expect_display_id(0, 9, {7, 8}, 7)
            && expect_display_id(42, 9, {9, 7}, std::nullopt)
            && expect_display_id(0, 9, {}, std::nullopt)
            && expect_input_point(
                {-1512.0, 0.0, 1512.0, 982.0},
                3024,
                1964,
                0,
                0,
                -1512.0,
                0.0)
            && expect_input_point(
                {-1512.0, 0.0, 1512.0, 982.0},
                3024,
                1964,
                3023,
                1963,
                -1.0,
                981.0)
            && expect_input_point(
                {1512.0, -400.0, 1920.0, 1080.0},
                1920,
                1080,
                1919,
                1079,
                3431.0,
                679.0)
        ? 0
        : 1;
}
