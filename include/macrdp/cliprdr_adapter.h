#pragma once

#include <freerdp/server/shadow.h>

#ifdef __cplusplus
extern "C"
{
#endif

BOOL macrdp_shadow_cliprdr_init(rdpShadowClient* client);
void macrdp_shadow_cliprdr_uninit(rdpShadowClient* client);

#ifdef __cplusplus
}
#endif
