#include "macrdp/rdpgfx_frame_flow.h"

#include <freerdp/channels/rdpgfx.h>

#include <iostream>

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

} // namespace

int main() {
    bool ok = true;
    macrdp_rdpgfx_frame_flow flow{};
    macrdp_rdpgfx_frame_flow_stats stats{};
    macrdp_rdpgfx_frame_flow_init(&flow);

    ok = expect(macrdp_rdpgfx_h264_window_full(&flow, QUEUE_DEPTH_UNAVAILABLE) == FALSE,
                "an empty H.264 frame window was reported full") && ok;
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 1, 1000) == TRUE,
                "the first H.264 frame reservation failed") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(&flow, QUEUE_DEPTH_UNAVAILABLE) == TRUE,
                "a reserved H.264 frame did not close the initial window") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(&flow, SUSPEND_FRAME_ACKNOWLEDGEMENT) == FALSE,
                "suspended frame acknowledgements blocked H.264 output") && ok;

    macrdp_rdpgfx_frame_flow_sent(&flow, 1, 8000, 1010);
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 1, 0, 1160);
    macrdp_rdpgfx_frame_flow_get_stats(&flow, 1160, &stats);
    ok = expect(stats.window_size == 1 && stats.active_frames == 0,
                "an acknowledged H.264 frame kept the initial window closed") && ok;
    ok = expect(stats.acknowledged_frames == 1 && stats.average_ack_latency_ms == 150,
                "the first frame acknowledgement metrics are incorrect") && ok;
    ok = expect(stats.encoded_bytes == 8000 && stats.average_frame_bytes == 8000
                    && stats.sent_fps_milli == 6666
                    && stats.effective_bitrate_bps == 426666,
                "the initial frame rate or bitrate metrics are incorrect") && ok;

    for (UINT32 frame_id = 2; frame_id <= 12; frame_id++) {
        const UINT64 sent_at = 1000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, frame_id, sent_at) == TRUE,
                    "a stable frame reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(&flow, frame_id, 0, sent_at + 150);
    }
    macrdp_rdpgfx_frame_flow_get_stats(&flow, 3550, &stats);
    ok = expect(stats.window_size == 2 && stats.window_promotions == 1,
                "stable acknowledgements did not promote the frame window") && ok;

    macrdp_rdpgfx_frame_flow windows_startup_flow{};
    macrdp_rdpgfx_frame_flow_init(&windows_startup_flow);
    constexpr UINT64 windows_startup_ack_ms[] = {1117, 432, 386, 445};
    for (UINT32 frame_id = 1; frame_id <= 4; frame_id++) {
        const UINT64 sent_at = 12000 + frame_id * 1500;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &windows_startup_flow, frame_id, sent_at) == TRUE,
                    "a high-latency Windows startup reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(
            &windows_startup_flow, frame_id, 120000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &windows_startup_flow, frame_id, 0,
            sent_at + windows_startup_ack_ms[frame_id - 1]);
    }
    ok = expect(windows_startup_flow.window_size == 2
                    && windows_startup_flow.window_promotions == 1,
                "healthy stop-and-wait Windows ACKs did not open the initial pipeline") && ok;

    macrdp_rdpgfx_frame_flow failed_probe_flow{};
    macrdp_rdpgfx_frame_flow_init(&failed_probe_flow);
    constexpr UINT64 failed_probe_ack_ms[] = {500, 500, 500, 1300, 500, 500, 500};
    for (UINT32 frame_id = 1; frame_id <= 7; frame_id++) {
        const UINT64 sent_at = 20000 + frame_id * 1500;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &failed_probe_flow, frame_id, sent_at) == TRUE,
                    "a failed initial-probe reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&failed_probe_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &failed_probe_flow, frame_id, 0,
            sent_at + failed_probe_ack_ms[frame_id - 1]);
    }
    ok = expect(failed_probe_flow.window_size == 1
                    && failed_probe_flow.window_promotions == 0,
                "an interrupted initial probe opened the frame pipeline") && ok;
    for (UINT32 frame_id = 8; frame_id <= 11; frame_id++) {
        const UINT64 sent_at = 33000 + (frame_id - 8) * 1000;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &failed_probe_flow, frame_id, sent_at) == TRUE,
                    "a restarted initial-probe reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&failed_probe_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &failed_probe_flow, frame_id, 0, sent_at + 500);
    }
    ok = expect(failed_probe_flow.window_size == 2
                    && failed_probe_flow.window_promotions == 1,
                "four fresh healthy ACKs did not complete the restarted initial probe") && ok;

    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 13, 4000) == TRUE &&
                    macrdp_rdpgfx_frame_flow_reserve(&flow, 14, 4010) == TRUE,
                "the promoted window did not accept two reservations") && ok;
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 15, 4015) == FALSE,
                "the promoted window accepted an unbounded reservation") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(&flow, 0) == TRUE,
                "two reservations did not close the promoted window") && ok;
    macrdp_rdpgfx_frame_flow_sent(&flow, 13, 6000, 4020);
    macrdp_rdpgfx_frame_flow_sent(&flow, 14, 7000, 4030);
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 14, 0, 4180);
    macrdp_rdpgfx_frame_flow_get_stats(&flow, 4180, &stats);
    ok = expect(stats.active_frames == 0 && stats.acknowledged_frames == 14,
                "a cumulative acknowledgement did not release both frames") && ok;

    for (UINT32 frame_id = 15; frame_id <= 26; frame_id++) {
        const UINT64 sent_at = 5000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, frame_id, sent_at) == TRUE,
                    "a second stable frame reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(&flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(flow.window_size == 2, "the frame window did not promote a second time") && ok;
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 27, 11000) == TRUE,
                "the slow frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&flow, 27, 8000, 11010);
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 27, 0, 12610);
    ok = expect(flow.window_size == 1 && flow.window_demotions == 1
                    && flow.demotions_ack_latency == 1,
                "a slow acknowledgement did not demote the frame window") && ok;

    macrdp_rdpgfx_frame_flow_release(&flow, 99);
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 28, 12000) == TRUE,
                "the releasable frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_release(&flow, 28);
    ok = expect(macrdp_rdpgfx_h264_window_full(&flow, 0) == FALSE,
                "releasing an empty encoder result kept the frame window closed") && ok;

    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&flow, 29, 13000) == TRUE,
                "the stalled frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&flow, 29, 9000, 13010);
    macrdp_rdpgfx_frame_flow_observe_output(&flow, FALSE, 0, 16000000, 15510);
    macrdp_rdpgfx_frame_flow_observe_output(&flow, FALSE, 0, 16000000, 16000);
    macrdp_rdpgfx_frame_flow_get_stats(&flow, 16000, &stats);
    ok = expect(stats.ack_stalls == 1 && stats.oldest_outstanding_ms == 2990,
                "a stalled acknowledgement was not counted exactly once") && ok;
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 29, 0, 16010);

    macrdp_rdpgfx_frame_flow pressure_flow{};
    macrdp_rdpgfx_frame_flow_init(&pressure_flow);
    for (UINT32 frame_id = 1; frame_id <= 12; frame_id++) {
        const UINT64 sent_at = 20000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &pressure_flow, frame_id, sent_at) == TRUE,
                    "a transport-pressure test reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&pressure_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &pressure_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(pressure_flow.window_size == 2,
                "the transport-pressure test window did not promote") && ok;
    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, TRUE, 0, 16000000, 23000);
    ok = expect(pressure_flow.window_size == 2 && pressure_flow.window_demotions == 0,
                "a transient blocked write demoted the frame window") && ok;
    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, TRUE, 0, 16000000, 24501);
    ok = expect(pressure_flow.window_size == 1 && pressure_flow.window_demotions == 1
                    && pressure_flow.demotions_output_blocked == 1,
                "sustained blocked transport did not demote the frame window") && ok;

    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, FALSE, 0, 16000000, 24510);
    for (UINT32 frame_id = 13; frame_id <= 24; frame_id++) {
        const UINT64 sent_at = 24000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &pressure_flow, frame_id, sent_at) == TRUE,
                    "a queue-pressure test reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&pressure_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &pressure_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(pressure_flow.window_size == 1,
                "the frame window ignored its post-demotion promotion cooldown") && ok;
    for (UINT32 frame_id = 25; frame_id <= 30; frame_id++) {
        const UINT64 sent_at = 29600 + (frame_id - 25) * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &pressure_flow, frame_id, sent_at) == TRUE,
                    "a post-cooldown frame reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&pressure_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &pressure_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(pressure_flow.window_size == 2,
                "the frame window did not promote after its cooldown") && ok;
    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, FALSE, 1000000, 16000000, 31000);
    ok = expect(pressure_flow.window_size == 1 && pressure_flow.window_demotions == 2
                    && pressure_flow.demotions_queue_pressure == 1,
                "transport queue pressure did not demote the frame window") && ok;

    macrdp_rdpgfx_frame_flow queue_depth_flow{};
    macrdp_rdpgfx_frame_flow_init(&queue_depth_flow);
    for (UINT32 frame_id = 1; frame_id <= 12; frame_id++) {
        const UINT64 sent_at = 30000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &queue_depth_flow, frame_id, sent_at) == TRUE,
                    "a decoder-queue test reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&queue_depth_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &queue_depth_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                    &queue_depth_flow, 13, 33000) == TRUE,
                "the small client-queue frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&queue_depth_flow, 13, 8000, 33010);
    macrdp_rdpgfx_frame_flow_acknowledge(&queue_depth_flow, 13, 12000, 33160);
    macrdp_rdpgfx_frame_flow_get_stats(&queue_depth_flow, 33160, &stats);
    ok = expect(queue_depth_flow.window_size == 2
                    && queue_depth_flow.demotions_queue_depth == 0
                    && stats.last_client_queue_bytes == 12000
                    && stats.max_client_queue_bytes == 12000
                    && stats.client_queue_reports == 1,
                "a sub-threshold client queue report caused a demotion") && ok;

    ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                    &queue_depth_flow, 14, 33200) == TRUE,
                "the client-queue demotion frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&queue_depth_flow, 14, 8000, 33210);
    macrdp_rdpgfx_frame_flow_acknowledge(&queue_depth_flow, 14, 16384, 33360);
    macrdp_rdpgfx_frame_flow_get_stats(&queue_depth_flow, 33360, &stats);
    ok = expect(queue_depth_flow.window_size == 1
                    && queue_depth_flow.demotions_queue_depth == 1
                    && stats.last_client_queue_bytes == 16384
                    && stats.max_client_queue_bytes == 16384
                    && stats.client_queue_demotion_threshold_bytes == 16384
                    && stats.client_queue_reports == 2,
                "client buffered-byte pressure was not measured or attributed") && ok;

    ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                    &queue_depth_flow, 15, 33400) == TRUE,
                "the unavailable client-queue frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&queue_depth_flow, 15, 8000, 33410);
    macrdp_rdpgfx_frame_flow_acknowledge(
        &queue_depth_flow, 15, QUEUE_DEPTH_UNAVAILABLE, 33560);
    macrdp_rdpgfx_frame_flow_get_stats(&queue_depth_flow, 33560, &stats);
    ok = expect(stats.last_client_queue_bytes == QUEUE_DEPTH_UNAVAILABLE
                    && stats.max_client_queue_bytes == 16384
                    && stats.client_queue_reports == 2,
                "an unavailable queue report retained a stale current byte count") && ok;

    macrdp_rdpgfx_frame_flow large_frame_flow{};
    macrdp_rdpgfx_frame_flow_init(&large_frame_flow);
    for (UINT32 frame_id = 1; frame_id <= 6; frame_id++) {
        const UINT64 sent_at = 45000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &large_frame_flow, frame_id, sent_at) == TRUE,
                    "a large-frame reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&large_frame_flow, frame_id, 80000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &large_frame_flow, frame_id, 0, sent_at + 150);
    }
    macrdp_rdpgfx_frame_flow_get_stats(&large_frame_flow, 46400, &stats);
    ok = expect(large_frame_flow.window_size == 2
                    && stats.client_queue_demotion_threshold_bytes == 160000,
                "the decoder queue threshold was capped below two average frames") && ok;
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                    &large_frame_flow, 7, 46500) == TRUE,
                "the sub-threshold large-frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&large_frame_flow, 7, 80000, 46500);
    macrdp_rdpgfx_frame_flow_acknowledge(&large_frame_flow, 7, 100000, 46650);
    ok = expect(large_frame_flow.window_size == 2,
                "less than two average frames of decoder queue caused a demotion") && ok;
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                    &large_frame_flow, 8, 46700) == TRUE,
                "the above-threshold large-frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&large_frame_flow, 8, 80000, 46700);
    macrdp_rdpgfx_frame_flow_acknowledge(&large_frame_flow, 8, 200000, 46850);
    ok = expect(large_frame_flow.window_size == 1
                    && large_frame_flow.demotions_queue_depth == 1,
                "more than two average frames of decoder queue did not demote") && ok;

    macrdp_rdpgfx_frame_flow stall_flow{};
    macrdp_rdpgfx_frame_flow_init(&stall_flow);
    for (UINT32 frame_id = 1; frame_id <= 12; frame_id++) {
        const UINT64 sent_at = 34000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &stall_flow, frame_id, sent_at) == TRUE,
                    "an ACK-stall test reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&stall_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &stall_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&stall_flow, 13, 37000) == TRUE,
                "the ACK-stall demotion frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&stall_flow, 13, 8000, 37010);
    macrdp_rdpgfx_frame_flow_observe_output(
        &stall_flow, FALSE, 0, 16000000, 39510);
    ok = expect(stall_flow.window_size == 1 && stall_flow.ack_stalls == 1
                    && stall_flow.demotions_ack_stall == 1,
                "an ACK stall did not record its demotion reason") && ok;

    macrdp_rdpgfx_frame_flow wrap_flow{};
    macrdp_rdpgfx_frame_flow_init(&wrap_flow);
    ok = expect(macrdp_rdpgfx_frame_flow_reserve(&wrap_flow, UINT32_MAX, 30000) == TRUE,
                "the wrapped frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&wrap_flow, UINT32_MAX, 8000, 30010);
    macrdp_rdpgfx_frame_flow_acknowledge(&wrap_flow, 0, 0, 30160);
    macrdp_rdpgfx_frame_flow_get_stats(&wrap_flow, 30160, &stats);
    ok = expect(stats.active_frames == 0 && stats.acknowledged_frames == 1,
                "a wrapped cumulative acknowledgement did not release its frame") && ok;

    ok = expect(macrdp_rdpgfx_frame_id_should_advance(UINT32_MAX, 0) == TRUE,
                "frame identifier wrap was not treated as forward progress") && ok;
    ok = expect(macrdp_rdpgfx_frame_id_should_advance(10, 9) == FALSE,
                "a stale frame acknowledgement was treated as forward progress") && ok;

    return ok ? 0 : 1;
}
