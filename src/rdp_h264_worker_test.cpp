#include "macrdp/rdp_h264_worker.h"
#include "macrdp/videotoolbox_h264.h"

#include "shadow_encoder.h"

#include <freerdp/codec/h264.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

bool has_nal_type(const BYTE* data, std::size_t size, BYTE type) {
    if (data == nullptr) {
        return false;
    }
    for (std::size_t index = 0; index + 4 < size; ++index) {
        std::size_t nal_offset = 0;
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            nal_offset = index + 3;
        } else if (index + 5 < size && data[index] == 0 && data[index + 1] == 0
                   && data[index + 2] == 0 && data[index + 3] == 1) {
            nal_offset = index + 4;
        } else {
            continue;
        }
        if ((data[nal_offset] & 0x1FU) == type) {
            return true;
        }
    }
    return false;
}

bool run_worker_failure_cycle(macrdp_h264_worker* worker, const std::vector<BYTE>& frame,
                              const RECTANGLE_16& region) {
    const int submit_status = macrdp_h264_worker_submit(
        worker,
        frame.data(),
        frame.size(),
        16,
        4,
        4,
        PIXEL_FORMAT_BGRX32,
        RDPGFX_CODECID_AVC420,
        &region);
    if (!expect(submit_status == 1, "worker did not accept a valid job")) {
        return false;
    }
    if (!expect(macrdp_h264_worker_wait_idle(worker) == TRUE,
                "worker did not become idle")) {
        return false;
    }

    macrdp_h264_encoded_frame result{};
    const int take_status = macrdp_h264_worker_take(worker, &result);
    const bool valid = expect(take_status == -1, "invalid encoder job did not fail")
        && expect(result.failed == TRUE, "worker failure result was not marked failed")
        && expect(result.width == 4 && result.height == 4,
                  "worker failure result lost frame dimensions")
        && expect(macrdp_h264_worker_busy(worker) == FALSE,
                  "worker remained busy after taking a result");
    macrdp_h264_encoded_frame_free(&result);
    return valid;
}

bool expect_worker_stats(const macrdp_h264_worker* worker, UINT64 expected_jobs) {
    macrdp_h264_worker_stats stats{};
    macrdp_h264_worker_get_stats(worker, &stats);
    return expect(stats.submitted == expected_jobs,
                  "worker statistics reported the wrong submission count")
        && expect(stats.completed == expected_jobs,
                  "worker statistics reported the wrong completion count")
        && expect(stats.encodeTimeMsTotal >= stats.lastEncodeTimeMs,
                  "worker statistics reported an invalid total encode time")
        && expect(stats.encodeTimeMsMax >= stats.lastEncodeTimeMs,
                   "worker statistics reported an invalid maximum encode time")
        && expect(stats.outputBytes == 0,
                   "failed worker jobs unexpectedly reported encoded output");
}

void fill_frame(std::vector<BYTE>& frame, UINT32 width, UINT32 height) {
    for (UINT32 y = 0; y < height; ++y) {
        for (UINT32 x = 0; x < width; ++x) {
            auto* pixel = frame.data() + (static_cast<std::size_t>(y) * width + x) * 4U;
            pixel[0] = static_cast<BYTE>(x & 0xFFU);
            pixel[1] = static_cast<BYTE>(y & 0xFFU);
            pixel[2] = static_cast<BYTE>((x + y) & 0xFFU);
            pixel[3] = 0xFF;
        }
    }
}

void fill_region(std::vector<BYTE>& frame, UINT32 width, const RECTANGLE_16& region,
                 UINT32 frame_index) {
    for (UINT32 y = region.top; y < region.bottom; ++y) {
        for (UINT32 x = region.left; x < region.right; ++x) {
            auto* pixel = frame.data() + (static_cast<std::size_t>(y) * width + x) * 4U;
            pixel[0] = static_cast<BYTE>(0x20U + frame_index * 13U);
            pixel[1] = static_cast<BYTE>(0xD8U - frame_index * 7U);
            pixel[2] = static_cast<BYTE>(0x38U + frame_index * 17U);
            pixel[3] = 0xFF;
        }
    }
}

bool expect_full_frame_metadata(const macrdp_h264_encoded_frame& result,
                                UINT16 width, UINT16 height) {
    const auto& meta = result.avc420.meta;
    if (!expect(result.codecId == RDPGFX_CODECID_AVC420,
                "worker returned the wrong codec")
        || !expect(result.hasData == TRUE && result.avc420.data != nullptr
                       && result.avc420.length > 0,
                   "VideoToolbox worker returned no AVC420 packet")
        || !expect(meta.numRegionRects == 1 && meta.regionRects != nullptr
                       && meta.quantQualityVals != nullptr,
                   "AVC420 output did not contain one metadata rectangle")) {
        return false;
    }

    const RECTANGLE_16& region = meta.regionRects[0];
    return expect(region.left == 0 && region.top == 0
                      && region.right == width && region.bottom == height,
                  "AVC420 metadata did not cover the complete desktop");
}

bool frame_is_close(const std::vector<BYTE>& decoded,
                    const std::vector<BYTE>& expected,
                    UINT32 width,
                    UINT32 height) {
    std::uint64_t total_error = 0;
    std::uint64_t severe_pixels = 0;
    const auto pixel_count = static_cast<std::uint64_t>(width) * height;
    for (std::uint64_t pixel_index = 0; pixel_index < pixel_count; ++pixel_index) {
        unsigned maximum_error = 0;
        for (std::size_t channel = 0; channel < 3; ++channel) {
            const auto offset = static_cast<std::size_t>(pixel_index) * 4U + channel;
            const auto error = static_cast<unsigned>(std::abs(
                static_cast<int>(decoded[offset]) - static_cast<int>(expected[offset])));
            total_error += error;
            maximum_error = std::max(maximum_error, error);
        }
        severe_pixels += maximum_error > 64U;
    }
    const double mean_error = static_cast<double>(total_error)
        / static_cast<double>(pixel_count * 3U);
    const auto severe_limit = std::max<std::uint64_t>(1, pixel_count / 50U);
    if (mean_error > 12.0 || severe_pixels > severe_limit) {
        std::cerr << "worker AVC420 reconstruction differs from the assembled desktop "
                  << "(mean error " << mean_error << ", severe pixels "
                  << severe_pixels << '/' << pixel_count << ")\n";
        return false;
    }
    return true;
}

bool run_videotoolbox_metadata_test() {
    constexpr UINT16 width = 1920;
    constexpr UINT16 height = 1080;
    constexpr UINT32 stride = static_cast<UINT32>(width) * 4U;
    const RECTANGLE_16 full_region{0, 0, width, height};
    constexpr RECTANGLE_16 changed_regions[] = {
        {32, 24, 256, 192},
        {640, 360, 960, 640},
        {1536, 800, 1888, 1056},
    };

    macrdp_vt_h264_encoder_set_enabled(1);
    macrdp_vt_h264_encoder_set_key_frame_interval(10);
    H264_CONTEXT* h264 = h264_context_new(TRUE);
    if (!expect(h264 != nullptr, "unable to allocate the VideoToolbox H.264 context")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_RATECONTROL, H264_RATECONTROL_VBR),
                   "unable to configure H.264 rate control")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_BITRATE, 16'000'000),
                   "unable to configure H.264 bitrate")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_FRAMERATE, 5),
                   "unable to configure H.264 frame rate")
        || !expect(h264_context_reset(h264, width, height),
                   "unable to initialize the VideoToolbox H.264 context")) {
        h264_context_free(h264);
        return false;
    }

    rdpShadowEncoder encoder{};
    encoder.h264 = h264;
    H264_CONTEXT* decoder = h264_context_new(FALSE);
    if (!expect(decoder != nullptr
                    && h264_context_reset(decoder, width, height),
                "unable to initialize the worker H.264 decoder")) {
        h264_context_free(decoder);
        h264_context_free(h264);
        return false;
    }
    macrdp_h264_worker* worker = macrdp_h264_worker_new(&encoder);
    if (!expect(worker != nullptr, "unable to allocate the VideoToolbox worker")) {
        h264_context_free(decoder);
        h264_context_free(h264);
        return false;
    }
    if (!expect(macrdp_h264_worker_set_targets(worker, 2'000'000, 3) == TRUE,
                "worker rejected adaptive H.264 targets")) {
        macrdp_h264_worker_free(worker);
        h264_context_free(decoder);
        h264_context_free(h264);
        return false;
    }

    std::vector<BYTE> frame(static_cast<std::size_t>(stride) * height);
    std::vector<BYTE> decoded(static_cast<std::size_t>(stride) * height);
    fill_frame(frame, width, height);
    bool ok = true;
    for (UINT32 frame_index = 0; frame_index < 12; ++frame_index) {
        const auto& changed_region =
            changed_regions[(frame_index == 0 ? 0 : frame_index - 1)
                            % std::size(changed_regions)];
        if (frame_index > 0) {
            fill_region(frame, width, changed_region, frame_index);
        }
        const RECTANGLE_16& submitted_region =
            frame_index == 0 ? full_region : changed_region;
        const int submit_status = macrdp_h264_worker_submit(
            worker, frame.data(), frame.size(), stride, width, height,
            PIXEL_FORMAT_BGRX32, RDPGFX_CODECID_AVC420, &submitted_region);
        if (!expect(submit_status == 1, "VideoToolbox worker rejected a frame")
            || !expect(macrdp_h264_worker_wait_idle(worker) == TRUE,
                       "VideoToolbox worker did not become idle")) {
            ok = false;
            break;
        }

        macrdp_h264_encoded_frame result{};
        const int take_status = macrdp_h264_worker_take(worker, &result);
        if (take_status != 1) {
            std::cerr << "VideoToolbox worker did not produce packet for frame "
                      << frame_index << " (status " << take_status << ")\n";
            ok = false;
        }
        if (take_status == 1) {
            ok = expect(
                     h264_context_get_option(h264, H264_CONTEXT_OPTION_BITRATE) == 2'000'000
                         && h264_context_get_option(
                                h264, H264_CONTEXT_OPTION_FRAMERATE) == 3,
                     "worker did not apply adaptive targets before encoding")
                && ok;
            ok = expect_full_frame_metadata(result, width, height) && ok;
            ok = expect(
                     has_nal_type(
                         result.avc420.data,
                         result.avc420.length,
                         frame_index % 10 == 0 ? 5 : 1),
                     frame_index % 10 == 0
                         ? "worker key-frame boundary was not an IDR frame"
                         : "worker partial update was not a P frame")
                && ok;
            if (avc420_decompress(
                    decoder,
                    result.avc420.data,
                    result.avc420.length,
                    decoded.data(),
                    PIXEL_FORMAT_BGRX32,
                    stride,
                    width,
                    height,
                    result.avc420.meta.regionRects,
                    result.avc420.meta.numRegionRects) < 0) {
                ok = expect(false, "worker AVC420 packet could not be decoded") && ok;
            } else {
                ok = frame_is_close(decoded, frame, width, height) && ok;
            }
        }
        macrdp_h264_encoded_frame_free(&result);
        if (!ok) {
            break;
        }
    }

    macrdp_h264_worker_free(worker);
    h264_context_free(decoder);
    h264_context_free(h264);
    macrdp_vt_h264_encoder_set_key_frame_interval(0);
    return ok;
}

bool run_openh264_adaptive_target_test() {
    constexpr UINT16 width = 1920;
    constexpr UINT16 height = 1080;
    constexpr UINT32 stride = static_cast<UINT32>(width) * 4U;
    const RECTANGLE_16 full_region{0, 0, width, height};
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
    H264_CONTEXT* h264 = h264_context_new(TRUE);
    if (!expect(h264 != nullptr
                    && h264_context_set_option(
                        h264, H264_CONTEXT_OPTION_RATECONTROL, H264_RATECONTROL_VBR)
                    && h264_context_set_option(
                        h264, H264_CONTEXT_OPTION_BITRATE, 2'000'000)
                    && h264_context_set_option(
                        h264, H264_CONTEXT_OPTION_FRAMERATE, 5)
                    && h264_context_reset(h264, width, height),
                "unable to initialize adaptive OpenH264 worker context")) {
        h264_context_free(h264);
        return false;
    }

    rdpShadowEncoder encoder{};
    encoder.h264 = h264;
    macrdp_h264_worker* worker = macrdp_h264_worker_new(&encoder);
    if (!expect(worker != nullptr, "unable to allocate adaptive OpenH264 worker")) {
        h264_context_free(h264);
        return false;
    }

    std::vector<BYTE> frame(static_cast<std::size_t>(stride) * height);
    fill_frame(frame, width, height);
    bool ok = true;
    bool saw_rate_control_skip = false;
    bool saw_output_after_recovery = false;
    for (UINT32 frame_index = 0; frame_index < 24; ++frame_index) {
        if (frame_index == 1) {
            ok = expect(macrdp_h264_worker_set_targets(
                            worker, 1'333'333, 3) == TRUE,
                        "worker rejected reduced OpenH264 targets") && ok;
        } else if (frame_index == 2) {
            ok = expect(macrdp_h264_worker_set_targets(
                            worker, 888'888, 1) == TRUE,
                        "worker rejected severe OpenH264 targets") && ok;
        } else if (frame_index == 12) {
            ok = expect(macrdp_h264_worker_set_targets(
                            worker, 16'000'000, 30) == TRUE,
                        "worker rejected recovered OpenH264 targets") && ok;
        }
        for (std::size_t offset = 0; offset < frame.size(); offset += 4U) {
            frame[offset] = static_cast<BYTE>(frame[offset] + frame_index * 17U);
            frame[offset + 1] = static_cast<BYTE>(frame[offset + 1] + frame_index * 29U);
            frame[offset + 2] = static_cast<BYTE>(frame[offset + 2] + frame_index * 43U);
        }

        const int submit_status = macrdp_h264_worker_submit(
            worker, frame.data(), frame.size(), stride, width, height,
            PIXEL_FORMAT_BGRX32, RDPGFX_CODECID_AVC420, &full_region);
        if (!expect(submit_status == 1, "OpenH264 worker rejected an adaptive frame")
            || !expect(macrdp_h264_worker_wait_idle(worker) == TRUE,
                       "OpenH264 adaptive worker did not become idle")) {
            ok = false;
            break;
        }

        macrdp_h264_encoded_frame result{};
        const int take_status = macrdp_h264_worker_take(worker, &result);
        if (take_status == 0) {
            saw_rate_control_skip = true;
        } else if (take_status > 0 && frame_index >= 12) {
            saw_output_after_recovery = true;
        }
        ok = expect(take_status >= 0,
                    "OpenH264 rate-control skip was reported as an encode failure") && ok;
        macrdp_h264_encoded_frame_free(&result);
        if (!ok) {
            break;
        }
    }
    ok = expect(saw_rate_control_skip,
                "OpenH264 regression did not exercise rate-control skipping") && ok;
    ok = expect(saw_output_after_recovery,
                "OpenH264 did not resume output after adaptive target recovery") && ok;

    macrdp_h264_worker_free(worker);
    h264_context_free(h264);
    return ok;
}

} // namespace

int main() {
    rdpShadowEncoder encoder{};
    macrdp_h264_worker* worker = macrdp_h264_worker_new(&encoder);
    if (!expect(worker != nullptr, "worker allocation failed")
        || !expect(macrdp_h264_worker_event(worker) != nullptr,
                   "worker event was not created")) {
        macrdp_h264_worker_free(worker);
        return 1;
    }

    const std::vector<BYTE> frame(4U * 4U * 4U, 0x7f);
    const RECTANGLE_16 region{0, 0, 4, 4};
    bool ok = true;
    ok = run_worker_failure_cycle(worker, frame, region) && ok;
    ok = expect_worker_stats(worker, 1) && ok;

    const int invalid_status = macrdp_h264_worker_submit(
        worker,
        frame.data(),
        frame.size() - 1,
        16,
        4,
        4,
        PIXEL_FORMAT_BGRX32,
        RDPGFX_CODECID_AVC420,
        &region);
    ok = expect(invalid_status == -1, "short frame was accepted") && ok;

    ok = run_worker_failure_cycle(worker, frame, region) && ok;
    ok = expect_worker_stats(worker, 2) && ok;
    macrdp_h264_worker_free(worker);
    ok = run_videotoolbox_metadata_test() && ok;
    ok = run_openh264_adaptive_target_test() && ok;
    return ok ? 0 : 1;
}
