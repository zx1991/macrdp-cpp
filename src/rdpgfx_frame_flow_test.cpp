#include "macrdp/rdpgfx_frame_flow.h"

#include <freerdp/channels/rdpgfx.h>

#include <iostream>

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

} // namespace

int main() {
    bool ok = true;
    ok = expect(macrdp_rdpgfx_h264_window_full(0, 0, QUEUE_DEPTH_UNAVAILABLE) == FALSE,
                "an empty H.264 frame window was reported full") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(1, 0, QUEUE_DEPTH_UNAVAILABLE) == TRUE,
                "an unacknowledged H.264 frame did not close the frame window") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(17, 17, 2) == FALSE,
                "an acknowledged H.264 frame kept the frame window closed") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(
                    17, 16, SUSPEND_FRAME_ACKNOWLEDGEMENT) == FALSE,
                "suspended frame acknowledgements blocked H.264 output") && ok;
    ok = expect(macrdp_rdpgfx_h264_window_full(0, UINT32_MAX, 1) == TRUE,
                "frame identifier wrap lost an unacknowledged frame") && ok;
    return ok ? 0 : 1;
}
