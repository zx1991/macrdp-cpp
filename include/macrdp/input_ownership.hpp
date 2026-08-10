#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace macrdp {

using InputClientId = std::uint64_t;

enum class InputButton : std::uint8_t {
    left,
    right,
    other,
    x1,
    x2,
};

struct InputReleaseState {
    std::vector<std::uint16_t> keys;
    std::vector<std::uint16_t> unicode;
    std::array<bool, 5> buttons{};
};

// Tracks which RDP clients currently own physical input state. The platform
// injector can then emit a release only when the last owner lets go.
class InputOwnership final {
public:
    // RDP represents Pause as E1 1D down, 45 down, E1 1D up, 45 up.
    // macOS has no native Pause key, and forwarding the constituents would
    // inject Control and Keypad Clear independently. Consume that sequence
    // while leaving ordinary Num Lock (scan code 45) untouched.
    [[nodiscard]] bool consume_pause_sequence_event(
        InputClientId client,
        std::uint16_t key_identity,
        bool key_down) {
        constexpr std::uint16_t pause_control = 0x021DU;
        constexpr std::uint16_t num_lock = 0x0045U;

        auto client_it = clients_.find(client);
        if (key_identity == pause_control) {
            if (key_down) {
                clients_[client].pause_sequence = PauseSequenceState::control_down;
            } else if (client_it != clients_.end()) {
                client_it->second.pause_sequence =
                    client_it->second.pause_sequence == PauseSequenceState::num_lock_down
                    ? PauseSequenceState::control_up
                    : PauseSequenceState::idle;
            }
            return true;
        }

        if (client_it == clients_.end()
            || client_it->second.pause_sequence == PauseSequenceState::idle) {
            return false;
        }

        auto& pause_sequence = client_it->second.pause_sequence;
        if (key_identity == num_lock) {
            if (key_down && pause_sequence == PauseSequenceState::control_down) {
                pause_sequence = PauseSequenceState::num_lock_down;
                return true;
            }
            if (!key_down && pause_sequence == PauseSequenceState::control_up) {
                pause_sequence = PauseSequenceState::idle;
                return true;
            }
        }

        // Do not let a partial sequence consume a later, unrelated Num Lock.
        pause_sequence = PauseSequenceState::idle;
        return false;
    }

    [[nodiscard]] bool acquire_key(InputClientId client, std::uint16_t key) {
        auto& state = clients_[client];
        if (!state.keys.insert(key).second) {
            return false;
        }
        return ++key_counts_[key] == 1;
    }

    [[nodiscard]] bool release_key(InputClientId client, std::uint16_t key) {
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end() || !client_it->second.keys.erase(key)) {
            return false;
        }
        decrement_count(key_counts_, key);
        return key_counts_.find(key) == key_counts_.end();
    }

    // A few RDP clients have been observed to omit or change the extended
    // prefix on a key-up. Keep the physical identity lookup separate from
    // release_key so callers can recover the identity used by the key-down.
    [[nodiscard]] std::optional<std::uint16_t> find_key(
        InputClientId client,
        std::uint16_t key) const {
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end()
            || client_it->second.keys.find(key) == client_it->second.keys.end()) {
            return std::nullopt;
        }
        return key;
    }

    // A repeated key-down should only be forwarded when this client owns the
    // physical key exclusively. A second client sharing the same key must not
    // create an independent autorepeat stream.
    [[nodiscard]] bool is_key_exclusive(
        InputClientId client,
        std::uint16_t key) const {
        const auto client_it = clients_.find(client);
        const auto key_it = key_counts_.find(key);
        return client_it != clients_.end()
            && client_it->second.keys.find(key) != client_it->second.keys.end()
            && key_it != key_counts_.end()
            && key_it->second == 1;
    }

    [[nodiscard]] bool is_key_code_active(std::uint8_t code) const {
        for (const auto& [key, count] : key_counts_) {
            (void)count;
            if (static_cast<std::uint8_t>(key & 0x00FFU) == code) {
                return true;
            }
        }
        return false;
    }

    [[nodiscard]] std::vector<std::uint16_t> find_keys_by_code(
        InputClientId client,
        std::uint8_t code) const {
        std::vector<std::uint16_t> matches;
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end()) {
            return matches;
        }

        for (const auto key : client_it->second.keys) {
            if (static_cast<std::uint8_t>(key & 0x00FFU) != code) {
                continue;
            }
            matches.push_back(key);
        }
        return matches;
    }

    [[nodiscard]] std::optional<std::uint16_t> find_key_by_code(
        InputClientId client,
        std::uint8_t code) const {
        const auto matches = find_keys_by_code(client, code);
        // The same scan-code byte can represent distinct keys (for example
        // left and right Control). Do not guess when the caller only needs a
        // single identity.
        return matches.size() == 1 ? std::optional{matches.front()} : std::nullopt;
    }

    [[nodiscard]] bool acquire_unicode(InputClientId client, std::uint16_t code) {
        auto& state = clients_[client];
        if (!state.unicode.insert(code).second) {
            return false;
        }
        return ++unicode_counts_[code] == 1;
    }

    [[nodiscard]] bool release_unicode(InputClientId client, std::uint16_t code) {
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end() || !client_it->second.unicode.erase(code)) {
            return false;
        }
        decrement_count(unicode_counts_, code);
        return unicode_counts_.find(code) == unicode_counts_.end();
    }

    [[nodiscard]] bool acquire_button(InputClientId client, InputButton button) {
        auto& state = clients_[client];
        const auto index = button_index(button);
        if (state.buttons[index]) {
            return false;
        }
        state.buttons[index] = true;
        return ++button_counts_[index] == 1;
    }

    [[nodiscard]] bool release_button(InputClientId client, InputButton button) {
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end()) {
            return false;
        }
        const auto index = button_index(button);
        if (!client_it->second.buttons[index]) {
            return false;
        }
        client_it->second.buttons[index] = false;
        if (button_counts_[index] > 0) {
            --button_counts_[index];
        }
        return button_counts_[index] == 0;
    }

    [[nodiscard]] InputReleaseState release_client(InputClientId client) {
        InputReleaseState released;
        const auto client_it = clients_.find(client);
        if (client_it == clients_.end()) {
            return released;
        }

        ClientState state = std::move(client_it->second);
        clients_.erase(client_it);

        released.keys.reserve(state.keys.size());
        for (const auto key : state.keys) {
            decrement_count(key_counts_, key);
            if (key_counts_.find(key) == key_counts_.end()) {
                released.keys.push_back(key);
            }
        }
        released.unicode.reserve(state.unicode.size());
        for (const auto code : state.unicode) {
            decrement_count(unicode_counts_, code);
            if (unicode_counts_.find(code) == unicode_counts_.end()) {
                released.unicode.push_back(code);
            }
        }
        for (std::size_t index = 0; index < state.buttons.size(); ++index) {
            if (state.buttons[index] && button_counts_[index] > 0) {
                --button_counts_[index];
            }
            if (state.buttons[index] && button_counts_[index] == 0) {
                released.buttons[index] = true;
            }
        }
        return released;
    }

    [[nodiscard]] InputReleaseState release_all() {
        InputReleaseState released;
        std::vector<InputClientId> client_ids;
        client_ids.reserve(clients_.size());
        for (const auto& [client, state] : clients_) {
            (void)state;
            client_ids.push_back(client);
        }
        for (const auto client : client_ids) {
            const auto client_released = release_client(client);
            released.keys.insert(
                released.keys.end(),
                client_released.keys.begin(),
                client_released.keys.end());
            released.unicode.insert(
                released.unicode.end(),
                client_released.unicode.begin(),
                client_released.unicode.end());
            for (std::size_t index = 0; index < released.buttons.size(); ++index) {
                released.buttons[index] = released.buttons[index] || client_released.buttons[index];
            }
        }
        return released;
    }

private:
    enum class PauseSequenceState : std::uint8_t {
        idle,
        control_down,
        num_lock_down,
        control_up,
    };

    struct ClientState {
        std::unordered_set<std::uint16_t> keys;
        std::unordered_set<std::uint16_t> unicode;
        std::array<bool, 5> buttons{};
        PauseSequenceState pause_sequence = PauseSequenceState::idle;
    };

    template <typename Key>
    static void decrement_count(std::unordered_map<Key, std::size_t>& counts, Key key) {
        const auto it = counts.find(key);
        if (it == counts.end()) {
            return;
        }
        if (it->second <= 1) {
            counts.erase(it);
        } else {
            --it->second;
        }
    }

    static constexpr std::size_t button_index(InputButton button) noexcept {
        return static_cast<std::size_t>(button);
    }

    std::unordered_map<InputClientId, ClientState> clients_;
    std::unordered_map<std::uint16_t, std::size_t> key_counts_;
    std::unordered_map<std::uint16_t, std::size_t> unicode_counts_;
    std::array<std::size_t, 5> button_counts_{};
};

} // namespace macrdp
