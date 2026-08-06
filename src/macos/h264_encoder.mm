#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "macrdp/h264_encoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <mutex>
#include <utility>

namespace {

constexpr std::uint8_t kAnnexBStartCode[] = {0x00, 0x00, 0x00, 0x01};

std::string status_description(OSStatus status, const char* operation) {
    return std::string(operation) + " failed with OSStatus "
        + std::to_string(static_cast<std::int32_t>(status));
}

void append_start_code(std::vector<std::uint8_t>& output) {
    output.insert(
        output.end(),
        std::begin(kAnnexBStartCode),
        std::end(kAnnexBStartCode));
}

bool append_nal(
    std::vector<std::uint8_t>& output,
    const std::uint8_t* data,
    std::size_t size) {
    if (data == nullptr || size == 0) {
        return false;
    }
    append_start_code(output);
    output.insert(output.end(), data, data + size);
    return true;
}

std::uint64_t sample_timestamp_us(CMSampleBufferRef sample_buffer) {
    const CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
    if (!CMTIME_IS_NUMERIC(timestamp) || timestamp.timescale <= 0
        || timestamp.value < 0) {
        return 0;
    }

    const auto seconds = CMTimeGetSeconds(timestamp);
    if (!std::isfinite(seconds) || seconds <= 0.0) {
        return 0;
    }
    const auto microseconds = seconds * 1'000'000.0;
    if (microseconds >= static_cast<double>(std::numeric_limits<std::uint64_t>::max())) {
        return std::numeric_limits<std::uint64_t>::max();
    }
    return static_cast<std::uint64_t>(microseconds);
}

bool sample_is_key_frame(CMSampleBufferRef sample_buffer) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(
        sample_buffer,
        false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
        return true;
    }

    const auto* dictionary = static_cast<CFDictionaryRef>(
        CFArrayGetValueAtIndex(attachments, 0));
    const auto* not_sync = static_cast<CFBooleanRef>(CFDictionaryGetValue(
        dictionary,
        kCMSampleAttachmentKey_NotSync));
    return not_sync == nullptr || !CFBooleanGetValue(not_sync);
}

bool append_parameter_sets(
    CMFormatDescriptionRef format_description,
    std::vector<std::uint8_t>& output) {
    size_t parameter_set_count = 0;
    int nal_unit_header_length = 0;
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format_description,
        0,
        nullptr,
        nullptr,
        &parameter_set_count,
        &nal_unit_header_length);
    if (status != noErr || parameter_set_count == 0 || nal_unit_header_length <= 0) {
        return false;
    }

    for (size_t index = 0; index < parameter_set_count; ++index) {
        const std::uint8_t* parameter_set = nullptr;
        size_t parameter_set_size = 0;
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_description,
            index,
            &parameter_set,
            &parameter_set_size,
            nullptr,
            nullptr);
        if (status != noErr || !append_nal(output, parameter_set, parameter_set_size)) {
            return false;
        }
    }
    return true;
}

bool append_avcc_sample(
    CMBlockBufferRef block_buffer,
    int nal_unit_header_length,
    std::vector<std::uint8_t>& output) {
    if (nal_unit_header_length <= 0 || nal_unit_header_length > 4) {
        return false;
    }

    const auto data_length = CMBlockBufferGetDataLength(block_buffer);
    if (data_length == 0) {
        return false;
    }

    std::vector<std::uint8_t> data(data_length);
    if (CMBlockBufferCopyDataBytes(block_buffer, 0, data_length, data.data()) != noErr) {
        return false;
    }

    std::size_t offset = 0;
    while (offset < data.size()) {
        if (data.size() - offset < static_cast<std::size_t>(nal_unit_header_length)) {
            return false;
        }

        std::size_t nal_size = 0;
        for (int index = 0; index < nal_unit_header_length; ++index) {
            nal_size = (nal_size << 8) | data[offset + static_cast<std::size_t>(index)];
        }
        offset += static_cast<std::size_t>(nal_unit_header_length);
        if (nal_size == 0 || nal_size > data.size() - offset) {
            return false;
        }
        if (!append_nal(output, data.data() + offset, nal_size)) {
            return false;
        }
        offset += nal_size;
    }
    return true;
}

bool sample_to_annex_b(
    CMSampleBufferRef sample_buffer,
    macrdp::EncodedPacket& packet) {
    if (sample_buffer == nullptr) {
        return false;
    }

    auto* format_description = CMSampleBufferGetFormatDescription(sample_buffer);
    auto* block_buffer = CMSampleBufferGetDataBuffer(sample_buffer);
    if (format_description == nullptr || block_buffer == nullptr) {
        return false;
    }

    size_t parameter_set_count = 0;
    int nal_unit_header_length = 0;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_description,
            0,
            nullptr,
            nullptr,
            &parameter_set_count,
            &nal_unit_header_length) != noErr
        || nal_unit_header_length <= 0) {
        return false;
    }

    packet.key_frame = sample_is_key_frame(sample_buffer);
    if (packet.key_frame && !append_parameter_sets(format_description, packet.annex_b)) {
        return false;
    }
    if (!append_avcc_sample(block_buffer, nal_unit_header_length, packet.annex_b)) {
        return false;
    }
    packet.timestamp_us = sample_timestamp_us(sample_buffer);
    return true;
}

CFDictionaryRef frame_properties_force_key_frame() {
    const void* keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
    const void* values[] = {kCFBooleanTrue};
    return CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
}

} // namespace

namespace macrdp {

struct H264Encoder::Impl {
    explicit Impl(H264EncoderOptions encoder_options)
        : options(encoder_options) {}

    ~Impl() {
        if (session != nullptr) {
            (void)VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
            VTCompressionSessionInvalidate(session);
            CFRelease(session);
        }
    }

    [[nodiscard]] bool encode(const Frame& frame, std::vector<EncodedPacket>& output);
    [[nodiscard]] bool flush(std::vector<EncodedPacket>& output);
    [[nodiscard]] std::string last_error() const;

    bool initialize(const Frame& frame);
    void handle_output(OSStatus status, CMSampleBufferRef sample_buffer);
    static void compression_output_callback(
        void* output_callback_ref_con,
        void* source_frame_ref_con,
        OSStatus status,
        VTEncodeInfoFlags info_flags,
        CMSampleBufferRef sample_buffer);
    void set_error(std::string error);
    void drain(std::vector<EncodedPacket>& output);

    H264EncoderOptions options;
    VTCompressionSessionRef session = nullptr;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint64_t frame_index = 0;
    std::uint64_t last_timestamp_us = 0;
    mutable std::mutex mutex;
    std::vector<EncodedPacket> pending_packets;
    std::string error;
};

bool set_number_property(
    VTCompressionSessionRef session,
    CFStringRef key,
    std::int32_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (number == nullptr) {
        return false;
    }
    const auto status = VTSessionSetProperty(session, key, number);
    CFRelease(number);
    return status == noErr;
}

void H264Encoder::Impl::compression_output_callback(
    void* output_callback_ref_con,
    void* source_frame_ref_con,
    OSStatus status,
    VTEncodeInfoFlags info_flags,
    CMSampleBufferRef sample_buffer) {
    (void)source_frame_ref_con;
    (void)info_flags;
    auto* encoder = static_cast<Impl*>(output_callback_ref_con);
    encoder->handle_output(status, sample_buffer);
}

void H264Encoder::Impl::set_error(std::string error_message) {
    std::lock_guard lock(mutex);
    if (error.empty()) {
        error = std::move(error_message);
    }
}

void H264Encoder::Impl::handle_output(
    OSStatus status,
    CMSampleBufferRef sample_buffer) {
    if (status != noErr) {
        set_error(status_description(status, "VideoToolbox callback"));
        return;
    }
    if (sample_buffer == nullptr) {
        set_error("VideoToolbox returned an empty sample buffer");
        return;
    }

    EncodedPacket packet;
    if (!sample_to_annex_b(sample_buffer, packet)) {
        set_error("Unable to convert VideoToolbox H.264 output to Annex B");
        return;
    }

    std::lock_guard lock(mutex);
    pending_packets.push_back(std::move(packet));
}

bool H264Encoder::Impl::initialize(const Frame& frame) {
    if (frame.width > std::numeric_limits<int32_t>::max()
        || frame.height > std::numeric_limits<int32_t>::max()) {
        set_error("Frame dimensions are too large for VideoToolbox");
        return false;
    }

    NSDictionary* image_buffer_attributes = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferWidthKey: @(frame.width),
        (__bridge id)kCVPixelBufferHeightKey: @(frame.height),
        (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    const auto status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        static_cast<int32_t>(frame.width),
        static_cast<int32_t>(frame.height),
        kCMVideoCodecType_H264,
        nullptr,
        (__bridge CFDictionaryRef)image_buffer_attributes,
        nullptr,
        &Impl::compression_output_callback,
        this,
        &session);
    if (status != noErr || session == nullptr) {
        set_error(status_description(status, "VTCompressionSessionCreate"));
        return false;
    }

    (void)VTSessionSetProperty(
        session,
        kVTCompressionPropertyKey_RealTime,
        kCFBooleanTrue);
    (void)VTSessionSetProperty(
        session,
        kVTCompressionPropertyKey_AllowFrameReordering,
        kCFBooleanFalse);
    // Keep the synchronous wrapper from waiting on an ever-growing encoder
    // queue. The RDP path needs output for each submitted frame promptly.
    (void)set_number_property(
        session,
        kVTCompressionPropertyKey_MaxFrameDelayCount,
        0);
    (void)VTSessionSetProperty(
        session,
        kVTCompressionPropertyKey_ProfileLevel,
        kVTProfileLevel_H264_Main_AutoLevel);

    const auto frame_rate = static_cast<std::int32_t>(std::clamp(
        options.frame_rate == 0 ? 30 : options.frame_rate,
        std::uint32_t{1},
        std::uint32_t{60}));
    const auto bitrate = static_cast<std::int32_t>(std::min<std::uint32_t>(
        options.bitrate_bits_per_second == 0 ? 4'000'000 : options.bitrate_bits_per_second,
        static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())));
    const auto key_interval = static_cast<std::int32_t>(std::min<std::uint32_t>(
        options.key_frame_interval == 0 ? 60 : options.key_frame_interval,
        static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())));
    (void)set_number_property(
        session,
        kVTCompressionPropertyKey_ExpectedFrameRate,
        frame_rate);
    (void)set_number_property(
        session,
        kVTCompressionPropertyKey_AverageBitRate,
        bitrate);
    (void)set_number_property(
        session,
        kVTCompressionPropertyKey_MaxKeyFrameInterval,
        key_interval);
    (void)VTCompressionSessionPrepareToEncodeFrames(session);

    width = frame.width;
    height = frame.height;
    return true;
}

void H264Encoder::Impl::drain(std::vector<EncodedPacket>& output) {
    std::lock_guard lock(mutex);
    output.insert(
        output.end(),
        std::make_move_iterator(pending_packets.begin()),
        std::make_move_iterator(pending_packets.end()));
    pending_packets.clear();
}

bool H264Encoder::Impl::encode(
    const Frame& frame,
    std::vector<EncodedPacket>& output) {
    output.clear();
    if (!frame.valid()) {
        set_error("Cannot encode an invalid BGRA frame");
        return false;
    }
    if (session == nullptr && !initialize(frame)) {
        return false;
    }
    if (frame.width != width || frame.height != height) {
        set_error("Frame dimensions changed after H.264 session creation");
        return false;
    }

    CVPixelBufferRef pixel_buffer = nullptr;
    const auto pixel_status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame.width,
        frame.height,
        kCVPixelFormatType_32BGRA,
        nullptr,
        &pixel_buffer);
    if (pixel_status != kCVReturnSuccess || pixel_buffer == nullptr) {
        set_error(status_description(pixel_status, "CVPixelBufferCreate"));
        return false;
    }

    const auto lock_status = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_status != kCVReturnSuccess) {
        CVPixelBufferRelease(pixel_buffer);
        set_error(status_description(lock_status, "CVPixelBufferLockBaseAddress"));
        return false;
    }
    auto* destination = static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddress(pixel_buffer));
    const auto destination_stride = CVPixelBufferGetBytesPerRow(pixel_buffer);
    const auto row_bytes = static_cast<std::size_t>(frame.width) * 4;
    if (destination == nullptr || destination_stride < row_bytes) {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
        CVPixelBufferRelease(pixel_buffer);
        set_error("VideoToolbox pixel buffer has an invalid layout");
        return false;
    }
    for (std::uint32_t y = 0; y < frame.height; ++y) {
        std::memcpy(
            destination + static_cast<std::size_t>(y) * destination_stride,
            frame.bgra.data() + static_cast<std::size_t>(y) * frame.stride,
            row_bytes);
    }
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

    std::uint64_t timestamp = frame.timestamp_us;
    if (timestamp <= last_timestamp_us) {
        timestamp = last_timestamp_us + 1;
    }
    last_timestamp_us = timestamp;
    const auto frame_rate = std::clamp(
        options.frame_rate == 0 ? 30 : options.frame_rate,
        std::uint32_t{1},
        std::uint32_t{60});
    const CMTime presentation_time = CMTimeMake(
        static_cast<int64_t>(std::min<std::uint64_t>(
            timestamp,
            static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max()))),
        1'000'000);
    const CMTime duration = CMTimeMake(1, static_cast<int32_t>(frame_rate));
    const auto key_interval = options.key_frame_interval == 0
        ? 60
        : options.key_frame_interval;
    const bool force_key_frame = frame_index == 0 || frame_index % key_interval == 0;
    CFDictionaryRef frame_properties = force_key_frame
        ? frame_properties_force_key_frame()
        : nullptr;

    VTEncodeInfoFlags info_flags = 0;
    const auto encode_status = VTCompressionSessionEncodeFrame(
        session,
        pixel_buffer,
        presentation_time,
        duration,
        frame_properties,
        nullptr,
        &info_flags);
    if (frame_properties != nullptr) {
        CFRelease(frame_properties);
    }
    CVPixelBufferRelease(pixel_buffer);
    ++frame_index;

    if (encode_status != noErr) {
        set_error(status_description(encode_status, "VTCompressionSessionEncodeFrame"));
        return false;
    }

    drain(output);
    return last_error().empty();
}

bool H264Encoder::Impl::flush(std::vector<EncodedPacket>& output) {
    output.clear();
    if (session == nullptr) {
        return last_error().empty();
    }
    const auto status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    if (status != noErr) {
        set_error(status_description(status, "VTCompressionSessionCompleteFrames"));
        return false;
    }
    drain(output);
    return last_error().empty();
}

std::string H264Encoder::Impl::last_error() const {
    std::lock_guard lock(mutex);
    return error;
}

H264Encoder::H264Encoder(H264EncoderOptions options)
    : impl_(std::make_unique<Impl>(options)) {}

H264Encoder::~H264Encoder() = default;

H264Encoder::H264Encoder(H264Encoder&&) noexcept = default;

H264Encoder& H264Encoder::operator=(H264Encoder&&) noexcept = default;

bool H264Encoder::encode(const Frame& frame, std::vector<EncodedPacket>& output) {
    return impl_->encode(frame, output);
}

bool H264Encoder::flush(std::vector<EncodedPacket>& output) {
    return impl_->flush(output);
}

std::string H264Encoder::last_error() const {
    return impl_->last_error();
}

} // namespace macrdp
