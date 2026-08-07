#include "macrdp/config_permissions.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

bool set_mode(const std::filesystem::path& path, mode_t mode) {
    return ::chmod(path.c_str(), mode) == 0;
}

bool has_mode(const std::filesystem::path& path, mode_t expected) {
    struct stat status {};
    return ::lstat(path.c_str(), &status) == 0
        && (status.st_mode & static_cast<mode_t>(0777)) == expected;
}

bool write_file(const std::filesystem::path& path) {
    std::ofstream output(path);
    output << "test\n";
    return output.good();
}

} // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path()
        / ("macrdp-config-permissions-" + std::to_string(::getpid()));
    std::error_code error;
    if (std::filesystem::exists(root, error) || error
        || !std::filesystem::create_directory(root, error) || error) {
        std::cerr << "unable to create unique test directory\n";
        return 1;
    }

    bool success = macrdp::restrict_config_paths(root) && has_mode(root, 0700);

    const auto shadow = root / "shadow";
    const auto unknown = root / "unrelated.txt";
    const auto unknown_shadow = shadow / "unrelated.txt";
    const auto sam = root / "macrdp.sam";
    const auto certificate = shadow / "shadow.crt";
    const auto private_key = shadow / "shadow.key";

    success = success
        && std::filesystem::create_directory(shadow, error) && !error
        && write_file(unknown)
        && write_file(unknown_shadow)
        && write_file(sam)
        && write_file(certificate)
        && write_file(private_key)
        && set_mode(unknown, 0644)
        && set_mode(unknown_shadow, 0644)
        && set_mode(sam, 0644)
        && set_mode(certificate, 0644)
        && set_mode(private_key, 0644)
        && macrdp::restrict_config_paths(root)
        && has_mode(root, 0700)
        && has_mode(shadow, 0700)
        && has_mode(sam, 0600)
        && has_mode(certificate, 0600)
        && has_mode(private_key, 0600)
        && has_mode(unknown, 0644)
        && has_mode(unknown_shadow, 0644);

    if (success) {
        std::filesystem::remove(certificate, error);
        success = !error;
        error.clear();
        if (success) {
            std::filesystem::create_symlink(unknown, certificate, error);
            success = !error;
        }
        success = success && !macrdp::restrict_config_paths(root);
    }

    std::filesystem::remove_all(root, error);
    if (!success) {
        std::cerr << "config permission checks failed\n";
        return 1;
    }
    return 0;
}
