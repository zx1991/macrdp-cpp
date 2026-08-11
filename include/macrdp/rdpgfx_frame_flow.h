#pragma once

#include <winpr/wtypes.h>

#ifdef __cplusplus
extern "C"
{
#endif

BOOL macrdp_rdpgfx_h264_window_full(
	UINT32 last_sent_frame_id,
	UINT32 last_acknowledged_frame_id,
	UINT32 queue_depth);

#ifdef __cplusplus
}
#endif
