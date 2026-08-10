#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace macrdp {

inline constexpr std::uint32_t clipboard_format_text = 1;
inline constexpr std::uint32_t clipboard_format_unicode_text = 13;

// Correlates FORMAT_DATA_RESPONSE PDUs with the requests sent on one ordered
// cliprdr channel. A new connection receives a new instance, so queued state
// cannot cross a reconnect.
class ClipboardTransferState final {
public:
    static constexpr std::size_t max_pending_requests = 64;

    [[nodiscard]] bool begin_remote_request(std::uint32_t format) noexcept {
        if (!active_ || !is_text_format(format)
            || pending_size_ >= max_pending_requests) {
            return false;
        }
        const auto tail = (pending_head_ + pending_size_) % max_pending_requests;
        pending_remote_formats_[tail] = format;
        ++pending_size_;
        return true;
    }

    [[nodiscard]] bool cancel_latest_remote_request(std::uint32_t format) noexcept {
        if (!active_ || pending_size_ == 0) {
            return false;
        }
        const auto tail = (pending_head_ + pending_size_ - 1U) % max_pending_requests;
        if (pending_remote_formats_[tail] != format) {
            return false;
        }
        --pending_size_;
        return true;
    }

    [[nodiscard]] std::optional<std::uint32_t> finish_remote_request() noexcept {
        if (!active_ || pending_size_ == 0) {
            return std::nullopt;
        }
        const auto format = pending_remote_formats_[pending_head_];
        pending_head_ = (pending_head_ + 1U) % max_pending_requests;
        --pending_size_;
        if (pending_size_ == 0) {
            pending_head_ = 0;
        }
        return format;
    }

    void stop() noexcept {
        active_ = false;
        pending_head_ = 0;
        pending_size_ = 0;
    }

    [[nodiscard]] bool active() const noexcept {
        return active_;
    }

    [[nodiscard]] std::size_t pending_request_count() const noexcept {
        return pending_size_;
    }

    [[nodiscard]] static constexpr bool is_text_format(std::uint32_t format) noexcept {
        return format == clipboard_format_unicode_text
            || format == clipboard_format_text;
    }

    [[nodiscard]] static constexpr bool has_valid_payload_alignment(
        std::uint32_t format,
        std::size_t size) noexcept {
        return is_text_format(format)
            && (format != clipboard_format_unicode_text || (size % 2U) == 0);
    }

private:
    bool active_ = true;
    std::array<std::uint32_t, max_pending_requests> pending_remote_formats_{};
    std::size_t pending_head_ = 0;
    std::size_t pending_size_ = 0;
};

} // namespace macrdp
