#include <freerdp/server/shadow.h>

#include "macrdp/clipboard_transfer.hpp"
#include "macrdp/shadow_config.h"
#include "mac_shadow_subsystem.hpp"

#include <cstddef>
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

bool test_reconnect_lifecycle_cycles() {
    constexpr std::size_t reconnect_cycles = 100;

    macrdp_shadow_set_input_enabled(true);
    macrdp_shadow_set_capture_options(0, 0, 0, 30, false);
    RDP_SHADOW_ENTRY_POINTS entry_points{};
    if (!expect(macrdp_shadow_subsystem_entry(&entry_points) > 0,
                "unable to load the macOS shadow subsystem")) {
        return false;
    }

    rdpShadowSubsystem* subsystem = entry_points.New();
    if (!expect(subsystem != nullptr, "unable to create the shadow subsystem")) {
        return false;
    }

    rdpShadowServer server{};
    subsystem->server = &server;
    bool ok = true;
    ok = expect(macrdp_shadow_audio_is_enabled() == 0,
                "disabled audio policy was not observable") && ok;
    rdpShadowClient client{};
    RdpsndServerContext rdpsnd{};
    ok = expect(macrdp_shadow_capture_client_count(subsystem) == 0,
                "new subsystem unexpectedly had capture clients") && ok;
    for (std::size_t cycle = 0; cycle < reconnect_cycles; ++cycle) {
        client = rdpShadowClient{};
        rdpsnd = RdpsndServerContext{};
        client.activated = TRUE;
        client.rdpsnd = &rdpsnd;
        macrdp::ClipboardTransferState clipboard;

        ok = expect(!macrdp_shadow_client_session_is_active(&client),
                    "new client session started active") && ok;
        const bool connected = subsystem->ClientConnect(subsystem, &client);
        ok = expect(connected, "client input registration failed") && ok;
        ok = expect(macrdp_shadow_capture_client_count(subsystem) == 1,
                    "connected client did not activate capture") && ok;
        ok = expect(macrdp_shadow_client_session_start(&client),
                    "client session did not enter active state") && ok;
        ok = expect(macrdp_shadow_client_session_is_active(&client),
                    "active client session was not observable") && ok;

        client.macrdpRdpsndActivated = TRUE;
        ok = expect(shadow_client_rdpsnd_is_active(&client),
                    "active session rejected negotiated RDPSND") && ok;
        ok = expect(clipboard.begin_remote_request(
                        macrdp::clipboard_format_unicode_text),
                    "active session rejected a clipboard request") && ok;

        const auto x = static_cast<UINT16>((cycle % 500U) + 1U);
        const auto y = static_cast<UINT16>((cycle % 500U) + 2U);
        ok = expect(subsystem->MouseEvent(
                        subsystem,
                        &client,
                        PTR_FLAGS_MOVE,
                        x,
                        y),
                    "active session rejected pointer input") && ok;
        ok = expect(subsystem->pointerX == x && subsystem->pointerY == y,
                    "active pointer input did not update subsystem state") && ok;
        ok = expect(subsystem->KeyboardEvent(subsystem, &client, 0, 0x1E),
                    "active session rejected keyboard input") && ok;

        const bool notify_disconnect =
            macrdp_shadow_client_session_begin_stop(&client);
        ok = expect(notify_disconnect,
                    "active session did not begin stopping") && ok;
        ok = expect(!macrdp_shadow_client_session_begin_stop(&client),
                    "session teardown was not idempotent") && ok;
        ok = expect(!macrdp_shadow_client_session_is_active(&client),
                    "stopping client session remained active") && ok;
        ok = expect(!shadow_client_rdpsnd_is_active(&client),
                    "stopping session retained RDPSND publication") && ok;

        if (notify_disconnect && connected) {
            subsystem->ClientDisconnect(subsystem, &client);
        }
        ok = expect(macrdp_shadow_capture_client_count(subsystem) == 0,
                    "disconnected client kept capture active") && ok;
        clipboard.stop();

        const auto stopped_x = subsystem->pointerX;
        const auto stopped_y = subsystem->pointerY;
        ok = expect(subsystem->MouseEvent(
                        subsystem,
                        &client,
                        PTR_FLAGS_MOVE,
                        static_cast<UINT16>(x + 100U),
                        static_cast<UINT16>(y + 100U)),
                    "late pointer callback was not acknowledged") && ok;
        ok = expect(subsystem->pointerX == stopped_x
                        && subsystem->pointerY == stopped_y,
                    "late pointer callback mutated stopped session state") && ok;
        ok = expect(subsystem->KeyboardEvent(subsystem, &client, 0, 0x30),
                    "late keyboard callback was not acknowledged") && ok;
        ok = expect(subsystem->UnicodeKeyboardEvent(subsystem, &client, 0, 'a'),
                    "late Unicode callback was not acknowledged") && ok;
        ok = expect(subsystem->SynchronizeEvent(subsystem, &client, 0),
                    "late synchronize callback was not acknowledged") && ok;
        ok = expect(!clipboard.begin_remote_request(
                        macrdp::clipboard_format_text),
                    "stopped clipboard accepted a new request") && ok;
        ok = expect(!clipboard.finish_remote_request().has_value(),
                    "stopped clipboard accepted a late response") && ok;

        macrdp_shadow_client_session_finish_stop(&client);
        ok = expect(!macrdp_shadow_client_session_is_active(&client),
                    "finished session returned to active state") && ok;
        ok = expect(!macrdp_shadow_client_session_start(&client),
                    "stopped client object was reused as a new session") && ok;
    }

    entry_points.Free(subsystem);
    return ok;
}

bool test_suppressed_clients_control_video_demand() {
    macrdp_shadow_set_input_enabled(false);
    RDP_SHADOW_ENTRY_POINTS entry_points{};
    if (!expect(macrdp_shadow_subsystem_entry(&entry_points) > 0,
                "unable to load the subsystem for suppress-output lifecycle")) {
        return false;
    }

    rdpShadowSubsystem* subsystem = entry_points.New();
    if (!expect(subsystem != nullptr, "unable to create suppress-output subsystem")) {
        return false;
    }
    rdpShadowServer server{};
    subsystem->server = &server;
    rdpShadowClient first{};
    rdpShadowClient second{};
    bool ok = expect(subsystem->ClientConnect(subsystem, &first),
                     "first suppress-output client failed to connect")
        && expect(subsystem->ClientConnect(subsystem, &second),
                  "second suppress-output client failed to connect")
        && expect(macrdp_shadow_capture_client_count(subsystem) == 2,
                  "connected suppress-output clients were not registered")
        && expect(macrdp_shadow_capture_output_client_count(subsystem) == 2,
                  "new clients did not request video output");

    ok = expect(subsystem->ClientSuppressOutput(subsystem, &first, TRUE),
                "first client suppression was rejected") && ok;
    ok = expect(macrdp_shadow_capture_output_client_count(subsystem) == 1,
                "one suppressed client paused shared video") && ok;
    ok = expect(subsystem->ClientSuppressOutput(subsystem, &second, TRUE),
                "second client suppression was rejected") && ok;
    ok = expect(macrdp_shadow_capture_output_client_count(subsystem) == 0,
                "all suppressed clients kept video demand active") && ok;
    ok = expect(subsystem->ClientSuppressOutput(subsystem, &first, FALSE),
                "first client resume was rejected") && ok;
    ok = expect(macrdp_shadow_capture_output_client_count(subsystem) == 1,
                "resumed client did not reactivate video demand") && ok;

    subsystem->ClientDisconnect(subsystem, &first);
    ok = expect(macrdp_shadow_capture_client_count(subsystem) == 1
                    && macrdp_shadow_capture_output_client_count(subsystem) == 0,
                "disconnecting the only output client kept video active") && ok;
    ok = expect(subsystem->ClientSuppressOutput(subsystem, &second, FALSE),
                "remaining client resume was rejected") && ok;
    ok = expect(macrdp_shadow_capture_output_client_count(subsystem) == 1,
                "remaining client did not reactivate video") && ok;
    subsystem->ClientDisconnect(subsystem, &second);
    ok = expect(macrdp_shadow_capture_client_count(subsystem) == 0
                    && macrdp_shadow_capture_output_client_count(subsystem) == 0,
                "disconnected clients retained capture demand") && ok;

    entry_points.Free(subsystem);
    return ok;
}

} // namespace

int main() {
    return test_suppressed_clients_control_video_demand()
            && test_reconnect_lifecycle_cycles()
        ? 0
        : 1;
}
