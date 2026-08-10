#include "macrdp/async_completion.hpp"

#include <chrono>
#include <iostream>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

bool test_completion_before_wait() {
    macrdp::AsyncCompletion completion;
    bool timed_out = false;
    completion.set_timeout_handler([&timed_out] { timed_out = true; });

    const bool accepted = completion.finish("capture failed");
    const auto result = completion.wait_for(std::chrono::milliseconds{0});
    return expect(accepted, "first completion was rejected")
        && expect(result.completed, "completed operation timed out")
        && expect(result.error == "capture failed", "completion error was lost")
        && expect(!timed_out, "timeout handler ran after completion")
        && expect(!completion.finish(), "duplicate completion was accepted");
}

bool test_handler_installed_before_timeout() {
    macrdp::AsyncCompletion completion;
    int timeout_count = 0;
    completion.set_timeout_handler([&timeout_count] { ++timeout_count; });

    const auto result = completion.wait_for(std::chrono::milliseconds{0});
    return expect(!result.completed, "pending operation did not time out")
        && expect(completion.timed_out(), "timeout state was not retained")
        && expect(timeout_count == 1, "timeout handler did not run exactly once")
        && expect(!completion.finish(), "late completion was accepted");
}

bool test_handler_installed_after_timeout() {
    macrdp::AsyncCompletion completion;
    const auto result = completion.wait_for(std::chrono::milliseconds{0});
    int timeout_count = 0;
    completion.set_timeout_handler([&timeout_count] { ++timeout_count; });

    return expect(!result.completed, "pending operation did not time out")
        && expect(timeout_count == 1,
                  "late timeout handler was not invoked immediately")
        && expect(!completion.finish("late"), "late result replaced timeout state");
}

bool test_explicit_failure_invokes_handler() {
    macrdp::AsyncCompletion completion;
    int cleanup_count = 0;
    completion.set_timeout_handler([&cleanup_count] { ++cleanup_count; });

    const bool accepted = completion.finish_and_invoke_timeout_handler("failed");
    const auto result = completion.wait_for(std::chrono::milliseconds{0});
    return expect(accepted, "explicit failure was rejected")
        && expect(result.completed && result.error == "failed",
                  "explicit failure result was lost")
        && expect(cleanup_count == 1,
                  "explicit failure did not invoke its cleanup handler");
}

} // namespace

int main() {
    bool ok = test_completion_before_wait();
    ok = test_handler_installed_before_timeout() && ok;
    ok = test_handler_installed_after_timeout() && ok;
    ok = test_explicit_failure_invokes_handler() && ok;
    return ok ? 0 : 1;
}
