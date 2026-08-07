#pragma once

#include "input_ownership.hpp"

#include <algorithm>
#include <cstddef>
#include <deque>
#include <utility>

namespace macrdp {

// Replace only the trailing event when both events are safe to coalesce. A
// caller can use this for pointer motion while preserving clicks and keys.
template <typename Event, typename Predicate>
bool replace_trailing_coalescible(
    std::deque<Event>& queue,
    const Event& event,
    Predicate predicate) {
    if (!predicate(event) || queue.empty() || !predicate(queue.back())) {
        return false;
    }
    queue.back() = event;
    return true;
}

// Remove events that are safe to lose when a critical input event needs queue
// capacity. The caller should use this only for events such as pointer motion
// that do not represent a button or keyboard transition.
template <typename Event, typename Predicate>
std::size_t discard_coalescible(
    std::deque<Event>& queue,
    Predicate predicate) {
    const auto previous_size = queue.size();
    queue.erase(
        std::remove_if(
            queue.begin(),
            queue.end(),
            predicate),
        queue.end());
    return previous_size - queue.size();
}

// A disconnect reset is a barrier for one client's queued input. Discarding
// that client's stale events prevents a late key-up or click from running
// after its state has already been released.
template <typename Event>
void prioritize_client_reset(
    std::deque<Event>& queue,
    InputClientId client_id,
    Event reset) {
    queue.erase(
        std::remove_if(
            queue.begin(),
            queue.end(),
            [client_id](const Event& event) { return event.client_id == client_id; }),
        queue.end());
    queue.push_front(std::move(reset));
}

} // namespace macrdp
