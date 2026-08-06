#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "macrdp/videotoolbox_h264.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::uint8_t kAnnexBStartCode[] = {0x00, 0x00, 0x00, 0x01};
std::atomic_bool g_encoder_enabled{true};

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

bool append_parameter_sets(
    CMFormatDescriptionRef format_description,
    std::vector<std::uint8_t>& output) {
    std::size_t parameter_set_count = 0;
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

    for (std::size_t index = 0; index < parameter_set_count; ++index) {
        const std::uint8_t* parameter_set = nullptr;
        std::size_t parameter_set_size = 0;
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
    std::vector<std::uint8_t>& output) {
    if (sample_buffer == nullptr) {
        return false;
    }

    auto* format_description = CMSampleBufferGetFormatDescription(sample_buffer);
    auto* block_buffer = CMSampleBufferGetDataBuffer(sample_buffer);
    if (format_description == nullptr || block_buffer == nullptr) {
        return false;
    }

    std::size_t parameter_set_count = 0;
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

    output.clear();
    if (sample_is_key_frame(sample_buffer)
        && !append_parameter_sets(format_description, output)) {
        return false;
    }
    return append_avcc_sample(block_buffer, nal_unit_header_length, output);
}

CFDictionaryRef force_key_frame_properties() {
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

} // namespace

struct macrdp_vt_h264_encoder {
    VTCompressionSessionRef session = nullptr;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t frame_rate = 30;
    std::uint32_t key_frame_interval = 60;
    mutable std::mutex mutex;
    std::condition_variable output_condition;
    std::deque<std::vector<std::uint8_t>> pending_packets;
    std::vector<std::uint8_t> output_packet;
    std::string error;
    std::uint64_t completed_callbacks = 0;
};

namespace {

void set_error(macrdp_vt_h264_encoder* encoder, std::string message) {
    {
        std::lock_guard lock(encoder->mutex);
        if (encoder->error.empty()) {
            encoder->error = std::move(message);
        }
    }
    encoder->output_condition.notify_all();
}

void compression_output_callback(
    void* output_callback_ref_con,
    void* source_frame_ref_con,
    OSStatus status,
    VTEncodeInfoFlags info_flags,
    CMSampleBufferRef sample_buffer) {
    (void)source_frame_ref_con;
    (void)info_flags;
    auto* encoder = static_cast<macrdp_vt_h264_encoder*>(output_callback_ref_con);
    std::vector<std::uint8_t> packet;
    std::string callback_error;
    if (status != noErr) {
        callback_error = status_description(status, "VideoToolbox callback");
    } else if (sample_buffer == nullptr || !sample_to_annex_b(sample_buffer, packet)) {
        callback_error = "Unable to convert VideoToolbox H.264 output to Annex B";
    }

    {
        std::lock_guard lock(encoder->mutex);
        ++encoder->completed_callbacks;
        if (!callback_error.empty()) {
            if (encoder->error.empty()) {
                encoder->error = std::move(callback_error);
            }
        } else {
            encoder->pending_packets.push_back(std::move(packet));
        }
    }
    encoder->output_condition.notify_all();
}

bool create_pixel_buffer(
    macrdp_vt_h264_encoder* encoder,
    CVPixelBufferRef* pixel_buffer) {
    *pixel_buffer = nullptr;
    auto* pool = VTCompressionSessionGetPixelBufferPool(encoder->session);
    if (pool != nullptr) {
        const auto status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            pixel_buffer);
        if (status == kCVReturnSuccess && *pixel_buffer != nullptr) {
            return true;
        }
    }

    NSDictionary* attributes = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge id)kCVPixelBufferWidthKey: @(encoder->width),
        (__bridge id)kCVPixelBufferHeightKey: @(encoder->height),
        (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    return CVPixelBufferCreate(
               kCFAllocatorDefault,
               encoder->width,
               encoder->height,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               (__bridge CFDictionaryRef)attributes,
               pixel_buffer)
        == kCVReturnSuccess
        && *pixel_buffer != nullptr;
}

bool copy_i420_to_nv12(
    macrdp_vt_h264_encoder* encoder,
    const std::uint8_t* y_plane,
    const std::uint8_t* u_plane,
    const std::uint8_t* v_plane,
    const std::uint32_t strides[3],
    CVPixelBufferRef pixel_buffer) {
    if (y_plane == nullptr || u_plane == nullptr || v_plane == nullptr || strides == nullptr) {
        return false;
    }

    if (CVPixelBufferGetPlaneCount(pixel_buffer) != 2) {
        return false;
    }

    const auto chroma_width = (encoder->width + 1) / 2;
    const auto chroma_height = (encoder->height + 1) / 2;
    if (strides[0] < encoder->width
        || strides[1] < chroma_width
        || strides[2] < chroma_width) {
        return false;
    }
    const auto destination_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0);
    const auto destination_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1);
    if (destination_y_stride < encoder->width
        || destination_uv_stride < chroma_width * 2) {
        return false;
    }

    auto* destination_y = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0));
    auto* destination_uv = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1));
    if (destination_y == nullptr || destination_uv == nullptr) {
        return false;
    }

    for (std::uint32_t row = 0; row < encoder->height; ++row) {
        std::memcpy(
            destination_y + static_cast<std::size_t>(row) * destination_y_stride,
            y_plane + static_cast<std::size_t>(row) * strides[0],
            encoder->width);
    }

    for (std::uint32_t row = 0; row < chroma_height; ++row) {
        auto* destination_row = destination_uv
            + static_cast<std::size_t>(row) * destination_uv_stride;
        const auto* source_u = u_plane + static_cast<std::size_t>(row) * strides[1];
        const auto* source_v = v_plane + static_cast<std::size_t>(row) * strides[2];
        for (std::uint32_t column = 0; column < chroma_width; ++column) {
            destination_row[column * 2] = source_u[column];
            destination_row[column * 2 + 1] = source_v[column];
        }
    }
    return true;
}

} // namespace

extern "C" macrdp_vt_h264_encoder* macrdp_vt_h264_encoder_new(
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t bitrate,
    std::uint32_t frame_rate,
    std::uint32_t key_frame_interval) {
    if (!g_encoder_enabled.load(std::memory_order_acquire)) {
        return nullptr;
    }
    if (width == 0 || height == 0
        || width > static_cast<std::uint32_t>(std::numeric_limits<int32_t>::max())
        || height > static_cast<std::uint32_t>(std::numeric_limits<int32_t>::max())) {
        return nullptr;
    }

    auto* encoder = new macrdp_vt_h264_encoder{};
    encoder->width = width;
    encoder->height = height;
    encoder->frame_rate = std::clamp(frame_rate == 0 ? 30U : frame_rate, 1U, 60U);
    encoder->key_frame_interval = key_frame_interval == 0 ? 60 : key_frame_interval;

    NSDictionary* attributes = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge id)kCVPixelBufferWidthKey: @(width),
        (__bridge id)kCVPixelBufferHeightKey: @(height),
        (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    const auto status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        static_cast<int32_t>(width),
        static_cast<int32_t>(height),
        kCMVideoCodecType_H264,
        nullptr,
        (__bridge CFDictionaryRef)attributes,
        nullptr,
        compression_output_callback,
        encoder,
        &encoder->session);
    if (status != noErr || encoder->session == nullptr) {
        if (encoder->session != nullptr) {
            VTCompressionSessionInvalidate(encoder->session);
            CFRelease(encoder->session);
        }
        delete encoder;
        return nullptr;
    }

    (void)VTSessionSetProperty(
        encoder->session,
        kVTCompressionPropertyKey_RealTime,
        kCFBooleanTrue);
    (void)VTSessionSetProperty(
        encoder->session,
        kVTCompressionPropertyKey_AllowFrameReordering,
        kCFBooleanFalse);
    // The RDP codec API is synchronous. Do not let VideoToolbox build an
    // unbounded compression window while the client thread is handling input.
    (void)set_number_property(
        encoder->session,
        kVTCompressionPropertyKey_MaxFrameDelayCount,
        0);
    (void)VTSessionSetProperty(
        encoder->session,
        kVTCompressionPropertyKey_ProfileLevel,
        kVTProfileLevel_H264_Main_AutoLevel);
    (void)set_number_property(
        encoder->session,
        kVTCompressionPropertyKey_ExpectedFrameRate,
        static_cast<std::int32_t>(encoder->frame_rate));
    (void)set_number_property(
        encoder->session,
        kVTCompressionPropertyKey_AverageBitRate,
        static_cast<std::int32_t>(std::min<std::uint32_t>(
            bitrate == 0 ? 16'000'000U : bitrate,
            static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()))));
    (void)set_number_property(
        encoder->session,
        kVTCompressionPropertyKey_MaxKeyFrameInterval,
        static_cast<std::int32_t>(std::min<std::uint32_t>(
            encoder->key_frame_interval,
            static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()))));
    (void)VTCompressionSessionPrepareToEncodeFrames(encoder->session);
    return encoder;
}

extern "C" void macrdp_vt_h264_encoder_set_enabled(int enabled) {
    g_encoder_enabled.store(enabled != 0, std::memory_order_release);
}

extern "C" void macrdp_vt_h264_encoder_free(macrdp_vt_h264_encoder* encoder) {
    if (encoder == nullptr) {
        return;
    }
    if (encoder->session != nullptr) {
        (void)VTCompressionSessionCompleteFrames(encoder->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(encoder->session);
        CFRelease(encoder->session);
    }
    delete encoder;
}

extern "C" int macrdp_vt_h264_encoder_encode(
    macrdp_vt_h264_encoder* encoder,
    const std::uint8_t* y_plane,
    const std::uint8_t* u_plane,
    const std::uint8_t* v_plane,
    const std::uint32_t strides[3],
    std::uint64_t frame_index,
    std::uint8_t** output,
    std::uint32_t* output_size) {
    if (encoder == nullptr || encoder->session == nullptr || output == nullptr
        || output_size == nullptr) {
        return -1;
    }
    *output = nullptr;
    *output_size = 0;

    CVPixelBufferRef pixel_buffer = nullptr;
    if (!create_pixel_buffer(encoder, &pixel_buffer)) {
        set_error(encoder, "Unable to allocate a VideoToolbox NV12 pixel buffer");
        return -1;
    }

    if (CVPixelBufferLockBaseAddress(pixel_buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixel_buffer);
        set_error(encoder, "Unable to lock VideoToolbox NV12 pixel buffer");
        return -1;
    }
    const bool copied = copy_i420_to_nv12(
        encoder,
        y_plane,
        u_plane,
        v_plane,
        strides,
        pixel_buffer);
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    if (!copied) {
        CVPixelBufferRelease(pixel_buffer);
        set_error(encoder, "Unable to copy I420 data into VideoToolbox NV12 buffer");
        return -1;
    }

    CFDictionaryRef frame_properties = nullptr;
    if (frame_index == 0 || frame_index % encoder->key_frame_interval == 0) {
        frame_properties = force_key_frame_properties();
    }
    std::uint64_t callback_count = 0;
    bool encoder_ready = true;
    {
        std::lock_guard lock(encoder->mutex);
        encoder_ready = encoder->error.empty();
        callback_count = encoder->completed_callbacks;
    }
    if (!encoder_ready) {
        if (frame_properties != nullptr) {
            CFRelease(frame_properties);
        }
        CVPixelBufferRelease(pixel_buffer);
        return -1;
    }

    VTEncodeInfoFlags info_flags = 0;
    const auto encode_status = VTCompressionSessionEncodeFrame(
        encoder->session,
        pixel_buffer,
        CMTimeMake(
            static_cast<int64_t>(std::min<std::uint64_t>(
                frame_index,
                static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max()))),
            static_cast<int32_t>(encoder->frame_rate)),
        CMTimeMake(1, static_cast<int32_t>(encoder->frame_rate)),
        frame_properties,
        nullptr,
        &info_flags);
    if (frame_properties != nullptr) {
        CFRelease(frame_properties);
    }
    CVPixelBufferRelease(pixel_buffer);
    if (encode_status != noErr) {
        set_error(encoder, status_description(encode_status, "VTCompressionSessionEncodeFrame"));
        return -1;
    }

    // VideoToolbox may invoke the callback asynchronously even when the
    // session is configured for real-time, zero-reordering output. Wait for
    // this submission's callback before exposing its packet to FreeRDP; the
    // RDP codec API has no frame identity to repair a late result later.
    std::unique_lock lock(encoder->mutex);
    constexpr auto callback_timeout = std::chrono::seconds{5};
    if (!encoder->output_condition.wait_for(lock, callback_timeout, [&] {
            return encoder->completed_callbacks > callback_count || !encoder->error.empty();
        })) {
        if (encoder->error.empty()) {
            encoder->error = "VideoToolbox H.264 output callback timed out";
        }
        return -1;
    }
    if (!encoder->error.empty()) {
        return -1;
    }
    if (encoder->pending_packets.empty()) {
        return 0;
    }

    encoder->output_packet = std::move(encoder->pending_packets.front());
    encoder->pending_packets.pop_front();
    if (encoder->output_packet.empty()
        || encoder->output_packet.size() > std::numeric_limits<std::uint32_t>::max()) {
        encoder->error = "VideoToolbox returned an invalid H.264 packet";
        return -1;
    }
    *output = encoder->output_packet.data();
    *output_size = static_cast<std::uint32_t>(encoder->output_packet.size());
    return 1;
}

extern "C" const char* macrdp_vt_h264_encoder_last_error(
    const macrdp_vt_h264_encoder* encoder) {
    if (encoder == nullptr) {
        return "invalid VideoToolbox encoder";
    }
    std::lock_guard lock(encoder->mutex);
    return encoder->error.c_str();
}
