#pragma once

#include <cstdint>

namespace macrdp {

// RDP stores wheel deltas as a signed 9-bit two's-complement value in the
// low bits of the pointer flags field.
[[nodiscard]] constexpr int decode_rdp_wheel_delta(std::uint16_t flags) noexcept {
    constexpr std::uint16_t rotation_mask = 0x01FFU;
    constexpr std::uint16_t sign_bit = 0x0100U;
    constexpr int value_range = 0x0200;

    const auto encoded = static_cast<std::uint16_t>(flags & rotation_mask);
    return (encoded & sign_bit) != 0
        ? static_cast<int>(encoded) - value_range
        : static_cast<int>(encoded);
}

} // namespace macrdp
