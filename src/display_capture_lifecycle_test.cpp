#include "macrdp/display_capture.hpp"
#include "macrdp/display_capture_backend.hpp"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <future>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

class FakeCaptureBackend final : public macrdp::detail::DisplayCaptureBackend {
public:
    struct Session {
        macrdp::DisplayCaptureOptions options;
        std::shared_ptr<macrdp::detail::DisplayCaptureState> state;
        macrdp::detail::CaptureGeneration generation = 0;
        std::chrono::milliseconds timeout{};
    };

    using StartHook = std::function<void(const Session&)>;

    macrdp::detail::DisplayCaptureBackendStartResult start(
        const macrdp::DisplayCaptureOptions& options,
        const std::shared_ptr<macrdp::detail::DisplayCaptureState>& state,
        macrdp::detail::CaptureGeneration generation,
        std::chrono::milliseconds timeout) override {
        Session session{options, state, generation, timeout};
        StartHook hook;
        {
            std::lock_guard lock(mutex_);
            sessions_.push_back(session);
            hook = start_hook_;
        }
        if (hook) {
            hook(session);
        }
        return {true, {}};
    }

    void stop(std::chrono::milliseconds timeout) noexcept override {
        std::unique_lock lock(mutex_);
        stop_timeouts_.push_back(timeout);
        ++stop_count_;
        stop_condition_.notify_all();
        if (!block_next_stop_) {
            return;
        }

        block_next_stop_ = false;
        stop_blocked_ = true;
        stop_condition_.notify_all();
        stop_condition_.wait(lock, [this] { return release_blocked_stop_; });
        stop_blocked_ = false;
        release_blocked_stop_ = false;
    }

    void set_start_hook(StartHook hook) {
        std::lock_guard lock(mutex_);
        start_hook_ = std::move(hook);
    }

    void block_next_stop() {
        std::lock_guard lock(mutex_);
        block_next_stop_ = true;
    }

    bool wait_for_blocked_stop(std::chrono::milliseconds timeout) {
        std::unique_lock lock(mutex_);
        return stop_condition_.wait_for(
            lock,
            timeout,
            [this] { return stop_blocked_; });
    }

    void release_stop() {
        {
            std::lock_guard lock(mutex_);
            release_blocked_stop_ = true;
        }
        stop_condition_.notify_all();
    }

    Session session(std::size_t index) const {
        std::lock_guard lock(mutex_);
        return sessions_.at(index);
    }

    std::size_t session_count() const {
        std::lock_guard lock(mutex_);
        return sessions_.size();
    }

    std::size_t stop_count() const {
        std::lock_guard lock(mutex_);
        return stop_count_;
    }

    std::vector<std::chrono::milliseconds> stop_timeouts() const {
        std::lock_guard lock(mutex_);
        return stop_timeouts_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable stop_condition_;
    std::vector<Session> sessions_;
    std::vector<std::chrono::milliseconds> stop_timeouts_;
    StartHook start_hook_;
    std::size_t stop_count_ = 0;
    bool block_next_stop_ = false;
    bool stop_blocked_ = false;
    bool release_blocked_stop_ = false;
};

macrdp::Frame test_frame(std::uint8_t marker) {
    macrdp::Frame frame;
    frame.width = 1;
    frame.height = 1;
    frame.stride = 4;
    frame.bgra = {marker, 0, 0, 0};
    frame.dirty_rects = {{0, 0, 1, 1}};
    return frame;
}

macrdp::AudioFrame test_audio(
    std::int16_t marker,
    std::uint64_t display_generation = 1) {
    macrdp::AudioFrame frame;
    frame.sample_rate = 48'000;
    frame.channels = 2;
    frame.display_generation = display_generation;
    frame.pcm = {marker, marker};
    return frame;
}

bool test_audio_display_generation_gate() {
    const auto current = test_audio(1, 12);
    const auto stale = test_audio(2, 11);
    return expect(macrdp::audio_frame_matches_display_generation(current, 12),
                  "current-generation audio was rejected")
        && expect(!macrdp::audio_frame_matches_display_generation(stale, 12),
                  "stale-generation audio was accepted")
        && expect(!macrdp::audio_frame_matches_display_generation(
                      current,
                      std::nullopt),
                  "audio was accepted without an active display generation");
}

bool test_backend_stop_wakes_both_consumers() {
    auto backend = std::make_unique<FakeCaptureBackend>();
    auto* fake = backend.get();
    macrdp::DisplayCapture capture({}, std::move(backend));
    bool ok = expect(capture.start(), "fake capture did not start");
    const auto session = fake->session(0);

    auto frame_waiter = std::async(std::launch::async, [&capture] {
        return capture.next_frame(5s);
    });
    auto audio_waiter = std::async(std::launch::async, [&capture] {
        return capture.next_audio(5s);
    });

    ok = expect(macrdp::detail::capture_backend_generation_stopped(
                    session.state,
                    session.generation,
                    "synthetic capture failure"),
                "active backend stop callback was rejected") && ok;
    ok = expect(frame_waiter.wait_for(2s) == std::future_status::ready,
                "frame consumer was not woken by backend stop") && ok;
    ok = expect(audio_waiter.wait_for(2s) == std::future_status::ready,
                "audio consumer was not woken by backend stop") && ok;
    ok = expect(!frame_waiter.get().has_value(),
                "frame consumer returned data after backend stop") && ok;
    ok = expect(!audio_waiter.get().has_value(),
                "audio consumer returned data after backend stop") && ok;
    ok = expect(capture.last_error() == "synthetic capture failure",
                "backend stop error was not retained") && ok;
    return ok;
}

bool test_reconfigure_rejects_old_generation_callbacks() {
    auto backend = std::make_unique<FakeCaptureBackend>();
    auto* fake = backend.get();
    macrdp::DisplayCapture capture({}, std::move(backend));
    bool ok = expect(capture.start(), "initial fake capture did not start");
    const auto first = fake->session(0);

    macrdp::DisplayCaptureOptions next_options;
    next_options.display_id = 42;
    next_options.display_generation = 12;
    next_options.native_width = 2560;
    next_options.native_height = 1440;
    next_options.max_width = 1280;
    next_options.max_height = 720;
    next_options.capture_audio = false;
    ok = expect(capture.reconfigure(next_options),
                "fake capture reconfigure failed") && ok;
    ok = expect(fake->session_count() == 2,
                "reconfigure did not create a new backend session") && ok;
    const auto second = fake->session(1);
    ok = expect(second.generation != first.generation,
                "reconfigure reused the previous capture generation") && ok;
    ok = expect(second.options.display_id == 42
                    && second.options.display_generation == 12
                    && second.options.native_width == 2560
                    && second.options.native_height == 1440
                    && second.options.max_width == 1280
                    && second.options.max_height == 720
                    && !second.options.capture_audio,
                "reconfigure did not pass new options to the backend") && ok;

    ok = expect(!macrdp::detail::capture_backend_generation_stopped(
                    first.state,
                    first.generation,
                    "late old-generation stop"),
                "old-generation stop callback mutated active state") && ok;
    ok = expect(!macrdp::detail::capture_backend_publish_frame(
                    first.state,
                    first.generation,
                    test_frame(1)),
                "old-generation frame was accepted") && ok;
    ok = expect(!macrdp::detail::capture_backend_publish_audio(
                    first.state,
                    first.generation,
                    test_audio(1)),
                "old-generation audio was accepted") && ok;
    ok = expect(macrdp::detail::capture_backend_publish_frame(
                    second.state,
                    second.generation,
                    test_frame(2)),
                "active-generation frame was rejected") && ok;
    ok = expect(macrdp::detail::capture_backend_publish_audio(
                    second.state,
                    second.generation,
                    test_audio(2, 12)),
                "active-generation audio was rejected") && ok;

    const auto frame = capture.next_frame(0ms);
    const auto audio = capture.next_audio(0ms);
    ok = expect(frame.has_value() && frame->bgra.front() == 2,
                "active-generation frame was not delivered") && ok;
    ok = expect(audio.has_value() && audio->pcm.front() == 2
                    && audio->display_generation == 12,
                "active-generation audio was not delivered") && ok;
    ok = expect(capture.last_error().empty(),
                "old-generation callback replaced active error state") && ok;

    capture.stop();
    ok = expect(fake->stop_count() == 2,
                "reconfigure and final stop did not stop both sessions") && ok;
    ok = expect(!macrdp::detail::capture_backend_publish_frame(
                    second.state,
                    second.generation,
                    test_frame(3)),
                "stopped generation accepted a late frame") && ok;
    return ok;
}

bool test_stop_during_backend_start_is_rejected() {
    auto backend = std::make_unique<FakeCaptureBackend>();
    auto* fake = backend.get();
    fake->set_start_hook([](const FakeCaptureBackend::Session& session) {
        (void)macrdp::detail::capture_backend_generation_stopped(
            session.state,
            session.generation,
            "stream stopped during start");
    });

    macrdp::DisplayCapture capture({}, std::move(backend));
    bool ok = expect(!capture.start(),
                     "capture accepted a generation stopped during start");
    ok = expect(fake->stop_count() == 1,
                "failed start did not clean up the backend session") && ok;
    ok = expect(capture.last_error()
                    == "ScreenCaptureKit stream was superseded while starting",
                "start race did not report a stable lifecycle error") && ok;
    return ok;
}

bool test_stop_and_reconfigure_are_serialized() {
    auto backend = std::make_unique<FakeCaptureBackend>();
    auto* fake = backend.get();
    macrdp::DisplayCapture capture({}, std::move(backend));
    bool ok = expect(capture.start(), "fake capture did not start before race");
    fake->block_next_stop();

    macrdp::DisplayCaptureOptions next_options;
    next_options.max_width = 1024;
    next_options.max_height = 768;
    auto reconfigure = std::async(std::launch::async, [&capture, next_options] {
        return capture.reconfigure(next_options);
    });
    ok = expect(fake->wait_for_blocked_stop(2s),
                "reconfigure did not enter the backend stop") && ok;

    auto stop = std::async(std::launch::async, [&capture] { capture.stop(); });
    ok = expect(stop.wait_for(20ms) == std::future_status::timeout,
                "stop bypassed the in-progress reconfigure") && ok;
    fake->release_stop();

    ok = expect(reconfigure.wait_for(2s) == std::future_status::ready,
                "reconfigure did not finish after backend stop was released") && ok;
    ok = expect(reconfigure.get(), "serialized reconfigure failed") && ok;
    ok = expect(stop.wait_for(2s) == std::future_status::ready,
                "stop did not finish after reconfigure") && ok;
    stop.get();

    ok = expect(fake->session_count() == 2,
                "serialized reconfigure did not start a replacement session") && ok;
    ok = expect(fake->stop_count() == 2,
                "serialized stop did not stop the replacement session") && ok;
    const auto stop_timeouts = fake->stop_timeouts();
    ok = expect(stop_timeouts.size() == 2
                    && stop_timeouts[0] == 5s
                    && stop_timeouts[1] == 5s,
                "backend stop did not retain the finite timeout") && ok;

    const auto replacement = fake->session(1);
    ok = expect(replacement.timeout == 15s,
                "backend start did not retain the finite timeout") && ok;
    ok = expect(!macrdp::detail::capture_backend_publish_frame(
                    replacement.state,
                    replacement.generation,
                    test_frame(4)),
                "final stop left the replacement generation active") && ok;
    return ok;
}

bool test_video_suppression_keeps_audio_active() {
    auto backend = std::make_unique<FakeCaptureBackend>();
    auto* fake = backend.get();
    macrdp::DisplayCapture capture({}, std::move(backend));
    bool ok = expect(capture.start(), "fake capture did not start before video suppression");
    const auto session = fake->session(0);

    ok = expect(macrdp::detail::capture_backend_publish_frame(
                    session.state,
                    session.generation,
                    test_frame(1)),
                "initial video frame was rejected") && ok;
    capture.set_video_enabled(false);
    ok = expect(!capture.video_enabled(), "video suppression was not observable") && ok;
    ok = expect(!capture.next_frame(0ms).has_value(),
                "queued video survived output suppression") && ok;
    ok = expect(!macrdp::detail::capture_backend_publish_frame(
                    session.state,
                    session.generation,
                    test_frame(2)),
                "suppressed video frame was accepted") && ok;
    ok = expect(capture.suppressed_video_frames() == 1,
                "suppressed video frame was not counted") && ok;
    ok = expect(macrdp::detail::capture_backend_publish_audio(
                    session.state,
                    session.generation,
                    test_audio(3)),
                "video suppression also suppressed audio") && ok;
    const auto audio = capture.next_audio(0ms);
    ok = expect(audio.has_value() && audio->pcm.front() == 3,
                "audio was not delivered while video was suppressed") && ok;

    capture.set_video_enabled(true);
    ok = expect(capture.video_enabled(), "video resume was not observable") && ok;
    ok = expect(macrdp::detail::capture_backend_publish_frame(
                    session.state,
                    session.generation,
                    test_frame(4)),
                "resumed video frame was rejected") && ok;
    const auto frame = capture.next_frame(0ms);
    ok = expect(frame.has_value() && frame->bgra.front() == 4,
                "resumed video frame was not delivered") && ok;
    capture.stop();
    return ok;
}

} // namespace

int main() {
    bool ok = test_audio_display_generation_gate();
    ok = test_backend_stop_wakes_both_consumers() && ok;
    ok = test_reconfigure_rejects_old_generation_callbacks() && ok;
    ok = test_stop_during_backend_start_is_rejected() && ok;
    ok = test_stop_and_reconfigure_are_serialized() && ok;
    ok = test_video_suppression_keeps_audio_active() && ok;
    return ok ? 0 : 1;
}
