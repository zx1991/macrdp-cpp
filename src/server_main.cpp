#include <freerdp/config.h>

#include <freerdp/log.h>
#include <freerdp/server/shadow.h>
#include <freerdp/settings.h>
#include <winpr/ntlm.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>

#include "mac_shadow_subsystem.hpp"

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>
#include <thread>
#include <sys/stat.h>
#include <unistd.h>

namespace {

enum class SecurityMode {
    nla,
    tls,
    rdp,
};

struct Options {
    std::uint16_t port = 3389;
    SecurityMode security = SecurityMode::nla;
    std::string username;
    std::string domain;
    std::string password;
    std::string sam_file;
    std::filesystem::path config_dir;
    bool password_from_stdin = false;
    std::string log_level = "INFO";
};

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

void print_usage(const char* program) {
    std::cout
        << "Usage: " << program << " [options]\n"
        << "\n"
        << "  --port <number>             Listen port (default: 3389)\n"
        << "  --security <nla|tls|rdp>    Security protocol (default: nla)\n"
        << "  --user <name>               Login user for generated SAM/TLS auth\n"
        << "  --domain <name>             Optional login domain\n"
        << "  --password <value>          Login password (visible in process list)\n"
        << "  --password-stdin            Read one login password line from stdin\n"
        << "  --sam-file <path>           Existing FreeRDP NTLM SAM file for NLA\n"
        << "  --config-dir <path>         Certificate and generated SAM directory\n"
        << "  --log-level <level>         FreeRDP log level (default: INFO)\n"
        << "  --help                      Show this help\n"
        << "\n"
        << "NLA requires --sam-file or a non-empty --user/--password pair.\n";
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

bool next_value(int& index, int argc, char** argv, std::string& value) {
    if (index + 1 >= argc) {
        return false;
    }
    value = argv[++index];
    return !value.empty();
}

bool parse_options(int argc, char** argv, Options& options) {
    options.config_dir = default_config_dir();
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument = argv[index];
        std::string value;
        if (argument == "--help" || argument == "-h") {
            print_usage(argv[0]);
            return false;
        } else if (argument == "--port") {
            if (!next_value(index, argc, argv, value)
                || !parse_port(value, options.port)) {
                std::cerr << "Invalid --port value\n";
                return false;
            }
        } else if (argument == "--security") {
            if (!next_value(index, argc, argv, value)
                || !parse_security(value, options.security)) {
                std::cerr << "--security must be nla, tls, or rdp\n";
                return false;
            }
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
            if (options.password_from_stdin
                || !next_value(index, argc, argv, options.password)) {
                std::cerr << "--password requires a non-empty value and cannot be combined with"
                             " --password-stdin\n";
                return false;
            }
        } else if (argument == "--password-stdin") {
            if (!options.password.empty() || options.password_from_stdin) {
                std::cerr << "Use only one of --password and --password-stdin\n";
                return false;
            }
            options.password_from_stdin = true;
        } else if (argument == "--sam-file") {
            if (!next_value(index, argc, argv, options.sam_file)) {
                std::cerr << "--sam-file requires a non-empty value\n";
                return false;
            }
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

    if (options.password.empty()) {
        const char* environment_password = std::getenv("MACRDP_PASSWORD");
        if (environment_password != nullptr) {
            options.password = environment_password;
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
    return success;
}

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
    server->selectedMonitor = 0;
    server->mayView = TRUE;
    server->mayInteract = TRUE;
    server->authentication = TRUE;
    server->ShowMouseCursor = FALSE;
    // Windows 11 24H2 clients are more reliable with one bitmap rectangle.
    server->SupportMultiRectBitmapUpdates = FALSE;
    server->h264BitRate = 8'000'000;
    server->h264FrameRate = 30;
    server->h264QP = 0;

    if (!set_security(server->settings, options.security)
        || !freerdp_settings_set_uint32(server->settings, FreeRDP_ColorDepth, 32)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_NSCodec, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_RemoteFxCodec, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_RemoteFxImageCodec, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_SupportGraphicsPipeline, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxProgressive, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxProgressiveV2, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxPlanar, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_MouseUseRelativeMove, FALSE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_HasRelativeMouseEvent, FALSE)) {
        return false;
    }

#if defined(WITH_GFX_H264)
    if (!freerdp_settings_set_bool(server->settings, FreeRDP_GfxH264, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxAVC444, TRUE)
        || !freerdp_settings_set_bool(server->settings, FreeRDP_GfxAVC444v2, TRUE)) {
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

    std::error_code directory_error;
    std::filesystem::create_directories(options.config_dir, directory_error);
    if (directory_error) {
        std::cerr << "Unable to create config directory " << options.config_dir << ": "
                  << directory_error.message() << "\n";
        clear_secret(options.password);
        return 1;
    }

    if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) {
        std::cerr << "Unable to initialize FreeRDP TLS/NTLM support\n";
        clear_secret(options.password);
        return 1;
    }

    std::string generated_sam_file;
    if (options.security == SecurityMode::nla && options.sam_file.empty()) {
        const auto generated_path = options.config_dir / "macrdp.sam";
        if (!write_sam_file(generated_path, options)) {
            std::cerr << "Unable to create the generated SAM file " << generated_path << "\n";
            clear_secret(options.password);
            return 1;
        }
        generated_sam_file = generated_path.string();
    }
    const std::string sam_file = options.sam_file.empty() ? generated_sam_file : options.sam_file;

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

    if (shadow_server_start(server) < 0) {
        std::cerr << "Unable to start FreeRDP shadow server\n";
        shadow_server_uninit(server);
        shadow_server_free(server);
        macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
        clear_secret(options.password);
        return 1;
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    std::cout << "macrdp-server listening on port " << options.port
              << " with "
              << (options.security == SecurityMode::nla
                      ? "NLA"
                      : options.security == SecurityMode::tls ? "TLS" : "RDP")
              << " security\n";

    while (!g_stop_requested) {
        if (server->thread != nullptr
            && WaitForSingleObject(server->thread, 0) == WAIT_OBJECT_0) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{250});
    }

    shadow_server_stop(server);
    shadow_server_uninit(server);
    shadow_server_free(server);
    macrdp_shadow_set_credentials(nullptr, nullptr, nullptr);
    clear_secret(options.password);
    return 0;
}
