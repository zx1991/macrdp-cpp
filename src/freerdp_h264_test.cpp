#include <freerdp/codec/color.h>
#include <freerdp/codec/h264.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <thread>
#include <vector>

namespace {

constexpr std::uint8_t kH264BaselineProfileIdc = 66;

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

bool has_sps_profile(
    const std::uint8_t* data,
    std::size_t size,
    std::uint8_t profile_idc) {
    if (data == nullptr || size < 6) {
        return false;
    }

    for (std::size_t index = 0; index + 5 < size; ++index) {
        std::size_t start = 0;
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            start = index + 3;
        } else if (index + 4 < size && data[index] == 0 && data[index + 1] == 0
                   && data[index + 2] == 0 && data[index + 3] == 1) {
            start = index + 4;
        } else {
            continue;
        }

        if (start + 1 < size && (data[start] & 0x1F) == 7
            && data[start + 1] == profile_idc) {
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

void fill_region(std::vector<std::uint8_t>& frame, std::uint32_t width,
                 const RECTANGLE_16& region, std::uint32_t frame_index) {
    constexpr std::array<std::array<std::uint8_t, 3>, 6> colors{{
        {0x18, 0x28, 0xE8},
        {0xE0, 0x30, 0x20},
        {0x20, 0xD8, 0x38},
        {0xD8, 0xD0, 0x20},
        {0xD8, 0x28, 0xD0},
        {0x28, 0xD0, 0xD8},
    }};
    const auto& color = colors[frame_index % colors.size()];
    for (std::uint32_t y = region.top; y < region.bottom; ++y) {
        for (std::uint32_t x = region.left; x < region.right; ++x) {
            auto* pixel = frame.data() + (static_cast<std::size_t>(y) * width + x) * 4;
            pixel[0] = color[0];
            pixel[1] = color[1];
            pixel[2] = color[2];
            pixel[3] = 0xFF;
        }
    }
}

bool frame_is_close(const std::vector<std::uint8_t>& decoded,
                    const std::vector<std::uint8_t>& expected,
                    std::uint32_t width, std::uint32_t height,
                    std::uint32_t frame_index) {
    std::uint64_t total_error = 0;
    std::uint64_t severe_pixels = 0;
    const auto pixel_count = static_cast<std::uint64_t>(width) * height;

    for (std::uint64_t pixel_index = 0; pixel_index < pixel_count; ++pixel_index) {
        std::uint8_t maximum_error = 0;
        for (std::size_t channel = 0; channel < 3; ++channel) {
            const auto offset = static_cast<std::size_t>(pixel_index) * 4 + channel;
            const auto actual = static_cast<int>(decoded[offset]);
            const auto target = static_cast<int>(expected[offset]);
            const auto error = static_cast<std::uint8_t>(std::abs(actual - target));
            total_error += error;
            maximum_error = std::max(maximum_error, error);
        }
        severe_pixels += maximum_error > 64;
    }

    const double mean_error = static_cast<double>(total_error)
        / static_cast<double>(pixel_count * 3);
    const std::uint64_t severe_limit = std::max<std::uint64_t>(1, pixel_count / 50);
    if (mean_error > 12.0 || severe_pixels > severe_limit) {
        std::fprintf(stderr,
                     "H.264 frame %u did not preserve the complete desktop "
                     "(mean error %.2f, severe pixels %llu/%llu)\n",
                     frame_index,
                     mean_error,
                     static_cast<unsigned long long>(severe_pixels),
                     static_cast<unsigned long long>(pixel_count));
        return false;
    }
    return true;
}

bool verify_avc444(std::uint32_t width, std::uint32_t height,
                   std::uint32_t stride) {
    H264_CONTEXT* encoder = h264_context_new(TRUE);
    if (encoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 4'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 30)
        || !h264_context_reset(encoder, width, height)) {
        h264_context_free(encoder);
        std::fprintf(stderr, "Unable to initialize FreeRDP AVC444 encoder\n");
        return false;
    }

    const RECTANGLE_16 full_region = {
        0,
        0,
        static_cast<UINT16>(width),
        static_cast<UINT16>(height),
    };
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::uint32_t packet_count = 0;
    bool saw_luma = false;
    bool saw_chroma = false;

    for (std::uint32_t frame_index = 0; frame_index < 8; ++frame_index) {
        fill_frame(frame, width, height, frame_index + 20);
        BYTE op = 0;
        BYTE* luma = nullptr;
        BYTE* chroma = nullptr;
        UINT32 luma_size = 0;
        UINT32 chroma_size = 0;
        RDPGFX_H264_METABLOCK luma_meta{};
        RDPGFX_H264_METABLOCK chroma_meta{};
        const auto result = avc444_compress(
            encoder,
            frame.data(),
            PIXEL_FORMAT_BGRX32,
            stride,
            width,
            height,
            1,
            &full_region,
            &op,
            &luma,
            &luma_size,
            &chroma,
            &chroma_size,
            &luma_meta,
            &chroma_meta);

        if (result < 0) {
            free_h264_metablock(&luma_meta);
            free_h264_metablock(&chroma_meta);
            h264_context_free(encoder);
            std::fprintf(stderr, "FreeRDP AVC444 encoder returned an error\n");
            return false;
        }
        if (result > 0) {
            if ((luma_size > 0 && !has_annex_b_start_code(luma, luma_size))
                || (chroma_size > 0
                    && !has_annex_b_start_code(chroma, chroma_size))) {
                free_h264_metablock(&luma_meta);
                free_h264_metablock(&chroma_meta);
                h264_context_free(encoder);
                std::fprintf(stderr, "FreeRDP AVC444 output is not valid Annex-B data\n");
                return false;
            }
            saw_luma = saw_luma || luma_size > 0;
            saw_chroma = saw_chroma || chroma_size > 0;
            packet_count += static_cast<std::uint32_t>(luma_size > 0)
                + static_cast<std::uint32_t>(chroma_size > 0);
        }
        free_h264_metablock(&luma_meta);
        free_h264_metablock(&chroma_meta);

        if (frame_index + 1 < 8) {
            std::this_thread::sleep_for(std::chrono::milliseconds{33});
        }
    }

    h264_context_free(encoder);
    if (!saw_luma || !saw_chroma || packet_count < 4) {
        std::fprintf(stderr,
                     "FreeRDP AVC444 stream did not produce luma/chroma packets "
                     "(packets=%u)\n",
                     packet_count);
        return false;
    }

    std::printf("FreeRDP H.264 AVC444 encoder produced %u Annex-B packets\n",
                packet_count);
    return true;
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

    const RECTANGLE_16 full_region = {0, 0, width, height};
    constexpr std::array<RECTANGLE_16, 2> dirty_regions{{
        {16, 16, 112, 80},
        {208, 104, 304, 168},
    }};
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::vector<std::uint8_t> decoded(static_cast<std::size_t>(stride) * height);
    bool saw_immediate_inter_frame = false;
    std::uint32_t output_count = 0;
    std::uint32_t first_output_frame = 8;

    for (std::uint32_t frame_index = 0; frame_index < 8; ++frame_index) {
        if (frame_index == 0) {
            fill_frame(frame, width, height, 0);
        } else {
            fill_region(frame, width, dirty_regions[(frame_index - 1) % dirty_regions.size()],
                        frame_index);
        }

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
            &full_region,
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
        for (std::uint32_t rect_index = 0; rect_index < meta.numRegionRects; ++rect_index) {
            const RECTANGLE_16& rect = meta.regionRects[rect_index];
            if (rect.left >= rect.right || rect.top >= rect.bottom
                || rect.right > width || rect.bottom > height) {
                free_h264_metablock(&meta);
                h264_context_free(encoder);
                h264_context_free(decoder);
                std::fprintf(stderr, "H.264 metadata contained an invalid desktop rectangle\n");
                return 1;
            }
        }
        if (!has_annex_b_start_code(encoded, encoded_size)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr, "FreeRDP H.264 output is not valid Annex-B data\n");
            return 1;
        }

        const bool is_idr = has_nal_type(encoded, encoded_size, 5);
        if (output_count == 1 && !is_idr) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr,
                         "FreeRDP H.264 first packet %u was not an IDR frame\n",
                         output_count);
            return 1;
        }
        if (output_count == 1
            && !has_sps_profile(encoded, encoded_size, kH264BaselineProfileIdc)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr,
                         "FreeRDP H.264 first packet was not Baseline profile\n");
            return 1;
        }
        if (output_count == 2 && !has_nal_type(encoded, encoded_size, 1)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr,
                         "FreeRDP H.264 second packet was not an inter frame\n");
            return 1;
        }

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
        if (!frame_is_close(decoded, frame, width, height, frame_index)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            return 1;
        }

        if (output_count == 2) {
            saw_immediate_inter_frame = true;
        }
        free_h264_metablock(&meta);

        // Match the server's 30 FPS pacing so asynchronous hardware output
        // is tested under the same timing as a real desktop stream.
        if (frame_index + 1 < 8) {
            std::this_thread::sleep_for(std::chrono::milliseconds{33});
        }
    }

    h264_context_free(encoder);
    h264_context_free(decoder);
    if (!saw_immediate_inter_frame || output_count < 4 || first_output_frame > 1) {
        std::fprintf(stderr,
                     "FreeRDP H.264 stream did not produce startup I/P frames "
                     "(packets=%u first=%u)\n",
                     output_count,
                     first_output_frame);
        return 1;
    }

    std::printf("FreeRDP H.264 AVC420 encoder produced %u Annex-B I/P packets\n",
                output_count);
    return verify_avc444(width, height, stride) ? 0 : 1;
}
