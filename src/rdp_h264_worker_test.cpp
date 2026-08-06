#include "macrdp/rdp_h264_worker.h"

#include "shadow_encoder.h"

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
    return ok ? 0 : 1;
}
