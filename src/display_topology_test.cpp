#include "macrdp/display_topology.hpp"
#include "macrdp/display_topology_backend.hpp"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

macrdp::DisplayGeometry display(
    std::uint32_t id,
    std::uint32_t pixel_width,
    std::uint32_t pixel_height,
    macrdp::DisplayBounds bounds,
    double rotation,
    bool main) {
    return {id, pixel_width, pixel_height, bounds, rotation, main};
}

class FakeDisplayTopologyBackend final
    : public macrdp::detail::DisplayTopologyBackend {
public:
    struct Observer {
        std::shared_ptr<macrdp::detail::DisplayTopologyObserverState> state;
        macrdp::detail::DisplayTopologyObserverGeneration generation = 0;
    };

    bool start(
        const std::shared_ptr<macrdp::detail::DisplayTopologyObserverState>& state,
        macrdp::detail::DisplayTopologyObserverGeneration generation,
        std::string& error) override {
        std::lock_guard lock(mutex_);
        observers_.push_back({state, generation});
        error.clear();
        return true;
    }

    macrdp::detail::DisplayTopologyReadResult read() override {
        std::lock_guard lock(mutex_);
        ++read_count_;
        return reading_;
    }

    void stop() noexcept override {
        std::lock_guard lock(mutex_);
        ++stop_count_;
    }

    void set_reading(macrdp::detail::DisplayTopologyReadResult reading) {
        std::lock_guard lock(mutex_);
        reading_ = std::move(reading);
    }

    bool signal(std::size_t index) {
        Observer observer;
        {
            std::lock_guard lock(mutex_);
            observer = observers_.at(index);
        }
        return macrdp::detail::display_topology_backend_changed(
            observer.state,
            observer.generation);
    }

    std::size_t observer_count() const {
        std::lock_guard lock(mutex_);
        return observers_.size();
    }

    std::size_t read_count() const {
        std::lock_guard lock(mutex_);
        return read_count_;
    }

    std::size_t stop_count() const {
        std::lock_guard lock(mutex_);
        return stop_count_;
    }

private:
    mutable std::mutex mutex_;
    macrdp::detail::DisplayTopologyReadResult reading_;
    std::vector<Observer> observers_;
    std::size_t read_count_ = 0;
    std::size_t stop_count_ = 0;
};

bool test_geometry_changes_and_exact_selection() {
    auto backend = std::make_unique<FakeDisplayTopologyBackend>();
    auto* fake = backend.get();
    fake->set_reading({
        true,
        5,
        {
            display(9, 1920, 1080, {1512.0, -400.0, 1920.0, 1080.0}, 0.0, false),
            display(5, 3024, 1964, {-1512.0, 0.0, 1512.0, 982.0}, 0.0, true),
        },
        {},
    });
    macrdp::DisplayTopology topology(std::move(backend));
    bool ok = expect(topology.start(), "initial topology did not start");
    auto snapshot = topology.snapshot();
    ok = expect(snapshot.has_value() && snapshot->generation == 1,
                "initial topology generation was not one") && ok;
    const auto* retina = snapshot.has_value() ? snapshot->find(5) : nullptr;
    ok = expect(retina != nullptr
                    && retina->pixel_width == 3024
                    && retina->bounds.width == 1512.0
                    && retina->bounds.origin_x == -1512.0,
                "Retina or negative-origin geometry was not retained") && ok;
    ok = expect(macrdp::display_topology_select(*snapshot, 5) == retina,
                "exact display selection failed") && ok;

    fake->set_reading({
        true,
        9,
        {
            display(5, 3024, 1964, {-1512.0, 0.0, 1512.0, 982.0}, 0.0, false),
            display(9, 1920, 1080, {0.0, 0.0, 1920.0, 1080.0}, 0.0, true),
        },
        {},
    });
    ok = expect(fake->signal(0), "active main-display callback was rejected") && ok;
    ok = expect(topology.refresh(), "main-display refresh failed") && ok;
    snapshot = topology.snapshot();
    ok = expect(snapshot->generation == 2
                    && macrdp::display_topology_select(*snapshot, 0)->id == 9
                    && macrdp::display_topology_select(*snapshot, 5)->id == 5,
                "main-display change switched an exact selection") && ok;

    fake->set_reading({
        true,
        9,
        {
            display(5, 2560, 1440, {-1280.0, 0.0, 1280.0, 720.0}, 90.0, false),
            display(9, 1920, 1080, {0.0, 0.0, 1920.0, 1080.0}, 0.0, true),
        },
        {},
    });
    ok = expect(fake->signal(0) && topology.refresh(),
                "mode/scaling/rotation refresh failed") && ok;
    snapshot = topology.snapshot();
    const auto* rotated = snapshot->find(5);
    ok = expect(snapshot->generation == 3 && rotated != nullptr
                    && rotated->pixel_width == 2560
                    && rotated->bounds.width == 1280.0
                    && rotated->bounds.height == 720.0
                    && rotated->rotation_degrees == 90.0,
                "mode, scaling, or rotation change was not generation-tagged") && ok;
    return ok;
}

bool test_detach_reconnect_and_stale_callbacks() {
    auto backend = std::make_unique<FakeDisplayTopologyBackend>();
    auto* fake = backend.get();
    fake->set_reading({
        true,
        7,
        {display(7, 1920, 1080, {0.0, 0.0, 1920.0, 1080.0}, 0.0, true)},
        {},
    });
    macrdp::DisplayTopology topology(std::move(backend));
    bool ok = expect(topology.start(), "detach topology did not start");

    fake->set_reading({true, 9,
        {display(9, 1512, 982, {0.0, 0.0, 1512.0, 982.0}, 0.0, true)}, {}});
    ok = expect(fake->signal(0) && topology.refresh(), "detach refresh failed") && ok;
    auto snapshot = topology.snapshot();
    ok = expect(snapshot->generation == 2
                    && macrdp::display_topology_select(*snapshot, 7) == nullptr
                    && macrdp::display_topology_select(*snapshot, 0)->id == 9,
                "detached exact display silently fell back") && ok;

    fake->set_reading({true, 7,
        {display(7, 3840, 2160, {-1920.0, 0.0, 1920.0, 1080.0}, 0.0, true)}, {}});
    ok = expect(fake->signal(0) && topology.refresh(), "reconnect refresh failed") && ok;
    snapshot = topology.snapshot();
    ok = expect(snapshot->generation == 3
                    && macrdp::display_topology_select(*snapshot, 7)->pixel_width == 3840,
                "same-ID reconnect geometry was not restored") && ok;

    topology.stop();
    const auto reads_before_stale_callback = fake->read_count();
    ok = expect(!fake->signal(0), "stopped observer accepted a stale callback") && ok;
    ok = expect(!topology.refresh(), "stopped topology unexpectedly refreshed") && ok;
    ok = expect(fake->read_count() == reads_before_stale_callback,
                "stale callback triggered a topology read") && ok;

    ok = expect(topology.start() && fake->observer_count() == 2,
                "topology did not restart with a new observer generation") && ok;
    ok = expect(!fake->signal(0), "old observer mutated restarted topology") && ok;
    ok = expect(fake->signal(1) && topology.refresh(),
                "new observer callback was rejected") && ok;
    ok = expect(fake->stop_count() >= 1, "topology stop did not stop its backend") && ok;
    return ok;
}

bool test_invalid_refresh_preserves_snapshot() {
    auto backend = std::make_unique<FakeDisplayTopologyBackend>();
    auto* fake = backend.get();
    fake->set_reading({true, 3,
        {display(3, 1920, 1080, {0.0, 0.0, 1920.0, 1080.0}, 0.0, true)}, {}});
    macrdp::DisplayTopology topology(std::move(backend));
    bool ok = expect(topology.start(), "validation topology did not start");

    fake->set_reading({true, 3,
        {
            display(3, 1920, 1080, {0.0, 0.0, 1920.0, 1080.0}, 0.0, true),
            display(3, 1280, 720, {0.0, 0.0, 1280.0, 720.0}, 0.0, false),
        }, {}});
    ok = expect(fake->signal(0), "invalid topology callback was rejected") && ok;
    ok = expect(!topology.refresh(), "duplicate display IDs were accepted") && ok;
    const auto snapshot = topology.snapshot();
    ok = expect(snapshot.has_value() && snapshot->generation == 1
                    && snapshot->displays.size() == 1,
                "invalid refresh replaced the last valid snapshot") && ok;
    ok = expect(!topology.last_error().empty(),
                "invalid refresh did not report an error") && ok;
    return ok;
}

} // namespace

int main() {
    bool ok = test_geometry_changes_and_exact_selection();
    ok = test_detach_reconnect_and_stale_callbacks() && ok;
    ok = test_invalid_refresh_preserves_snapshot() && ok;
    return ok ? 0 : 1;
}
