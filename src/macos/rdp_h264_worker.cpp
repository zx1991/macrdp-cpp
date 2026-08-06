#include "macrdp/rdp_h264_worker.h"

#include <freerdp/codec/h264.h>

#include "shadow_encoder.h"

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace {

struct EncodeJob {
    std::vector<BYTE> frame;
    UINT32 stride = 0;
    UINT32 width = 0;
    UINT32 height = 0;
    UINT32 format = 0;
    UINT32 codec_id = 0;
    RECTANGLE_16 region{};
    bool full_frame = false;
};

void clear_encoded_frame(macrdp_h264_encoded_frame& frame) {
    std::memset(&frame, 0, sizeof(frame));
}

bool copy_packet(const BYTE* source, UINT32 size, BYTE** destination) {
    if (source == nullptr || destination == nullptr) {
        return false;
    }
    *destination = nullptr;
    if (size == 0) {
        return false;
    }
    auto* copy = static_cast<BYTE*>(std::malloc(size));
    if (copy == nullptr) {
        return false;
    }
    std::memcpy(copy, source, size);
    *destination = copy;
    return true;
}

void free_stream(RDPGFX_AVC420_BITMAP_STREAM& stream) {
    free_h264_metablock(&stream.meta);
    std::free(stream.data);
    stream.data = nullptr;
    stream.length = 0;
}

} // namespace

struct macrdp_h264_worker {
    explicit macrdp_h264_worker(rdpShadowEncoder* encoder)
        // WinPR's macOS event backend does not implement auto-reset events.
        // Use a manual-reset event and clear it explicitly when a completion
        // is consumed or a new job is accepted.
        : encoder(encoder), done_event(CreateEvent(nullptr, TRUE, FALSE, nullptr)) {
        if (done_event != nullptr) {
            thread = std::thread([this] { run(); });
        }
    }

    ~macrdp_h264_worker() {
        {
            std::lock_guard lock(mutex);
            stopping = true;
        }
        condition.notify_one();
        if (thread.joinable()) {
            thread.join();
        }
        if (done_event != nullptr) {
            CloseHandle(done_event);
        }
        free_result(result);
    }

    void run() {
        while (true) {
            EncodeJob current;
            {
                std::unique_lock lock(mutex);
                condition.wait(lock, [this] { return stopping || job.has_value(); });
                if (stopping) {
                    return;
                }
                current = std::move(*job);
                job.reset();
            }

            const size_t full_row_bytes = static_cast<size_t>(current.width) * 4U;
            const size_t full_size =
                (static_cast<size_t>(current.height) - 1U) * current.stride + full_row_bytes;
            if (current.full_frame) {
                if (current.frame.size() < full_size) {
                    macrdp_h264_encoded_frame encoded{};
                    encoded.width = current.width;
                    encoded.height = current.height;
                    encoded.failed = TRUE;
                    std::lock_guard lock(mutex);
                    if (stopping) {
                        free_result(encoded);
                        return;
                    }
                    result = encoded;
                    completion = TRUE;
                    busy = FALSE;
                    (void)SetEvent(done_event);
                    continue;
                }
                assembled_frame = std::move(current.frame);
                assembled_stride = current.stride;
            } else {
                const auto region_width = static_cast<size_t>(
                    current.region.right - current.region.left);
                const auto region_height = static_cast<size_t>(
                    current.region.bottom - current.region.top);
                const auto patch_row_bytes = region_width * 4U;
                const auto assembled_size =
                    (static_cast<size_t>(current.height) - 1U) * assembled_stride
                    + full_row_bytes;
                if (assembled_frame.size() < assembled_size
                    || assembled_width != current.width
                    || assembled_height != current.height
                    || assembled_stride < full_row_bytes
                    || current.frame.size() < patch_row_bytes * region_height
                    || current.stride < patch_row_bytes) {
                    macrdp_h264_encoded_frame encoded{};
                    encoded.width = current.width;
                    encoded.height = current.height;
                    encoded.failed = TRUE;
                    std::lock_guard lock(mutex);
                    if (stopping) {
                        free_result(encoded);
                        return;
                    }
                    result = encoded;
                    completion = TRUE;
                    busy = FALSE;
                    (void)SetEvent(done_event);
                    continue;
                }
                for (size_t row = 0; row < region_height; ++row) {
                    auto* destination = assembled_frame.data()
                        + (static_cast<size_t>(current.region.top) + row) * assembled_stride
                        + static_cast<size_t>(current.region.left) * 4U;
                    const auto* source = current.frame.data() + row * current.stride;
                    std::memcpy(destination, source, patch_row_bytes);
                }
            }

            {
                std::lock_guard lock(mutex);
                assembled_width = current.width;
                assembled_height = current.height;
                frame_initialized = TRUE;
            }

            macrdp_h264_encoded_frame encoded{};
            encoded.width = current.width;
            encoded.height = current.height;

            if (encoder == nullptr || encoder->h264 == nullptr) {
                encoded.failed = TRUE;
            } else if (current.codec_id == RDPGFX_CODECID_AVC420) {
                encoded.codecId = current.codec_id;
                BYTE* packet = nullptr;
                UINT32 packet_size = 0;
                const auto status = avc420_compress(
                    encoder->h264,
                    assembled_frame.data(),
                    current.format,
                    assembled_stride,
                    current.width,
                    current.height,
                    &current.region,
                    &packet,
                    &packet_size,
                    &encoded.avc420.meta);
                if (status < 0) {
                    encoded.failed = TRUE;
                } else if (status > 0) {
                    encoded.hasData = TRUE;
                    encoded.avc420.length = packet_size;
                    if (!copy_packet(packet, packet_size, &encoded.avc420.data)) {
                        encoded.failed = TRUE;
                        encoded.hasData = FALSE;
                    }
                }
            } else if (current.codec_id == RDPGFX_CODECID_AVC444
                       || current.codec_id == RDPGFX_CODECID_AVC444v2) {
                encoded.codecId = current.codec_id;
                BYTE* packet = nullptr;
                BYTE* auxiliary_packet = nullptr;
                UINT32 packet_size = 0;
                UINT32 auxiliary_packet_size = 0;
                encoded.avc444.LC = current.codec_id == RDPGFX_CODECID_AVC444v2 ? 0 : 0;
                const BYTE version = current.codec_id == RDPGFX_CODECID_AVC444v2 ? 2 : 1;
                const auto status = avc444_compress(
                    encoder->h264,
                    assembled_frame.data(),
                    current.format,
                    assembled_stride,
                    current.width,
                    current.height,
                    version,
                    &current.region,
                    &encoded.avc444.LC,
                    &packet,
                    &packet_size,
                    &auxiliary_packet,
                    &auxiliary_packet_size,
                    &encoded.avc444.bitstream[0].meta,
                    &encoded.avc444.bitstream[1].meta);
                if (status < 0) {
                    encoded.failed = TRUE;
                } else if (status > 0) {
                    encoded.hasData = TRUE;
                    encoded.avc444.cbAvc420EncodedBitstream1 =
                        sizeof(UINT32) + 10 * encoded.avc444.bitstream[0].meta.numRegionRects
                        + packet_size;
                    encoded.avc444.bitstream[0].length = packet_size;
                    encoded.avc444.bitstream[1].length = auxiliary_packet_size;
                    if ((packet_size > 0
                         && !copy_packet(packet, packet_size, &encoded.avc444.bitstream[0].data))
                        || (auxiliary_packet_size > 0
                            && !copy_packet(auxiliary_packet,
                                            auxiliary_packet_size,
                                            &encoded.avc444.bitstream[1].data))) {
                        encoded.failed = TRUE;
                        encoded.hasData = FALSE;
                    }
                }
            } else {
                encoded.failed = TRUE;
            }

            std::lock_guard lock(mutex);
            if (stopping) {
                free_result(encoded);
                return;
            }
            result = encoded;
            completion = TRUE;
            busy = FALSE;
            (void)SetEvent(done_event);
        }
    }

    static void free_result(macrdp_h264_encoded_frame& frame) {
        free_stream(frame.avc420);
        free_stream(frame.avc444.bitstream[0]);
        free_stream(frame.avc444.bitstream[1]);
        clear_encoded_frame(frame);
    }

    rdpShadowEncoder* encoder = nullptr;
    HANDLE done_event = nullptr;
    std::thread thread;
    mutable std::mutex mutex;
    std::condition_variable condition;
    std::optional<EncodeJob> job;
    macrdp_h264_encoded_frame result{};
    std::vector<BYTE> assembled_frame;
    UINT32 assembled_stride = 0;
    UINT32 assembled_width = 0;
    UINT32 assembled_height = 0;
    BOOL frame_initialized = FALSE;
    BOOL completion = FALSE;
    BOOL busy = FALSE;
    BOOL stopping = FALSE;
};

extern "C" macrdp_h264_worker* macrdp_h264_worker_new(rdpShadowEncoder* encoder) {
    if (encoder == nullptr) {
        return nullptr;
    }
    auto* worker = new (std::nothrow) macrdp_h264_worker(encoder);
    if (worker == nullptr) {
        return nullptr;
    }
    if (worker->done_event == nullptr) {
        delete worker;
        return nullptr;
    }
    return worker;
}

extern "C" void macrdp_h264_worker_free(macrdp_h264_worker* worker) {
    delete worker;
}

extern "C" HANDLE macrdp_h264_worker_event(const macrdp_h264_worker* worker) {
    return worker == nullptr ? nullptr : worker->done_event;
}

extern "C" BOOL macrdp_h264_worker_busy(const macrdp_h264_worker* worker) {
    if (worker == nullptr) {
        return FALSE;
    }
    std::lock_guard lock(worker->mutex);
    return worker->busy || worker->job.has_value() || worker->completion;
}

extern "C" BOOL macrdp_h264_worker_has_completion(const macrdp_h264_worker* worker) {
    if (worker == nullptr) {
        return FALSE;
    }
    std::lock_guard lock(worker->mutex);
    return worker->completion;
}

extern "C" int macrdp_h264_worker_submit(
    macrdp_h264_worker* worker,
    const BYTE* frame,
    size_t frame_size,
    UINT32 stride,
    UINT32 width,
    UINT32 height,
    UINT32 format,
    UINT32 codec_id,
    const RECTANGLE_16* region) {
    if (worker == nullptr || frame == nullptr || frame_size == 0 || stride == 0
        || width == 0 || height == 0 || region == nullptr
        || (codec_id != RDPGFX_CODECID_AVC420 && codec_id != RDPGFX_CODECID_AVC444
            && codec_id != RDPGFX_CODECID_AVC444v2)) {
        return -1;
    }
    const size_t width_size = static_cast<size_t>(width);
    if (width_size > std::numeric_limits<size_t>::max() / 4U) {
        return -1;
    }
    const size_t row_bytes = width_size * 4U;
    if (stride < row_bytes
        || (height > 0 && (static_cast<size_t>(height) - 1) >
                           (std::numeric_limits<size_t>::max() - row_bytes) / stride)
        || frame_size < (static_cast<size_t>(height) - 1) * stride + row_bytes) {
        return -1;
    }

    if (region->left >= region->right || region->top >= region->bottom
        || region->right > width || region->bottom > height) {
        return -1;
    }

    bool full_frame = false;
    {
        std::lock_guard lock(worker->mutex);
        if (worker->stopping || worker->busy || worker->job.has_value() || worker->completion) {
            return 0;
        }
        full_frame = !worker->frame_initialized
            || worker->assembled_width != width
            || worker->assembled_height != height
            || worker->assembled_stride != stride;
    }

    EncodeJob next;
    try {
        next.full_frame = full_frame;
        if (full_frame) {
            const size_t required_size =
                (static_cast<size_t>(height) - 1U) * stride + row_bytes;
            next.frame.assign(frame, frame + required_size);
            next.stride = stride;
        } else {
            const auto region_width = static_cast<size_t>(region->right - region->left);
            const auto region_height = static_cast<size_t>(region->bottom - region->top);
            const auto patch_stride = region_width * 4U;
            next.frame.resize(patch_stride * region_height);
            for (size_t row = 0; row < region_height; ++row) {
                const auto* source = frame
                    + (static_cast<size_t>(region->top) + row) * stride
                    + static_cast<size_t>(region->left) * 4U;
                std::memcpy(next.frame.data() + row * patch_stride, source, patch_stride);
            }
            next.stride = static_cast<UINT32>(patch_stride);
        }
    } catch (...) {
        return -1;
    }
    next.width = width;
    next.height = height;
    next.format = format;
    next.codec_id = codec_id;
    next.region = *region;

    {
        std::lock_guard lock(worker->mutex);
        if (worker->stopping || worker->busy || worker->job.has_value() || worker->completion) {
            return 0;
        }
        if (!ResetEvent(worker->done_event)) {
            return -1;
        }
        worker->job = std::move(next);
        worker->busy = TRUE;
    }
    worker->condition.notify_one();
    return 1;
}

extern "C" BOOL macrdp_h264_worker_wait_idle(macrdp_h264_worker* worker) {
    if (worker == nullptr) {
        return FALSE;
    }
    while (true) {
        {
            std::lock_guard lock(worker->mutex);
            if (!worker->busy && !worker->job.has_value()) {
                return TRUE;
            }
            if (worker->stopping) {
                return FALSE;
            }
        }
        if (WaitForSingleObject(worker->done_event, INFINITE) == WAIT_FAILED) {
            return FALSE;
        }
    }
}

extern "C" int macrdp_h264_worker_take(
    macrdp_h264_worker* worker,
    macrdp_h264_encoded_frame* frame) {
    if (worker == nullptr || frame == nullptr) {
        return -1;
    }
    clear_encoded_frame(*frame);
    std::lock_guard lock(worker->mutex);
    if (!worker->completion) {
        return 0;
    }
    *frame = worker->result;
    clear_encoded_frame(worker->result);
    worker->completion = FALSE;
    if (!ResetEvent(worker->done_event)) {
        macrdp_h264_worker::free_result(*frame);
        return -1;
    }
    if (frame->failed) {
        return -1;
    }
    return frame->hasData ? 1 : 0;
}

extern "C" void macrdp_h264_encoded_frame_free(macrdp_h264_encoded_frame* frame) {
    if (frame == nullptr) {
        return;
    }
    free_stream(frame->avc420);
    free_stream(frame->avc444.bitstream[0]);
    free_stream(frame->avc444.bitstream[1]);
    clear_encoded_frame(*frame);
}
