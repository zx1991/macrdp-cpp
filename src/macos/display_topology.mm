#import <CoreGraphics/CoreGraphics.h>

#include "macrdp/display_topology.hpp"
#include "macrdp/display_topology_backend.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

bool same_bounds(const macrdp::DisplayBounds& left, const macrdp::DisplayBounds& right) {
    return left.origin_x == right.origin_x
        && left.origin_y == right.origin_y
        && left.width == right.width
        && left.height == right.height;
}

bool same_geometry(
    const macrdp::DisplayGeometry& left,
    const macrdp::DisplayGeometry& right) {
    return left.id == right.id
        && left.pixel_width == right.pixel_width
        && left.pixel_height == right.pixel_height
        && same_bounds(left.bounds, right.bounds)
        && left.rotation_degrees == right.rotation_degrees
        && left.main == right.main;
}

bool same_topology(
    const macrdp::DisplayTopologySnapshot& previous,
    std::uint32_t main_display_id,
    const std::vector<macrdp::DisplayGeometry>& displays) {
    return previous.main_display_id == main_display_id
        && previous.displays.size() == displays.size()
        && std::equal(
            previous.displays.begin(),
            previous.displays.end(),
            displays.begin(),
            same_geometry);
}

class CoreGraphicsDisplayTopologyBackend final
    : public macrdp::detail::DisplayTopologyBackend {
public:
    ~CoreGraphicsDisplayTopologyBackend() override {
        stop();
    }

    bool start(
        const std::shared_ptr<macrdp::detail::DisplayTopologyObserverState>& state,
        macrdp::detail::DisplayTopologyObserverGeneration generation,
        std::string& error) override {
        {
            std::lock_guard lock(callback_mutex_);
            state_ = state;
            generation_ = generation;
        }
        const CGError result = CGDisplayRegisterReconfigurationCallback(
            &CoreGraphicsDisplayTopologyBackend::display_changed,
            this);
        if (result != kCGErrorSuccess) {
            std::lock_guard lock(callback_mutex_);
            state_.reset();
            generation_ = 0;
            error = "Unable to observe macOS display changes (CoreGraphics error "
                + std::to_string(result) + ")";
            return false;
        }
        registered_ = true;
        error.clear();
        return true;
    }

    macrdp::detail::DisplayTopologyReadResult read() override {
        std::uint32_t display_count = 0;
        CGError result = CGGetActiveDisplayList(0, nullptr, &display_count);
        if (result != kCGErrorSuccess) {
            return {
                false,
                0,
                {},
                "Unable to query active macOS displays (CoreGraphics error "
                    + std::to_string(result) + ")"};
        }

        std::vector<CGDirectDisplayID> display_ids(display_count);
        if (display_count > 0) {
            result = CGGetActiveDisplayList(
                display_count,
                display_ids.data(),
                &display_count);
            if (result != kCGErrorSuccess) {
                return {
                    false,
                    0,
                    {},
                    "Unable to enumerate active macOS displays (CoreGraphics error "
                        + std::to_string(result) + ")"};
            }
            display_ids.resize(display_count);
        }

        const auto main_display_id = CGMainDisplayID();
        std::vector<macrdp::DisplayGeometry> displays;
        displays.reserve(display_ids.size());
        for (const auto display_id : display_ids) {
            const auto pixel_width = CGDisplayPixelsWide(display_id);
            const auto pixel_height = CGDisplayPixelsHigh(display_id);
            const CGRect bounds = CGDisplayBounds(display_id);
            const double rotation = CGDisplayRotation(display_id);
            if (display_id == kCGNullDirectDisplay || pixel_width == 0
                || pixel_height == 0
                || pixel_width > std::numeric_limits<std::uint32_t>::max()
                || pixel_height > std::numeric_limits<std::uint32_t>::max()
                || !std::isfinite(bounds.origin.x)
                || !std::isfinite(bounds.origin.y)
                || !std::isfinite(bounds.size.width)
                || !std::isfinite(bounds.size.height)
                || !std::isfinite(rotation)
                || bounds.size.width <= 0.0
                || bounds.size.height <= 0.0) {
                continue;
            }
            displays.push_back({
                display_id,
                static_cast<std::uint32_t>(pixel_width),
                static_cast<std::uint32_t>(pixel_height),
                {
                    bounds.origin.x,
                    bounds.origin.y,
                    bounds.size.width,
                    bounds.size.height,
                },
                rotation,
                display_id == main_display_id,
            });
        }

        return {true, main_display_id, std::move(displays), {}};
    }

    void stop() noexcept override {
        if (registered_) {
            (void)CGDisplayRemoveReconfigurationCallback(
                &CoreGraphicsDisplayTopologyBackend::display_changed,
                this);
            registered_ = false;
        }
        std::lock_guard lock(callback_mutex_);
        state_.reset();
        generation_ = 0;
    }

private:
    static void display_changed(
        CGDirectDisplayID,
        CGDisplayChangeSummaryFlags flags,
        void* context) {
        if ((flags & kCGDisplayBeginConfigurationFlag) != 0 || context == nullptr) {
            return;
        }
        auto* backend = static_cast<CoreGraphicsDisplayTopologyBackend*>(context);
        std::shared_ptr<macrdp::detail::DisplayTopologyObserverState> state;
        macrdp::detail::DisplayTopologyObserverGeneration generation = 0;
        {
            std::lock_guard lock(backend->callback_mutex_);
            state = backend->state_;
            generation = backend->generation_;
        }
        (void)macrdp::detail::display_topology_backend_changed(
            state,
            generation);
    }

    std::mutex callback_mutex_;
    std::shared_ptr<macrdp::detail::DisplayTopologyObserverState> state_;
    macrdp::detail::DisplayTopologyObserverGeneration generation_ = 0;
    bool registered_ = false;
};

} // namespace

namespace macrdp {

bool DisplayGeometry::valid() const noexcept {
    return id != 0 && pixel_width > 0 && pixel_height > 0
        && std::isfinite(bounds.origin_x) && std::isfinite(bounds.origin_y)
        && std::isfinite(bounds.width) && std::isfinite(bounds.height)
        && bounds.width > 0.0 && bounds.height > 0.0
        && std::isfinite(rotation_degrees);
}

const DisplayGeometry* DisplayTopologySnapshot::find(
    std::uint32_t display_id) const noexcept {
    const auto found = std::find_if(
        displays.begin(),
        displays.end(),
        [display_id](const DisplayGeometry& display) {
            return display.id == display_id;
        });
    return found == displays.end() ? nullptr : &*found;
}

const DisplayGeometry* display_topology_select(
    const DisplayTopologySnapshot& topology,
    std::uint32_t requested_display_id) noexcept {
    if (requested_display_id != 0) {
        return topology.find(requested_display_id);
    }
    if (topology.main_display_id != 0) {
        if (const auto* main = topology.find(topology.main_display_id); main != nullptr) {
            return main;
        }
    }
    return topology.displays.empty() ? nullptr : &topology.displays.front();
}

namespace detail {

bool display_topology_backend_changed(
    const std::shared_ptr<DisplayTopologyObserverState>& state,
    DisplayTopologyObserverGeneration generation) noexcept {
    if (state == nullptr) {
        return false;
    }
    std::lock_guard lock(state->mutex);
    if (!state->active || state->generation != generation) {
        return false;
    }
    state->dirty = true;
    return true;
}

} // namespace detail

struct DisplayTopology::Impl {
    explicit Impl(std::unique_ptr<detail::DisplayTopologyBackend> topology_backend)
        : backend(std::move(topology_backend)),
          observer_state(std::make_shared<detail::DisplayTopologyObserverState>()) {}

    ~Impl() {
        stop();
    }

    bool start() {
        std::lock_guard lifecycle_lock(lifecycle_mutex);
        if (started) {
            return true;
        }

        {
            std::lock_guard lock(observer_state->mutex);
            observer_generation = ++observer_state->generation;
            observer_state->active = true;
            observer_state->dirty = true;
        }
        std::string start_error;
        if (!backend->start(observer_state, observer_generation, start_error)) {
            {
                std::lock_guard lock(observer_state->mutex);
                observer_state->active = false;
                observer_state->dirty = false;
            }
            set_error(std::move(start_error));
            return false;
        }
        started = true;
        if (refresh_locked(true)) {
            return true;
        }

        backend->stop();
        started = false;
        std::lock_guard lock(observer_state->mutex);
        observer_state->active = false;
        observer_state->dirty = false;
        return false;
    }

    bool refresh(bool force) {
        std::lock_guard lifecycle_lock(lifecycle_mutex);
        return started && refresh_locked(force);
    }

    bool refresh_locked(bool force) {
        {
            std::lock_guard lock(observer_state->mutex);
            if (!force && !observer_state->dirty) {
                return true;
            }
            // A callback racing with read() sets this back to true, preserving
            // a second refresh instead of losing the notification.
            observer_state->dirty = false;
        }

        auto result = backend->read();
        if (!result.succeeded) {
            {
                std::lock_guard lock(observer_state->mutex);
                observer_state->dirty = true;
            }
            set_error(result.error.empty()
                    ? "Unable to read the active display topology"
                    : std::move(result.error));
            return false;
        }

        std::unordered_set<std::uint32_t> ids;
        for (auto& display : result.displays) {
            display.main = display.id == result.main_display_id;
            if (!display.valid() || !ids.insert(display.id).second) {
                {
                    std::lock_guard lock(observer_state->mutex);
                    observer_state->dirty = true;
                }
                set_error("Display topology contained invalid or duplicate geometry");
                return false;
            }
        }
        std::sort(
            result.displays.begin(),
            result.displays.end(),
            [](const DisplayGeometry& left, const DisplayGeometry& right) {
                return left.id < right.id;
            });

        {
            std::lock_guard lock(data_mutex);
            if (!current.has_value()
                || !same_topology(*current, result.main_display_id, result.displays)) {
                const auto next_generation = current.has_value()
                    ? current->generation + 1
                    : std::uint64_t{1};
                current = DisplayTopologySnapshot{
                    next_generation,
                    result.main_display_id,
                    std::move(result.displays),
                };
            }
            error.clear();
        }
        return true;
    }

    void stop() noexcept {
        std::lock_guard lifecycle_lock(lifecycle_mutex);
        if (!started) {
            return;
        }
        {
            std::lock_guard lock(observer_state->mutex);
            ++observer_state->generation;
            observer_state->active = false;
            observer_state->dirty = false;
        }
        backend->stop();
        started = false;
    }

    std::optional<DisplayTopologySnapshot> snapshot() const {
        std::lock_guard lock(data_mutex);
        return current;
    }

    std::string last_error() const {
        std::lock_guard lock(data_mutex);
        return error;
    }

    void set_error(std::string next_error) {
        std::lock_guard lock(data_mutex);
        error = std::move(next_error);
    }

    std::unique_ptr<detail::DisplayTopologyBackend> backend;
    std::shared_ptr<detail::DisplayTopologyObserverState> observer_state;
    mutable std::mutex lifecycle_mutex;
    mutable std::mutex data_mutex;
    std::optional<DisplayTopologySnapshot> current;
    std::string error;
    detail::DisplayTopologyObserverGeneration observer_generation = 0;
    bool started = false;
};

DisplayTopology::DisplayTopology()
    : impl_(std::make_unique<Impl>(
          std::make_unique<CoreGraphicsDisplayTopologyBackend>())) {}

DisplayTopology::DisplayTopology(
    std::unique_ptr<detail::DisplayTopologyBackend> backend)
    : impl_(std::make_unique<Impl>(
          backend == nullptr
              ? std::make_unique<CoreGraphicsDisplayTopologyBackend>()
              : std::move(backend))) {}

DisplayTopology::~DisplayTopology() = default;
DisplayTopology::DisplayTopology(DisplayTopology&&) noexcept = default;
DisplayTopology& DisplayTopology::operator=(DisplayTopology&&) noexcept = default;

bool DisplayTopology::start() {
    return impl_->start();
}

bool DisplayTopology::refresh(bool force) {
    return impl_->refresh(force);
}

void DisplayTopology::stop() noexcept {
    impl_->stop();
}

std::optional<DisplayTopologySnapshot> DisplayTopology::snapshot() const {
    return impl_->snapshot();
}

std::string DisplayTopology::last_error() const {
    return impl_->last_error();
}

} // namespace macrdp
