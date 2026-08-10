#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace macrdp {

struct DisplayBounds {
    double origin_x = 0.0;
    double origin_y = 0.0;
    double width = 0.0;
    double height = 0.0;
};

struct DisplayGeometry {
    std::uint32_t id = 0;
    std::uint32_t pixel_width = 0;
    std::uint32_t pixel_height = 0;
    DisplayBounds bounds;
    double rotation_degrees = 0.0;
    bool main = false;

    [[nodiscard]] bool valid() const noexcept;
};

struct DisplayTopologySnapshot {
    std::uint64_t generation = 0;
    std::uint32_t main_display_id = 0;
    std::vector<DisplayGeometry> displays;

    [[nodiscard]] const DisplayGeometry* find(std::uint32_t display_id) const noexcept;
};

namespace detail {
class DisplayTopologyBackend;
}

// Generation-tagged view of active CoreGraphics displays. Platform callbacks
// only mark the topology dirty; callers decide when to take and commit a new
// immutable snapshot.
class DisplayTopology final {
public:
    DisplayTopology();
    explicit DisplayTopology(std::unique_ptr<detail::DisplayTopologyBackend> backend);
    ~DisplayTopology();

    DisplayTopology(const DisplayTopology&) = delete;
    DisplayTopology& operator=(const DisplayTopology&) = delete;
    DisplayTopology(DisplayTopology&&) noexcept;
    DisplayTopology& operator=(DisplayTopology&&) noexcept;

    [[nodiscard]] bool start();
    [[nodiscard]] bool refresh(bool force = false);
    void stop() noexcept;

    [[nodiscard]] std::optional<DisplayTopologySnapshot> snapshot() const;
    [[nodiscard]] std::string last_error() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] const DisplayGeometry* display_topology_select(
    const DisplayTopologySnapshot& topology,
    std::uint32_t requested_display_id) noexcept;

} // namespace macrdp
