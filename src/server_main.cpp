#include <freerdp/config.h>

#include <freerdp/log.h>
#include <freerdp/server/shadow.h>
#include <freerdp/settings.h>
#include <winpr/ntlm.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>
#include <winpr/wtsapi.h>

#include "macrdp/cliprdr_adapter.h"
#include "macrdp/config_permissions.hpp"
#include "macrdp/preset_config.hpp"
#include "mac_shadow_subsystem.hpp"
#include "macrdp/videotoolbox_h264.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <iterator>
#include <limits>
#include <pwd.h>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace {

enum class SecurityMode {
    nla,
    tls,
    rdp,
};

enum class H264EncoderMode {
    automatic,
    videotoolbox,
    ffmpeg,
    openh264,
};

struct Options {
    std::uint16_t port = 3389;
    std::string bind_address = "127.0.0.1";
    SecurityMode security = SecurityMode::nla;
    bool allow_insecure_security = false;
    std::string username;
    std::string domain;
    std::string password;
    std::string sam_file;
    std::filesystem::path config_dir;
    std::uint32_t h264_bitrate = 16'000'000;
    std::uint32_t frame_rate = 30;
    std::uint32_t h264_key_frame_interval = 0;
    std::uint32_t display_id = 0;
    std::uint32_t max_width = 0;
    std::uint32_t max_height = 0;
    std::uint32_t max_clients = 1;
    H264EncoderMode h264_encoder = H264EncoderMode::automatic;
    bool avc444 = false;
    bool no_gfx = false;
    bool audio_enabled = true;
    bool view_only = false;
    bool clipboard_enabled = true;
    bool preflight = false;
    bool list_displays = false;
    bool list_presets = false;
    bool print_effective_config = false;
    bool password_from_stdin = false;
    bool password_from_command_line = false;
    std::string password_file;
    std::string log_level = "INFO";
    std::string preset_name;
    std::string preset_description;
};

struct BuiltinPreset {
    std::string_view name;
    std::string_view description;
};

constexpr std::array<BuiltinPreset, 5> kBuiltinPresets{{
    {"local", "Loopback-only stable OpenH264 session"},
    {"standard", "Balanced adaptive OpenH264 session"},
    {"high-quality", "Higher quality and frame-rate ceilings"},
    {"resource-saving", "Lower resource ceilings with a 1280x720 size limit"},
    {"view-only", "Screen sharing without input, clipboard, or audio"},
}};

volatile std::sig_atomic_t g_stop_requested = 0;

void handle_signal(int) {
    g_stop_requested = 1;
}

std::filesystem::path default_config_dir() {
    const char* home = std::getenv("HOME");
    if (home != nullptr && home[0] != '\0') {
        return std::filesystem::path(home) / "Library/Application Support/macrdp-cpp";
    }
    return std::filesystem::current_path() / "macrdp-data";
}

void clear_secret(std::string& value) {
    volatile char* data = value.empty() ? nullptr : value.data();
    for (std::size_t index = 0; data != nullptr && index < value.size(); ++index) {
        data[index] = '\0';
    }
    value.clear();
}

std::string current_username() {
    const passwd* account = ::getpwuid(::geteuid());
    return account != nullptr && account->pw_name != nullptr
        ? account->pw_name
        : std::string{};
}

void apply_compatible_defaults(Options& options) {
    options.port = 3389;
    options.security = SecurityMode::nla;
    options.h264_bitrate = 16'000'000;
    options.frame_rate = 30;
    options.h264_key_frame_interval = 10;
    options.display_id = 0;
    options.max_clients = 1;
    options.h264_encoder = H264EncoderMode::openh264;
    options.audio_enabled = false;
}

bool apply_builtin_preset(std::string_view name, Options& options) {
    std::string_view canonical_name = name;
    if (name == "trusted-lan") {
        canonical_name = "standard";
    } else if (name == "smooth-lan") {
        canonical_name = "high-quality";
    } else if (name == "low-bandwidth") {
        canonical_name = "resource-saving";
    }

    if (canonical_name == "local") {
        apply_compatible_defaults(options);
        options.bind_address = "127.0.0.1";
    } else if (canonical_name == "standard") {
        apply_compatible_defaults(options);
        options.bind_address = "0.0.0.0";
    } else if (canonical_name == "high-quality") {
        apply_compatible_defaults(options);
        options.bind_address = "0.0.0.0";
        options.h264_bitrate = 24'000'000;
        options.frame_rate = 30;
        options.h264_key_frame_interval = 30;
    } else if (canonical_name == "resource-saving") {
        apply_compatible_defaults(options);
        options.bind_address = "0.0.0.0";
        options.h264_bitrate = 4'000'000;
        options.frame_rate = 10;
        options.h264_key_frame_interval = 25;
        options.max_width = 1280;
        options.max_height = 720;
    } else if (name == "view-only") {
        apply_compatible_defaults(options);
        options.bind_address = "0.0.0.0";
        options.view_only = true;
        options.clipboard_enabled = false;
    } else {
        return false;
    }
    const auto preset = std::find_if(
        kBuiltinPresets.begin(), kBuiltinPresets.end(), [canonical_name](const auto& candidate) {
            return candidate.name == canonical_name;
        });
    options.preset_name = std::string(name);
    options.preset_description = preset == kBuiltinPresets.end() ? std::string{}
        : canonical_name == name ? std::string(preset->description)
                                 : "Compatibility alias for '"
            + std::string(canonical_name) + "': " + std::string(preset->description);
    return true;
}

bool read_password_from_terminal(const std::string& username, std::string& password) {
    if (!::isatty(STDIN_FILENO)) {
        return false;
    }

    const std::string prompt = "RDP password for " + username + ": ";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    char* input = ::getpass(prompt.c_str());
#pragma clang diagnostic pop
    if (input == nullptr) {
        return false;
    }
    password = input;
    volatile char* secret = input;
    while (*secret != '\0') {
        *secret++ = '\0';
    }
    return !password.empty();
}

void print_usage(const char* program) {
    std::cout
        << "Usage: " << program << " [options]\n"
        << "\n"
        << "  --preset <name>            Apply a built-in or user preset\n"
        << "  --list-presets             List available presets and exit\n"
        << "  --print-effective-config   Print merged non-secret settings and exit\n"
        << "  --preflight                 Check macOS capture/input access and exit\n"
        << "  --list-displays             List active display IDs and exit\n"
        << "  --display-id <number>       Capture one exact display (default: main)\n"
        << "  --port <number>             Listen port (default: 3389)\n"
        << "  --bind-address <address>    Address to bind (default: 127.0.0.1)\n"
        << "  --max-clients <number>      Concurrent client limit, 1-64 (default: 1)\n"
        << "  --security <nla|tls|rdp>    Security protocol (default: nla)\n"
        << "  --allow-insecure-security   Required with TLS/RDP compatibility modes\n"
        << "  --view-only                 Disable remote keyboard and pointer input\n"
        << "  --input                     Enable input when overriding a preset\n"
        << "  --no-clipboard              Disable clipboard redirection\n"
        << "  --clipboard                 Enable clipboard when overriding a preset\n"
        << "  --max-bitrate <value>       Per-client adaptive H.264 ceiling, e.g. 16M\n"
        << "  --bitrate <value>           Compatibility alias for --max-bitrate\n"
        << "  --max-fps <number>          Capture/send ceiling, 1-60 (default: 30)\n"
        << "  --fps <number>              Compatibility alias for --max-fps\n"
        << "  --h264-keyint <frames>      Key-frame interval, 1-300 (1: diagnostic all-IDR)\n"
        << "  --max-width <pixels>        Optional capture width limit\n"
        << "  --max-height <pixels>       Optional capture height limit\n"
        << "  --h264-encoder <mode>       H.264 path: auto, videotoolbox, ffmpeg, or openh264\n"
        << "  --avc444                    Use AVC444 (higher CPU and color fidelity)\n"
        << "  --avc420                    Use AVC420 when overriding a preset\n"
        << "  --no-gfx                    Use incremental SurfaceBits updates instead of GFX/H.264\n"
        << "  --gfx                       Enable GFX/H.264 when overriding a preset\n"
        << "  --no-audio                  Disable screen audio capture and RDPSND output\n"
        << "  --audio                     Enable audio when overriding a preset\n"
        << "  --user <name>               Login user for generated SAM/TLS auth\n"
        << "  --domain <name>             Optional login domain\n"
        << "  --password <value>          Login password (visible in process list)\n"
        << "  --password-stdin            Read one login password line from stdin\n"
        << "  --password-file <path>      Read one password line from an owner-only file\n"
        << "  --sam-file <path>           Existing FreeRDP NTLM SAM file for NLA\n"
        << "  --config-dir <path>         Certificate and generated SAM directory\n"
        << "  --log-level <level>         FreeRDP log level (default: INFO)\n"
        << "  --help                      Show this help\n"
        << "\n"
        << "NLA requires --sam-file or a non-empty --user/--password pair.\n"
        << "Presets use the current macOS user and main display unless overridden.\n"
        << "User presets: <config-dir>/presets/<name>.conf (see docs/presets.md).\n";
}

bool parse_port(std::string_view value, std::uint16_t& port) {
    if (value.empty()) {
        return false;
    }
    unsigned long parsed = 0;
    const auto result = std::from_chars(
        value.data(),
        value.data() + value.size(),
        parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()
        || parsed == 0 || parsed > std::numeric_limits<std::uint16_t>::max()) {
        return false;
    }
    port = static_cast<std::uint16_t>(parsed);
    return true;
}

bool parse_bitrate(std::string_view value, std::uint32_t& bitrate) {
    if (value.empty()) {
        return false;
    }

    std::uint64_t multiplier = 1;
    const char suffix = value.back();
    if (suffix == 'k' || suffix == 'K') {
        multiplier = 1'000;
        value.remove_suffix(1);
    } else if (suffix == 'm' || suffix == 'M') {
        multiplier = 1'000'000;
        value.remove_suffix(1);
    }
    if (value.empty()) {
        return false;
    }

    std::uint64_t parsed = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()
        || parsed == 0 || parsed > std::numeric_limits<std::uint32_t>::max() / multiplier) {
        return false;
    }
    bitrate = static_cast<std::uint32_t>(parsed * multiplier);
    return true;
}

bool parse_uint32_range(
    std::string_view value,
    std::uint32_t minimum,
    std::uint32_t maximum,
    std::uint32_t& result_value) {
    if (value.empty()) {
        return false;
    }

    std::uint64_t parsed = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()
        || parsed < minimum || parsed > maximum) {
        return false;
    }
    result_value = static_cast<std::uint32_t>(parsed);
    return true;
}

bool parse_security(std::string_view value, SecurityMode& mode) {
    if (value == "nla") {
        mode = SecurityMode::nla;
    } else if (value == "tls") {
        mode = SecurityMode::tls;
    } else if (value == "rdp") {
        mode = SecurityMode::rdp;
    } else {
        return false;
    }
    return true;
}

bool parse_h264_encoder(std::string_view value, H264EncoderMode& mode) {
    if (value == "auto") {
        mode = H264EncoderMode::automatic;
    } else if (value == "videotoolbox") {
        mode = H264EncoderMode::videotoolbox;
    } else if (value == "ffmpeg") {
        mode = H264EncoderMode::ffmpeg;
    } else if (value == "openh264") {
        mode = H264EncoderMode::openh264;
    } else {
        return false;
    }
    return true;
}

const char* h264_encoder_name(H264EncoderMode mode) {
    switch (mode) {
    case H264EncoderMode::automatic:
        return "auto";
    case H264EncoderMode::videotoolbox:
        return "videotoolbox";
    case H264EncoderMode::ffmpeg:
        return "ffmpeg";
    case H264EncoderMode::openh264:
        return "openh264";
    }
    return "unknown";
}

const char* security_name(SecurityMode mode) {
    switch (mode) {
    case SecurityMode::nla:
        return "nla";
    case SecurityMode::tls:
        return "tls";
    case SecurityMode::rdp:
        return "rdp";
    }
    return "unknown";
}

bool parse_boolean(std::string_view value, bool& result) {
    if (value == "true") {
        result = true;
    } else if (value == "false") {
        result = false;
    } else {
        return false;
    }
    return true;
}

std::filesystem::path preset_directory(const Options& options) {
    return options.config_dir / "presets";
}

bool apply_preset_setting(const macrdp::PresetSetting& setting, Options& options,
                          std::string& error) {
    const auto invalid = [&](std::string_view expectation) {
        error = "line " + std::to_string(setting.line) + ": '" + setting.key
            + "' " + std::string(expectation);
        return false;
    };
    const std::string_view value = setting.value;
    if (setting.key == "description") {
        options.preset_description = setting.value;
    } else if (setting.key == "port") {
        if (!parse_port(value, options.port)) {
            return invalid("must be between 1 and 65535");
        }
    } else if (setting.key == "bind-address") {
        if (value.empty() || value.find(',') != std::string_view::npos) {
            return invalid("must be one address without commas");
        }
        options.bind_address = setting.value;
    } else if (setting.key == "max-clients") {
        if (!parse_uint32_range(value, 1, 64, options.max_clients)) {
            return invalid("must be between 1 and 64");
        }
    } else if (setting.key == "security") {
        if (!parse_security(value, options.security)) {
            return invalid("must be nla, tls, or rdp");
        }
    } else if (setting.key == "allow-insecure-security") {
        if (!parse_boolean(value, options.allow_insecure_security)) {
            return invalid("must be true or false");
        }
    } else if (setting.key == "user") {
        options.username = setting.value;
    } else if (setting.key == "domain") {
        options.domain = setting.value;
    } else if (setting.key == "display-id") {
        if (value == "main") {
            options.display_id = 0;
        } else if (!parse_uint32_range(
                       value, 1, std::numeric_limits<std::uint32_t>::max(),
                       options.display_id)) {
            return invalid("must be main or an active display ID");
        }
    } else if (setting.key == "bitrate" || setting.key == "max-bitrate") {
        if (!parse_bitrate(value, options.h264_bitrate)) {
            return invalid("must be a positive bps, Kbps, or Mbps value");
        }
    } else if (setting.key == "fps" || setting.key == "max-fps") {
        if (!parse_uint32_range(value, 1, 60, options.frame_rate)) {
            return invalid("must be between 1 and 60");
        }
    } else if (setting.key == "h264-keyint") {
        if (value == "auto") {
            options.h264_key_frame_interval = 0;
        } else if (!parse_uint32_range(value, 1, 300, options.h264_key_frame_interval)) {
            return invalid("must be auto or between 1 and 300");
        }
    } else if (setting.key == "h264-encoder") {
        if (!parse_h264_encoder(value, options.h264_encoder)) {
            return invalid("must be auto, videotoolbox, ffmpeg, or openh264");
        }
    } else if (setting.key == "max-width") {
        if (value == "none") {
            options.max_width = 0;
        } else if (!parse_uint32_range(value, 1, std::numeric_limits<std::uint16_t>::max(),
                                       options.max_width)) {
            return invalid("must be none or between 1 and 65535");
        }
    } else if (setting.key == "max-height") {
        if (value == "none") {
            options.max_height = 0;
        } else if (!parse_uint32_range(value, 1, std::numeric_limits<std::uint16_t>::max(),
                                       options.max_height)) {
            return invalid("must be none or between 1 and 65535");
        }
    } else if (setting.key == "audio") {
        if (!parse_boolean(value, options.audio_enabled)) {
            return invalid("must be true or false");
        }
    } else if (setting.key == "input") {
        bool enabled = false;
        if (!parse_boolean(value, enabled)) {
            return invalid("must be true or false");
        }
        options.view_only = !enabled;
    } else if (setting.key == "clipboard") {
        if (!parse_boolean(value, options.clipboard_enabled)) {
            return invalid("must be true or false");
        }
    } else if (setting.key == "gfx") {
        bool enabled = false;
        if (!parse_boolean(value, enabled)) {
            return invalid("must be true or false");
        }
        options.no_gfx = !enabled;
    } else if (setting.key == "avc444") {
        if (!parse_boolean(value, options.avc444)) {
            return invalid("must be true or false");
        }
    } else if (setting.key == "log-level") {
        options.log_level = setting.value;
    } else if (setting.key == "extends") {
        return true;
    } else if (setting.key == "password-file") {
        if (!std::filesystem::path(setting.value).is_absolute()) {
            return invalid("must be an absolute path");
        }
        options.sam_file.clear();
        options.password_file = setting.value;
    } else if (setting.key == "sam-file") {
        if (!std::filesystem::path(setting.value).is_absolute()) {
            return invalid("must be an absolute path");
        }
        options.password_file.clear();
        options.sam_file = setting.value;
    } else if (setting.key == "password" || setting.key == "password-stdin") {
        return invalid("is forbidden in presets; supply credentials at startup");
    } else {
        return invalid("is not a supported preset key");
    }
    return true;
}

bool load_named_preset(std::string_view name, Options& options,
                       std::vector<std::string>& chain, std::string& error) {
    if (!macrdp::valid_preset_name(name)) {
        error = "Invalid preset name '" + std::string(name)
            + "'; use letters, numbers, '.', '_', or '-'";
        return false;
    }
    if (std::find(chain.begin(), chain.end(), name) != chain.end()) {
        error = "Preset inheritance cycle at '" + std::string(name) + "'";
        return false;
    }
    if (chain.size() >= 8) {
        error = "Preset inheritance exceeds 8 levels";
        return false;
    }

    if (apply_builtin_preset(name, options)) {
        return true;
    }

    chain.emplace_back(name);
    const auto path = preset_directory(options) / (std::string(name) + ".conf");
    std::vector<macrdp::PresetSetting> settings;
    if (!macrdp::load_preset_file(path, settings, error)) {
        chain.pop_back();
        return false;
    }

    const auto extends = std::find_if(settings.begin(), settings.end(), [](const auto& setting) {
        return setting.key == "extends";
    });
    const auto password_file = std::find_if(
        settings.begin(), settings.end(), [](const auto& setting) {
            return setting.key == "password-file";
        });
    const auto sam_file = std::find_if(settings.begin(), settings.end(), [](const auto& setting) {
        return setting.key == "sam-file";
    });
    if (password_file != settings.end() && sam_file != settings.end()) {
        error = path.string() + ": specify only one of 'password-file' and 'sam-file'";
        chain.pop_back();
        return false;
    }
    if (extends != settings.end()
        && !load_named_preset(extends->value, options, chain, error)) {
        error = path.string() + ":" + std::to_string(extends->line) + ": " + error;
        chain.pop_back();
        return false;
    }

    options.preset_name = std::string(name);
    options.preset_description = "User preset " + path.string();
    for (const auto& setting : settings) {
        std::string setting_error;
        if (!apply_preset_setting(setting, options, setting_error)) {
            error = path.string() + ":" + setting_error;
            chain.pop_back();
            return false;
        }
    }
    chain.pop_back();
    return true;
}

bool next_value(int& index, int argc, char** argv, std::string& value) {
    if (index + 1 >= argc) {
        return false;
    }
    value = argv[++index];
    return !value.empty();
}

bool read_password_file(const std::filesystem::path& path, std::string& password) {
    password.clear();
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) {
        std::cerr << "Unable to open password file " << path << ": "
                  << std::strerror(errno) << "\n";
        return false;
    }

    struct stat file_status {};
    const bool metadata_ok = ::fstat(descriptor, &file_status) == 0
        && S_ISREG(file_status.st_mode)
        && file_status.st_uid == ::geteuid()
        && (file_status.st_mode & (S_IRWXG | S_IRWXO)) == 0;
    if (!metadata_ok) {
        std::cerr << "Password file must be a regular owner-only file owned by the current user: "
                  << path << "\n";
        (void)::close(descriptor);
        return false;
    }

    std::array<char, 1024> buffer{};
    bool success = true;
    while (true) {
        const ssize_t count = ::read(descriptor, buffer.data(), buffer.size());
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            std::cerr << "Unable to read password file " << path << ": "
                      << std::strerror(errno) << "\n";
            success = false;
            break;
        }
        if (password.size() + static_cast<std::size_t>(count) > 4096) {
            std::cerr << "Password file is too large: " << path << "\n";
            success = false;
            break;
        }
        password.append(buffer.data(), static_cast<std::size_t>(count));
    }
    if (::close(descriptor) != 0) {
        success = false;
    }
    if (!success) {
        clear_secret(password);
        return false;
    }

    if (!password.empty() && password.back() == '\n') {
        password.pop_back();
        if (!password.empty() && password.back() == '\r') {
            password.pop_back();
        }
    }
    if (password.find_first_of("\r\n") != std::string::npos
        || password.find('\0') != std::string::npos) {
        std::cerr << "Password file must contain exactly one password line: " << path << "\n";
        clear_secret(password);
        return false;
    }
    return true;
}

bool parse_options(int argc, char** argv, Options& options) {
    options.config_dir = default_config_dir();

    // Resolve the configuration root first so preset lookup does not depend on
    // whether --config-dir appears before or after --preset.
    bool saw_cli_credential_source = false;
    for (int index = 1; index < argc; ++index) {
        if (std::string_view(argv[index]) == "--config-dir") {
            if (index + 1 >= argc || argv[index + 1][0] == '\0') {
                std::cerr << "--config-dir requires a non-empty value\n";
                return false;
            }
            options.config_dir = argv[++index];
        }
    }

    bool saw_preset = false;
    for (int index = 1; index < argc; ++index) {
        if (std::string_view(argv[index]) != "--preset") {
            continue;
        }
        if (saw_preset || index + 1 >= argc) {
            std::cerr << "--preset requires one preset name\n";
            return false;
        }
        saw_preset = true;
        const std::string_view preset = argv[++index];
        std::vector<std::string> chain;
        std::string error;
        if (!load_named_preset(preset, options, chain, error)) {
            std::cerr << "Unable to load preset '" << preset << "': " << error << '\n';
            return false;
        }
    }

    for (int index = 1; index < argc; ++index) {
        const std::string_view argument = argv[index];
        std::string value;
        if (argument == "--help" || argument == "-h") {
            print_usage(argv[0]);
            return false;
        } else if (argument == "--preset") {
            ++index;
        } else if (argument == "--preflight") {
            options.preflight = true;
        } else if (argument == "--list-displays") {
            options.list_displays = true;
        } else if (argument == "--list-presets") {
            options.list_presets = true;
        } else if (argument == "--print-effective-config") {
            options.print_effective_config = true;
        } else if (argument == "--display-id") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(
                    value,
                    1,
                    std::numeric_limits<std::uint32_t>::max(),
                    options.display_id)) {
                std::cerr << "--display-id must be between 1 and 4294967295\n";
                return false;
            }
        } else if (argument == "--port") {
            if (!next_value(index, argc, argv, value)
                || !parse_port(value, options.port)) {
                std::cerr << "Invalid --port value\n";
                return false;
            }
        } else if (argument == "--bind-address") {
            if (!next_value(index, argc, argv, options.bind_address)
                || options.bind_address.empty()
                || options.bind_address.find(',') != std::string::npos) {
                std::cerr << "--bind-address requires one non-empty address without commas\n";
                return false;
            }
        } else if (argument == "--max-clients") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(value, 1, 64, options.max_clients)) {
                std::cerr << "--max-clients must be between 1 and 64\n";
                return false;
            }
        } else if (argument == "--security") {
            if (!next_value(index, argc, argv, value)
                || !parse_security(value, options.security)) {
                std::cerr << "--security must be nla, tls, or rdp\n";
                return false;
            }
        } else if (argument == "--allow-insecure-security") {
            options.allow_insecure_security = true;
        } else if (argument == "--bitrate" || argument == "--max-bitrate") {
            if (!next_value(index, argc, argv, value)
                || !parse_bitrate(value, options.h264_bitrate)) {
                std::cerr << argument
                          << " must be a positive value in bps, Kbps, or Mbps\n";
                return false;
            }
        } else if (argument == "--fps" || argument == "--max-fps") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(value, 1, 60, options.frame_rate)) {
                std::cerr << argument << " must be between 1 and 60\n";
                return false;
            }
        } else if (argument == "--h264-keyint") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(
                    value, 1, 300, options.h264_key_frame_interval)) {
                std::cerr << "--h264-keyint must be between 1 and 300\n";
                return false;
            }
        } else if (argument == "--max-width") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(
                       value,
                       1,
                       std::numeric_limits<std::uint16_t>::max(),
                       options.max_width)) {
                std::cerr << "--max-width must be between 1 and 65535\n";
                return false;
            }
        } else if (argument == "--max-height") {
            if (!next_value(index, argc, argv, value)
                || !parse_uint32_range(
                       value,
                       1,
                       std::numeric_limits<std::uint16_t>::max(),
                       options.max_height)) {
                std::cerr << "--max-height must be between 1 and 65535\n";
                return false;
            }
        } else if (argument == "--h264-encoder") {
            if (!next_value(index, argc, argv, value)
                || !parse_h264_encoder(value, options.h264_encoder)) {
                std::cerr << "--h264-encoder must be auto, videotoolbox, ffmpeg, or openh264\n";
                return false;
            }
        } else if (argument == "--avc444") {
            options.avc444 = true;
        } else if (argument == "--avc420") {
            options.avc444 = false;
        } else if (argument == "--no-gfx") {
            options.no_gfx = true;
        } else if (argument == "--gfx") {
            options.no_gfx = false;
        } else if (argument == "--no-audio") {
            options.audio_enabled = false;
        } else if (argument == "--audio") {
            options.audio_enabled = true;
        } else if (argument == "--view-only") {
            options.view_only = true;
        } else if (argument == "--input") {
            options.view_only = false;
        } else if (argument == "--no-clipboard") {
            options.clipboard_enabled = false;
        } else if (argument == "--clipboard") {
            options.clipboard_enabled = true;
        } else if (argument == "--user") {
            if (!next_value(index, argc, argv, options.username)) {
                std::cerr << "--user requires a non-empty value\n";
                return false;
            }
        } else if (argument == "--domain") {
            if (!next_value(index, argc, argv, options.domain)) {
                std::cerr << "--domain requires a non-empty value\n";
                return false;
            }
        } else if (argument == "--password") {
            if (saw_cli_credential_source
                || !next_value(index, argc, argv, options.password)) {
                std::cerr << "Use only one of --password, --password-stdin,"
                             " --password-file, and --sam-file\n";
                return false;
            }
            saw_cli_credential_source = true;
            options.password_from_command_line = true;
            options.password_from_stdin = false;
            options.password_file.clear();
            options.sam_file.clear();
        } else if (argument == "--password-stdin") {
            if (saw_cli_credential_source) {
                std::cerr << "Use only one of --password, --password-stdin,"
                             " --password-file, and --sam-file\n";
                return false;
            }
            saw_cli_credential_source = true;
            clear_secret(options.password);
            options.password_from_command_line = false;
            options.password_from_stdin = true;
            options.password_file.clear();
            options.sam_file.clear();
        } else if (argument == "--password-file") {
            if (saw_cli_credential_source
                || !next_value(index, argc, argv, options.password_file)) {
                std::cerr << "Use only one of --password, --password-stdin,"
                             " --password-file, and --sam-file\n";
                return false;
            }
            saw_cli_credential_source = true;
            clear_secret(options.password);
            options.password_from_command_line = false;
            options.password_from_stdin = false;
            options.sam_file.clear();
        } else if (argument == "--sam-file") {
            if (saw_cli_credential_source
                || !next_value(index, argc, argv, options.sam_file)) {
                std::cerr << "Use only one of --password, --password-stdin,"
                             " --password-file, and --sam-file\n";
                return false;
            }
            saw_cli_credential_source = true;
            clear_secret(options.password);
            options.password_from_command_line = false;
            options.password_from_stdin = false;
            options.password_file.clear();
        } else if (argument == "--config-dir") {
            if (!next_value(index, argc, argv, value)) {
                std::cerr << "--config-dir requires a non-empty value\n";
                return false;
            }
            options.config_dir = value;
        } else if (argument == "--log-level") {
            if (!next_value(index, argc, argv, options.log_level)) {
                std::cerr << "--log-level requires a non-empty value\n";
                return false;
            }
        } else {
            std::cerr << "Unknown option: " << argument << "\n";
            print_usage(argv[0]);
            return false;
        }
    }

    if (options.avc444
        && (options.h264_encoder == H264EncoderMode::videotoolbox
            || options.h264_encoder == H264EncoderMode::openh264)) {
        std::cerr << "--h264-encoder videotoolbox/openh264 cannot be used with --avc444\n";
        return false;
    }

    if (!options.preset_name.empty() && options.username.empty()) {
        options.username = current_username();
    }

    // Discovery, inspection, and preflight deliberately avoid credential sources,
    // generated configuration, TLS initialization, and listener setup.
    if (options.list_displays || options.list_presets || options.print_effective_config
        || options.preflight) {
        clear_secret(options.password);
        return true;
    }

    if (options.security != SecurityMode::nla && !options.allow_insecure_security) {
        std::cerr << "--security tls/rdp requires --allow-insecure-security;"
                     " these compatibility modes disable NLA\n";
        return false;
    }
    if (options.security == SecurityMode::nla && options.allow_insecure_security) {
        std::cerr << "--allow-insecure-security is valid only with --security tls or rdp\n";
        return false;
    }

    if (options.password_from_stdin) {
        if (!std::getline(std::cin, options.password)) {
            std::cerr << "Unable to read password from stdin\n";
            return false;
        }
        while (!options.password.empty()
               && (options.password.back() == '\n' || options.password.back() == '\r')) {
            options.password.pop_back();
        }
    }

    if (!options.password_file.empty()) {
        if (!read_password_file(options.password_file, options.password)) {
            return false;
        }
    }

    if (options.password.empty()) {
        const char* environment_password = std::getenv("MACRDP_PASSWORD");
        if (environment_password != nullptr) {
            options.password = environment_password;
        }
    }

    if (!options.preset_name.empty() && options.security == SecurityMode::nla
        && options.sam_file.empty()) {
        if (options.password.empty()
            && !read_password_from_terminal(options.username, options.password)
            && ::isatty(STDIN_FILENO)) {
            std::cerr << "Unable to read an interactive RDP password\n";
            return false;
        }
    }

    if (options.security == SecurityMode::nla) {
        if (options.sam_file.empty()
            && (options.username.empty() || options.password.empty())) {
            std::cerr << "NLA requires --sam-file or non-empty --user and --password"
                      << " (or MACRDP_PASSWORD)\n";
            return false;
        }
    } else if (options.username.empty() || options.password.empty()) {
        std::cerr << "TLS/RDP authentication requires non-empty --user and --password"
                  << " (or MACRDP_PASSWORD)\n";
        return false;
    }

    if (!options.sam_file.empty()) {
        options.sam_file = std::filesystem::absolute(options.sam_file).string();
    }
    if (!options.password_file.empty()) {
        options.password_file = std::filesystem::absolute(options.password_file).string();
    }
    return true;
}

std::string hex_encode(const std::uint8_t* bytes, std::size_t size) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.resize(size * 2);
    for (std::size_t index = 0; index < size; ++index) {
        result[index * 2] = digits[bytes[index] >> 4];
        result[index * 2 + 1] = digits[bytes[index] & 0x0F];
    }
    return result;
}

bool valid_sam_field(std::string_view value) {
    return std::all_of(value.begin(), value.end(), [](char character) {
        return character != ':' && character != '\n' && character != '\r'
            && character != '\0';
    });
}

bool write_sam_file(const std::filesystem::path& path, const Options& options) {
    if (options.username.empty() || options.password.empty()
        || !valid_sam_field(options.username) || !valid_sam_field(options.domain)
        || options.password.size() > std::numeric_limits<UINT32>::max()) {
        return false;
    }

    std::uint8_t nt_hash[16]{};
    if (!NTOWFv1A(
            options.password.c_str(),
            static_cast<UINT32>(options.password.size()),
            nt_hash)) {
        return false;
    }

    const std::string line = options.username + ":" + options.domain + "::"
        + hex_encode(nt_hash, sizeof(nt_hash)) + ":::\n";
    std::fill(std::begin(nt_hash), std::end(nt_hash), 0);

    const auto parent = path.parent_path();
    if (!parent.empty()) {
        std::error_code error;
        std::filesystem::create_directories(parent, error);
        if (error) {
            return false;
        }
    }

    const int descriptor = ::open(
        path.c_str(),
        O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        return false;
    }
    (void)::fchmod(descriptor, S_IRUSR | S_IWUSR);

    std::size_t offset = 0;
    bool success = true;
    while (offset < line.size()) {
        const ssize_t written = ::write(descriptor, line.data() + offset, line.size() - offset);
        if (written <= 0) {
            success = false;
            break;
        }
        offset += static_cast<std::size_t>(written);
    }
    if (::close(descriptor) != 0) {
        success = false;
    }
    if (!success) {
        (void)::unlink(path.c_str());
    }
    return success;
}

void secure_remove_file(const std::filesystem::path& path) noexcept {
    if (path.empty()) {
        return;
    }

    const int descriptor = ::open(path.c_str(), O_WRONLY | O_NOFOLLOW);
    if (descriptor >= 0) {
        struct stat file_status {};
        if (::fstat(descriptor, &file_status) == 0 && S_ISREG(file_status.st_mode)) {
            std::array<std::uint8_t, 4096> zeros{};
            off_t remaining = file_status.st_size;
            while (remaining > 0) {
                const auto requested = static_cast<std::size_t>(std::min<off_t>(
                    remaining,
                    static_cast<off_t>(zeros.size())));
                const ssize_t written = ::write(descriptor, zeros.data(), requested);
                if (written <= 0) {
                    break;
                }
                remaining -= written;
            }
            (void)::fsync(descriptor);
            (void)::ftruncate(descriptor, 0);
        }
        (void)::close(descriptor);
    }
    (void)::unlink(path.c_str());
}

class GeneratedSamFileCleanup final {
public:
    GeneratedSamFileCleanup() = default;
    explicit GeneratedSamFileCleanup(std::filesystem::path path)
        : path_(std::move(path)) {}

    ~GeneratedSamFileCleanup() {
        secure_remove_file(path_);
    }

    GeneratedSamFileCleanup(const GeneratedSamFileCleanup&) = delete;
    GeneratedSamFileCleanup& operator=(const GeneratedSamFileCleanup&) = delete;

private:
    std::filesystem::path path_;
};

bool set_security(rdpSettings* settings, SecurityMode mode) {
    if (settings == nullptr) {
        return false;
    }
    const bool nla = mode == SecurityMode::nla;
    const bool tls = mode == SecurityMode::tls;
    const bool rdp = mode == SecurityMode::rdp;
    return freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, nla)
        && freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, tls)
        && freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, rdp)
        && freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, false)
        && freerdp_settings_set_bool(settings, FreeRDP_UseRdpSecurityLayer, rdp);
}

bool configure_server(rdpShadowServer* server, const Options& options, const std::string& sam_file) {
    if (server == nullptr || server->settings == nullptr) {
        return false;
    }

    server->port = options.port;
    if (!options.bind_address.empty()) {
        const std::string bind_configuration = "bind-address," + options.bind_address;
        server->ipcSocket = ::strdup(bind_configuration.c_str());
        if (server->ipcSocket == nullptr) {
            return false;
        }
    }
    server->selectedMonitor = 0;
    server->mayView = TRUE;
    server->mayInteract = options.view_only ? FALSE : TRUE;
    server->maxClientsConnected = options.max_clients;
    server->authentication = TRUE;
    server->ShowMouseCursor = FALSE;
    // Windows 11 24H2 clients are more reliable with one bitmap rectangle.
    server->SupportMultiRectBitmapUpdates = FALSE;
    server->h264BitRate = options.h264_bitrate;
    server->h264FrameRate = options.frame_rate;
    server->h264QP = 0;
    const bool use_graphics_pipeline = !options.no_gfx;

    // The direct bridge accepts AVC420/I420. AVC444 has a separate YUV444
    // stream and therefore remains on FreeRDP's FFmpeg fallback path.
    const bool use_videotoolbox = !options.avc444
        && options.h264_encoder != H264EncoderMode::ffmpeg;
    const bool use_openh264 = options.h264_encoder == H264EncoderMode::openh264;
    macrdp_h264_encoder_set_backend(
        use_openh264 ? MACRDP_H264_BACKEND_OPENH264 : MACRDP_H264_BACKEND_FFMPEG);
    macrdp_vt_h264_encoder_set_enabled(use_videotoolbox && !use_openh264 ? 1 : 0);
    macrdp_vt_h264_encoder_set_key_frame_interval(options.h264_key_frame_interval);
    macrdp_shadow_set_capture_options(
        options.display_id,
        options.max_width,
        options.max_height,
        options.frame_rate,
        options.audio_enabled);
    macrdp_shadow_set_input_enabled(!options.view_only);
    macrdp_shadow_cliprdr_set_enabled(options.clipboard_enabled ? TRUE : FALSE);

    // This server currently exposes only the TCP RDP transport. These
    // features use the MCS message channel and must stay off until their
    // negotiation and transport paths are implemented here.
    if (!set_security(server->settings, options.security)
        || !freerdp_settings_set_uint32(server->settings, FreeRDP_ColorDepth, 32)
        || !freerdp_settings_set_uint32(
               server->settings, FreeRDP_VCChunkSize, CHANNEL_CHUNK_LENGTH)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_NSCodec, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_RemoteFxCodec, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_RemoteFxImageCodec, TRUE)
        || !freerdp_settings_set_bool(
               server->settings, FreeRDP_SupportGraphicsPipeline, use_graphics_pipeline)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxProgressive, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxProgressiveV2, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxPlanar, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_MouseUseRelativeMove, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_HasRelativeMouseEvent, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_NetworkAutoDetect, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_SupportHeartbeatPdu, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_SupportMultitransport, FALSE)
        || !freerdp_settings_set_uint32(server->settings, FreeRDP_MultitransportFlags, 0)) {
        return false;
    }

#if defined(WITH_GFX_H264)
    if (!freerdp_settings_set_bool(server->settings, FreeRDP_GfxH264, use_graphics_pipeline)
        || !freerdp_settings_set_bool(
               server->settings, FreeRDP_GfxAVC444, use_graphics_pipeline && options.avc444)
        || !freerdp_settings_set_bool(
               server->settings, FreeRDP_GfxAVC444v2, use_graphics_pipeline && options.avc444)) {
        return false;
    }
#else
    if (!freerdp_settings_set_bool(server->settings, FreeRDP_GfxH264, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxAVC444, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxAVC444v2, FALSE)) {
        return false;
    }
#endif

    if (!sam_file.empty()
        && !freerdp_settings_set_string(server->settings, FreeRDP_NtlmSamFile, sam_file.c_str())) {
        return false;
    }
    return true;
}

int list_displays() {
    std::vector<MacrdpDisplayInfo> displays;
    std::string error;
    if (!macrdp_shadow_enumerate_displays(displays, error)) {
        std::cerr << "Unable to list displays: " << error << '\n';
        return 1;
    }

    for (const auto& display : displays) {
        std::cout << "display_id=" << display.id
                  << " main=" << (display.main ? "yes" : "no")
                  << " pixels=" << display.pixel_width << 'x' << display.pixel_height
                  << " points=" << display.point_width << 'x' << display.point_height
                  << " origin=" << display.origin_x << ',' << display.origin_y
                  << '\n';
    }
    return 0;
}

int list_presets(const Options& options) {
    for (const auto& preset : kBuiltinPresets) {
        std::cout << preset.name << "\tbuilt-in\t" << preset.description << '\n';
    }

    std::vector<std::string> names;
    std::string error;
    if (!macrdp::list_preset_files(preset_directory(options), names, error)) {
        std::cerr << error << '\n';
        return 1;
    }
    for (const auto& name : names) {
        const bool shadows_builtin = std::any_of(
            kBuiltinPresets.begin(), kBuiltinPresets.end(), [&name](const auto& preset) {
                return preset.name == name;
            });
        if (!shadows_builtin) {
            std::cout << name << "\tuser\t"
                      << (preset_directory(options) / (name + ".conf")) << '\n';
        }
    }
    return 0;
}

int print_effective_config(const Options& options) {
    const char* credential_source = "none";
    if (!options.sam_file.empty()) {
        credential_source = "sam-file";
    } else if (!options.password_file.empty()) {
        credential_source = "password-file";
    } else if (options.password_from_stdin) {
        credential_source = "stdin";
    } else if (options.password_from_command_line) {
        credential_source = "command-line";
    } else if (std::getenv("MACRDP_PASSWORD") != nullptr) {
        credential_source = "environment";
    } else if (!options.preset_name.empty() && options.security == SecurityMode::nla) {
        credential_source = "interactive-prompt";
    }

    std::cout << "preset="
              << (options.preset_name.empty() ? "none" : options.preset_name) << '\n'
              << "description=" << options.preset_description << '\n'
              << "port=" << options.port << '\n'
              << "bind-address=" << options.bind_address << '\n'
              << "max-clients=" << options.max_clients << '\n'
              << "security=" << security_name(options.security) << '\n'
              << "allow-insecure-security="
              << (options.allow_insecure_security ? "true" : "false") << '\n'
              << "user=" << options.username << '\n'
              << "domain=" << options.domain << '\n'
              << "credential-source=" << credential_source << '\n'
              << "display-id="
              << (options.display_id == 0 ? "main" : std::to_string(options.display_id)) << '\n'
              << "max-bitrate=" << options.h264_bitrate << '\n'
              << "max-fps=" << options.frame_rate << '\n'
              << "h264-encoder=" << h264_encoder_name(options.h264_encoder) << '\n'
              << "h264-keyint="
              << (options.h264_key_frame_interval == 0
                      ? "auto"
                      : std::to_string(options.h264_key_frame_interval)) << '\n'
              << "max-width="
              << (options.max_width == 0 ? "none" : std::to_string(options.max_width)) << '\n'
              << "max-height="
              << (options.max_height == 0 ? "none" : std::to_string(options.max_height)) << '\n'
              << "audio=" << (options.audio_enabled ? "true" : "false") << '\n'
              << "input=" << (options.view_only ? "false" : "true") << '\n'
              << "clipboard=" << (options.clipboard_enabled ? "true" : "false") << '\n'
              << "gfx=" << (options.no_gfx ? "false" : "true") << '\n'
              << "avc444=" << (options.avc444 ? "true" : "false") << '\n'
              << "log-level=" << options.log_level << '\n';
    return 0;
}

int run_preflight(const Options& options) {
    macrdp_shadow_set_capture_options(
        options.display_id,
        options.max_width,
        options.max_height,
        options.frame_rate,
        options.audio_enabled);

    std::string capture_error;
    const bool capture_available = macrdp_shadow_preflight_capture(capture_error);
    std::cout << "screen_capture="
              << (capture_available ? "available" : "unavailable") << '\n';
    std::cout << "display_id=" << options.display_id << '\n';
    if (!capture_available) {
        std::cerr << "Screen capture preflight failed: " << capture_error << '\n';
    }

    bool input_available = true;
    if (options.view_only) {
        std::cout << "accessibility=not-required\n";
    } else {
        std::string input_error;
        input_available = macrdp_shadow_preflight_input(input_error);
        std::cout << "accessibility="
                  << (input_available ? "available" : "unavailable") << '\n';
        if (!input_available) {
            std::cerr << "Input preflight failed: " << input_error << '\n';
        }
    }

    const bool success = capture_available && input_available;
    std::cout << "preflight=" << (success ? "pass" : "fail") << std::endl;
    return success ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    Options options;
    if (!parse_options(argc, argv, options)) {
        clear_secret(options.password);
        return argc > 1 && (std::string_view(argv[1]) == "--help"
                             || std::string_view(argv[1]) == "-h")
            ? 0
            : 1;
    }

    if (options.list_displays) {
        return list_displays();
    }
    if (options.list_presets) {
        return list_presets(options);
    }
    if (options.print_effective_config) {
        return print_effective_config(options);
    }

    std::string display_error;
    std::uint32_t resolved_display_id = 0;
    if (!macrdp_shadow_resolve_display_id(
            options.display_id,
            resolved_display_id,
            display_error)) {
        std::cerr << "Unable to select macOS display: " << display_error << '\n';
        clear_secret(options.password);
        return 1;
    }
    options.display_id = resolved_display_id;

    if (options.preflight) {
        return run_preflight(options);
    }

    std::error_code directory_error;
    std::filesystem::create_directories(options.config_dir, directory_error);
    if (directory_error) {
        std::cerr << "Unable to create config directory " << options.config_dir << ": "
                  << directory_error.message() << "\n";
        clear_secret(options.password);
        return 1;
    }
    if (!macrdp::restrict_config_paths(options.config_dir)) {
        std::cerr << "Unable to make config directory private: " << options.config_dir << "\n";
        clear_secret(options.password);
        return 1;
    }

    if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) {
        std::cerr << "Unable to initialize FreeRDP TLS/NTLM support\n";
        clear_secret(options.password);
        return 1;
    }

    std::filesystem::path generated_sam_path;
    if (options.security == SecurityMode::nla && options.sam_file.empty()) {
        const auto generated_path = options.config_dir / "macrdp.sam";
        if (!write_sam_file(generated_path, options)) {
            std::cerr << "Unable to create the generated SAM file " << generated_path << "\n";
            clear_secret(options.password);
            return 1;
        }
        generated_sam_path = generated_path;
    }
    GeneratedSamFileCleanup generated_sam_cleanup(generated_sam_path);
    const std::string sam_file = options.sam_file.empty()
        ? generated_sam_path.string()
        : options.sam_file;

    macrdp_shadow_set_credentials(
        options.username.empty() ? nullptr : options.username.c_str(),
        options.domain.empty() ? nullptr : options.domain.c_str(),
        options.password.empty() ? nullptr : options.password.c_str());

    wLog* root_log = WLog_GetRoot();
    if (root_log == nullptr || !WLog_SetStringLogLevel(root_log, options.log_level.c_str())) {
        std::cerr << "Invalid FreeRDP log level: " << options.log_level << "\n";
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    shadow_subsystem_set_entry(macrdp_shadow_subsystem_entry);
    rdpShadowServer* server = shadow_server_new();
    if (server == nullptr) {
        std::cerr << "Unable to allocate FreeRDP shadow server\n";
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    server->ConfigPath = ::strdup(options.config_dir.c_str());
    if (server->ConfigPath == nullptr || !configure_server(server, options, sam_file)) {
        std::cerr << "Unable to configure FreeRDP shadow server\n";
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    if (shadow_server_init(server) < 0) {
        std::cerr << "Unable to initialize FreeRDP shadow server. Check certificate, SAM, and"
                     " Screen Recording prerequisites.\n";
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }
    if (!macrdp::restrict_config_paths(options.config_dir)) {
        std::cerr << "Unable to make generated FreeRDP configuration private: "
                  << options.config_dir << "\n";
        shadow_server_uninit(server);
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    std::string capture_error;
    if (!macrdp_shadow_preflight_capture(capture_error)) {
        std::cerr << "Unable to access the macOS display before starting the RDP listener: "
                  << capture_error << "\n"
                  << "Grant Screen Recording permission and run from the logged-in GUI session.\n";
        shadow_server_uninit(server);
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    std::string input_error;
    if (!options.view_only && !macrdp_shadow_preflight_input(input_error)) {
        std::cerr << "Unable to inject macOS input before starting the RDP listener: "
                  << input_error << "\n"
                  << "Grant Accessibility permission to this executable or Terminal.\n";
        shadow_server_uninit(server);
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    if (shadow_server_start(server) < 0) {
        std::cerr << "Unable to start FreeRDP shadow server\n";
        shadow_server_uninit(server);
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    if (options.bind_address == "0.0.0.0" || options.bind_address == "[::]"
        || options.bind_address == "::") {
        std::cerr << "Warning: macrdp-server is listening on every network interface; "
                     "use this only behind a firewall or on a trusted LAN/VPN.\n";
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    std::cout << "macrdp-server listening on port " << options.port
              << " address=" << options.bind_address
              << " with "
              << (options.security == SecurityMode::nla
                      ? "NLA"
                      : options.security == SecurityMode::tls ? "TLS" : "RDP")
              << " security h264_encoder=" << h264_encoder_name(options.h264_encoder)
              << " max_bitrate=" << options.h264_bitrate
              << " max_fps=" << options.frame_rate
              << " adaptive_video=enabled"
              << " h264_keyint="
              << (options.h264_key_frame_interval == 0
                      ? "auto"
                      : std::to_string(options.h264_key_frame_interval))
              << " input=" << (options.view_only ? "disabled" : "enabled")
              << " clipboard=" << (options.clipboard_enabled ? "enabled" : "disabled")
              << " display_id=" << options.display_id
              << " max_clients=" << options.max_clients
              << std::endl;

    bool server_failed = false;
    while (!g_stop_requested) {
        if (server->thread != nullptr
            && WaitForSingleObject(server->thread, 0) == WAIT_OBJECT_0) {
            server_failed = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{250});
    }

    shadow_server_stop(server);
    shadow_server_uninit(server);
    shadow_server_free(server);
    macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
    clear_secret(options.password);
    if (server_failed) {
        std::cerr << "RDP server stopped unexpectedly\n";
    }
    return server_failed ? 1 : 0;
}
