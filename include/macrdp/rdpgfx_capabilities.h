#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool macrdp_rdpgfx_caps_support_avc420(uint32_t version, uint32_t flags);
bool macrdp_rdpgfx_caps_support_avc444(uint32_t version, uint32_t flags);

#ifdef __cplusplus
}
#endif
