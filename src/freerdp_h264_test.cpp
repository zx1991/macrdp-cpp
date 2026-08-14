#include <freerdp/codec/color.h>
#include <freerdp/codec/h264.h>

#include "macrdp/videotoolbox_h264.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <optional>
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

bool has_constrained_baseline_sps(
    const std::uint8_t* data,
    std::size_t size) {
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

        if (start + 2 < size && (data[start] & 0x1F) == 7
            && data[start + 1] == kH264BaselineProfileIdc
            && (data[start + 2] & 0xC0) == 0xC0) {
            return true;
        }
    }
    return false;
}

struct SpsDimensions {
    std::uint32_t coded_width = 0;
    std::uint32_t coded_height = 0;
    std::uint32_t display_width = 0;
    std::uint32_t display_height = 0;
    bool frame_cropping = false;
};

class BitReader {
public:
    explicit BitReader(const std::vector<std::uint8_t>& data) : data_(data) {}

    bool read_bits(std::uint32_t count, std::uint32_t& value) {
        if (count > 32 || bit_offset_ + count > data_.size() * 8) {
            return false;
        }
        value = 0;
        for (std::uint32_t index = 0; index < count; ++index) {
            const auto byte = data_[bit_offset_ / 8];
            value = (value << 1) | ((byte >> (7 - bit_offset_ % 8)) & 1U);
            ++bit_offset_;
        }
        return true;
    }

    bool read_bit(bool& value) {
        std::uint32_t bit = 0;
        if (!read_bits(1, bit)) {
            return false;
        }
        value = bit != 0;
        return true;
    }

    bool read_ue(std::uint32_t& value) {
        std::uint32_t leading_zero_bits = 0;
        bool bit = false;
        while (true) {
            if (!read_bit(bit)) {
                return false;
            }
            if (bit) {
                break;
            }
            if (++leading_zero_bits >= 32) {
                return false;
            }
        }

        std::uint32_t suffix = 0;
        if (leading_zero_bits > 0 && !read_bits(leading_zero_bits, suffix)) {
            return false;
        }
        value = ((1U << leading_zero_bits) - 1U) + suffix;
        return true;
    }

    bool read_se(std::int32_t& value) {
        std::uint32_t code = 0;
        if (!read_ue(code)) {
            return false;
        }
        const auto magnitude = static_cast<std::int32_t>((code + 1U) / 2U);
        value = (code & 1U) != 0 ? magnitude : -magnitude;
        return true;
    }

private:
    const std::vector<std::uint8_t>& data_;
    std::size_t bit_offset_ = 0;
};

std::optional<std::vector<std::uint8_t>> find_sps_rbsp(
    const std::uint8_t* data,
    std::size_t size) {
    if (data == nullptr) {
        return std::nullopt;
    }

    for (std::size_t index = 0; index + 4 < size; ++index) {
        std::size_t nal_start = 0;
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            nal_start = index + 3;
        } else if (index + 4 < size && data[index] == 0 && data[index + 1] == 0
                   && data[index + 2] == 0 && data[index + 3] == 1) {
            nal_start = index + 4;
        } else {
            continue;
        }
        if (nal_start >= size || (data[nal_start] & 0x1F) != 7) {
            continue;
        }

        std::size_t nal_end = size;
        for (std::size_t next = nal_start + 1; next + 3 < size; ++next) {
            if (data[next] == 0 && data[next + 1] == 0
                && (data[next + 2] == 1
                    || (next + 3 < size && data[next + 2] == 0
                        && data[next + 3] == 1))) {
                nal_end = next;
                break;
            }
        }

        std::vector<std::uint8_t> rbsp;
        rbsp.reserve(nal_end - nal_start - 1);
        std::uint32_t zero_count = 0;
        for (std::size_t offset = nal_start + 1; offset < nal_end; ++offset) {
            const auto byte = data[offset];
            if (zero_count == 2 && byte == 3) {
                zero_count = 0;
                continue;
            }
            rbsp.push_back(byte);
            zero_count = byte == 0 ? zero_count + 1 : 0;
        }
        return rbsp;
    }
    return std::nullopt;
}

std::optional<SpsDimensions> parse_sps_dimensions(
    const std::uint8_t* data,
    std::size_t size) {
    const auto rbsp = find_sps_rbsp(data, size);
    if (!rbsp) {
        return std::nullopt;
    }

    BitReader bits(*rbsp);
    std::uint32_t profile_idc = 0;
    std::uint32_t ignored = 0;
    std::uint32_t pic_order_cnt_type = 0;
    if (!bits.read_bits(8, profile_idc)
        || !bits.read_bits(8, ignored)
        || !bits.read_bits(8, ignored)
        || !bits.read_ue(ignored)
        || profile_idc != kH264BaselineProfileIdc
        || !bits.read_ue(ignored)
        || !bits.read_ue(pic_order_cnt_type)) {
        return std::nullopt;
    }

    if (pic_order_cnt_type == 0) {
        if (!bits.read_ue(ignored)) {
            return std::nullopt;
        }
    } else if (pic_order_cnt_type == 1) {
        bool delta_pic_order_always_zero = false;
        std::int32_t signed_ignored = 0;
        std::uint32_t cycle_count = 0;
        if (!bits.read_bit(delta_pic_order_always_zero)
            || !bits.read_se(signed_ignored)
            || !bits.read_se(signed_ignored)
            || !bits.read_ue(cycle_count)) {
            return std::nullopt;
        }
        for (std::uint32_t index = 0; index < cycle_count; ++index) {
            if (!bits.read_se(signed_ignored)) {
                return std::nullopt;
            }
        }
    } else if (pic_order_cnt_type != 2) {
        return std::nullopt;
    }

    bool gaps_allowed = false;
    bool frame_mbs_only = false;
    bool direct_8x8_inference = false;
    bool frame_cropping = false;
    std::uint32_t width_in_mbs_minus1 = 0;
    std::uint32_t height_in_map_units_minus1 = 0;
    if (!bits.read_ue(ignored)
        || !bits.read_bit(gaps_allowed)
        || !bits.read_ue(width_in_mbs_minus1)
        || !bits.read_ue(height_in_map_units_minus1)
        || !bits.read_bit(frame_mbs_only)) {
        return std::nullopt;
    }
    if (!frame_mbs_only) {
        bool mb_adaptive_frame_field = false;
        if (!bits.read_bit(mb_adaptive_frame_field)) {
            return std::nullopt;
        }
    }
    if (!bits.read_bit(direct_8x8_inference)
        || !bits.read_bit(frame_cropping)) {
        return std::nullopt;
    }

    std::uint32_t crop_left = 0;
    std::uint32_t crop_right = 0;
    std::uint32_t crop_top = 0;
    std::uint32_t crop_bottom = 0;
    if (frame_cropping
        && (!bits.read_ue(crop_left)
            || !bits.read_ue(crop_right)
            || !bits.read_ue(crop_top)
            || !bits.read_ue(crop_bottom))) {
        return std::nullopt;
    }

    SpsDimensions dimensions;
    dimensions.coded_width = (width_in_mbs_minus1 + 1U) * 16U;
    dimensions.coded_height = (2U - static_cast<std::uint32_t>(frame_mbs_only))
        * (height_in_map_units_minus1 + 1U) * 16U;
    const std::uint32_t crop_unit_x = 2;
    const std::uint32_t crop_unit_y = 2U
        * (2U - static_cast<std::uint32_t>(frame_mbs_only));
    const auto horizontal_crop = (crop_left + crop_right) * crop_unit_x;
    const auto vertical_crop = (crop_top + crop_bottom) * crop_unit_y;
    if (horizontal_crop > dimensions.coded_width
        || vertical_crop > dimensions.coded_height) {
        return std::nullopt;
    }
    dimensions.display_width = dimensions.coded_width - horizontal_crop;
    dimensions.display_height = dimensions.coded_height - vertical_crop;
    dimensions.frame_cropping = frame_cropping;
    return dimensions;
}

bool verify_rdp_sps_dimensions(const std::uint8_t* data, std::size_t size,
                               std::uint32_t visible_width,
                               std::uint32_t visible_height,
                               const char* encoder_name) {
    const auto dimensions = parse_sps_dimensions(data, size);
    const auto aligned_width = (visible_width + 15U) & ~15U;
    const auto aligned_height = (visible_height + 15U) & ~15U;
    const bool cropping_required = visible_width != aligned_width
        || visible_height != aligned_height;
    if (!dimensions
        || dimensions->coded_width != aligned_width
        || dimensions->coded_height != aligned_height
        || dimensions->display_width != visible_width
        || dimensions->display_height != visible_height
        || dimensions->frame_cropping != cropping_required) {
        std::fprintf(
            stderr,
            "%s H.264 SPS does not expose the %ux%u desktop inside the "
            "%ux%u coded surface "
            "(coded=%ux%u display=%ux%u cropping=%d)\n",
            encoder_name,
            visible_width,
            visible_height,
            aligned_width,
            aligned_height,
            dimensions ? dimensions->coded_width : 0,
            dimensions ? dimensions->coded_height : 0,
            dimensions ? dimensions->display_width : 0,
            dimensions ? dimensions->display_height : 0,
            dimensions ? static_cast<int>(dimensions->frame_cropping) : -1);
        return false;
    }
    return true;
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

bool verify_all_idr(std::uint32_t width, std::uint32_t height,
                    std::uint32_t stride, bool direct_bridge) {
    struct EncoderModeReset {
        ~EncoderModeReset() {
            macrdp_vt_h264_encoder_set_enabled(1);
            macrdp_vt_h264_encoder_set_key_frame_interval(0);
        }
    } reset;

    macrdp_vt_h264_encoder_set_enabled(direct_bridge ? 1 : 0);
    macrdp_vt_h264_encoder_set_key_frame_interval(1);
    H264_CONTEXT* encoder = h264_context_new(TRUE);
    if (encoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 4'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 30)
        || !h264_context_reset(encoder, width, height)) {
        h264_context_free(encoder);
        std::fprintf(stderr, "Unable to initialize all-IDR H.264 encoder\n");
        return false;
    }

    const RECTANGLE_16 full_region = {
        0,
        0,
        static_cast<UINT16>(width),
        static_cast<UINT16>(height),
    };
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::uint32_t output_count = 0;
    for (std::uint32_t frame_index = 0; frame_index < 6; ++frame_index) {
        fill_frame(frame, width, height, frame_index + 40);
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
        if (result < 0
            || (encoded_size > 0 && !has_nal_type(encoded, encoded_size, 5))) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            std::fprintf(stderr, "%s all-IDR mode emitted a non-IDR packet\n",
                         direct_bridge ? "Direct" : "FFmpeg");
            return false;
        }
        output_count += encoded_size > 0 ? 1U : 0U;
        free_h264_metablock(&meta);
        if (frame_index + 1 < 6) {
            std::this_thread::sleep_for(std::chrono::milliseconds{33});
        }
    }
    h264_context_free(encoder);
    if (output_count < 4) {
        std::fprintf(stderr, "%s all-IDR mode produced too few packets (%u)\n",
                     direct_bridge ? "Direct" : "FFmpeg", output_count);
        return false;
    }
    std::printf("%s all-IDR mode produced %u IDR packets\n",
                direct_bridge ? "Direct" : "FFmpeg", output_count);
    return true;
}

bool verify_ffmpeg_inter_frames(std::uint32_t width, std::uint32_t height,
                                std::uint32_t stride) {
    struct EncoderModeReset {
        ~EncoderModeReset() {
            macrdp_vt_h264_encoder_set_enabled(1);
            macrdp_vt_h264_encoder_set_key_frame_interval(0);
        }
    } reset;

    macrdp_vt_h264_encoder_set_enabled(0);
    macrdp_vt_h264_encoder_set_key_frame_interval(60);
    H264_CONTEXT* encoder = h264_context_new(TRUE);
    if (encoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 4'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 30)
        || !h264_context_reset(encoder, width, height)) {
        h264_context_free(encoder);
        std::fprintf(stderr, "Unable to initialize FFmpeg inter-frame H.264 encoder\n");
        return false;
    }

    const RECTANGLE_16 full_region = {
        0,
        0,
        static_cast<UINT16>(width),
        static_cast<UINT16>(height),
    };
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::uint32_t output_count = 0;
    bool saw_inter_frame = false;
    for (std::uint32_t frame_index = 0; frame_index < 8; ++frame_index) {
        fill_frame(frame, width, height, frame_index + 60);
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
            std::fprintf(stderr, "FFmpeg inter-frame H.264 encoder returned an error\n");
            return false;
        }
        if (encoded_size > 0) {
            ++output_count;
            if (output_count == 1
                && (!has_nal_type(encoded, encoded_size, 5)
                    || !has_constrained_baseline_sps(encoded, encoded_size)
                    || !verify_rdp_sps_dimensions(
                        encoded, encoded_size, width, height, "FFmpeg"))) {
                free_h264_metablock(&meta);
                h264_context_free(encoder);
                std::fprintf(stderr,
                             "FFmpeg first H.264 packet was not Constrained Baseline IDR\n");
                return false;
            }
            if (output_count == 2) {
                saw_inter_frame = has_nal_type(encoded, encoded_size, 1);
            }
        }
        free_h264_metablock(&meta);
        if (frame_index + 1 < 8) {
            std::this_thread::sleep_for(std::chrono::milliseconds{33});
        }
    }

    h264_context_free(encoder);
    if (!saw_inter_frame || output_count < 4) {
        std::fprintf(stderr,
                     "FFmpeg H.264 stream did not produce constrained I/P frames "
                     "(packets=%u)\n",
                     output_count);
        return false;
    }
    std::printf("FFmpeg H.264 encoder produced %u Constrained Baseline I/P packets\n",
                output_count);
    return true;
}

bool verify_1080p_rdp_surface() {
    constexpr std::uint32_t width = 1920;
    constexpr std::uint32_t height = 1080;
    constexpr std::uint32_t stride = width * 4;
    struct EncoderModeReset {
        ~EncoderModeReset() {
            macrdp_vt_h264_encoder_set_enabled(1);
            macrdp_vt_h264_encoder_set_key_frame_interval(0);
        }
    } reset;

    macrdp_vt_h264_encoder_set_enabled(1);
    macrdp_vt_h264_encoder_set_key_frame_interval(10);
    H264_CONTEXT* encoder = h264_context_new(TRUE);
    if (encoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 16'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 30)
        || !h264_context_reset(encoder, width, height)) {
        h264_context_free(encoder);
        std::fprintf(stderr, "Unable to initialize 1080p H.264 encoder\n");
        return false;
    }

    const RECTANGLE_16 full_region = {0, 0, width, height};
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    bool ok = true;
    for (std::uint32_t frame_index = 0; frame_index < 2; ++frame_index) {
        fill_frame(frame, width, height, frame_index + 100);
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
        bool valid_region = meta.numRegionRects > 0 && meta.regionRects != nullptr;
        std::uint32_t left = width;
        std::uint32_t top = height;
        std::uint32_t right = 0;
        std::uint32_t bottom = 0;
        for (std::uint32_t index = 0; valid_region && index < meta.numRegionRects; ++index) {
            const auto& region = meta.regionRects[index];
            valid_region = region.left < region.right
                && region.top < region.bottom
                && region.right <= width
                && region.bottom <= height;
            left = std::min<std::uint32_t>(left, region.left);
            top = std::min<std::uint32_t>(top, region.top);
            right = std::max<std::uint32_t>(right, region.right);
            bottom = std::max<std::uint32_t>(bottom, region.bottom);
        }
        valid_region = valid_region
            && left == 0 && top == 0 && right == width && bottom == height;
        const bool valid_frame_type = frame_index == 0
            ? has_nal_type(encoded, encoded_size, 5)
            : has_nal_type(encoded, encoded_size, 1);
        if (result <= 0 || encoded_size == 0 || !valid_region || !valid_frame_type
            || (frame_index == 0
                && !verify_rdp_sps_dimensions(
                    encoded, encoded_size, width, height, "1080p VideoToolbox"))) {
            std::fprintf(stderr,
                         "1080p RDP H.264 frame %u failed codec-surface validation\n",
                         frame_index);
            ok = false;
        }
        free_h264_metablock(&meta);
        if (!ok) {
            break;
        }
    }
    h264_context_free(encoder);
    if (ok) {
        std::printf(
            "1080p H.264 stream produced cropped 1920x1080 IDR/P frames "
            "in a 1920x1088 coded surface\n");
    }
    return ok;
}

bool verify_openh264_rdp_stream() {
    constexpr std::uint32_t width = 1920;
    constexpr std::uint32_t height = 1080;
    constexpr std::uint32_t stride = width * 4;
    struct BackendReset {
        ~BackendReset() {
            macrdp_h264_encoder_set_backend(MACRDP_H264_BACKEND_FFMPEG);
            macrdp_vt_h264_encoder_set_enabled(1);
            macrdp_vt_h264_encoder_set_key_frame_interval(0);
        }
    } reset;

    macrdp_h264_encoder_set_backend(MACRDP_H264_BACKEND_OPENH264);
    macrdp_vt_h264_encoder_set_enabled(0);
    macrdp_vt_h264_encoder_set_key_frame_interval(10);
    H264_CONTEXT* encoder = h264_context_new(TRUE);
    H264_CONTEXT* decoder = h264_context_new(FALSE);
    if (encoder == nullptr || decoder == nullptr
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_RATECONTROL,
                                    H264_RATECONTROL_VBR)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_BITRATE, 16'000'000)
        || !h264_context_set_option(encoder, H264_CONTEXT_OPTION_FRAMERATE, 5)
        || !h264_context_reset(encoder, width, height)
        || !h264_context_reset(decoder, width, height)) {
        h264_context_free(encoder);
        h264_context_free(decoder);
        std::fprintf(stderr, "Unable to initialize the OpenH264 RDP stream test\n");
        return false;
    }

    const RECTANGLE_16 full_region = {0, 0, width, height};
    std::vector<std::uint8_t> frame(static_cast<std::size_t>(stride) * height);
    std::vector<std::uint8_t> decoded(static_cast<std::size_t>(stride) * height);
    bool ok = true;
    for (std::uint32_t frame_index = 0; frame_index < 12; ++frame_index) {
        fill_frame(frame, width, height, frame_index + 200);
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
        const bool expected_idr = frame_index % 10 == 0;
        const bool has_idr = has_nal_type(encoded, encoded_size, 5);
        const bool has_inter = has_nal_type(encoded, encoded_size, 1);
        const bool valid_type = expected_idr ? has_idr : has_inter;
        const bool valid_sps = !expected_idr
            || (has_constrained_baseline_sps(encoded, encoded_size)
                && verify_rdp_sps_dimensions(
                    encoded, encoded_size, width, height, "OpenH264"));
        int decode_result = -1;
        bool pixels_close = false;
        if (result > 0 && encoded_size > 0 && valid_type && valid_sps) {
            decode_result = avc420_decompress(
                decoder,
                encoded,
                encoded_size,
                decoded.data(),
                PIXEL_FORMAT_BGRX32,
                stride,
                width,
                height,
                meta.regionRects,
                meta.numRegionRects);
            if (decode_result >= 0) {
                pixels_close = frame_is_close(
                    decoded, frame, width, height, frame_index);
            }
        }
        if (result <= 0 || encoded_size == 0 || !valid_type || !valid_sps
            || decode_result < 0 || !pixels_close) {
            std::fprintf(stderr,
                         "OpenH264 RDP frame %u details: result=%d size=%u "
                         "idr=%d inter=%d decode=%d rects=%u\n",
                         frame_index,
                         result,
                         encoded_size,
                         has_idr,
                         has_inter,
                         decode_result,
                         meta.numRegionRects);
            std::fprintf(stderr, "OpenH264 RDP frame %u failed validation\n", frame_index);
            ok = false;
        }
        free_h264_metablock(&meta);
        if (!ok) {
            break;
        }
    }

    h264_context_free(encoder);
    h264_context_free(decoder);
    if (ok) {
        std::printf("OpenH264 produced 12 validated 1080p IDR/P frames across keyint 10\n");
    }
    return ok;
}

} // namespace

int main() {
    constexpr std::uint32_t width = 320;
    constexpr std::uint32_t height = 180;
    constexpr std::uint32_t stride = width * 4;

    macrdp_h264_encoder_set_backend(MACRDP_H264_BACKEND_FFMPEG);

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
            && !has_constrained_baseline_sps(encoded, encoded_size)) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
            std::fprintf(stderr,
                         "FreeRDP H.264 first packet was not Constrained Baseline profile\n");
            return 1;
        }
        if (output_count == 1
            && !verify_rdp_sps_dimensions(
                encoded, encoded_size, width, height, "Direct VideoToolbox")) {
            free_h264_metablock(&meta);
            h264_context_free(encoder);
            h264_context_free(decoder);
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
    return verify_avc444(width, height, stride)
            && verify_ffmpeg_inter_frames(width, height, stride)
            && verify_1080p_rdp_surface()
            && verify_openh264_rdp_stream()
            && verify_all_idr(width, height, stride, true)
            && verify_all_idr(width, height, stride, false)
        ? 0
        : 1;
}
