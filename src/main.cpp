#include "macrdp/display_capture.hpp"
#include "macrdp/h264_encoder.hpp"

#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

bool write_ppm(const macrdp::Frame& frame, const std::string& path) {
    if (!frame.valid()) {
        return false;
    }

    std::ofstream output(path, std::ios::binary);
    if (!output) {
        return false;
    }

    output << "P6\n" << frame.width << ' ' << frame.height << "\n255\n";
    for (std::uint32_t y = 0; y < frame.height; ++y) {
        const auto* row = frame.bgra.data() + frame.stride * y;
        for (std::uint32_t x = 0; x < frame.width; ++x) {
            const auto* pixel = row + static_cast<std::size_t>(x) * 4;
            // Frame memory is BGRA; PPM stores RGB.
            output.put(static_cast<char>(pixel[2]));
            output.put(static_cast<char>(pixel[1]));
            output.put(static_cast<char>(pixel[0]));
        }
    }

    return output.good();
}

bool write_h264_packets(
    std::ofstream& output,
    const std::vector<macrdp::EncodedPacket>& packets,
    std::size_t& packet_count) {
    for (const auto& packet : packets) {
        output.write(
            reinterpret_cast<const char*>(packet.annex_b.data()),
            static_cast<std::streamsize>(packet.annex_b.size()));
        if (!output) {
            return false;
        }
        ++packet_count;
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    const std::string output_path = argc > 1 ? argv[1] : "capture.ppm";
    const std::string h264_path = argc > 2 ? argv[2] : "capture.h264";
    const auto capture_duration = std::chrono::seconds{2};

    macrdp::DisplayCapture capture;
    if (!capture.start()) {
        std::cerr << "Unable to start display capture: " << capture.last_error() << "\n"
                  << "Grant Screen Recording permission to this executable or Terminal.\n";
        return 1;
    }

    std::ofstream h264_output(h264_path, std::ios::binary);
    if (!h264_output) {
        capture.stop();
        std::cerr << "Unable to open H.264 output " << h264_path << "\n";
        return 1;
    }

    macrdp::H264Encoder encoder;
    std::optional<macrdp::Frame> latest_frame;
    std::size_t frame_count = 0;
    std::size_t packet_count = 0;
    std::string pipeline_error;
    const auto deadline = std::chrono::steady_clock::now() + capture_duration;
    while (std::chrono::steady_clock::now() < deadline) {
        auto frame = capture.next_frame(std::chrono::milliseconds{250});
        if (frame.has_value()) {
            latest_frame = std::move(frame);
            ++frame_count;

            std::vector<macrdp::EncodedPacket> packets;
            if (!encoder.encode(*latest_frame, packets)) {
                pipeline_error = encoder.last_error();
                break;
            }
            if (!write_h264_packets(h264_output, packets, packet_count)) {
                pipeline_error = "Unable to write H.264 output";
                break;
            }
        }
    }
    capture.stop();

    if (pipeline_error.empty()) {
        std::vector<macrdp::EncodedPacket> packets;
        if (!encoder.flush(packets)) {
            pipeline_error = encoder.last_error();
        } else if (!write_h264_packets(h264_output, packets, packet_count)) {
            pipeline_error = "Unable to write H.264 output";
        }
    }

    h264_output.flush();
    if (!pipeline_error.empty()) {
        std::cerr << "Capture pipeline failed: " << pipeline_error << "\n";
        return 1;
    }

    if (!latest_frame.has_value()) {
        std::cerr << "Display capture produced no frames";
        if (!capture.last_error().empty()) {
            std::cerr << ": " << capture.last_error();
        }
        std::cerr << "\n";
        return 1;
    }

    if (!write_ppm(*latest_frame, output_path)) {
        std::cerr << "Unable to write capture to " << output_path << "\n";
        return 1;
    }

    std::cout << "Captured " << frame_count << " frames; latest is "
              << latest_frame->width << 'x' << latest_frame->height
              << " and was written to " << output_path << "; encoded "
              << packet_count << " H.264 packets to " << h264_path << "\n";
    return 0;
}
