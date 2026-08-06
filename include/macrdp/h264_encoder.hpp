#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "macrdp/frame.hpp"

namespace macrdp {

struct EncodedPacket {
    // H.264 NAL units in Annex B format, including start codes.
    std::vector<std::uint8_t> annex_b;
    std::uint64_t timestamp_us = 0;
    bool key_frame = false;
};

struct H264EncoderOptions {
    std::uint32_t frame_rate = 30;
    std::uint32_t bitrate_bits_per_second = 4'000'000;
    std::uint32_t key_frame_interval = 60;
};

// C++-only wrapper around VideoToolbox's H.264 encoder. The encoder lazily
// creates a session from the first Frame's dimensions.
class H264Encoder final {
public:
    explicit H264Encoder(H264EncoderOptions options = {});
    ~H264Encoder();

    H264Encoder(const H264Encoder&) = delete;
    H264Encoder& operator=(const H264Encoder&) = delete;
    H264Encoder(H264Encoder&&) noexcept;
    H264Encoder& operator=(H264Encoder&&) noexcept;

    // Encodes one BGRA frame and appends any completed packets to output.
    // VideoToolbox output is drained before this method returns, which keeps
    // this first implementation simple and deterministic for the next layer.
    [[nodiscard]] bool encode(
        const Frame& frame,
        std::vector<EncodedPacket>& output);

    // Completes any frames still pending in VideoToolbox.
    [[nodiscard]] bool flush(std::vector<EncodedPacket>& output);

    [[nodiscard]] std::string last_error() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace macrdp
