#pragma once

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <utility>

namespace macrdp {

struct AsyncCompletionResult {
    bool completed = false;
    std::string error;
};

// Coordinates one asynchronous callback with a bounded synchronous caller.
// The timeout handler also covers the race where it is installed after the
// caller has already timed out.
class AsyncCompletion final {
public:
    using TimeoutHandler = std::function<void()>;

    [[nodiscard]] bool finish(std::string error = {}) {
        return finish_impl(std::move(error), false);
    }

    [[nodiscard]] bool finish_and_invoke_timeout_handler(std::string error) {
        return finish_impl(std::move(error), true);
    }

    void set_timeout_handler(TimeoutHandler handler) {
        bool invoke_now = false;
        {
            std::lock_guard lock(mutex_);
            if (completed_) {
                return;
            }
            if (timed_out_) {
                invoke_now = true;
            } else {
                timeout_handler_ = std::move(handler);
            }
        }
        if (invoke_now && handler) {
            handler();
        }
    }

    [[nodiscard]] AsyncCompletionResult wait_for(std::chrono::milliseconds timeout) {
        TimeoutHandler timeout_handler;
        {
            std::unique_lock lock(mutex_);
            if (!condition_.wait_for(lock, timeout, [this] { return completed_; })) {
                timed_out_ = true;
                timeout_handler = std::move(timeout_handler_);
            } else {
                return {true, error_};
            }
        }
        if (timeout_handler) {
            timeout_handler();
        }
        return {};
    }

    [[nodiscard]] bool timed_out() const {
        std::lock_guard lock(mutex_);
        return timed_out_;
    }

private:
    [[nodiscard]] bool finish_impl(std::string error, bool invoke_timeout_handler) {
        TimeoutHandler timeout_handler;
        {
            std::lock_guard lock(mutex_);
            if (completed_ || timed_out_) {
                return false;
            }
            completed_ = true;
            error_ = std::move(error);
            timeout_handler = std::move(timeout_handler_);
        }
        condition_.notify_all();
        if (invoke_timeout_handler && timeout_handler) {
            timeout_handler();
        }
        return true;
    }

    mutable std::mutex mutex_;
    std::condition_variable condition_;
    TimeoutHandler timeout_handler_;
    std::string error_;
    bool completed_ = false;
    bool timed_out_ = false;
};

} // namespace macrdp
