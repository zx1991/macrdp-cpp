#pragma once

#include <freerdp/server/shadow.h>

#ifdef __cplusplus
extern "C"
{
#endif

int macrdp_shadow_subsystem_entry(RDP_SHADOW_ENTRY_POINTS* entry_points);

void macrdp_shadow_set_credentials(
    const char* username,
    const char* domain,
    const char* password);

#ifdef __cplusplus
}
#endif
