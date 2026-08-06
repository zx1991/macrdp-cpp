#include "macrdp/h264_encoder.hpp"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

macrdp::Frame make_frame(
    std::uint32_t width,
    std::uint32_t height,
    std::uint64_t timestamp_us) {
    macrdp::Frame frame;
    frame.width = width;
    frame.height = height;
    frame.stride = static_cast<std::size_t>(width) * 4;
    frame.timestamp_us = timestamp_us;
    frame.bgra.resize(frame.stride * height);

    for (std::uint32_t y = 0; y < height; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
            auto* pixel = frame.bgra.data() + frame.stride * y + x * 4;
            pixel[0] = static_cast<std::uint8_t>((x + timestamp_us / 33'333) % 256);
            pixel[1] = static_cast<std::uint8_t>((y * 2) % 256);
            pixel[2] = static_cast<std::uint8_t>((x + y) % 256);
            pixel[3] = 255;
        }
    }
    return frame;
}

bool write_packets(
    std::ofstream& output,
    const std::vector<macrdp::EncodedPacket>& packets,
    std::size_t& packet_count,
    std::size_t& byte_count) {
    for (const auto& packet : packets) {
        output.write(
            reinterpret_cast<const char*>(packet.annex_b.data()),
            static_cast<std::streamsize>(packet.annex_b.size()));
        if (!output) {
            return false;
        }
        ++packet_count;
        byte_count += packet.annex_b.size();
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    const std::string output_path = argc > 1 ? argv[1] : "encoder-test.h264";
    std::ofstream output(output_path, std::ios::binary);
    if (!output) {
        std::cerr << "Unable to open " << output_path << "\n";
        return 1;
    }

    macrdp::H264Encoder encoder;
    std::size_t packet_count = 0;
    std::size_t byte_count = 0;
    for (std::uint32_t index = 0; index < 30; ++index) {
        const auto frame = make_frame(320, 180, static_cast<std::uint64_t>(index) * 33'333);
        std::vector<macrdp::EncodedPacket> packets;
        if (!encoder.encode(frame, packets)
            || !write_packets(output, packets, packet_count, byte_count)) {
            std::cerr << "H.264 encode failed: " << encoder.last_error() << "\n";
            return 1;
        }
    }

    std::vector<macrdp::EncodedPacket> packets;
    if (!encoder.flush(packets)
        || !write_packets(output, packets, packet_count, byte_count)) {
        std::cerr << "H.264 flush failed: " << encoder.last_error() << "\n";
        return 1;
    }

    std::cout << "Encoded " << packet_count << " packets (" << byte_count
              << " bytes) to " << output_path << "\n";
    return packet_count == 0 ? 1 : 0;
}
