#include "macrdp/config_permissions.hpp"

#include <filesystem>
#include <sys/stat.h>

namespace {

bool restrict_directory(const std::filesystem::path& path, bool allow_missing) {
    std::error_code error;
    const auto status = std::filesystem::symlink_status(path, error);
    if (error) {
        return false;
    }
    if (status.type() == std::filesystem::file_type::not_found) {
        return allow_missing;
    }
    if (std::filesystem::is_symlink(status) || !std::filesystem::is_directory(status)) {
        return false;
    }
    return ::chmod(path.c_str(), S_IRWXU) == 0;
}

bool restrict_file(const std::filesystem::path& path) {
    std::error_code error;
    const auto status = std::filesystem::symlink_status(path, error);
    if (error) {
        return false;
    }
    if (status.type() == std::filesystem::file_type::not_found) {
        return true;
    }
    if (std::filesystem::is_symlink(status) || !std::filesystem::is_regular_file(status)) {
        return false;
    }
    return ::chmod(path.c_str(), S_IRUSR | S_IWUSR) == 0;
}

} // namespace

namespace macrdp {

bool restrict_config_paths(const std::filesystem::path& root) {
    if (root.empty() || !restrict_directory(root, false)) {
        return false;
    }

    const auto shadow_directory = root / "shadow";
    return restrict_directory(shadow_directory, true)
        && restrict_file(root / "macrdp.sam")
        && restrict_file(shadow_directory / "shadow.crt")
        && restrict_file(shadow_directory / "shadow.key");
}

} // namespace macrdp
