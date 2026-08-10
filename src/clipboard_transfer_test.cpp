#include "macrdp/clipboard_transfer.hpp"

#include <iostream>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

bool test_fifo_response_correlation() {
    macrdp::ClipboardTransferState state;
    bool ok = expect(
        state.begin_remote_request(macrdp::clipboard_format_unicode_text),
        "Unicode request was rejected");
    ok = expect(
        state.begin_remote_request(macrdp::clipboard_format_text),
        "text request was rejected") && ok;

    ok = expect(
        state.finish_remote_request() == macrdp::clipboard_format_unicode_text,
        "first response did not consume the first request") && ok;
    ok = expect(
        state.finish_remote_request() == macrdp::clipboard_format_text,
        "second response did not consume the second request") && ok;
    ok = expect(
        !state.finish_remote_request().has_value(),
        "unsolicited response was correlated with a request") && ok;
    return ok;
}

bool test_send_failure_rollback() {
    macrdp::ClipboardTransferState state;
    bool ok = expect(
        state.begin_remote_request(macrdp::clipboard_format_unicode_text),
        "first request was rejected");
    ok = expect(
        state.begin_remote_request(macrdp::clipboard_format_text),
        "second request was rejected") && ok;
    ok = expect(
        !state.cancel_latest_remote_request(macrdp::clipboard_format_unicode_text),
        "rollback removed a non-latest request") && ok;
    ok = expect(
        state.cancel_latest_remote_request(macrdp::clipboard_format_text),
        "failed send did not roll back its request") && ok;
    ok = expect(
        state.finish_remote_request() == macrdp::clipboard_format_unicode_text,
        "rollback changed the earlier response correlation") && ok;
    return ok;
}

bool test_bounded_pending_requests() {
    macrdp::ClipboardTransferState state;
    bool ok = true;
    for (std::size_t index = 0;
         index < macrdp::ClipboardTransferState::max_pending_requests;
         ++index) {
        ok = expect(
            state.begin_remote_request(macrdp::clipboard_format_unicode_text),
            "request queue reached its bound too early") && ok;
    }
    ok = expect(
        state.pending_request_count()
            == macrdp::ClipboardTransferState::max_pending_requests,
        "request queue size did not reach its documented bound") && ok;
    ok = expect(
        !state.begin_remote_request(macrdp::clipboard_format_text),
        "request queue accepted an unbounded request") && ok;

    const auto half = macrdp::ClipboardTransferState::max_pending_requests / 2U;
    for (std::size_t index = 0; index < half; ++index) {
        ok = expect(
            state.finish_remote_request() == macrdp::clipboard_format_unicode_text,
            "bounded queue changed the order of an existing request") && ok;
    }
    for (std::size_t index = 0; index < half; ++index) {
        ok = expect(state.begin_remote_request(macrdp::clipboard_format_text),
                    "bounded queue did not reuse consumed storage") && ok;
    }
    for (std::size_t index = 0; index < half; ++index) {
        ok = expect(
            state.finish_remote_request() == macrdp::clipboard_format_unicode_text,
            "wrapped queue reordered its original tail") && ok;
    }
    for (std::size_t index = 0; index < half; ++index) {
        ok = expect(
            state.finish_remote_request() == macrdp::clipboard_format_text,
            "wrapped queue reordered newly appended requests") && ok;
    }
    return ok;
}

bool test_stop_and_reconnect_isolation() {
    macrdp::ClipboardTransferState old_connection;
    bool ok = expect(
        old_connection.begin_remote_request(macrdp::clipboard_format_unicode_text),
        "old connection request was rejected");
    old_connection.stop();
    ok = expect(!old_connection.active(), "stopped connection remained active") && ok;
    ok = expect(old_connection.pending_request_count() == 0,
                "stopped connection retained pending requests") && ok;
    ok = expect(!old_connection.finish_remote_request().has_value(),
                "stopped connection accepted a late response") && ok;
    ok = expect(
        !old_connection.begin_remote_request(macrdp::clipboard_format_text),
        "stopped connection accepted a new request") && ok;

    macrdp::ClipboardTransferState new_connection;
    ok = expect(new_connection.begin_remote_request(macrdp::clipboard_format_text),
                "new connection inherited the stopped state") && ok;
    ok = expect(
        new_connection.finish_remote_request() == macrdp::clipboard_format_text,
        "new connection did not own its response state") && ok;
    return ok;
}

bool test_supported_formats_only() {
    macrdp::ClipboardTransferState state;
    return expect(
               macrdp::ClipboardTransferState::is_text_format(
                   macrdp::clipboard_format_unicode_text),
               "Unicode text was not recognized")
        && expect(
            macrdp::ClipboardTransferState::is_text_format(
                macrdp::clipboard_format_text),
            "legacy text was not recognized")
        && expect(!macrdp::ClipboardTransferState::is_text_format(15),
                  "unsupported format was recognized as text")
        && expect(
            macrdp::ClipboardTransferState::has_valid_payload_alignment(
                macrdp::clipboard_format_unicode_text,
                4),
            "aligned Unicode payload was rejected")
        && expect(
            !macrdp::ClipboardTransferState::has_valid_payload_alignment(
                macrdp::clipboard_format_unicode_text,
                3),
            "misaligned Unicode payload was accepted")
        && expect(
            macrdp::ClipboardTransferState::has_valid_payload_alignment(
                macrdp::clipboard_format_text,
                3),
            "byte-oriented text payload was treated as UTF-16")
        && expect(
            !macrdp::ClipboardTransferState::has_valid_payload_alignment(15, 4),
            "unsupported payload alignment was accepted")
        && expect(!state.begin_remote_request(15),
                  "unsupported format entered the request queue");
}

} // namespace

int main() {
    bool ok = test_fifo_response_correlation();
    ok = test_send_failure_rollback() && ok;
    ok = test_bounded_pending_requests() && ok;
    ok = test_stop_and_reconnect_isolation() && ok;
    ok = test_supported_formats_only() && ok;
    return ok ? 0 : 1;
}
