#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace macrdp {

struct PresetSetting {
    std::string key;
    std::string value;
    std::size_t line = 0;
};

bool valid_preset_name(std::string_view name);

bool load_preset_file(
    const std::filesystem::path& path,
    std::vector<PresetSetting>& settings,
    std::string& error);

bool list_preset_files(
    const std::filesystem::path& directory,
    std::vector<std::string>& names,
    std::string& error);

} // namespace macrdp
