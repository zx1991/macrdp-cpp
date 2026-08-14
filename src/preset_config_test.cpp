#include "macrdp/preset_config.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

bool write_file(const std::filesystem::path& path, const std::string& content, mode_t mode) {
    std::ofstream output(path);
    output << content;
    output.close();
    return output.good() && ::chmod(path.c_str(), mode) == 0;
}

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

} // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path()
        / ("macrdp-preset-config-" + std::to_string(::getpid()));
    std::error_code filesystem_error;
    bool ok = std::filesystem::create_directory(root, filesystem_error)
        && !filesystem_error && ::chmod(root.c_str(), 0700) == 0;

    const auto valid = root / "home.conf";
    ok = expect(ok && write_file(valid,
        "# Home profile\n"
        "extends = trusted-lan\n"
        "description = Home office\n"
        "fps = 10\n"
        "audio = true\n", 0600), "unable to create valid preset") && ok;

    std::vector<macrdp::PresetSetting> settings;
    std::string error;
    ok = expect(macrdp::load_preset_file(valid, settings, error), error.c_str()) && ok;
    ok = expect(settings.size() == 4 && settings[0].key == "extends"
                    && settings[2].value == "10",
                "valid preset was parsed incorrectly") && ok;

    std::vector<std::string> names;
    ok = expect(macrdp::list_preset_files(root, names, error)
                    && names == std::vector<std::string>{"home"},
                "preset discovery returned the wrong names") && ok;

    const auto duplicate = root / "duplicate.conf";
    ok = expect(write_file(duplicate, "fps = 5\nfps = 10\n", 0600),
                "unable to create duplicate preset") && ok;
    ok = expect(!macrdp::load_preset_file(duplicate, settings, error)
                    && error.find("duplicate key 'fps'") != std::string::npos,
                "duplicate key was not rejected") && ok;

    const auto writable = root / "writable.conf";
    ok = expect(write_file(writable, "fps = 5\n", 0666),
                "unable to create writable preset") && ok;
    ok = expect(!macrdp::load_preset_file(writable, settings, error)
                    && error.find("not writable by others") != std::string::npos,
                "other-writable preset was not rejected") && ok;

    const auto link = root / "link.conf";
    std::filesystem::create_symlink(valid, link, filesystem_error);
    ok = expect(!filesystem_error
                    && !macrdp::load_preset_file(link, settings, error),
                "preset symlink was not rejected") && ok;

    ok = expect(macrdp::valid_preset_name("home-office")
                    && !macrdp::valid_preset_name("../home")
                    && !macrdp::valid_preset_name("home/office"),
                "preset name validation failed") && ok;

    std::filesystem::remove_all(root, filesystem_error);
    return ok ? 0 : 1;
}
