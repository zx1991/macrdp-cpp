#include "macrdp/video_adaptation.h"

#include <cstdint>
#include <iostream>
#include <limits>
#include <string>

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

macrdp_video_adaptation_observation observation(
    std::uint64_t now_ms,
    std::uint64_t ack_samples,
    std::uint64_t ack_latency_ms) {
    macrdp_video_adaptation_observation value{};
    value.now_ms = now_ms;
    value.acknowledged_samples = ack_samples;
    value.last_ack_latency_ms = ack_latency_ms;
    return value;
}

} // namespace

int main() {
    bool ok = true;
    macrdp_video_adaptation adaptation{};
    macrdp_video_adaptation_init(&adaptation, 16'000'000, 30, 1000);

    ok = expect(adaptation.max_bitrate_bps == 16'000'000
                    && adaptation.current_bitrate_bps == 2'000'000
                    && adaptation.max_fps == 30
                    && adaptation.current_fps == 5,
                "adaptive video did not start conservatively below its ceilings") && ok;
    ok = expect(macrdp_video_adaptation_frame_ready(&adaptation, 1000),
                "the first adaptive frame was incorrectly paced") && ok;
    macrdp_video_adaptation_frame_submitted(&adaptation, 1000);
    ok = expect(!macrdp_video_adaptation_frame_ready(&adaptation, 1199)
                    && macrdp_video_adaptation_frame_wait_ms(&adaptation, 1199) == 1
                    && macrdp_video_adaptation_frame_ready(&adaptation, 1200),
                "per-client frame pacing used the wrong interval") && ok;

    auto transient_blocked = observation(1300, 0, 0);
    transient_blocked.output_blocked = true;
    auto reasons = macrdp_video_adaptation_observe(&adaptation, &transient_blocked);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && adaptation.current_bitrate_bps == 2'000'000
                    && adaptation.current_fps == 5,
                "a transient blocked write reduced adaptive video") && ok;
    transient_blocked.now_ms = 1700;
    reasons = macrdp_video_adaptation_observe(&adaptation, &transient_blocked);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && adaptation.current_bitrate_bps == 2'000'000,
                "a sub-second blocked interval was treated as congestion") && ok;
    auto unblocked = observation(1800, 0, 0);
    reasons = macrdp_video_adaptation_observe(&adaptation, &unblocked);

    constexpr std::uint64_t startup_ack_ms[] = {893, 440, 243, 412};
    for (std::uint64_t sample = 1; sample <= 4; ++sample) {
        auto startup_ack = observation(
            2200 + sample * 500, sample, startup_ack_ms[sample - 1]);
        reasons = macrdp_video_adaptation_observe(&adaptation, &startup_ack);
    }
    ok = expect(adaptation.current_bitrate_bps == 3'000'000
                    && adaptation.current_fps == 7,
                "normal Windows startup ACKs did not recover above the conservative start") && ok;

    auto persistent_blocked = observation(4500, 4, 412);
    persistent_blocked.output_blocked = true;
    reasons = macrdp_video_adaptation_observe(&adaptation, &persistent_blocked);
    persistent_blocked.now_ms = 6600;
    reasons = macrdp_video_adaptation_observe(&adaptation, &persistent_blocked);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED) != 0
                    && adaptation.current_bitrate_bps == 2'000'000
                    && adaptation.current_fps == 6,
                "sustained output blocking did not reduce bitrate and FPS") && ok;
    unblocked = observation(6700, 4, 412);
    reasons = macrdp_video_adaptation_observe(&adaptation, &unblocked);

    auto slow_ack = observation(8500, 5, 2200);
    reasons = macrdp_video_adaptation_observe(&adaptation, &slow_ack);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_ACK_LATENCY) != 0
                    && adaptation.current_fps == 4
                    && adaptation.current_bitrate_bps == 2'000'000,
                "slow ACK did not reduce FPS independently") && ok;

    auto stalled = observation(10500, 5, 2200);
    stalled.ack_stalls = 1;
    reasons = macrdp_video_adaptation_observe(&adaptation, &stalled);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_ACK_STALL) != 0
                    && adaptation.current_bitrate_bps == 1'333'333
                    && adaptation.current_fps == 2,
                "ACK stall did not apply the severe backoff") && ok;

    auto stalled_ack = observation(10600, 6, 2600);
    stalled_ack.ack_stalls = 1;
    reasons = macrdp_video_adaptation_observe(&adaptation, &stalled_ack);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && adaptation.current_bitrate_bps == 1'333'333
                    && adaptation.current_fps == 2,
                "the delayed ACK for a penalized stall caused a second backoff") && ok;

    const auto suppressed_bitrate = adaptation.current_bitrate_bps;
    const auto suppressed_fps = adaptation.current_fps;
    auto suppressed = observation(11500, 7, 5000);
    suppressed.ack_stalls = 2;
    suppressed.output_suppressed = true;
    reasons = macrdp_video_adaptation_observe(&adaptation, &suppressed);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && adaptation.current_bitrate_bps == suppressed_bitrate
                    && adaptation.current_fps == suppressed_fps,
                "client output suppression was treated as network congestion") && ok;

    for (std::uint64_t sample = 8; sample <= 19; ++sample) {
        auto healthy = observation(9000 + sample * 500, sample, 500);
        healthy.ack_stalls = 2;
        reasons = macrdp_video_adaptation_observe(&adaptation, &healthy);
    }
    ok = expect(adaptation.current_bitrate_bps > suppressed_bitrate
                    && adaptation.current_fps == 6,
                "healthy ACKs did not recover bitrate and FPS independently") && ok;

    macrdp_video_adaptation intermittent{};
    macrdp_video_adaptation_init(&intermittent, 16'000'000, 30, 0);
    for (std::uint64_t sample = 1; sample <= 3; ++sample) {
        const auto healthy = observation(sample * 500, sample, 300);
        reasons = macrdp_video_adaptation_observe(&intermittent, &healthy);
    }
    auto intermittent_block = observation(1600, 3, 300);
    intermittent_block.output_blocked = true;
    reasons = macrdp_video_adaptation_observe(&intermittent, &intermittent_block);
    auto first_after_block = observation(4000, 4, 300);
    reasons = macrdp_video_adaptation_observe(&intermittent, &first_after_block);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && intermittent.current_bitrate_bps == 2'000'000
                    && intermittent.current_fps == 5,
                "a transient pressure event preserved stale healthy samples") && ok;
    for (std::uint64_t sample = 5; sample <= 7; ++sample) {
        const auto healthy = observation(2000 + sample * 500, sample, 300);
        reasons = macrdp_video_adaptation_observe(&intermittent, &healthy);
    }
    ok = expect(intermittent.current_bitrate_bps == 3'000'000
                    && intermittent.current_fps == 7,
                "fresh healthy ACKs did not recover after the pressure quiet period") && ok;

    auto queue_pressure = observation(6000, 7, 300);
    queue_pressure.client_queue_pressure = true;
    reasons = macrdp_video_adaptation_observe(&intermittent, &queue_pressure);
    for (std::uint64_t sample = 8; sample <= 15; ++sample) {
        const auto healthy = observation(6000 + (sample - 7) * 500, sample, 300);
        reasons = macrdp_video_adaptation_observe(&intermittent, &healthy);
    }
    ok = expect(intermittent.current_bitrate_bps == 3'000'000
                    && intermittent.current_fps == 7,
                "decoder queue pressure did not hold recovery during its quiet period") && ok;
    for (std::uint64_t sample = 16; sample <= 23; ++sample) {
        const auto healthy = observation(11000 + (sample - 15) * 500, sample, 300);
        reasons = macrdp_video_adaptation_observe(&intermittent, &healthy);
    }
    ok = expect(intermittent.current_bitrate_bps == 3'500'000
                    && intermittent.current_fps == 8,
                "steady recovery did not resume additively after queue pressure") && ok;

    macrdp_video_adaptation encoder_limited{};
    macrdp_video_adaptation_init(&encoder_limited, 16'000'000, 30, 0);
    auto encoder_sample = observation(1000, 0, 0);
    encoder_sample.encoder_completed_frames = 5;
    reasons = macrdp_video_adaptation_observe(&encoder_limited, &encoder_sample);
    encoder_sample.now_ms = 2100;
    encoder_sample.encoder_completed_frames = 15;
    encoder_sample.encoder_no_output_frames = 2;
    reasons = macrdp_video_adaptation_observe(&encoder_limited, &encoder_sample);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_ENCODER_NO_OUTPUT) != 0
                    && encoder_limited.current_bitrate_bps == 2'000'000
                    && encoder_limited.current_fps == 3,
                "sustained encoder no-output did not reduce FPS independently") && ok;
    ok = expect(std::string(macrdp_video_adaptation_reason_name(reasons))
                    == "encoder-no-output",
                "encoder no-output reason was not reported") && ok;
    auto encoder_quiet = observation(2200, 1, 100);
    encoder_quiet.encoder_completed_frames = 16;
    encoder_quiet.encoder_no_output_frames = 2;
    reasons = macrdp_video_adaptation_observe(&encoder_limited, &encoder_quiet);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && encoder_limited.current_fps == 3,
                "encoder pressure did not hold recovery during its quiet period") && ok;

    macrdp_video_adaptation large_encoder_counters{};
    macrdp_video_adaptation_init(&large_encoder_counters, 16'000'000, 30, 0);
    auto large_encoder_sample = observation(1, 0, 0);
    large_encoder_sample.encoder_completed_frames =
        std::numeric_limits<std::uint64_t>::max();
    reasons = macrdp_video_adaptation_observe(
        &large_encoder_counters,
        &large_encoder_sample);
    large_encoder_sample.now_ms = 1001;
    reasons = macrdp_video_adaptation_observe(
        &large_encoder_counters,
        &large_encoder_sample);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && large_encoder_counters.current_fps == 5,
                "large encoder counters overflowed the no-output threshold") && ok;

    macrdp_video_adaptation repeated_pressure{};
    macrdp_video_adaptation_init(&repeated_pressure, 16'000'000, 30, 0);
    auto blocked_episode = observation(2000, 0, 0);
    blocked_episode.output_blocked = true;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    blocked_episode.now_ms = 2600;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    ok = expect(reasons == MACRDP_VIDEO_ADAPT_NONE
                    && repeated_pressure.current_fps == 5,
                "a sub-threshold blocked interval reduced FPS") && ok;
    blocked_episode.now_ms = 2750;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED) != 0
                    && repeated_pressure.current_bitrate_bps == 2'000'000
                    && repeated_pressure.current_fps == 4,
                "sustained output pressure did not reduce FPS") && ok;
    blocked_episode.now_ms = 4300;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED) != 0
                    && repeated_pressure.current_bitrate_bps == 1'333'333
                    && repeated_pressure.current_fps == 4,
                "one blocked interval reduced FPS more than once") && ok;
    auto pressure_cleared = observation(4400, 0, 0);
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &pressure_cleared);
    blocked_episode.now_ms = 4500;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    blocked_episode.now_ms = 5250;
    reasons = macrdp_video_adaptation_observe(&repeated_pressure, &blocked_episode);
    ok = expect((reasons & MACRDP_VIDEO_ADAPT_OUTPUT_BLOCKED) != 0
                    && repeated_pressure.current_bitrate_bps == 1'333'333
                    && repeated_pressure.current_fps == 3,
                "a later blocked interval did not apply a fresh FPS reduction") && ok;

    macrdp_video_adaptation limited{};
    macrdp_video_adaptation_init(&limited, 500'000, 3, 0);
    ok = expect(limited.current_bitrate_bps == 500'000
                    && limited.min_bitrate_bps == 500'000
                    && limited.current_fps == 3,
                "small user ceilings were not respected") && ok;
    auto limited_stall = observation(2000, 0, 0);
    limited_stall.ack_stalls = 1;
    (void)macrdp_video_adaptation_observe(&limited, &limited_stall);
    ok = expect(limited.current_bitrate_bps == 500'000
                    && limited.current_fps == 1,
                "adaptive minima exceeded a user ceiling") && ok;

    return ok ? 0 : 1;
}
