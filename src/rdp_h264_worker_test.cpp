#include "macrdp/rdp_h264_worker.h"
#include "macrdp/videotoolbox_h264.h"

#include "shadow_encoder.h"

#include <freerdp/codec/h264.h>

#include <cstdint>
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

void fill_region(std::vector<BYTE>& frame, UINT32 width, const RECTANGLE_16& region) {
    for (UINT32 y = region.top; y < region.bottom; ++y) {
        for (UINT32 x = region.left; x < region.right; ++x) {
            auto* pixel = frame.data() + (static_cast<std::size_t>(y) * width + x) * 4U;
            pixel[0] = 0x20;
            pixel[1] = 0xD8;
            pixel[2] = 0x38;
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

bool run_videotoolbox_metadata_test() {
    constexpr UINT16 width = 320;
    constexpr UINT16 height = 180;
    constexpr UINT32 stride = static_cast<UINT32>(width) * 4U;
    const RECTANGLE_16 full_region{0, 0, width, height};
    const RECTANGLE_16 changed_region{32, 24, 128, 96};

    macrdp_vt_h264_encoder_set_enabled(1);
    H264_CONTEXT* h264 = h264_context_new(TRUE);
    if (!expect(h264 != nullptr, "unable to allocate the VideoToolbox H.264 context")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_RATECONTROL, H264_RATECONTROL_VBR),
                   "unable to configure H.264 rate control")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_BITRATE, 4'000'000),
                   "unable to configure H.264 bitrate")
        || !expect(h264_context_set_option(
                       h264, H264_CONTEXT_OPTION_FRAMERATE, 30),
                   "unable to configure H.264 frame rate")
        || !expect(h264_context_reset(h264, width, height),
                   "unable to initialize the VideoToolbox H.264 context")) {
        h264_context_free(h264);
        return false;
    }

    rdpShadowEncoder encoder{};
    encoder.h264 = h264;
    macrdp_h264_worker* worker = macrdp_h264_worker_new(&encoder);
    if (!expect(worker != nullptr, "unable to allocate the VideoToolbox worker")) {
        h264_context_free(h264);
        return false;
    }

    std::vector<BYTE> frame(static_cast<std::size_t>(stride) * height);
    fill_frame(frame, width, height);
    bool ok = true;
    for (UINT32 frame_index = 0; frame_index < 2; ++frame_index) {
        if (frame_index == 1) {
            fill_region(frame, width, changed_region);
        }
        const int submit_status = macrdp_h264_worker_submit(
            worker, frame.data(), frame.size(), stride, width, height,
            PIXEL_FORMAT_BGRX32, RDPGFX_CODECID_AVC420, &full_region);
        if (!expect(submit_status == 1, "VideoToolbox worker rejected a frame")
            || !expect(macrdp_h264_worker_wait_idle(worker) == TRUE,
                       "VideoToolbox worker did not become idle")) {
            ok = false;
            break;
        }

        macrdp_h264_encoded_frame result{};
        const int take_status = macrdp_h264_worker_take(worker, &result);
        ok = expect(take_status == 1, "VideoToolbox worker did not produce a packet") && ok;
        if (take_status == 1) {
            ok = expect_full_frame_metadata(result, width, height) && ok;
        }
        macrdp_h264_encoded_frame_free(&result);
        if (!ok) {
            break;
        }
    }

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
    return ok ? 0 : 1;
}
