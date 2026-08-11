#include <freerdp/server/shadow.h>

#include "macrdp/cliprdr_adapter.h"
#include "mac_shadow_subsystem.hpp"

#include <iostream>

namespace {

bool expect(bool value, const char* message) {
    if (!value) {
        std::cerr << message << '\n';
        return false;
    }
    return true;
}

bool test_view_only_input_gate() {
    macrdp_shadow_set_input_enabled(false);

    RDP_SHADOW_ENTRY_POINTS entry_points{};
    if (!expect(macrdp_shadow_subsystem_entry(&entry_points) > 0,
                "unable to load the macOS shadow subsystem")) {
        return false;
    }

    rdpShadowSubsystem* subsystem = entry_points.New();
    if (!expect(subsystem != nullptr, "unable to create a view-only subsystem")) {
        return false;
    }

    rdpShadowServer server{};
    rdpShadowClient client{};
    subsystem->server = &server;
    subsystem->pointerX = 11;
    subsystem->pointerY = 12;

    bool ok = expect(subsystem->ClientConnect(subsystem, &client),
                     "view-only client connection was rejected")
        && expect(subsystem->SynchronizeEvent(subsystem, &client, 0),
                  "view-only synchronize event was rejected")
        && expect(subsystem->KeyboardEvent(subsystem, &client, 0, 0x1E),
                  "view-only keyboard event was rejected")
        && expect(subsystem->UnicodeKeyboardEvent(subsystem, &client, 0, 'a'),
                  "view-only Unicode event was rejected")
        && expect(subsystem->MouseEvent(subsystem, &client, PTR_FLAGS_MOVE, 100, 200),
                  "view-only mouse event was rejected")
        && expect(subsystem->ExtendedMouseEvent(
                      subsystem, &client, PTR_XFLAGS_BUTTON1, 300, 400),
                  "view-only extended mouse event was rejected")
        && expect(subsystem->RelMouseEvent(subsystem, &client, 0, 5, 6),
                  "view-only relative mouse event was rejected")
        && expect(subsystem->pointerX == 11 && subsystem->pointerY == 12,
                  "view-only input changed the shadow pointer state");

    subsystem->ClientDisconnect(subsystem, &client);
    entry_points.Free(subsystem);
    macrdp_shadow_set_input_enabled(true);
    return ok;
}

bool test_interactive_input_path_remains_active() {
    macrdp_shadow_set_input_enabled(true);

    RDP_SHADOW_ENTRY_POINTS entry_points{};
    if (!expect(macrdp_shadow_subsystem_entry(&entry_points) > 0,
                "unable to load the interactive shadow subsystem")) {
        return false;
    }

    rdpShadowSubsystem* subsystem = entry_points.New();
    if (!expect(subsystem != nullptr, "unable to create an interactive subsystem")) {
        return false;
    }

    rdpShadowServer server{};
    rdpShadowClient client{};
    subsystem->server = &server;
    const bool ok = expect(subsystem->ClientConnect(subsystem, &client),
                           "interactive client connection was rejected")
        && expect(subsystem->MouseEvent(subsystem, &client, PTR_FLAGS_MOVE, 100, 200),
                  "interactive mouse event was rejected")
        && expect(subsystem->pointerX == 100 && subsystem->pointerY == 200,
                  "interactive input did not reach the shadow pointer state");

    subsystem->ClientDisconnect(subsystem, &client);
    entry_points.Free(subsystem);
    return ok;
}

bool test_clipboard_gate() {
    macrdp_shadow_cliprdr_set_enabled(FALSE);
    const bool disabled_short_circuited = macrdp_shadow_cliprdr_init(nullptr) == TRUE;
    macrdp_shadow_cliprdr_set_enabled(TRUE);
    const bool enabled_validated_client = macrdp_shadow_cliprdr_init(nullptr) == FALSE;
    return expect(disabled_short_circuited,
                  "disabled clipboard attempted to initialize a channel")
        && expect(enabled_validated_client,
                  "enabled clipboard skipped channel input validation");
}

bool test_rdpsnd_negotiation_gate() {
    rdpShadowClient client{};
    RdpsndServerContext rdpsnd{};
    client.activated = TRUE;
    client.rdpsnd = &rdpsnd;

    bool ok = expect(!shadow_client_rdpsnd_is_active(&client),
                     "unnegotiated RDPSND client was treated as active");
    ok = expect(macrdp_shadow_client_session_start(&client),
                "RDPSND test session did not start") && ok;
    client.macrdpRdpsndActivated = TRUE;
    ok = expect(shadow_client_rdpsnd_is_active(&client),
                "negotiated RDPSND client was not treated as active") && ok;
    ok = expect(macrdp_shadow_client_session_begin_stop(&client),
                "RDPSND test session did not begin stopping") && ok;
    ok = expect(!shadow_client_rdpsnd_is_active(&client),
                "stopping RDPSND client retained active state") && ok;
    macrdp_shadow_client_session_finish_stop(&client);
    return ok;
}

} // namespace

int main() {
    return test_view_only_input_gate()
            && test_interactive_input_path_remains_active()
            && test_clipboard_gate()
            && test_rdpsnd_negotiation_gate()
        ? 0
        : 1;
}
