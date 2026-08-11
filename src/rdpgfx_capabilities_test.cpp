#include "macrdp/rdpgfx_capabilities.h"

#include <freerdp/channels/rdpgfx.h>

#include <array>
#include <cstdint>
#include <iostream>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

bool test_legacy_capabilities() {
    bool ok = expect(
        !macrdp_rdpgfx_caps_support_avc420(RDPGFX_CAPVERSION_8, 0),
        "RDPGFX 8.0 unexpectedly enabled AVC420");
    ok = expect(
        !macrdp_rdpgfx_caps_support_avc444(RDPGFX_CAPVERSION_8, 0),
        "RDPGFX 8.0 unexpectedly enabled AVC444") && ok;
    ok = expect(
        !macrdp_rdpgfx_caps_support_avc420(RDPGFX_CAPVERSION_81, 0),
        "RDPGFX 8.1 enabled AVC420 without its capability flag") && ok;
    ok = expect(
        macrdp_rdpgfx_caps_support_avc420(
            RDPGFX_CAPVERSION_81, RDPGFX_CAPS_FLAG_AVC420_ENABLED),
        "RDPGFX 8.1 rejected its AVC420 capability flag") && ok;
    ok = expect(
        !macrdp_rdpgfx_caps_support_avc444(
            RDPGFX_CAPVERSION_81, RDPGFX_CAPS_FLAG_AVC420_ENABLED),
        "RDPGFX 8.1 unexpectedly enabled AVC444") && ok;
    return ok;
}

bool test_modern_capabilities() {
    constexpr std::array<std::uint32_t, 9> modern_versions{
        RDPGFX_CAPVERSION_10,
        RDPGFX_CAPVERSION_101,
        RDPGFX_CAPVERSION_102,
        RDPGFX_CAPVERSION_103,
        RDPGFX_CAPVERSION_104,
        RDPGFX_CAPVERSION_105,
        RDPGFX_CAPVERSION_106,
        RDPGFX_CAPVERSION_106_ERR,
        RDPGFX_CAPVERSION_107,
    };

    bool ok = true;
    for (const auto version : modern_versions) {
        ok = expect(
            macrdp_rdpgfx_caps_support_avc420(version, 0),
            "modern RDPGFX capabilities did not enable AVC420") && ok;
        ok = expect(
            macrdp_rdpgfx_caps_support_avc444(version, 0),
            "modern RDPGFX capabilities did not enable AVC444") && ok;
        ok = expect(
            !macrdp_rdpgfx_caps_support_avc420(
                version, RDPGFX_CAPS_FLAG_AVC_DISABLED),
            "modern RDPGFX AVC_DISABLED flag did not disable AVC420") && ok;
        ok = expect(
            !macrdp_rdpgfx_caps_support_avc444(
                version, RDPGFX_CAPS_FLAG_AVC_DISABLED),
            "modern RDPGFX AVC_DISABLED flag did not disable AVC444") && ok;
    }
    return ok;
}

bool test_unknown_capabilities() {
    constexpr std::uint32_t unknown_version = 0xFFFFFFFFU;
    return expect(
               !macrdp_rdpgfx_caps_support_avc420(
                   unknown_version, RDPGFX_CAPS_FLAG_AVC420_ENABLED),
               "unknown RDPGFX capabilities enabled AVC420")
        && expect(
               !macrdp_rdpgfx_caps_support_avc444(unknown_version, 0),
               "unknown RDPGFX capabilities enabled AVC444");
}

} // namespace

int main() {
    return test_legacy_capabilities()
            && test_modern_capabilities()
            && test_unknown_capabilities()
        ? 0
        : 1;
}
