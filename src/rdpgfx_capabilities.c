#include "macrdp/rdpgfx_capabilities.h"

#include <freerdp/channels/rdpgfx.h>

bool macrdp_rdpgfx_caps_support_avc444(uint32_t version, uint32_t flags)
{
	switch (version)
	{
		case RDPGFX_CAPVERSION_10:
		case RDPGFX_CAPVERSION_101:
		case RDPGFX_CAPVERSION_102:
		case RDPGFX_CAPVERSION_103:
		case RDPGFX_CAPVERSION_104:
		case RDPGFX_CAPVERSION_105:
		case RDPGFX_CAPVERSION_106:
		case RDPGFX_CAPVERSION_106_ERR:
		case RDPGFX_CAPVERSION_107:
#if defined(WITH_GFX_AZURE)
		case RDPGFX_CAPVERSION_111:
		case RDPGFX_CAPVERSION_112:
		case RDPGFX_CAPVERSION_113:
#endif
			return (flags & RDPGFX_CAPS_FLAG_AVC_DISABLED) == 0;

		default:
			return false;
	}
}

bool macrdp_rdpgfx_caps_support_avc420(uint32_t version, uint32_t flags)
{
	if (macrdp_rdpgfx_caps_support_avc444(version, flags))
		return true;
	if (version != RDPGFX_CAPVERSION_81)
		return false;
	return (flags & RDPGFX_CAPS_FLAG_AVC420_ENABLED) != 0;
}
