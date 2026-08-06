#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "macrdp/display_capture.hpp"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

namespace {

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

struct CompletionWaiter {
    std::mutex mutex;
    std::condition_variable condition;
    bool complete = false;
    std::string error;

    void finish(NSError* error_value) {
        finish_message(error_value == nil ? std::string{} : error_description(error_value));
    }

    void finish_message(std::string error_message) {
        {
            std::lock_guard lock(mutex);
            complete = true;
            error = std::move(error_message);
        }
        condition.notify_one();
    }

    [[nodiscard]] bool wait() {
        std::unique_lock lock(mutex);
        condition.wait(lock, [this] { return complete; });
        return error.empty();
    }
};

struct CaptureState {
    mutable std::mutex mutex;
    std::condition_variable condition;
    std::optional<macrdp::Frame> latest_frame;
    std::string error;
    bool accepting_frames = false;
    bool stopped = true;
};

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

    macrdp::Frame copied;
    copied.width = static_cast<std::uint32_t>(width);
    copied.height = static_cast<std::uint32_t>(height);
    copied.stride = bytes_per_row;
    copied.timestamp_us = timestamp_us();
    copied.bgra.resize(bytes_per_row * height);

    for (std::size_t y = 0; y < height; ++y) {
        std::memcpy(
            copied.bgra.data() + y * bytes_per_row,
            base_address + y * bytes_per_row,
            bytes_per_row);
    }

    CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    frame = std::move(copied);
    return true;
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
}

- (instancetype)initWithState:(std::shared_ptr<CaptureState>)state;
@end

@implementation MacCaptureOutput

- (instancetype)initWithState:(std::shared_ptr<CaptureState>)state {
    self = [super init];
    if (self != nil) {
        state_ = std::move(state);
    }
    return self;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || sampleBuffer == nullptr) {
        return;
    }

    macrdp::Frame frame;
    if (!copy_sample_buffer(sampleBuffer, frame)) {
        return;
    }

    const auto state = state_;
    {
        std::lock_guard lock(state->mutex);
        if (!state->accepting_frames) {
            return;
        }

        // Keep only the newest frame. A remote desktop stream must prefer a
        // current image over a queue of old images waiting to be encoded.
        state->latest_frame = std::move(frame);
    }
    state->condition.notify_one();
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    const auto state = state_;
    {
        std::lock_guard lock(state->mutex);
        if (error != nil) {
            state->error = error_description(error);
        } else if (state->accepting_frames) {
            state->error = "ScreenCaptureKit stream stopped unexpectedly";
        }
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->condition.notify_all();
}

@end

namespace macrdp {

struct DisplayCapture::Impl {
    explicit Impl(DisplayCaptureOptions capture_options)
        : options(capture_options), state(std::make_shared<CaptureState>()) {}

    ~Impl() {
        stop();
    }

    [[nodiscard]] bool start();
    [[nodiscard]] std::optional<Frame> next_frame(std::chrono::milliseconds timeout);
    void stop() noexcept;
    [[nodiscard]] std::string last_error() const;

    DisplayCaptureOptions options;
    std::shared_ptr<CaptureState> state;
    std::mutex lifecycle_mutex;
    SCStream* stream = nil;
    MacCaptureOutput* output = nil;
};

namespace {

void set_capture_error(
    const std::shared_ptr<CaptureState>& state,
    std::string error) {
    {
        std::lock_guard lock(state->mutex);
        state->error = std::move(error);
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->condition.notify_all();
}

void stop_stream(SCStream* stream, MacCaptureOutput* output) {
    if (stream == nil) {
        return;
    }

    auto waiter = std::make_shared<CompletionWaiter>();
    [stream stopCaptureWithCompletionHandler:^(NSError* error) {
        waiter->finish(error);
    }];
    (void)waiter->wait();

    if (output != nil) {
        [stream removeStreamOutput:output type:SCStreamOutputTypeScreen error:nil];
    }
}

} // namespace

bool DisplayCapture::Impl::start() {
    std::lock_guard lifecycle_lock(lifecycle_mutex);
    if (stream != nil) {
        return true;
    }

    {
        std::lock_guard lock(state->mutex);
        state->latest_frame.reset();
        state->error.clear();
        state->accepting_frames = false;
        state->stopped = false;
    }

    const auto state_for_callback = state;
    const auto capture_options = options;
    auto waiter = std::make_shared<CompletionWaiter>();
    __block SCStream* new_stream = nil;
    __block MacCaptureOutput* new_output = nil;

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
        onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent* content, NSError* error) {
        @autoreleasepool {
            if (error != nil) {
                waiter->finish(error);
                return;
            }
            if (content == nil || [content.displays count] == 0) {
                waiter->finish_message(
                    "ScreenCaptureKit returned no shareable displays");
                return;
            }

            SCDisplay* selected_display = nil;
            const auto main_display_id = CGMainDisplayID();
            for (SCDisplay* display in content.displays) {
                if ([display displayID] == main_display_id) {
                    selected_display = display;
                    break;
                }
            }
            if (selected_display == nil) {
                selected_display = [content.displays firstObject];
            }

            const auto display_id = [selected_display displayID];
            const auto [width, height] = output_size(display_id, capture_options);
            if (width == 0 || height == 0) {
                waiter->finish_message(
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
            configuration.capturesAudio = NO;
            configuration.queueDepth = 2;
            configuration.preservesAspectRatio = YES;
            configuration.scalesToFit = YES;
            configuration.shouldBeOpaque = YES;
            configuration.ignoreShadowsDisplay = YES;

            new_output = [[MacCaptureOutput alloc] initWithState:state_for_callback];
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
                waiter->finish(add_error);
                return;
            }

            {
                std::lock_guard lock(state_for_callback->mutex);
                state_for_callback->accepting_frames = true;
            }

            [new_stream startCaptureWithCompletionHandler:^(NSError* start_error) {
                waiter->finish(start_error);
            }];
        }
    }];

    const bool started = waiter->wait();
    if (!started) {
        if (new_stream != nil) {
            stop_stream(new_stream, new_output);
        }
        {
            std::lock_guard lock(state->mutex);
            state->accepting_frames = false;
        }
        if (!waiter->error.empty()) {
            set_capture_error(state, waiter->error);
        } else {
            set_capture_error(state, "Unable to start ScreenCaptureKit stream");
        }
        return false;
    }

    stream = new_stream;
    output = new_output;
    return true;
}

std::optional<Frame> DisplayCapture::Impl::next_frame(
    std::chrono::milliseconds timeout) {
    std::unique_lock lock(state->mutex);
    const auto ready = [this] {
        return state->latest_frame.has_value() || state->stopped;
    };
    if (!state->condition.wait_for(lock, timeout, ready)) {
        return std::nullopt;
    }
    if (!state->latest_frame.has_value()) {
        return std::nullopt;
    }

    Frame frame = std::move(*state->latest_frame);
    state->latest_frame.reset();
    return frame;
}

void DisplayCapture::Impl::stop() noexcept {
    std::lock_guard lifecycle_lock(lifecycle_mutex);
    {
        std::lock_guard lock(state->mutex);
        state->accepting_frames = false;
        state->stopped = true;
    }
    state->condition.notify_all();

    if (stream != nil) {
        stop_stream(stream, output);
        stream = nil;
        output = nil;
    }
}

std::string DisplayCapture::Impl::last_error() const {
    std::lock_guard lock(state->mutex);
    return state->error;
}

DisplayCapture::DisplayCapture(DisplayCaptureOptions options)
    : impl_(std::make_unique<Impl>(options)) {}

DisplayCapture::~DisplayCapture() = default;

DisplayCapture::DisplayCapture(DisplayCapture&&) noexcept = default;

DisplayCapture& DisplayCapture::operator=(DisplayCapture&&) noexcept = default;

bool DisplayCapture::start() {
    return impl_->start();
}

std::optional<Frame> DisplayCapture::next_frame(std::chrono::milliseconds timeout) {
    return impl_->next_frame(timeout);
}

void DisplayCapture::stop() noexcept {
    impl_->stop();
}

std::string DisplayCapture::last_error() const {
    return impl_->last_error();
}

} // namespace macrdp
