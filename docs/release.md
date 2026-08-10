# Release Engineering

`macrdp-package-validate` produces a relocatable developer payload, not a
public release installer. The target currently proves the package's load-path,
architecture, minimum-macOS, signature, loader, dependency, and compliance
metadata properties. Developer ID signing and notarization are still pending.

## Compliance payload

The generated `build/macrdp-dist/share/macrdp` directory contains:

- `sbom.cdx.json`: a deterministic CycloneDX 1.6 inventory.
- `THIRD_PARTY_NOTICES.md`: versions, declared licenses, homepages, packaged
  files, and bundled license locations.
- `ffmpeg-build-configuration.txt`: the exact `ffmpeg -buildconf` output from
  the FFmpeg installation that supplied the packaged libraries.
- `licenses/`: project, FreeRDP, and Homebrew formula license and notice files.

The packager records each copied dylib's canonical Homebrew Cellar source and
the dylib that required it. It obtains structured formula metadata from
`brew info --json=v2`, uses the installed Cellar version rather than the latest
formula version, and builds component dependency edges from the actual Mach-O
graph. A dependency that cannot be traced to a Cellar fails packaging instead
of receiving guessed metadata.

Validation requires every binary and dylib to have an SBOM SHA-256 entry,
every component to declare a license and non-empty license directory, and every
generated compliance file to have a verified SHA-256 entry. It also rejects
unknown component references, missing dependency rows, symbolic links in the
compliance tree, and stale files not covered by the SBOM.

## Current FFmpeg license

The ordinary Homebrew FFmpeg bottle is not a release-ready dependency for an
Apache-only binary distribution. The generated build configuration currently
records `--enable-gpl`, `--enable-version3`, `--enable-libx264`, and
`--enable-libx265`; Homebrew declares the resulting FFmpeg formula as
`GPL-3.0-or-later`, while x264 and x265 are GPL-2.0-or-later components.

Do not publish the current developer payload as an Apache-2.0-only artifact.
A public binary release must either use a purpose-built, version-pinned FFmpeg
configuration with an intentionally selected license and codec set, or adopt
distribution terms and source-offer procedures reviewed for the resulting GPL
combination. The generated notices and SBOM document the current package; they
do not by themselves satisfy every distribution obligation.

## Remaining release gates

1. Build only the FFmpeg libraries, codecs, and Apple framework integrations
   required by AVC420, AVC444, image conversion, and RDPSND resampling.
2. Pin source archives, hashes, configure flags, compiler settings, and the
   macOS deployment target for that dependency build.
3. Re-run functional codec and audio tests against the reduced dependency set
   and confirm the SBOM contains no undeclared or unexpected component.
4. Define install, upgrade, rollback, and uninstall behavior for certificates,
   configuration, SAM files, and LaunchAgent state.
5. Sign the final package with Developer ID, submit it for notarization, staple
   the ticket, and verify it on a clean supported Mac.
