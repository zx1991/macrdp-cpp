#pragma once

#include "macrdp/display_topology.hpp"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace macrdp::detail {

using DisplayTopologyObserverGeneration = std::uint64_t;

struct DisplayTopologyObserverState {
    mutable std::mutex mutex;
    DisplayTopologyObserverGeneration generation = 0;
    bool active = false;
    bool dirty = false;
};

struct DisplayTopologyReadResult {
    bool succeeded = false;
    std::uint32_t main_display_id = 0;
    std::vector<DisplayGeometry> displays;
    std::string error;
};

class DisplayTopologyBackend {
public:
    virtual ~DisplayTopologyBackend() = default;

    [[nodiscard]] virtual bool start(
        const std::shared_ptr<DisplayTopologyObserverState>& state,
        DisplayTopologyObserverGeneration generation,
        std::string& error) = 0;

    [[nodiscard]] virtual DisplayTopologyReadResult read() = 0;
    virtual void stop() noexcept = 0;
};

// Backends and deterministic fakes share the same lifecycle-generation gate.
[[nodiscard]] bool display_topology_backend_changed(
    const std::shared_ptr<DisplayTopologyObserverState>& state,
    DisplayTopologyObserverGeneration generation) noexcept;

} // namespace macrdp::detail
