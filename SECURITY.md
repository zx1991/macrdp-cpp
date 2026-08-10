# Security Policy

macrdp-cpp provides remote screen access and input injection. Treat every
listener as security-sensitive and expose it only on a trusted network or
behind an appropriate firewall/VPN.

## Supported scope

Security reports are welcome for the project-owned code, including:

- NLA credential handling and authentication decisions;
- accidental credential or clipboard disclosure;
- unsafe configuration-file and generated-SAM handling;
- listener exposure, privilege boundaries, and process behavior;
- memory-safety or command-injection issues in project code and scripts.

FreeRDP defects that reproduce independently of this project should also be
reported to the upstream FreeRDP project, with the pinned version and a
minimal reproducer.

## Reporting

Use the repository's private vulnerability reporting form in the GitHub
Security tab rather than opening a public issue. Include the commit, macOS
version, architecture, build options, and a minimal reproducer. Redact
passwords, SAM files, private IP addresses, clipboard contents, and screen
captures. Do not attach generated `build/_deps` trees unless they are
necessary to reproduce an upstream issue.

There is no guaranteed response time. Reports will be acknowledged when the
maintainer can reproduce or triage them.

## Deployment notes

The server listens only on `127.0.0.1` unless `--bind-address` explicitly
selects another interface. The default security mode is NLA and empty passwords
are rejected. TLS certificates are generated under the configured private
directory. The `/cert:ignore` option shown in the loopback test is for a local
test client only and must not be used as a general deployment recommendation.
The `tls` and `rdp` compatibility modes disable NLA and require the additional
`--allow-insecure-security` acknowledgement. Do not use them as routine
deployment modes.

The server accepts one concurrent client by default; `--max-clients` can set an
explicit limit from 1 through 64, enforced before FreeRDP accepts a new shadow
client. Interactive input and text clipboard redirection are enabled by
default. Use `--view-only` to disable keyboard and pointer injection and
`--no-clipboard` to prevent creation of the clipboard channel context and
monitor. These options are independent, so a view-only session still has
clipboard and audio access unless those capabilities are disabled separately.

Bind to the narrowest practical interface and restrict network reachability
with a host firewall, trusted network, or VPN. Capability flags limit what an
authenticated session can do; they are not a substitute for listener isolation,
strong unique credentials, or rotating credentials after suspected exposure.

For a LaunchAgent installed by this project, rotate the RDP credential with
`scripts/rotate_launch_agent_password.sh`. It validates the configured
owner-only password file, replaces it atomically, and restarts the service so
the old in-memory credential and existing sessions are discarded. Test the new
credential and reject the old one before considering rotation complete. The
helper does not manage an external `--sam-file`; operators using one must
replace it through their SAM provisioning process and restart the service.
