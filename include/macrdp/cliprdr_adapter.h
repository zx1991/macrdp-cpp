#pragma once

#include <freerdp/server/shadow.h>

#ifdef __cplusplus
extern "C"
{
#endif

BOOL macrdp_shadow_cliprdr_init(rdpShadowClient* client);
void macrdp_shadow_cliprdr_uninit(rdpShadowClient* client);
void macrdp_shadow_cliprdr_set_enabled(BOOL enabled);

#ifdef __cplusplus
}
#endif
