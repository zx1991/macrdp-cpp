# Supported-Hardware Validation Matrix

This matrix is the P0 acceptance record for behavior that deterministic tests
and the loopback client cannot observe directly. Complete one copy per macOS
host, Windows client, display, and keyboard combination that the project claims
to support. Raw diagnostic bundles are local evidence and should not be
committed.

## Result vocabulary

| Result | Meaning |
| --- | --- |
| `PASS` | The expected behavior was observed and evidence was retained. |
| `FAIL` | The behavior was incorrect or exceeded its bound; link an issue. |
| `BLOCKED` | An external prerequisite prevented the test; record the reason. |
| `NOT RUN` | The case has not been attempted. |
| `N/A` | The case does not apply to this declared hardware configuration. |

Do not use `PASS` for an unobserved behavior. Automated protocol delivery does
not prove visible wheel direction, audible output, Retina quality, or recovery
after a physical display and power-state transition.

## Safety and prerequisites

- Use a trusted test network and a dedicated RDP credential. Keep NLA enabled.
- Build and test one exact `macrdp-server` binary. Do not relink it between
  preflight, loopback profiles, and the Windows run.
- Grant only the TCC capabilities required by the case. `--view-only` should
  not require Accessibility.
- Close sensitive applications and use a disposable text document for keyboard
  and clipboard checks. The tests change the general pasteboard and inject
  keyboard and pointer events.
- Record the state of every modifier before and after interactive input. Stop
  immediately if Command, Control, Option, Shift, Caps Lock, or Fn remains
  active.
- Review every diagnostic bundle before sharing it. The built-in probes do not
  query serial numbers, network addresses, credentials, or keychain contents.
  Supplied logs are copied verbatim and can contain credentials or other
  sensitive data; signing details can contain local paths or identity names.

## Run metadata

| Field | Value |
| --- | --- |
| Run id and UTC date | |
| Git commit | |
| Server SHA-256 | |
| Signing designated requirement | |
| Mac model / CPU / memory | |
| macOS product and build version | |
| Displays, resolutions, scaling, rotation | |
| Keyboard model and connection type | |
| Windows hardware and Windows build | |
| `mstsc.exe` version | |
| Client display resolution and scaling | |
| Network path | |
| Tester | |

Create a baseline bundle before testing. When Codex or another automation
process runs through SSH, use the Aqua option so ScreenCaptureKit checks the
same graphical launch context as the server:

```bash
tools/collect_hardware_diagnostics.sh \
  --server build/macrdp-server \
  --aqua-preflight
```

The bundle is created in an owner-only temporary directory. `summary.txt`
records the source revision, binary hash, signing verification, preflight mode,
preflight duration, and probe status. `system-probe.txt` records the graphical
session, non-identifying display geometry and active/asleep/online state, and
modifier-key state. Verify the bundle before relying on it:

```bash
cd /path/printed/by/the/collector
shasum -a 256 -c manifest.sha256
```

Use `--server-log PATH` more than once to attach relevant server and client
logs. Use `--skip-preflight` when collecting after a deliberate permission
denial or when another server instance already owns the capture path.

## Automated baseline

Run these against the same binary before manual Windows testing. Preserve the
terminal summary or add the retained log with `--server-log`.

| Id | Case | Expected | Result | Evidence |
| --- | --- | --- | --- | --- |
| AUTO-01 | `ctest --test-dir build --output-on-failure` | All deterministic tests pass. | `NOT RUN` | |
| AUTO-02 | Loopback `direct` | GFX, classic updates, input, clipboard, audio, reconnect, resize, and slow-client checks pass. | `NOT RUN` | |
| AUTO-03 | Loopback `wan` | Shaped-link primary and reconnect cases pass. | `NOT RUN` | |
| AUTO-04 | Loopback `wifi --reconnect` | Variable low-bandwidth link and explicit reconnect cases pass. | `NOT RUN` | |
| AUTO-05 | Loopback `outage` | Periodic forwarding stalls and reconnect cases pass. | `NOT RUN` | |
| AUTO-06 | Loopback `bad --reconnect` | Extreme backpressure completes within the configured budgets. | `NOT RUN` | |
| AUTO-07 | Harness post-run system probe | Every automated profile reports zero modifier flags and no held modifier key. | `NOT RUN` | |

Run network profiles in the documented order: `direct`, `wan`, `wifi`,
`outage`, then `bad`. See [Testing](testing.md) for proxy requirements and
profile parameters.

## Permission and lifecycle matrix

Change TCC permissions only through macOS System Settings. Record elapsed time
and the exact error for every deliberate failure.

| Id | Case | Procedure | Expected | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| LIFE-01 | Interactive preflight | Run the collector with `--aqua-preflight`. | Screen capture and Accessibility are available; no listener or config files are created. | `NOT RUN` | |
| LIFE-02 | View-only policy | Disable Accessibility for the exact server and run with `--view-only --aqua-preflight`. | Screen capture passes and Accessibility is reported `not-required`. | `NOT RUN` | |
| LIFE-03 | Screen Recording denied | Disable Screen Recording and run exact-server preflight. | Preflight fails within its bounded startup/cleanup window and no listener opens. | `NOT RUN` | |
| LIFE-04 | Accessibility denied | Enable Screen Recording, disable Accessibility, and run interactive preflight. | Capture passes, input preflight fails, and no listener opens. | `NOT RUN` | |
| LIFE-05 | Locked session | Lock for at least 60 seconds during an active connection, then unlock. | The process stays bounded, resumes frames or exits with a clear error, and accepts a clean restart. | `NOT RUN` | |
| LIFE-06 | Display sleep/wake | Sleep the display during capture, then wake it. | No deadlock; capture recovers or exits within documented bounds and restarts cleanly. | `NOT RUN` | |
| LIFE-07 | System sleep/wake | Sleep and wake the Mac with a connected client. | No deadlock or orphan server; reconnect and input ownership recover cleanly. | `NOT RUN` | |
| LIFE-08 | Display reconfiguration | Change resolution/scaling and attach or detach a supported display. | Frames remain valid or the server fails cleanly; requested resize still works afterward. | `NOT RUN` | |
| LIFE-09 | Repeated lifecycle | Start, stop, and restart the same signed binary at least 20 times. | Every stop is bounded; no process, listener, or held input state remains. | `NOT RUN` | |

Automate `LIFE-09` against the unchanged server binary. Use `--aqua` when the
controller is an SSH session; the harness retains no credential or generated
server configuration:

```bash
tools/run_hardware_lifecycle.sh \
  --server build/macrdp-server \
  --aqua
```

Record the printed evidence path, cycle count, maximum observed startup and
shutdown durations, final modifier state, server hash, and harness result.

After each lifecycle case, create another bundle and compare its binary hash,
display geometry, preflight result, and modifier state with the baseline.

## Windows `mstsc` matrix

Use the current supported Windows Remote Desktop client without third-party RDP
gateways. Keep a safe text editor visible on the Mac for text and modifier
checks.

| Id | Area | Procedure | Expected | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| WIN-01 | NLA success | Connect with the configured user and password. | Authentication succeeds and one desktop session opens. | `NOT RUN` | |
| WIN-02 | NLA failure | Attempt a wrong password, then reconnect correctly. | Wrong credentials fail without affecting the later valid session. | `NOT RUN` | |
| WIN-03 | Certificate path | Inspect the first-connect certificate warning or trusted certificate result. | The identity is expected for the configured test certificate; no silent downgrade occurs. | `NOT RUN` | |
| WIN-04 | Initial display | Inspect the captured main display at native and windowed sizes. | The correct display is visible, oriented correctly, and not blank or corrupted. | `NOT RUN` | |
| WIN-05 | Resize and Retina | Resize, maximize, minimize, and restore the client on each supported scaling mode. | Content remains framed and readable; updates resume after every change. | `NOT RUN` | |
| WIN-06 | Text keyboard | Type ASCII, shifted text, digits, punctuation, and Unicode into the safe document. | Characters arrive once and in order with the expected case. | `NOT RUN` | |
| WIN-07 | Modifier cleanup | Exercise left/right Shift, Control, Alt, and Windows keys separately, then disconnect. | Each key releases; the post-run probe reports no held modifier. | `NOT RUN` | |
| WIN-08 | Pause and lock keys | Exercise Pause/Break when available and toggle Num Lock and Caps Lock twice. | Pause does not inject Control/Keypad Clear; Num Lock does not leave Fn active; Caps Lock returns to its initial state. | `NOT RUN` | |
| WIN-09 | Pointer buttons and drag | Test left, right, middle, drag, and available extended buttons. | Button identity, press/release, and drag behavior are correct with no held button after disconnect. | `NOT RUN` | |
| WIN-10 | Vertical wheel | Scroll a document in both directions. | Direction and approximate distance match the Windows gesture. | `NOT RUN` | |
| WIN-11 | Horizontal wheel | Scroll a horizontally overflowed document in both directions. | Direction and approximate distance match the Windows gesture. | `NOT RUN` | |
| WIN-12 | Clipboard Mac to Windows | Copy multiline Unicode text on the Mac and paste in Windows. | Text and line breaks match exactly. | `NOT RUN` | |
| WIN-13 | Clipboard Windows to Mac | Copy different multiline Unicode text in Windows and paste on the Mac. | Text and line breaks match exactly without reflection loops. | `NOT RUN` | |
| WIN-14 | Audio | Play a known stereo test source and exercise Windows mute/volume. | Audio is audible, correctly channeled, and free of persistent stalls after reconnect. | `NOT RUN` | |
| WIN-15 | Orderly reconnect | Close and reconnect repeatedly, changing the client window size between sessions. | Every session receives frames, clipboard, audio, and clean input state. | `NOT RUN` | |
| WIN-16 | Network interruption | Interrupt the client network, restore it, and reconnect. | The old client is cleaned up and a new session succeeds without restarting the Mac. | `NOT RUN` | |
| WIN-17 | Lock/sleep recovery | Repeat display, input, clipboard, and audio checks after LIFE-05 through LIFE-07. | The recovered or restarted server behaves like the baseline session. | `NOT RUN` | |

## P0 acceptance

P0 is complete for a declared hardware configuration only when:

- all applicable automated, lifecycle, and Windows rows are `PASS`;
- every `FAIL` has a reproducible diagnostic bundle and a linked issue;
- permission denial, stop, and recovery paths stay within documented bounds;
- no interactive case leaves a modifier, pointer button, server process, or
  listening socket behind; and
- the exact Git revision, server hash, macOS/Windows builds, display mode, and
  keyboard model are recorded with the result.

Publish a reviewed result summary in an issue or pull request. Do not commit
raw bundles, credentials, generated SAM files, certificates, or private keys.
