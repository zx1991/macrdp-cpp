# Server presets

Presets give `macrdp-server` reusable, named configurations while keeping every
setting available as a command-line override. Five presets are built into the
executable, and users can add their own files without rebuilding the project.

## Quick start

List all built-in and user presets:

```bash
./build/macrdp-server --list-presets
```

Inspect the final merged configuration without reading credentials, requesting
macOS permissions, capturing a display, or opening a listening socket:

```bash
./build/macrdp-server --preset standard --print-effective-config
```

Start the balanced compatibility configuration:

```bash
./build/macrdp-server --preset standard
```

The server uses the current macOS username and asks for the RDP password without
echoing it. The RDP client must use the username displayed in that prompt.

Command-line options always override the selected preset, independent of option
order. For example:

```bash
./build/macrdp-server \
  --max-fps 10 \
  --preset standard \
  --display-id 5 \
  --audio
```

## Built-in presets

Built-in presets describe server resource, quality, and access policy. They do
not select a fixed operating bitrate or infer whether a client is on a LAN,
Wi-Fi, VPN, or WAN. `Max bitrate` and `Max FPS` below are hard user ceilings;
each connected H.264 client independently adapts below them from observed ACK
latency and output pressure.

`Max bitrate` is the ceiling for the encoder's average bitrate target, not a
token-bucket limit on every TCP interval. An IDR frame can temporarily exceed
that average. The transport remains latency-oriented and coalesces obsolete
frames instead of delaying them to enforce a rigid byte rate.

All built-in presets use TCP port 3389, NLA security, the current macOS user,
the main display, one client, AVC420 through GFX, and OpenH264. OpenH264 is the
tested compatibility path for Windows RDP clients. The direct VideoToolbox path
remains available as an explicit override but is not used by these presets.

| Preset | Bind address | Max bitrate | Max FPS | Key-frame interval | Size limit | Input | Clipboard | Audio |
| --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |
| `local` | `127.0.0.1` | 16 Mbps | 30 | 10 frames | None | On | On | Off |
| `standard` | `0.0.0.0` | 16 Mbps | 30 | 10 frames | None | On | On | Off |
| `high-quality` | `0.0.0.0` | 24 Mbps | 30 | 30 frames | None | On | On | Off |
| `resource-saving` | `0.0.0.0` | 4 Mbps | 10 | 25 frames | 1280x720 | On | On | Off |
| `view-only` | `0.0.0.0` | 16 Mbps | 30 | 10 frames | None | Off | Off | Off |

- `local` is suitable for an SSH tunnel or a client on the same Mac.
- `standard` is the balanced default.
- `high-quality` permits higher quality ceilings when server resources allow.
- `resource-saving` limits resolution and both media ceilings.
- `view-only` shares the screen without accepting input or clipboard data.

The old `trusted-lan`, `smooth-lan`, and `low-bandwidth` names remain accepted
as compatibility aliases for `standard`, `high-quality`, and
`resource-saving`, respectively. New configurations should use the policy
names because the server cannot know link quality before observing a client.

Every preset bound to `0.0.0.0` listens on all IPv4 interfaces. Use those
presets only behind a firewall or on a trusted LAN/VPN. NLA authenticates the
client, but it does not turn an untrusted network into a trusted one.

## User presets

User preset files live below:

```text
~/Library/Application Support/macrdp-cpp/presets/<name>.conf
```

The name may contain letters, numbers, `.`, `_`, and `-`, and may be at most 64
characters. A user preset cannot replace a built-in preset with the same name.

Create the directory privately before adding a preset:

```bash
preset_dir="$HOME/Library/Application Support/macrdp-cpp/presets"
mkdir -p "$preset_dir"
chmod 700 "$preset_dir"
```

Example `home-office.conf`:

```ini
# Start with the standard policy, then change only local preferences.
extends = standard
description = Home office display
display-id = 5
max-fps = 10
audio = true
```

Protect the file and use it by name:

```bash
chmod 600 "$preset_dir/home-office.conf"
./build/macrdp-server --preset home-office
```

Blank lines and lines whose first non-space character is `#` are ignored. Each
other line is `key = value`. Keys must be lowercase and may contain hyphens.
Duplicate, unknown, malformed, or empty settings are rejected. Files are
limited to 64 KiB.

The presets directory must be a real directory owned by the current user and
must not be group- or other-writable. Each loaded preset must be a regular file
owned by the current user and must not be group- or other-writable. Symlinks are
rejected for both the directory and files.

Use `--config-dir <path>` to select a different configuration root. User
presets are then loaded from `<path>/presets`. The option may appear before or
after `--preset`.

## Supported keys

| Key | Accepted value | Meaning |
| --- | --- | --- |
| `extends` | Preset name | Inherit a built-in or user preset |
| `description` | Non-empty text | Description shown by effective configuration output |
| `port` | `1` to `65535` | TCP listening port |
| `bind-address` | One address | Listening address; commas are rejected |
| `max-clients` | `1` to `64` | Concurrent client limit |
| `security` | `nla`, `tls`, `rdp` | RDP security mode |
| `allow-insecure-security` | `true`, `false` | Required opt-in for non-NLA compatibility modes |
| `user` | Non-empty text | RDP login username |
| `domain` | Non-empty text | Optional login domain |
| `password-file` | Absolute path | Owner-only file containing one password line |
| `sam-file` | Absolute path | Existing FreeRDP NTLM SAM file |
| `display-id` | `main` or active ID | Display to capture |
| `max-bitrate` | Positive bps, `K`, or `M` value | Maximum adaptive bitrate per H.264 client |
| `bitrate` | Same as `max-bitrate` | Compatibility key for `max-bitrate` |
| `max-fps` | `1` to `60` | Maximum capture rate and per-client send rate |
| `fps` | Same as `max-fps` | Compatibility key for `max-fps` |
| `h264-encoder` | `auto`, `openh264`, `videotoolbox`, `ffmpeg` | H.264 encoder path |
| `h264-keyint` | `auto` or `1` to `300` | Maximum frames between key frames |
| `max-width` | `none` or `1` to `65535` | Capture width limit |
| `max-height` | `none` or `1` to `65535` | Capture height limit |
| `audio` | `true`, `false` | Screen audio and RDPSND output |
| `input` | `true`, `false` | Remote keyboard and pointer input |
| `clipboard` | `true`, `false` | Text clipboard redirection |
| `gfx` | `true`, `false` | GFX/H.264 instead of incremental SurfaceBits |
| `avc444` | `true`, `false` | AVC444 instead of AVC420 |
| `log-level` | Non-empty text | FreeRDP log level |

`openh264` and `videotoolbox` do not support AVC444 in this server. Use the
FFmpeg path when `avc444 = true`.

## Inheritance and overrides

Settings are resolved in this order:

```text
program defaults -> inherited preset -> selected preset -> command line
```

A preset may contain one `extends` key. Inheritance may be up to eight levels
deep. Cycles are rejected. The inherited preset is fully applied before the
child settings, so this example keeps the tested encoder settings but changes
listener exposure and display access policy:

```ini
extends = standard
bind-address = 127.0.0.1
display-id = 5
input = false
clipboard = false
```

Boolean settings have positive and negative command-line forms so either value
can override a preset: `--audio`/`--no-audio`, `--input`/`--view-only`,
`--clipboard`/`--no-clipboard`, `--gfx`/`--no-gfx`, and
`--avc420`/`--avc444`.

Use `--print-effective-config` after any changes. It prints all merged settings
and the credential source type, but never secret contents. Inspection does not
read a password file or standard input.

## Passwords and unattended startup

Preset files may name a secure credential source, but they may not contain a
plaintext password. Both of these settings are rejected:

```ini
password = plaintext-secret
password-stdin = true
```

Without a credential source, an interactive preset launch prompts for the
password without echo. For unattended startup, create an owner-only password
file and refer to its absolute path:

```bash
credential_dir="$HOME/Library/Application Support/macrdp-cpp/credentials"
password_file="$credential_dir/rdp-password"
umask 077
mkdir -p "$credential_dir"
read -r -s macrdp_password
printf '\n'
printf '%s\n' "$macrdp_password" > "$password_file"
unset macrdp_password
```

Then add this to the preset:

```ini
password-file = /Users/example/Library/Application Support/macrdp-cpp/credentials/rdp-password
```

The password file must be a regular file owned by the current user, may not be
a symlink, and may not grant any permissions to the group or other users. It
must contain exactly one non-empty password line. `sam-file` is an alternative
credential source for an existing FreeRDP NTLM SAM. A single preset may select
only one of `password-file` and `sam-file`.

An absolute path is required because background services do not have a stable,
user-visible working directory. `~` is not expanded inside preset files.

A command-line credential option replaces the source inherited from a preset.
For example, this ignores the preset's `password-file` for that invocation:

```bash
printf '%s\n' "$MACRDP_ONE_TIME_PASSWORD" | \
  ./build/macrdp-server --preset home-office --password-stdin
```

`--password-stdin` remains a command-line operation because it describes how a
specific process invocation receives a secret. Storing it in a preset could
make a LaunchAgent wait for input or encounter end-of-file.

## LaunchAgent example

An unattended service preset can keep operational settings together without
putting the secret itself in the preset:

```ini
extends = standard
description = Logged-in user RDP service
user = example-user
password-file = /Users/example/Library/Application Support/macrdp-cpp/state/password
display-id = main
```

Point the LaunchAgent at the preset:

```text
--preset service
```

The process must run in the logged-in Aqua session for ScreenCaptureKit and
input permissions. Grant Screen Recording and, when input is enabled,
Accessibility permission to the exact signed `macrdp-server` executable used by
the service.

## Troubleshooting

- Run `--list-presets` to confirm discovery and distinguish built-in from user
  presets.
- Run `--preset <name> --print-effective-config` to inspect inheritance and
  overrides without starting the server.
- If a display ID is rejected, rerun `--list-displays` after changing the
  display arrangement.
- If a preset or password file is rejected, inspect ownership and permissions
  with `ls -ld` and `ls -l`; do not fix the issue by making the file more
  broadly accessible.
- If the Windows client shows corrupted P-frames, confirm that the effective
  encoder is `openh264`. The VideoToolbox path is not the compatibility default.
