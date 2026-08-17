#pragma once

#include "macrdp/display_capture.hpp"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace macrdp::detail {

using CaptureGeneration = std::uint64_t;

// Project-internal state shared by DisplayCapture and its platform backend.
// Keeping Apple framework types out of this contract allows deterministic
// lifecycle tests to inject a backend without Screen Recording permission.
struct DisplayCaptureState {
    mutable std::mutex mutex;
    std::condition_variable frame_condition;
    std::condition_variable audio_condition;
    std::optional<Frame> latest_frame;
    std::optional<AudioFrame> latest_audio;
    std::optional<Frame> reusable_frame;
    std::string error;
    CaptureGeneration generation = 0;
    bool accepting_frames = false;
    bool video_enabled = true;
    bool stopped = true;
    std::uint64_t suppressed_video_frames = 0;
};

struct DisplayCaptureBackendStartResult {
    bool started = false;
    std::string error;
};

class DisplayCaptureBackend {
public:
    virtual ~DisplayCaptureBackend() = default;

    [[nodiscard]] virtual DisplayCaptureBackendStartResult start(
        const DisplayCaptureOptions& options,
        const std::shared_ptr<DisplayCaptureState>& state,
        CaptureGeneration generation,
        std::chrono::milliseconds timeout) = 0;

    virtual void stop(std::chrono::milliseconds timeout) noexcept = 0;
};

// Fake backends use the same generation checks as ScreenCaptureKit callbacks.
[[nodiscard]] bool capture_backend_publish_frame(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    Frame frame);

[[nodiscard]] bool capture_backend_publish_audio(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    AudioFrame frame);

[[nodiscard]] bool capture_backend_generation_stopped(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    std::string error = {});

} // namespace macrdp::detail
