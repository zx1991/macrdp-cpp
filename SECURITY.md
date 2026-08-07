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

The default security mode is NLA and empty passwords are rejected. TLS
certificates are generated under the configured private directory. The
`/cert:ignore` option shown in the loopback test is for a local test client
only and must not be used as a general deployment recommendation.
