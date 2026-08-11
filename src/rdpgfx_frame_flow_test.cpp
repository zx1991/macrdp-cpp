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
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 27, 0, 11410);
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
    macrdp_rdpgfx_frame_flow_observe_output(&flow, FALSE, 0, 16000000, 13760);
    macrdp_rdpgfx_frame_flow_observe_output(&flow, FALSE, 0, 16000000, 14000);
    macrdp_rdpgfx_frame_flow_get_stats(&flow, 14000, &stats);
    ok = expect(stats.ack_stalls == 1 && stats.oldest_outstanding_ms == 990,
                "a stalled acknowledgement was not counted exactly once") && ok;
    macrdp_rdpgfx_frame_flow_acknowledge(&flow, 29, 0, 14010);

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
    ok = expect(pressure_flow.window_size == 1 && pressure_flow.window_demotions == 1
                    && pressure_flow.demotions_output_blocked == 1,
                "blocked transport did not demote the frame window") && ok;

    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, FALSE, 0, 16000000, 23010);
    for (UINT32 frame_id = 13; frame_id <= 24; frame_id++) {
        const UINT64 sent_at = 24000 + frame_id * 200;
        ok = expect(macrdp_rdpgfx_frame_flow_reserve(
                        &pressure_flow, frame_id, sent_at) == TRUE,
                    "a queue-pressure test reservation failed") && ok;
        macrdp_rdpgfx_frame_flow_sent(&pressure_flow, frame_id, 8000, sent_at);
        macrdp_rdpgfx_frame_flow_acknowledge(
            &pressure_flow, frame_id, 0, sent_at + 150);
    }
    ok = expect(pressure_flow.window_size == 2,
                "the queue-pressure test window did not promote") && ok;
    macrdp_rdpgfx_frame_flow_observe_output(
        &pressure_flow, FALSE, 1000000, 16000000, 29000);
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
                "the decoder-queue demotion frame reservation failed") && ok;
    macrdp_rdpgfx_frame_flow_sent(&queue_depth_flow, 13, 8000, 33010);
    macrdp_rdpgfx_frame_flow_acknowledge(&queue_depth_flow, 13, 2, 33160);
    ok = expect(queue_depth_flow.window_size == 1
                    && queue_depth_flow.demotions_queue_depth == 1,
                "decoder queue pressure did not record its demotion reason") && ok;

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
        &stall_flow, FALSE, 0, 16000000, 37760);
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
