#include <freerdp/codec/color.h>
#include <freerdp/codec/h264.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

namespace {

bool has_annex_b_start_code(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size < 4) {
        return false;
    }

    for (std::size_t index = 0; index + 4 <= size; ++index) {
        if (data[index] == 0 && data[index + 1] == 0
            && data[index + 2] == 1) {
            return true;
        }
        if (index + 4 <= size && data[index] == 0 && data[index + 1] == 0
            && data[index + 2] == 0 && data[index + 3] == 1) {
            return true;
        }
    }
    return false;
}

bool has_nal_type(const std::uint8_t* data, std::size_t size, std::uint8_t type) {
    if (data == nullptr || size < 4) {
        return false;
    }

    for (std::size_t index = 0; index + 4 < size; ++index) {
        std::size_t start = 0;
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            start = index + 3;
        } else if (index + 4 < size && data[index] == 0 && data[index + 1] == 0
                   && data[index + 2] == 0 && data[index + 3] == 1) {
            start = index + 4;
        } else {
            continue;
        }

        if (start < size && (data[start] & 0x1F) == type) {
            return true;
        }
    }
    return false;
}

void fill_frame(std::vector<std::uint8_t>& frame, std::uint32_t width,
                std::uint32_t height, std::uint32_t frame_index) {
    for (std::uint32_t y = 0; y < height; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
            auto* pixel = frame.data() + (static_cast<std::size_t>(y) * width + x) * 4;
            pixel[0] = static_cast<std::uint8_t>((x + frame_index * 3) & 0xFF);
            pixel[1] = static_cast<std::uint8_t>((y + frame_index * 5) & 0xFF);
            pixel[2] = static_cast<std::uint8_t>((x + y + frame_index * 7) & 0xFF);
            pixel[3] = 0xFF;
        }
    }
}

} // namespace

int main() {
    constexpr std::uint32_t width = 320;
    constexpr std::uint32_t height = 180;
    constexpr std::uint32_t stride = width * 4;

    H264_CONTEXT* encoder = h264_context_new(TRUE);
    H264_CONTEXT* decoder = h264_context_new(FALSE);
    if (encoder == nullptr
        || decoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 4'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 30)
        || !h264_context_reset(encoder, width, height)) {
        h264_context_free(encoder);
        h264_context_free(decoder);
        std::fprintf(stderr, "Unable to initialize FreeRDP H.264 encoder\n");
        return 1;
    }
    if (!h264_context_reset(decoder, width, height)) {
        h264_context_free(encoder);
        h264_context_free(decoder);
        std::fprintf(stderr, "Unable to initialize FreeRDP H.264 decoder\n");
        return 1;
    }

    const RECTANGLE_16 region = {0, 0, width, height};
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::vector<std::uint8_t> decoded(static_cast<std::size_t>(stride) * height);
    bool saw_idr = false;
    bool saw_inter_frame = false;
    std::uint32_t output_count = 0;
    std::uint32_t first_output_frame = 8;

    for (std::uint32_t frame_index = 0; frame_index < 8; ++frame_index) {
        // Keep the second input identical to the first to cover the startup
        // case where the desktop is static immediately after connection.
        fill_frame(frame, width, height, frame_index < 2 ? 0 : frame_index);

        BYTE* encoded = nullptr;
        UINT32 encoded_size = 0;
        RDPGFX_H264_METABLOCK meta{};
        const auto result = avc420_compress(
            encoder,
            frame.data(),
            PIXEL_FORMAT_BGRX32,
            stride,
            width,
            height,
            &region,
            &encoded,
            &encoded_size,
            &meta);

        if (result < 0) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            std::fprintf(stderr, "FreeRDP H.264 encoder returned an error\n");
            return 1;
        }

        // Hardware encoders may acknowledge an input before their first
        // packet is ready. The next input should carry that packet.
        if (encoded == nullptr || encoded_size == 0) {
            free_h264_metablock(&meta);
            continue;
        }
        ++output_count;
        first_output_frame = std::min(first_output_frame, frame_index);
        if (!has_annex_b_start_code(encoded, encoded_size)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr, "FreeRDP H.264 output is not valid Annex-B data\n");
            return 1;
        }

        std::fill(decoded.begin(), decoded.end(), 0);
        if (avc420_decompress(
                decoder,
                encoded,
                encoded_size,
                decoded.data(),
                PIXEL_FORMAT_BGRX32,
                stride,
                width,
                height,
                meta.regionRects,
                meta.numRegionRects) < 0) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr, "FreeRDP H.264 output could not be decoded\n");
            return 1;
        }

        saw_idr = saw_idr || has_nal_type(encoded, encoded_size, 5);
        saw_inter_frame = saw_inter_frame || has_nal_type(encoded, encoded_size, 1);
        free_h264_metablock(&meta);

        // Match the server's 30 FPS pacing so asynchronous hardware output
        // is tested under the same timing as a real desktop stream.
        if (frame_index + 1 < 8) {
            std::this_thread::sleep_for(std::chrono::milliseconds{33});
        }
    }

    h264_context_free(encoder);
    h264_context_free(decoder);
    if (!saw_idr || !saw_inter_frame || output_count < 4 || first_output_frame > 1) {
        std::fprintf(stderr,
                     "FreeRDP H.264 stream did not produce startup I/P frames "
                     "(packets=%u first=%u)\n",
                     output_count,
                     first_output_frame);
        return 1;
    }

    std::printf("FreeRDP H.264 AVC420 encoder produced %u Annex-B I/P packets\n",
                output_count);
    return 0;
}
