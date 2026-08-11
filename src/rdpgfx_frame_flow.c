#include "macrdp/rdpgfx_frame_flow.h"

#include <freerdp/channels/rdpgfx.h>

BOOL macrdp_rdpgfx_h264_window_full(UINT32 last_sent_frame_id,
                                    UINT32 last_acknowledged_frame_id,
                                    UINT32 queue_depth)
{
	if (queue_depth == SUSPEND_FRAME_ACKNOWLEDGEMENT)
		return FALSE;

	return last_sent_frame_id != last_acknowledged_frame_id;
}
