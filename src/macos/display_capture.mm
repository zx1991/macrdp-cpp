#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "macrdp/async_completion.hpp"
#include "macrdp/display_capture.hpp"
#include "macrdp/display_capture_backend.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>
#include <vector>

namespace {

using CaptureState = macrdp::detail::DisplayCaptureState;

std::uint64_t timestamp_us() {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(now).count());
}

std::string error_description(NSError* error) {
    if (error == nil) {
        return "unknown ScreenCaptureKit error";
    }

    NSString* description = [error localizedDescription];
    if (description == nil || [description UTF8String] == nullptr) {
        return "unknown ScreenCaptureKit error";
    }
    return [description UTF8String];
}

constexpr auto capture_start_timeout = std::chrono::milliseconds{15000};
constexpr auto capture_stop_timeout = std::chrono::milliseconds{5000};

void recycle_frame_locked(CaptureState& state, macrdp::Frame frame) noexcept {
    try {
        frame.dirty_rects.clear();
        if (!state.reusable_frame.has_value()
            || state.reusable_frame->bgra.capacity() < frame.bgra.capacity()) {
            state.reusable_frame = std::move(frame);
        }
    } catch (...) {
        // Recycling is only an allocation optimization; a frame can still be
        // released normally when storage cannot be retained.
    }
}

} // namespace

namespace macrdp::detail {

bool capture_backend_publish_frame(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    Frame frame) {
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation || !state->accepting_frames) {
            return false;
        }
        if (state->latest_frame.has_value()) {
            coalesce_dropped_frame_dirty_regions(*state->latest_frame, frame);
        }
        state->latest_frame = std::move(frame);
    }
    state->frame_condition.notify_one();
    return true;
}

bool capture_backend_publish_audio(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    AudioFrame frame) {
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation || !state->accepting_frames) {
            return false;
        }
        state->latest_audio = std::move(frame);
    }
    state->audio_condition.notify_one();
    return true;
}

bool capture_backend_generation_stopped(
    const std::shared_ptr<DisplayCaptureState>& state,
    CaptureGeneration generation,
    std::string error) {
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation) {
            return false;
        }
        if (!error.empty()) {
            state->error = std::move(error);
        } else if (state->accepting_frames) {
            state->error = "ScreenCaptureKit stream stopped unexpectedly";
        }
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->frame_condition.notify_all();
    state->audio_condition.notify_all();
    return true;
}

} // namespace macrdp::detail

namespace {

bool sample_status_is_usable(CMSampleBufferRef sample_buffer) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(
        sample_buffer,
        false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
        return true;
    }

    NSDictionary* dictionary = (__bridge NSDictionary*)CFArrayGetValueAtIndex(
        attachments,
        0);
    NSNumber* status_value = dictionary[SCStreamFrameInfoStatus];
    if (status_value == nil) {
        return true;
    }

    const auto status = static_cast<SCFrameStatus>([status_value integerValue]);
    // Started/Idle samples can contain an incomplete surface. Passing them
    // through creates stale or partially updated frames under load.
    return status == SCFrameStatusComplete;
}

void copy_dirty_rects(
    CMSampleBufferRef sample_buffer,
    std::uint32_t width,
    std::uint32_t height,
    macrdp::Frame& frame) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(
        sample_buffer,
        false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
        return;
    }

    NSDictionary* dictionary = (__bridge NSDictionary*)CFArrayGetValueAtIndex(
        attachments,
        0);
    id dirty_rects_object = dictionary[SCStreamFrameInfoDirtyRects];
    if (dirty_rects_object == nil
        || ![dirty_rects_object isKindOfClass:[NSArray class]]) {
        return;
    }

    const double max_width = static_cast<double>(width);
    const double max_height = static_cast<double>(height);
    for (id object in static_cast<NSArray*>(dirty_rects_object)) {
        if (![object isKindOfClass:[NSValue class]]) {
            continue;
        }

        CGRect rect{};
        [static_cast<NSValue*>(object) getValue:&rect size:sizeof(rect)];
        const double raw_right = rect.origin.x + rect.size.width;
        const double raw_bottom = rect.origin.y + rect.size.height;
        if (!std::isfinite(rect.origin.x) || !std::isfinite(rect.origin.y)
            || !std::isfinite(raw_right) || !std::isfinite(raw_bottom)
            || rect.size.width <= 0.0 || rect.size.height <= 0.0) {
            continue;
        }

        const auto left = static_cast<std::uint32_t>(std::clamp(
            std::floor(rect.origin.x),
            0.0,
            max_width));
        const auto top = static_cast<std::uint32_t>(std::clamp(
            std::floor(rect.origin.y),
            0.0,
            max_height));
        const auto right = static_cast<std::uint32_t>(std::clamp(
            std::ceil(raw_right),
            0.0,
            max_width));
        const auto bottom = static_cast<std::uint32_t>(std::clamp(
            std::ceil(raw_bottom),
            0.0,
            max_height));
        macrdp::FrameRect dirty{left, top, right, bottom};
        if (dirty.valid()) {
            frame.dirty_rects.push_back(dirty);
        }
    }
}

bool copy_sample_buffer(CMSampleBufferRef sample_buffer, macrdp::Frame& frame) {
    if (sample_buffer == nullptr || !sample_status_is_usable(sample_buffer)) {
        return false;
    }

    CVPixelBufferRef pixel_buffer = CMSampleBufferGetImageBuffer(sample_buffer);
    if (pixel_buffer == nullptr
        || CVPixelBufferGetPixelFormatType(pixel_buffer) != kCVPixelFormatType_32BGRA) {
        return false;
    }

    const auto width = CVPixelBufferGetWidth(pixel_buffer);
    const auto height = CVPixelBufferGetHeight(pixel_buffer);
    const auto bytes_per_row = CVPixelBufferGetBytesPerRow(pixel_buffer);
    if (width == 0 || height == 0
        || width > std::numeric_limits<std::uint32_t>::max()
        || width > std::numeric_limits<std::size_t>::max() / 4
        || bytes_per_row < width * 4
        || height > std::numeric_limits<std::size_t>::max() / bytes_per_row) {
        return false;
    }

    const auto lock_status = CVPixelBufferLockBaseAddress(
        pixel_buffer,
        kCVPixelBufferLock_ReadOnly);
    if (lock_status != kCVReturnSuccess) {
        return false;
    }
    const auto* base_address = static_cast<const std::uint8_t*>(
        CVPixelBufferGetBaseAddress(pixel_buffer));
    if (base_address == nullptr) {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    const auto copy_started = std::chrono::steady_clock::now();
    try {
        frame.bgra.resize(bytes_per_row * height);
    } catch (...) {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    frame.width = static_cast<std::uint32_t>(width);
    frame.height = static_cast<std::uint32_t>(height);
    frame.stride = bytes_per_row;
    frame.timestamp_us = timestamp_us();
    frame.capture_copy_time_us = 0;
    frame.dirty_rects.clear();

    for (std::size_t y = 0; y < height; ++y) {
        std::memcpy(
            frame.bgra.data() + y * bytes_per_row,
            base_address + y * bytes_per_row,
            bytes_per_row);
    }

    CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    try {
        copy_dirty_rects(
            sample_buffer,
            frame.width,
            frame.height,
            frame);
    } catch (...) {
        // Missing metadata is intentionally treated as a full-frame update.
        frame.dirty_rects.clear();
    }
    frame.capture_copy_time_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - copy_started)
            .count());
    return true;
}

struct AudioBufferView {
    const std::uint8_t* data = nullptr;
    std::size_t byte_size = 0;
    std::size_t channel_count = 0;
    std::size_t bytes_per_sample = 0;
    std::size_t bytes_per_frame = 0;
};

float read_audio_sample(
    const std::uint8_t* data,
    std::size_t byte_size,
    std::size_t byte_offset,
    const AudioStreamBasicDescription& description) {
    const std::size_t bytes_per_sample =
        (description.mBitsPerChannel + 7U) / 8U;
    if (data == nullptr || bytes_per_sample == 0 || byte_offset > byte_size
        || bytes_per_sample > byte_size - byte_offset) {
        return 0.0F;
    }

    const auto* source = data + byte_offset;
    const bool big_endian =
        (description.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    const bool is_float =
        (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool is_signed =
        (description.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    if (is_float && description.mBitsPerChannel == 32) {
        std::uint32_t bits = 0;
        std::memcpy(&bits, source, sizeof(bits));
        if (big_endian) {
            bits = __builtin_bswap32(bits);
        }
        float value = 0.0F;
        std::memcpy(&value, &bits, sizeof(value));
        return std::isfinite(value) ? value : 0.0F;
    }

    if (is_float && description.mBitsPerChannel == 64) {
        std::uint64_t bits = 0;
        std::memcpy(&bits, source, sizeof(bits));
        if (big_endian) {
            bits = __builtin_bswap64(bits);
        }
        double value = 0.0;
        std::memcpy(&value, &bits, sizeof(value));
        return std::isfinite(value) ? static_cast<float>(value) : 0.0F;
    }

    if (!is_signed || !((description.mBitsPerChannel == 8)
                        || (description.mBitsPerChannel == 16)
                        || (description.mBitsPerChannel == 24)
                        || (description.mBitsPerChannel == 32))) {
        return 0.0F;
    }

    std::int64_t value = 0;
    if (big_endian) {
        for (std::size_t index = 0; index < bytes_per_sample; ++index) {
            value = (value << 8U) | source[index];
        }
    } else {
        for (std::size_t index = 0; index < bytes_per_sample; ++index) {
            value |= static_cast<std::int64_t>(source[index]) << (index * 8U);
        }
    }

    const auto bits = static_cast<unsigned>(description.mBitsPerChannel);
    const std::int64_t sign_bit = std::int64_t{1} << (bits - 1U);
    const std::int64_t full_scale = std::int64_t{1} << (bits - 1U);
    if ((value & sign_bit) != 0) {
        value -= std::int64_t{1} << bits;
    }
    return static_cast<float>(value) / static_cast<float>(full_scale);
}

std::optional<macrdp::AudioFrame> copy_audio_sample_buffer(
    CMSampleBufferRef sample_buffer) {
    if (sample_buffer == nullptr) {
        return std::nullopt;
    }

    auto* format_description = CMSampleBufferGetFormatDescription(sample_buffer);
    if (format_description == nullptr) {
        return std::nullopt;
    }
    const auto* description = CMAudioFormatDescriptionGetStreamBasicDescription(
        static_cast<CMAudioFormatDescriptionRef>(format_description));
    if (description == nullptr || description->mFormatID != kAudioFormatLinearPCM
        || description->mChannelsPerFrame == 0
        || description->mChannelsPerFrame > 32
        || !std::isfinite(description->mSampleRate)
        || description->mSampleRate <= 0.0
        || description->mBitsPerChannel == 0
        || description->mBytesPerFrame == 0) {
        return std::nullopt;
    }

    const auto source_channels = static_cast<std::size_t>(description->mChannelsPerFrame);
    const auto source_frames = static_cast<std::size_t>(CMSampleBufferGetNumSamples(sample_buffer));
    if (source_frames == 0 || source_frames > 1'000'000
        || source_frames > std::numeric_limits<std::size_t>::max() / source_channels) {
        return std::nullopt;
    }

    size_t buffer_list_size = 0;
    CMBlockBufferRef retained_block_buffer = nullptr;
    const auto size_status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample_buffer,
        &buffer_list_size,
        nullptr,
        0,
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &retained_block_buffer);
    if (retained_block_buffer != nullptr) {
        CFRelease(retained_block_buffer);
        retained_block_buffer = nullptr;
    }
    if (size_status != noErr && buffer_list_size == 0) {
        return std::nullopt;
    }
    if (buffer_list_size < sizeof(AudioBufferList)) {
        return std::nullopt;
    }

    std::vector<std::uint8_t> buffer_list_storage;
    try {
        buffer_list_storage.resize(buffer_list_size);
    } catch (...) {
        return std::nullopt;
    }
    auto* buffer_list = reinterpret_cast<AudioBufferList*>(buffer_list_storage.data());
    const auto list_status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample_buffer,
        nullptr,
        buffer_list,
        buffer_list_storage.size(),
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &retained_block_buffer);
    if (list_status != noErr || retained_block_buffer == nullptr
        || buffer_list->mNumberBuffers == 0) {
        if (retained_block_buffer != nullptr) {
            CFRelease(retained_block_buffer);
        }
        return std::nullopt;
    }

    const std::size_t bytes_per_sample =
        (description->mBitsPerChannel + 7U) / 8U;
    const bool non_interleaved =
        (description->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (bytes_per_sample == 0) {
        CFRelease(retained_block_buffer);
        return std::nullopt;
    }

    std::vector<AudioBufferView> views;
    views.reserve(buffer_list->mNumberBuffers);
    std::size_t represented_channels = 0;
    for (UInt32 index = 0; index < buffer_list->mNumberBuffers; ++index) {
        const auto& buffer = buffer_list->mBuffers[index];
        const std::size_t buffer_channels = buffer.mNumberChannels != 0
            ? static_cast<std::size_t>(buffer.mNumberChannels)
            : (non_interleaved ? 1U : source_channels);
        const std::size_t bytes_per_frame = non_interleaved
            ? bytes_per_sample
            : bytes_per_sample * buffer_channels;
        if (buffer_channels == 0 || bytes_per_frame == 0) {
            continue;
        }
        views.push_back({
            static_cast<const std::uint8_t*>(buffer.mData),
            static_cast<std::size_t>(buffer.mDataByteSize),
            buffer_channels,
            bytes_per_sample,
            bytes_per_frame});
        represented_channels += buffer_channels;
    }
    if (views.empty() || represented_channels < source_channels) {
        CFRelease(retained_block_buffer);
        return std::nullopt;
    }

    std::vector<float> source_pcm;
    try {
        source_pcm.resize(source_frames * source_channels);
    } catch (...) {
        CFRelease(retained_block_buffer);
        return std::nullopt;
    }

    bool complete = true;
    for (std::size_t frame = 0; frame < source_frames && complete; ++frame) {
        for (std::size_t channel = 0; channel < source_channels; ++channel) {
            const AudioBufferView* selected = nullptr;
            std::size_t local_channel = 0;
            std::size_t channel_base = 0;
            for (const auto& view : views) {
                if (channel < channel_base + view.channel_count) {
                    selected = &view;
                    local_channel = channel - channel_base;
                    break;
                }
                channel_base += view.channel_count;
            }
            if (selected == nullptr) {
                complete = false;
                break;
            }
            if (frame > std::numeric_limits<std::size_t>::max() / selected->bytes_per_frame) {
                complete = false;
                break;
            }
            const auto byte_offset = frame * selected->bytes_per_frame
                + local_channel * selected->bytes_per_sample;
            source_pcm[frame * source_channels + channel] = read_audio_sample(
                selected->data,
                selected->byte_size,
                byte_offset,
                *description);
        }
    }
    CFRelease(retained_block_buffer);
    if (!complete) {
        return std::nullopt;
    }

    constexpr std::uint32_t target_sample_rate = 48'000;
    constexpr std::uint16_t target_channels = 2;
    const auto target_frames = static_cast<std::size_t>(std::llround(
        static_cast<double>(source_frames) * target_sample_rate / description->mSampleRate));
    if (target_frames == 0 || target_frames > 1'000'000
        || target_frames > std::numeric_limits<std::size_t>::max() / target_channels) {
        return std::nullopt;
    }

    macrdp::AudioFrame frame;
    frame.sample_rate = target_sample_rate;
    frame.channels = target_channels;
    frame.pcm.resize(target_frames * target_channels);
    for (std::size_t output_frame = 0; output_frame < target_frames; ++output_frame) {
        const double source_position = static_cast<double>(output_frame)
            * description->mSampleRate / target_sample_rate;
        const auto source_index = std::min(
            source_frames - 1,
            static_cast<std::size_t>(source_position));
        const auto next_index = std::min(source_frames - 1, source_index + 1);
        const float interpolation = static_cast<float>(
            source_position - static_cast<double>(source_index));
        for (std::size_t channel = 0; channel < target_channels; ++channel) {
            const auto source_channel = source_channels == 1
                ? 0
                : std::min(channel, source_channels - 1);
            const float first = source_pcm[source_index * source_channels + source_channel];
            const float second = source_pcm[next_index * source_channels + source_channel];
            const float value = std::clamp(
                first + (second - first) * interpolation,
                -1.0F,
                1.0F);
            const auto converted = value <= -1.0F
                ? -32768
                : value >= 1.0F
                    ? 32767
                    : static_cast<int>(std::lrint(value * 32767.0F));
            frame.pcm[output_frame * target_channels + channel] =
                static_cast<std::int16_t>(converted);
        }
    }

    const auto timestamp = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
    if (CMTIME_IS_VALID(timestamp) && CMTIME_IS_NUMERIC(timestamp)
        && timestamp.timescale > 0 && timestamp.value >= 0) {
        frame.timestamp_us = static_cast<std::uint64_t>(
            (static_cast<long double>(timestamp.value) * 1'000'000.0L)
            / static_cast<long double>(timestamp.timescale));
    }
    return frame;
}

} // namespace

namespace macrdp {

std::pair<std::uint32_t, std::uint32_t> display_capture_output_size(
    std::uint32_t native_width,
    std::uint32_t native_height,
    std::uint32_t max_width,
    std::uint32_t max_height) noexcept {
    if (native_width == 0 || native_height == 0) {
        return {0, 0};
    }

    const double width_scale = max_width == 0
        ? 1.0
        : static_cast<double>(max_width) / static_cast<double>(native_width);
    const double height_scale = max_height == 0
        ? 1.0
        : static_cast<double>(max_height) / static_cast<double>(native_height);
    const double scale = std::min({1.0, width_scale, height_scale});
    const auto even_dimension = [](double value) -> std::uint32_t {
        const auto rounded_down = static_cast<std::uint64_t>(std::floor(value));
        if (rounded_down < 2) {
            return 0;
        }
        const auto even = rounded_down & ~std::uint64_t{1};
        return even > std::numeric_limits<std::uint32_t>::max()
            ? 0
            : static_cast<std::uint32_t>(even);
    };

    const auto scaled_width = even_dimension(static_cast<double>(native_width) * scale);
    const auto scaled_height = even_dimension(static_cast<double>(native_height) * scale);
    return {scaled_width, scaled_height};
}

std::optional<std::uint32_t> display_capture_select_id(
    std::uint32_t requested_display_id,
    std::uint32_t main_display_id,
    const std::vector<std::uint32_t>& available_display_ids) noexcept {
    if (available_display_ids.empty()) {
        return std::nullopt;
    }

    const auto contains = [&available_display_ids](std::uint32_t display_id) {
        return std::find(
                   available_display_ids.begin(),
                   available_display_ids.end(),
                   display_id)
            != available_display_ids.end();
    };
    if (requested_display_id != 0) {
        return contains(requested_display_id)
            ? std::optional<std::uint32_t>{requested_display_id}
            : std::nullopt;
    }
    if (main_display_id != 0 && contains(main_display_id)) {
        return main_display_id;
    }
    return available_display_ids.front();
}

std::pair<double, double> display_capture_input_point(
    DisplayBounds bounds,
    std::uint32_t surface_width,
    std::uint32_t surface_height,
    std::uint16_t x,
    std::uint16_t y) noexcept {
    const auto map_axis = [](double origin,
                             double extent,
                             std::uint32_t surface_extent,
                             std::uint16_t coordinate) {
        if (!std::isfinite(origin)) {
            origin = 0.0;
        }
        if (!std::isfinite(extent) || extent <= 0.0) {
            return origin;
        }
        const double denominator = surface_extent > 1
            ? static_cast<double>(surface_extent - 1)
            : std::max(1.0, extent - 1.0);
        const double normalized = std::clamp(
            static_cast<double>(coordinate) / denominator,
            0.0,
            1.0);
        return origin + normalized * std::max(0.0, extent - 1.0);
    };

    return {
        map_axis(bounds.origin_x, bounds.width, surface_width, x),
        map_axis(bounds.origin_y, bounds.height, surface_height, y)};
}

} // namespace macrdp

namespace {

std::pair<std::size_t, std::size_t> output_size(
    CGDirectDisplayID display_id,
    const macrdp::DisplayCaptureOptions& options) {
    std::size_t width = CGDisplayPixelsWide(display_id);
    std::size_t height = CGDisplayPixelsHigh(display_id);
    if (width == 0 || height == 0
        || width > std::numeric_limits<std::uint32_t>::max()
        || height > std::numeric_limits<std::uint32_t>::max()) {
        return {0, 0};
    }

    const auto dimensions = macrdp::display_capture_output_size(
        static_cast<std::uint32_t>(width),
        static_cast<std::uint32_t>(height),
        options.max_width,
        options.max_height);
    return {dimensions.first, dimensions.second};
}

} // namespace

@interface MacCaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate> {
@private
    std::shared_ptr<CaptureState> state_;
    std::uint64_t generation_;
}

- (instancetype)initWithState:(std::shared_ptr<CaptureState>)state
    generation:(std::uint64_t)generation;
@end

@implementation MacCaptureOutput

- (instancetype)initWithState:(std::shared_ptr<CaptureState>)state
    generation:(std::uint64_t)generation {
    self = [super init];
    if (self != nil) {
        state_ = std::move(state);
        generation_ = generation;
    }
    return self;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type {
    (void)stream;
    if (sampleBuffer == nullptr) {
        return;
    }

    const auto state = state_;
    if (type == SCStreamOutputTypeAudio) {
        auto audio = copy_audio_sample_buffer(sampleBuffer);
        if (!audio.has_value()) {
            return;
        }
        // The audio consumer runs independently from video and keeps the
        // newest block only, so audio backpressure cannot stall SCK.
        (void)macrdp::detail::capture_backend_publish_audio(
            state,
            generation_,
            std::move(*audio));
        return;
    }
    if (type != SCStreamOutputTypeScreen) {
        return;
    }

    macrdp::Frame frame;
    std::vector<macrdp::FrameRect> dropped_dirty_rects;
    std::uint32_t dropped_width = 0;
    std::uint32_t dropped_height = 0;
    bool reused_pending_frame = false;
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation_ || !state->accepting_frames) {
            return;
        }

        if (state->latest_frame.has_value()) {
            frame = std::move(*state->latest_frame);
            state->latest_frame.reset();
            dropped_width = frame.width;
            dropped_height = frame.height;
            dropped_dirty_rects = std::move(frame.dirty_rects);
            reused_pending_frame = true;
        } else if (state->reusable_frame.has_value()) {
            frame = std::move(*state->reusable_frame);
            state->reusable_frame.reset();
        }
    }

    if (!copy_sample_buffer(sampleBuffer, frame)) {
        std::lock_guard lock(state->mutex);
        if (reused_pending_frame && state->generation == generation_
            && state->accepting_frames
            && !state->latest_frame.has_value()) {
            frame.dirty_rects = std::move(dropped_dirty_rects);
            state->latest_frame = std::move(frame);
        } else {
            recycle_frame_locked(*state, std::move(frame));
        }
        return;
    }

    if (reused_pending_frame) {
        macrdp::Frame dropped_metadata;
        dropped_metadata.width = dropped_width;
        dropped_metadata.height = dropped_height;
        dropped_metadata.dirty_rects = std::move(dropped_dirty_rects);
        macrdp::coalesce_dropped_frame_dirty_regions(dropped_metadata, frame);
    }

    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation_ || !state->accepting_frames) {
            recycle_frame_locked(*state, std::move(frame));
            return;
        }
        state->latest_frame = std::move(frame);
    }
    state->frame_condition.notify_one();
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    (void)macrdp::detail::capture_backend_generation_stopped(
        state_,
        generation_,
        error == nil ? std::string{} : error_description(error));
}

@end

namespace macrdp {

class ScreenCaptureKitBackend final : public detail::DisplayCaptureBackend {
public:
    ~ScreenCaptureKitBackend() override {
        stop(capture_stop_timeout);
    }

    [[nodiscard]] detail::DisplayCaptureBackendStartResult start(
        const DisplayCaptureOptions& options,
        const std::shared_ptr<detail::DisplayCaptureState>& state,
        detail::CaptureGeneration generation,
        std::chrono::milliseconds timeout) override;

    void stop(std::chrono::milliseconds timeout) noexcept override;

private:
    SCStream* stream_ = nil;
    MacCaptureOutput* output_ = nil;
    bool audio_output_registered_ = false;
};

struct DisplayCapture::Impl {
    Impl(
        DisplayCaptureOptions capture_options,
        std::unique_ptr<detail::DisplayCaptureBackend> capture_backend)
        : options(capture_options),
          state(std::make_shared<CaptureState>()),
          backend(std::move(capture_backend)) {}

    ~Impl() {
        stop();
    }

    [[nodiscard]] bool start();
    [[nodiscard]] bool start_locked();
    [[nodiscard]] std::optional<Frame> next_frame(std::chrono::milliseconds timeout);
    [[nodiscard]] std::optional<AudioFrame> next_audio(std::chrono::milliseconds timeout);
    void recycle_frame(Frame frame) noexcept;
    [[nodiscard]] bool reconfigure(DisplayCaptureOptions next_options);
    void stop() noexcept;
    [[nodiscard]] std::string last_error() const;

    DisplayCaptureOptions options;
    std::shared_ptr<CaptureState> state;
    std::unique_ptr<detail::DisplayCaptureBackend> backend;
    std::mutex lifecycle_mutex;
    bool started = false;
};

namespace {

void set_capture_error(
    const std::shared_ptr<CaptureState>& state,
    std::uint64_t generation,
    std::string error) {
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation) {
            return;
        }
        ++state->generation;
        state->error = std::move(error);
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->frame_condition.notify_all();
    state->audio_condition.notify_all();
}

bool activate_capture_generation(
    const std::shared_ptr<CaptureState>& state,
    std::uint64_t generation) {
    std::lock_guard lock(state->mutex);
    if (state->generation != generation || state->stopped) {
        return false;
    }
    state->accepting_frames = true;
    return true;
}

void deactivate_capture_generation(
    const std::shared_ptr<CaptureState>& state,
    std::uint64_t generation) {
    {
        std::lock_guard lock(state->mutex);
        if (state->generation != generation) {
            return;
        }
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->frame_condition.notify_all();
    state->audio_condition.notify_all();
}

void remove_stream_outputs(
    SCStream* stream,
    MacCaptureOutput* output,
    bool audio_registered) {
    if (stream == nil || output == nil) {
        return;
    }
    if (audio_registered) {
        [stream removeStreamOutput:output type:SCStreamOutputTypeAudio error:nil];
    }
    [stream removeStreamOutput:output type:SCStreamOutputTypeScreen error:nil];
}

void stop_stream_without_waiting(
    SCStream* stream,
    MacCaptureOutput* output,
    bool audio_registered) {
    if (stream == nil) {
        return;
    }
    [stream stopCaptureWithCompletionHandler:^(NSError* error) {
        if (error != nil) {
            NSLog(@"macrdp: asynchronous ScreenCaptureKit stop failed: %@", error);
        }
    }];
    remove_stream_outputs(stream, output, audio_registered);
}

void stop_stream(
    SCStream* stream,
    MacCaptureOutput* output,
    bool audio_registered,
    std::chrono::milliseconds timeout) {
    if (stream == nil) {
        return;
    }

    auto waiter = std::make_shared<AsyncCompletion>();
    [stream stopCaptureWithCompletionHandler:^(NSError* error) {
        (void)waiter->finish(
            error == nil ? std::string{} : error_description(error));
    }];
    const auto result = waiter->wait_for(timeout);
    if (!result.completed) {
        NSLog(@"macrdp: ScreenCaptureKit stop timed out after %lld ms",
              static_cast<long long>(timeout.count()));
    } else if (!result.error.empty()) {
        NSLog(@"macrdp: ScreenCaptureKit stop failed: %s", result.error.c_str());
    }
    remove_stream_outputs(stream, output, audio_registered);
}

} // namespace

detail::DisplayCaptureBackendStartResult ScreenCaptureKitBackend::start(
    const DisplayCaptureOptions& options,
    const std::shared_ptr<detail::DisplayCaptureState>& state,
    detail::CaptureGeneration generation,
    std::chrono::milliseconds timeout) {
    const auto state_for_callback = state;
    const auto capture_options = options;
    auto waiter = std::make_shared<AsyncCompletion>();
    __block SCStream* new_stream = nil;
    __block MacCaptureOutput* new_output = nil;
    __block bool audio_registered = false;

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
        onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent* content, NSError* error) {
        @autoreleasepool {
            if (waiter->timed_out()) {
                return;
            }
            if (error != nil) {
                (void)waiter->finish(error_description(error));
                return;
            }
            if (content == nil || [content.displays count] == 0) {
                (void)waiter->finish(
                    "ScreenCaptureKit returned no shareable displays");
                return;
            }

            std::vector<std::uint32_t> available_display_ids;
            available_display_ids.reserve([content.displays count]);
            for (SCDisplay* display in content.displays) {
                available_display_ids.push_back([display displayID]);
            }
            const auto selected_display_id = macrdp::display_capture_select_id(
                capture_options.display_id,
                CGMainDisplayID(),
                available_display_ids);
            if (!selected_display_id.has_value()) {
                const std::string description = capture_options.display_id == 0
                    ? "ScreenCaptureKit returned no selectable display"
                    : "Requested display ID "
                        + std::to_string(capture_options.display_id)
                        + " is not shareable";
                (void)waiter->finish(description);
                return;
            }

            SCDisplay* selected_display = nil;
            for (SCDisplay* display in content.displays) {
                if ([display displayID] == *selected_display_id) {
                    selected_display = display;
                    break;
                }
            }
            if (selected_display == nil) {
                (void)waiter->finish(
                    "Selected display disappeared during ScreenCaptureKit discovery");
                return;
            }

            const auto display_id = [selected_display displayID];
            const auto [width, height] = output_size(display_id, capture_options);
            if (width == 0 || height == 0) {
                (void)waiter->finish(
                    "Unable to determine the selected display dimensions");
                return;
            }

            auto* filter = [[SCContentFilter alloc]
                initWithDisplay:selected_display excludingWindows:@[]];
            auto* configuration = [[SCStreamConfiguration alloc] init];
            configuration.width = width;
            configuration.height = height;
            configuration.pixelFormat = kCVPixelFormatType_32BGRA;
            configuration.minimumFrameInterval = CMTimeMake(
                1,
                static_cast<int32_t>(std::clamp(
                    capture_options.frame_rate == 0 ? 30 : capture_options.frame_rate,
                    std::uint32_t{1},
                    std::uint32_t{60})));
            configuration.showsCursor = capture_options.show_cursor;
            configuration.capturesAudio = capture_options.capture_audio ? YES : NO;
            if (capture_options.capture_audio) {
                configuration.sampleRate = 48000;
                configuration.channelCount = 2;
                configuration.excludesCurrentProcessAudio = YES;
            }
            configuration.queueDepth = 2;
            configuration.preservesAspectRatio = YES;
            configuration.scalesToFit = YES;
            configuration.shouldBeOpaque = YES;
            configuration.ignoreShadowsDisplay = YES;

            new_output = [[MacCaptureOutput alloc]
                initWithState:state_for_callback
                generation:generation];
            new_stream = [[SCStream alloc] initWithFilter:filter
                configuration:configuration
                delegate:new_output];

            NSError* add_error = nil;
            dispatch_queue_t sample_queue = dispatch_queue_create(
                "com.macrdp.cpp.screen-capture",
                DISPATCH_QUEUE_SERIAL);
            if (![new_stream addStreamOutput:new_output
                type:SCStreamOutputTypeScreen
                sampleHandlerQueue:sample_queue
                error:&add_error]) {
                (void)waiter->finish(
                    add_error == nil
                        ? "Unable to register ScreenCaptureKit video output"
                        : error_description(add_error));
                new_stream = nil;
                new_output = nil;
                return;
            }

            NSError* audio_add_error = nil;
            if (capture_options.capture_audio) {
                dispatch_queue_t audio_queue = dispatch_queue_create(
                    "com.macrdp.cpp.audio-capture",
                    DISPATCH_QUEUE_SERIAL);
                if ([new_stream addStreamOutput:new_output
                    type:SCStreamOutputTypeAudio
                    sampleHandlerQueue:audio_queue
                    error:&audio_add_error]) {
                    audio_registered = true;
                }
            }

            if (!audio_registered && audio_add_error != nil) {
                // Screen capture remains useful when the system has no audio
                // source or refuses audio output; RDPSND will simply stay idle.
                NSLog(@"macrdp: audio capture unavailable: %@", audio_add_error);
            }

            if (waiter->timed_out()) {
                remove_stream_outputs(new_stream, new_output, audio_registered);
                new_stream = nil;
                new_output = nil;
                audio_registered = false;
                return;
            }

            auto cleanup_stream = [
                state_for_callback,
                generation,
                stream_to_stop = new_stream,
                output_to_remove = new_output,
                audio_registered_for_cleanup = audio_registered] {
                deactivate_capture_generation(state_for_callback, generation);
                stop_stream_without_waiting(
                    stream_to_stop,
                    output_to_remove,
                    audio_registered_for_cleanup);
            };
            waiter->set_timeout_handler(cleanup_stream);
            if (waiter->timed_out()) {
                return;
            }

            [new_stream startCaptureWithCompletionHandler:^(NSError* start_error) {
                if (start_error != nil) {
                    (void)waiter->finish_and_invoke_timeout_handler(
                        error_description(start_error));
                    return;
                }

                if (!waiter->finish()) {
                    deactivate_capture_generation(state_for_callback, generation);
                }
            }];
            if (waiter->timed_out()) {
                // The timeout handler may have raced immediately before the
                // start request. Issue a second stop after start was invoked.
                stop_stream_without_waiting(
                    new_stream,
                    new_output,
                    audio_registered);
            }
        }
    }];

    const auto result = waiter->wait_for(timeout);
    if (!result.completed) {
        return {
            false,
            "ScreenCaptureKit start timed out after "
                + std::to_string(timeout.count()) + " ms"};
    }
    if (!result.error.empty()) {
        return {false, result.error};
    }
    if (new_stream == nil || new_output == nil) {
        stop_stream_without_waiting(new_stream, new_output, audio_registered);
        return {false, "ScreenCaptureKit completed without a valid stream"};
    }

    stream_ = new_stream;
    output_ = new_output;
    audio_output_registered_ = audio_registered;
    return {true, {}};
}

void ScreenCaptureKitBackend::stop(std::chrono::milliseconds timeout) noexcept {
    if (stream_ == nil) {
        return;
    }
    stop_stream(stream_, output_, audio_output_registered_, timeout);
    stream_ = nil;
    output_ = nil;
    audio_output_registered_ = false;
}

bool DisplayCapture::Impl::start_locked() {
    detail::CaptureGeneration generation = 0;
    {
        std::lock_guard lock(state->mutex);
        generation = ++state->generation;
        if (state->latest_frame.has_value()) {
            recycle_frame_locked(*state, std::move(*state->latest_frame));
        }
        state->latest_frame.reset();
        state->latest_audio.reset();
        state->error.clear();
        state->accepting_frames = false;
        state->stopped = false;
    }

    const auto result = backend->start(
        options,
        state,
        generation,
        capture_start_timeout);
    if (!result.started) {
        set_capture_error(
            state,
            generation,
            result.error.empty()
                ? "Unable to start ScreenCaptureKit stream"
                : result.error);
        return false;
    }
    if (!activate_capture_generation(state, generation)) {
        backend->stop(capture_stop_timeout);
        set_capture_error(
            state,
            generation,
            "ScreenCaptureKit stream was superseded while starting");
        return false;
    }

    started = true;
    return true;
}

bool DisplayCapture::Impl::start() {
    std::lock_guard lifecycle_lock(lifecycle_mutex);
    if (started) {
        return true;
    }
    return start_locked();
}

bool DisplayCapture::Impl::reconfigure(DisplayCaptureOptions next_options) {
    std::lock_guard lifecycle_lock(lifecycle_mutex);
    if (started) {
        {
            std::lock_guard lock(state->mutex);
            state->accepting_frames = false;
            state->stopped = true;
        }
        state->frame_condition.notify_all();
        state->audio_condition.notify_all();
        backend->stop(capture_stop_timeout);
        started = false;
    }
    options = next_options;
    return start_locked();
}

std::optional<Frame> DisplayCapture::Impl::next_frame(
    std::chrono::milliseconds timeout) {
    std::unique_lock lock(state->mutex);
    const auto ready = [this] {
        return state->latest_frame.has_value() || state->stopped;
    };
    if (!state->frame_condition.wait_for(lock, timeout, ready)) {
        return std::nullopt;
    }
    if (!state->latest_frame.has_value()) {
        return std::nullopt;
    }

    Frame frame = std::move(*state->latest_frame);
    state->latest_frame.reset();
    return frame;
}

std::optional<AudioFrame> DisplayCapture::Impl::next_audio(
    std::chrono::milliseconds timeout) {
    std::unique_lock lock(state->mutex);
    const auto ready = [this] {
        return state->latest_audio.has_value() || state->stopped;
    };
    if (!state->audio_condition.wait_for(lock, timeout, ready)) {
        return std::nullopt;
    }
    if (!state->latest_audio.has_value()) {
        return std::nullopt;
    }

    AudioFrame frame = std::move(*state->latest_audio);
    state->latest_audio.reset();
    return frame;
}

void DisplayCapture::Impl::recycle_frame(Frame frame) noexcept {
    try {
        std::lock_guard lock(state->mutex);
        if (!state->accepting_frames || state->stopped) {
            return;
        }
        recycle_frame_locked(*state, std::move(frame));
    } catch (...) {
        // Recycling must never affect shutdown or the publish thread.
    }
}

void DisplayCapture::Impl::stop() noexcept {
    std::lock_guard lifecycle_lock(lifecycle_mutex);
    {
        std::lock_guard lock(state->mutex);
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->frame_condition.notify_all();
    state->audio_condition.notify_all();

    if (started) {
        backend->stop(capture_stop_timeout);
        started = false;
    }
}

std::string DisplayCapture::Impl::last_error() const {
    std::lock_guard lock(state->mutex);
    return state->error;
}

DisplayCapture::DisplayCapture(DisplayCaptureOptions options)
    : impl_(std::make_unique<Impl>(
          options,
          std::make_unique<ScreenCaptureKitBackend>())) {}

DisplayCapture::DisplayCapture(
    DisplayCaptureOptions options,
    std::unique_ptr<detail::DisplayCaptureBackend> backend)
    : impl_(std::make_unique<Impl>(
          options,
          backend == nullptr
              ? std::make_unique<ScreenCaptureKitBackend>()
              : std::move(backend))) {}

DisplayCapture::~DisplayCapture() = default;

DisplayCapture::DisplayCapture(DisplayCapture&&) noexcept = default;

DisplayCapture& DisplayCapture::operator=(DisplayCapture&&) noexcept = default;

bool DisplayCapture::start() {
    return impl_->start();
}

std::optional<Frame> DisplayCapture::next_frame(std::chrono::milliseconds timeout) {
    return impl_->next_frame(timeout);
}

std::optional<AudioFrame> DisplayCapture::next_audio(std::chrono::milliseconds timeout) {
    return impl_->next_audio(timeout);
}

void DisplayCapture::recycle_frame(Frame frame) noexcept {
    impl_->recycle_frame(std::move(frame));
}

bool DisplayCapture::reconfigure(DisplayCaptureOptions options) {
    return impl_->reconfigure(options);
}

void DisplayCapture::stop() noexcept {
    impl_->stop();
}

std::string DisplayCapture::last_error() const {
    return impl_->last_error();
}

} // namespace macrdp
