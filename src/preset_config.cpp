#include "macrdp/preset_config.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/stat.h>
#include <unordered_set>
#include <unistd.h>

namespace {

constexpr std::size_t kMaximumPresetSize = 64 * 1024;

std::string_view trim(std::string_view value) {
    const auto first = value.find_first_not_of(" \t\r");
    if (first == std::string_view::npos) {
        return {};
    }
    const auto last = value.find_last_not_of(" \t\r");
    return value.substr(first, last - first + 1);
}

bool secure_directory(const std::filesystem::path& path, bool allow_missing,
                      std::string& error) {
    struct stat status {};
    if (::lstat(path.c_str(), &status) != 0) {
        if (allow_missing && errno == ENOENT) {
            return true;
        }
        error = "Unable to inspect preset directory " + path.string() + ": "
            + std::strerror(errno);
        return false;
    }
    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
        error = "Preset directory must be a real directory: " + path.string();
        return false;
    }
    if (status.st_uid != ::geteuid() || (status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        error = "Preset directory must be owned by the current user and not writable by others: "
            + path.string();
        return false;
    }
    return true;
}

bool read_secure_file(const std::filesystem::path& path, std::string& content,
                      std::string& error) {
    content.clear();
    if (!secure_directory(path.parent_path(), false, error)) {
        return false;
    }

    const int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        error = "Unable to open preset " + path.string() + ": " + std::strerror(errno);
        return false;
    }

    struct stat status {};
    if (::fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode)
        || status.st_uid != ::geteuid() || (status.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        error = "Preset must be a regular file owned by the current user and not writable by "
                "others: " + path.string();
        (void)::close(descriptor);
        return false;
    }
    if (status.st_size < 0
        || static_cast<std::uintmax_t>(status.st_size) > kMaximumPresetSize) {
        error = "Preset exceeds the 64 KiB size limit: " + path.string();
        (void)::close(descriptor);
        return false;
    }

    std::array<char, 4096> buffer{};
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
            error = "Unable to read preset " + path.string() + ": " + std::strerror(errno);
            success = false;
            break;
        }
        if (content.size() + static_cast<std::size_t>(count) > kMaximumPresetSize) {
            error = "Preset exceeds the 64 KiB size limit: " + path.string();
            success = false;
            break;
        }
        content.append(buffer.data(), static_cast<std::size_t>(count));
    }
    if (::close(descriptor) != 0 && success) {
        error = "Unable to close preset " + path.string() + ": " + std::strerror(errno);
        success = false;
    }
    return success;
}

} // namespace

namespace macrdp {

bool valid_preset_name(std::string_view name) {
    if (name.empty() || name.size() > 64 || name == "." || name == "..") {
        return false;
    }
    return std::all_of(name.begin(), name.end(), [](unsigned char character) {
        return (character >= 'a' && character <= 'z')
            || (character >= 'A' && character <= 'Z')
            || (character >= '0' && character <= '9')
            || character == '-' || character == '_' || character == '.';
    });
}

bool load_preset_file(const std::filesystem::path& path,
                      std::vector<PresetSetting>& settings, std::string& error) {
    settings.clear();
    error.clear();

    std::string content;
    if (!read_secure_file(path, content, error)) {
        return false;
    }
    if (content.find('\0') != std::string::npos) {
        error = "Preset contains a NUL byte: " + path.string();
        return false;
    }

    std::unordered_set<std::string> keys;
    std::size_t line_number = 0;
    std::size_t offset = 0;
    while (offset <= content.size()) {
        const auto end = content.find('\n', offset);
        const auto length = end == std::string::npos ? content.size() - offset : end - offset;
        const std::string_view line(content.data() + offset, length);
        ++line_number;
        const auto stripped = trim(line);
        if (!stripped.empty() && stripped.front() != '#') {
            const auto equals = stripped.find('=');
            if (equals == std::string_view::npos) {
                error = path.string() + ":" + std::to_string(line_number)
                    + ": expected key = value";
                return false;
            }
            const auto key = trim(stripped.substr(0, equals));
            const auto value = trim(stripped.substr(equals + 1));
            if (key.empty() || value.empty()) {
                error = path.string() + ":" + std::to_string(line_number)
                    + ": key and value must not be empty";
                return false;
            }
            if (!std::all_of(key.begin(), key.end(), [](unsigned char character) {
                    return (character >= 'a' && character <= 'z') || character == '-';
                })) {
                error = path.string() + ":" + std::to_string(line_number)
                    + ": keys must use lowercase letters and hyphens";
                return false;
            }
            std::string key_string(key);
            if (!keys.emplace(key_string).second) {
                error = path.string() + ":" + std::to_string(line_number)
                    + ": duplicate key '" + key_string + "'";
                return false;
            }
            settings.push_back({std::move(key_string), std::string(value), line_number});
        }
        if (end == std::string::npos) {
            break;
        }
        offset = end + 1;
    }
    return true;
}

bool list_preset_files(const std::filesystem::path& directory,
                       std::vector<std::string>& names, std::string& error) {
    names.clear();
    error.clear();
    if (!std::filesystem::exists(directory)) {
        return true;
    }
    if (!secure_directory(directory, false, error)) {
        return false;
    }

    std::error_code iteration_error;
    for (std::filesystem::directory_iterator iterator(directory, iteration_error), end;
         !iteration_error && iterator != end; iterator.increment(iteration_error)) {
        const auto status = iterator->symlink_status(iteration_error);
        if (iteration_error) {
            break;
        }
        if (!std::filesystem::is_regular_file(status) || std::filesystem::is_symlink(status)
            || iterator->path().extension() != ".conf") {
            continue;
        }
        const std::string name = iterator->path().stem().string();
        if (valid_preset_name(name)) {
            names.push_back(name);
        }
    }
    if (iteration_error) {
        error = "Unable to list preset directory " + directory.string() + ": "
            + iteration_error.message();
        names.clear();
        return false;
    }
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    return true;
}

} // namespace macrdp
