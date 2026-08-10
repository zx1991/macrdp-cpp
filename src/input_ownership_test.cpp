#include "macrdp/input_ownership.hpp"
#include "macrdp/input_queue.hpp"
#include "macrdp/input_translation.hpp"

#include <algorithm>
#include <deque>
#include <iostream>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

} // namespace

namespace {

struct QueuedEvent {
    macrdp::InputClientId client_id = 0;
    int sequence = 0;
    bool reset = false;
    bool motion = false;
    int x = 0;
};

bool test_reset_priority() {
    std::deque<QueuedEvent> queue{
        {1, 10, false},
        {2, 20, false},
        {1, 11, false},
        {2, 21, false},
    };
    macrdp::prioritize_client_reset(queue, 1, QueuedEvent{1, 99, true});

    return expect(queue.size() == 3, "reset did not remove stale client events")
        && expect(queue.front().client_id == 1 && queue.front().reset,
                   "reset was not moved to the front")
        && expect(queue[1].sequence == 20 && queue[2].sequence == 21,
                   "other client input order changed");
}

bool test_motion_coalescing() {
    const auto is_motion = [](const QueuedEvent& event) { return event.motion; };
    std::deque<QueuedEvent> queue{{1, 10, false, true, 100},
                                  {1, 11, false, false, 110}};

    const bool click_preserved = !macrdp::replace_trailing_coalescible(
        queue,
        QueuedEvent{1, 12, false, true, 120},
        is_motion);
    queue.pop_back();
    const bool motion_replaced = macrdp::replace_trailing_coalescible(
        queue,
        QueuedEvent{1, 13, false, true, 130},
        is_motion);
    return expect(click_preserved, "coalescing replaced a trailing click")
        && expect(motion_replaced, "coalescing did not replace trailing motion")
        && expect(queue.size() == 1 && queue.back().sequence == 13
                      && queue.back().x == 130,
                   "coalescing did not retain the newest pointer position");
}

bool test_discard_motion_for_critical_input() {
    const auto is_motion = [](const QueuedEvent& event) { return event.motion; };
    std::deque<QueuedEvent> queue{{1, 10, false, true, 100},
                                  {1, 11, false, false, 110},
                                  {2, 12, false, true, 120},
                                  {2, 13, false, true, 130}};

    const auto discarded = macrdp::discard_coalescible(queue, is_motion);
    return expect(discarded == 3, "critical input did not discard queued motion")
        && expect(queue.size() == 1 && queue.front().sequence == 11
                      && !queue.front().motion,
                   "critical input discard removed a non-coalescible event");
}

bool test_wheel_delta_decoding() {
    return expect(macrdp::decode_rdp_wheel_delta(0x0078U) == 120,
                  "positive wheel delta was decoded incorrectly")
        && expect(macrdp::decode_rdp_wheel_delta(0x0188U) == -120,
                  "negative wheel delta was not sign-extended from 9 bits")
        && expect(macrdp::decode_rdp_wheel_delta(0x0001U) == 1,
                  "small positive wheel delta was decoded incorrectly")
        && expect(macrdp::decode_rdp_wheel_delta(0x01FFU) == -1,
                  "small negative wheel delta was decoded incorrectly")
        && expect(macrdp::decode_rdp_wheel_delta(0x0278U) == 120,
                  "vertical wheel event flags changed the decoded delta")
        && expect(macrdp::decode_rdp_wheel_delta(0x0588U) == -120,
                  "horizontal wheel event flags changed the decoded delta");
}

bool test_release_all_is_ledger_bounded() {
    macrdp::InputOwnership ownership;
    bool ok = expect(ownership.acquire_key(6, 0x001D),
                     "tracked left Control was not acquired");
    ok = expect(ownership.acquire_key(6, 0x015B),
                "tracked left Command was not acquired") && ok;

    const auto released = ownership.release_all();
    ok = expect(
        released.keys.size() == 2
            && std::find(released.keys.begin(), released.keys.end(), 0x001D)
                != released.keys.end()
            && std::find(released.keys.begin(), released.keys.end(), 0x015B)
                != released.keys.end(),
        "release_all returned modifier keys outside the ownership ledger") && ok;
    ok = expect(released.unicode.empty()
                    && std::none_of(
                        released.buttons.begin(),
                        released.buttons.end(),
                        [](bool down) { return down; }),
                "release_all returned unowned non-key input state") && ok;
    ok = expect(ownership.release_all().keys.empty(),
                "release_all retained already released modifier state") && ok;
    return ok;
}

bool test_pause_sequence_filter() {
    constexpr std::uint16_t pause_control = 0x021D;
    constexpr std::uint16_t num_lock = 0x0045;
    macrdp::InputOwnership ownership;

    bool ok = expect(
        ownership.consume_pause_sequence_event(8, pause_control, true),
        "Pause E1 Control down was not consumed");
    ok = expect(ownership.consume_pause_sequence_event(8, num_lock, true),
                "Pause Num Lock down was not consumed") && ok;
    ok = expect(ownership.consume_pause_sequence_event(8, pause_control, false),
                "Pause E1 Control up was not consumed") && ok;
    ok = expect(ownership.consume_pause_sequence_event(8, num_lock, false),
                "Pause Num Lock up was not consumed") && ok;
    ok = expect(!ownership.consume_pause_sequence_event(8, num_lock, true)
                    && !ownership.consume_pause_sequence_event(8, num_lock, false),
                "ordinary Num Lock was consumed after a complete Pause sequence") && ok;
    return ok;
}

bool test_pause_sequence_recovery() {
    constexpr std::uint16_t pause_control = 0x021D;
    constexpr std::uint16_t num_lock = 0x0045;
    macrdp::InputOwnership ownership;

    bool ok = expect(
        ownership.consume_pause_sequence_event(9, pause_control, false),
        "stray Pause E1 Control release was not consumed");
    ok = expect(!ownership.consume_pause_sequence_event(9, num_lock, true),
                "stray Pause release poisoned ordinary Num Lock") && ok;

    (void)ownership.consume_pause_sequence_event(10, pause_control, true);
    (void)ownership.release_client(10);
    ok = expect(!ownership.consume_pause_sequence_event(10, num_lock, true),
                "client release retained a partial Pause sequence") && ok;

    (void)ownership.consume_pause_sequence_event(11, pause_control, true);
    (void)ownership.release_all();
    ok = expect(!ownership.consume_pause_sequence_event(11, num_lock, true),
                "global release retained a partial Pause sequence") && ok;

    (void)ownership.consume_pause_sequence_event(12, pause_control, true);
    ok = expect(!ownership.consume_pause_sequence_event(12, 0x001E, true),
                "partial Pause sequence consumed an unrelated key") && ok;
    ok = expect(!ownership.consume_pause_sequence_event(12, num_lock, true),
                "partial Pause sequence consumed a later ordinary Num Lock") && ok;
    return ok;
}

} // namespace

int main() {
    bool ok = test_wheel_delta_decoding();
    ok = test_release_all_is_ledger_bounded() && ok;
    ok = test_pause_sequence_filter() && ok;
    ok = test_pause_sequence_recovery() && ok;
    ok = test_reset_priority() && ok;
    ok = test_motion_coalescing() && ok;
    ok = test_discard_motion_for_critical_input() && ok;
    macrdp::InputOwnership ownership;

    ok = expect(ownership.acquire_key(1, 30), "first key owner was not announced") && ok;
    ok = expect(ownership.is_key_code_active(30), "owned key code was not marked active") && ok;
    ok = expect(!ownership.acquire_key(1, 30), "duplicate key press changed ownership") && ok;
    ok = expect(!ownership.acquire_key(2, 30), "second key owner caused a duplicate press") && ok;
    ok = expect(!ownership.release_key(1, 30), "first key release released a shared key") && ok;
    ok = expect(ownership.is_key_code_active(30), "shared key code became inactive too early") && ok;
    ok = expect(ownership.release_key(2, 30), "last key owner was not released") && ok;
    ok = expect(!ownership.is_key_code_active(30), "released key code remained active") && ok;
    ok = expect(!ownership.release_key(2, 30), "unknown key release was accepted") && ok;

    ok = expect(ownership.acquire_key(3, 0x015B),
                "extended key owner was not announced") && ok;
    ok = expect(ownership.find_key(3, 0x015B) == 0x015B,
                "exact key identity was not found") && ok;
    ok = expect(ownership.find_key(3, 0x025B) == std::nullopt,
                "mismatched extended identity unexpectedly matched exactly") && ok;
    ok = expect(ownership.find_key_by_code(3, 0x5B) == 0x015B,
                "key release fallback did not recover the scan-code identity") && ok;
    ok = expect(ownership.is_key_exclusive(3, 0x015B),
                "single key owner was not marked exclusive") && ok;
    ok = expect(ownership.release_key(3, 0x015B),
                "extended key owner was not released") && ok;

    ok = expect(ownership.acquire_key(4, 0x001D),
                "left modifier owner was not announced") && ok;
    ok = expect(ownership.acquire_key(4, 0x011D),
                "right modifier owner was not announced") && ok;
    ok = expect(ownership.is_key_code_active(0x1D),
                "extended modifier identity was not found by scan code") && ok;
    // A shared owner is recorded, but does not request a second platform
    // key-down, so acquire_key intentionally returns false here.
    ok = expect(!ownership.acquire_key(5, 0x001D),
                "shared modifier owner unexpectedly requested a duplicate press") && ok;
    ok = expect(!ownership.is_key_exclusive(4, 0x001D)
                    && !ownership.is_key_exclusive(5, 0x001D),
                "shared key was incorrectly marked exclusive") && ok;
    (void)ownership.release_client(5);
    ok = expect(ownership.is_key_exclusive(4, 0x001D),
                "key did not become exclusive after the shared owner left") && ok;
    const auto modifier_matches = ownership.find_keys_by_code(4, 0x1D);
    ok = expect(modifier_matches.size() == 2,
                "ambiguous modifier release candidates were not retained") && ok;
    ok = expect(ownership.find_key_by_code(4, 0x1D) == std::nullopt,
                "ambiguous modifier release guessed an identity") && ok;
    ok = expect(ownership.release_key(4, 0x001D),
                "left modifier owner was not released") && ok;
    ok = expect(ownership.release_key(4, 0x011D),
                "right modifier owner was not released") && ok;

    ok = expect(ownership.acquire_button(1, macrdp::InputButton::left),
                "first mouse owner was not announced") && ok;
    ok = expect(!ownership.acquire_button(2, macrdp::InputButton::left),
                "second mouse owner caused a duplicate press") && ok;
    auto released = ownership.release_client(1);
    ok = expect(!released.buttons[0], "shared mouse button released too early") && ok;
    released = ownership.release_client(2);
    ok = expect(released.buttons[0], "last mouse owner was not released") && ok;

    ok = expect(ownership.acquire_unicode(7, 0x4e2d), "unicode owner was not announced") && ok;
    released = ownership.release_all();
    ok = expect(released.unicode.size() == 1 && released.unicode.front() == 0x4e2d,
                "release_all did not return unicode state") && ok;

    return ok ? 0 : 1;
}
