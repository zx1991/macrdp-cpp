#pragma once

#include "input_ownership.hpp"

#include <algorithm>
#include <deque>
#include <utility>

namespace macrdp {

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
