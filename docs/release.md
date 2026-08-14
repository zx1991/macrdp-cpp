# Release Engineering

`macrdp-package-validate` produces a relocatable payload and
`macrdp-distribution-validate` wraps it in a read-only DMG. Both use ad-hoc
signatures by default. Their dependency closure and compliance metadata are
release-oriented, but only the explicitly gated release mode accepts Developer
ID identities and enables notarization.

## FFmpeg dependency policy

The project has two intentionally different dependency modes:

| Mode | FFmpeg source | Intended use |
| --- | --- | --- |
| Development | Homebrew discovery | Local builds, loopback work, and the sanitizer job only |
| Release-equivalent | `third_party/ffmpeg/manifest.json` | Package validation and future official binary releases |

The release-equivalent build pins FFmpeg 7.1.1 and its source SHA-256, applies
the checked-in patch, and produces only `libavcodec`, `libavutil`,
`libswresample`, and `libswscale`. The enabled codec surface is H.264 through
VideoToolbox, AAC, and PCM. The runtime probe requires FFmpeg to report
`LGPL-2.1-or-later` and rejects GPL, version3, nonfree, x264, and x265 options.

The ordinary Homebrew FFmpeg formula currently used for development declares
`GPL-3.0-or-later` and enables GPL codecs. A package configured from that
installation remains useful for local testing, but it must not be substituted
for the managed dependency in an Apache-only official binary release.

Build and select the managed dependency with:

```bash
scripts/build_macos_ffmpeg.sh build/third_party/ffmpeg arm64 15.0

cmake -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DMACRDP_FFMPEG_ROOT="$PWD/build/third_party/ffmpeg/prefix" \
  -DMACRDP_FFMPEG_PROVENANCE="$PWD/build/third_party/ffmpeg/provenance.json"
cmake --build build --parallel 8
ctest --test-dir build --output-on-failure
cmake --build build --target macrdp-package-validate
```

The final target validates the binary package and generates
`build/macrdp-ffmpeg-sources-7.1.1.tar.gz`.

## Compliance payload

The generated `build/macrdp-dist/share/macrdp` directory contains:

- `PRESETS.md`: built-in and user preset reference, including credentials and
  file permissions.
- `sbom.cdx.json`: a deterministic CycloneDX 1.6 inventory.
- `THIRD_PARTY_NOTICES.md`: versions, declared licenses, homepages, packaged
  files, and bundled license locations.
- `freerdp-source-provenance.json`: fork repository, upstream version, fixed
  commit, source URL, and archive SHA-256.
- `ffmpeg-build-configuration.txt`: the compiled FFmpeg configuration reported
  by the packaged build.
- `ffmpeg-source-provenance.json`: source URL and hash, patches, configure
  flags, architecture, compiler, deployment target, and library allowlist.
- `licenses/`: project, FreeRDP, FFmpeg, and Homebrew dependency license and
  notice files.

The packager records every copied dylib's canonical source and the dylib that
required it. Managed FFmpeg paths are checked against the generated provenance;
other dependencies must resolve to a specific Homebrew Cellar version. A file
with conflicting origins, an unknown dependency, or an unexpected FFmpeg
component fails packaging.

Validation requires every binary, management tool, and dylib to have an SBOM
SHA-256 entry, every component to declare a license and non-empty license
directory, and every generated compliance file to have a verified SHA-256
entry. It also rejects
unknown component references, missing dependency rows, symbolic links in the
compliance tree, stale files not covered by the SBOM, and managed FFmpeg builds
that omit the required codec or library flags.

## Corresponding source

An official release that distributes the FFmpeg dylibs must also make the
matching FFmpeg corresponding source available. This project does that as a
separate release attachment; the source archive does not need to be copied
inside the application or installer.

`macrdp-ffmpeg-sources-7.1.1.tar.gz` contains the pristine verified upstream
archive, every applied patch, the authoritative manifest, the build driver,
the runtime capability probe, rebuild instructions, and a checksum manifest.
The target extracts the finished archive and verifies every checksum before it
succeeds.

Each official binary release must keep these downloadable from the same
release page:

1. The signed, notarized, and stapled macrdp DMG.
2. The exact tagged macrdp project source archive.
3. `macrdp-ffmpeg-sources-7.1.1.tar.gz` and its published SHA-256.
4. Release notes identifying the SBOM and license files inside the binary
   package.

The final signing and packaging design must preserve the user's ability to
replace the dynamically linked FFmpeg libraries with interface-compatible
modified builds and locally re-sign the result. Do not enable library-validation
settings that prevent that workflow without a separately reviewed LGPL
compliance design.

## Developer ID and notarization

The release carrier is a signed, read-only DMG rather than a system-wide
installer package. The DMG contains `INSTALL.txt`, structured
`distribution.json` metadata, and one versioned package directory. Installation
still goes through `macrdp-manage`, so choosing a username, password file,
network binding, and access policy remains an explicit per-user operation.

The default target creates and validates an ad-hoc-signed development image:

```bash
cmake --build build --target macrdp-distribution-validate
```

Validation checks the DMG checksum and signature, mounts it read-only, matches
the DMG and server signing identifiers to `distribution.json`, verifies the
complete packaged SBOM, checks every Mach-O signature and architecture, and
runs the mounted server's loader-only `--help` path. The development image is
not publisher-authenticated and must not be released.

For an official candidate, configure the final package and DMG with the same
`Developer ID Application` identity:

```bash
developer_id='Developer ID Application: Example Developer (TEAMID)'

cmake -S . -B build \
  -DMACRDP_RELEASE_CODESIGN_EXECUTABLE=/path/to/codesign-or-wrapper \
  -DMACRDP_PACKAGE_SIGN_IDENTITY="$developer_id" \
  -DMACRDP_PACKAGE_HARDENED_RUNTIME=ON \
  -DMACRDP_PACKAGE_TIMESTAMP=ON \
  -DMACRDP_DISTRIBUTION_SIGN_IDENTITY="$developer_id" \
  -DMACRDP_DISTRIBUTION_TIMESTAMP=ON \
  -DMACRDP_REQUIRE_DEVELOPER_ID=ON \
  -DMACRDP_NOTARY_KEYCHAIN_PROFILE=macrdp-notary
```

Release mode fails configuration unless both identities, hardened runtime, and
trusted timestamps are enabled. After packaging, it also requires every inner
Mach-O and the outer DMG to have a timestamped `Developer ID Application`
signature from one Team ID. The SBOM is generated after inner signing, so its
hashes describe the actual distributed binaries.

`MACRDP_RELEASE_CODESIGN_EXECUTABLE` may point to a local owner-only wrapper
that unlocks a dedicated build Keychain before delegating to `codesign`. The
wrapper and its unlock material are workstation configuration and must not be
added to the repository. Use plain `codesign` when the selected identity is
already available to the build process.

Create the local notary profile without putting an app-specific password on the
command line:

```bash
xcrun notarytool store-credentials macrdp-notary \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID"
```

`notarytool` prompts securely for the app-specific password and stores it in
the selected Keychain. The certificate, private key, app-specific password,
API key, and Keychain contents must never be committed. Submit, wait for an
explicit `Accepted` result, staple, and run both stapler and Gatekeeper checks
with:

```bash
cmake --build build --target macrdp-notarize
```

The notarization script refuses ad-hoc or untimestamped DMGs and never staples
a rejected submission. A real Apple Developer account, certificate, and notary
profile are external prerequisites; the repository and ordinary CI contain no
such credentials.

## Installation lifecycle

`bin/macrdp-manage` implements the per-user lifecycle without modifying system
directories. Before installation or upgrade it rejects symbolic links and
unrecorded files, verifies every SHA-256 property in the packaged SBOM, and
checks the server and dylib signatures. It repeats those checks after copying.
These checks detect corruption and incomplete payloads; publisher authenticity
depends on validating the Developer ID signed and notarized outer DMG.

Each release is installed at
`~/Library/Application Support/macrdp-cpp/releases/<version-sbom-hash>`. The
LaunchAgent uses the stable `current/bin/macrdp-server` path, and `previous`
identifies the one-command rollback target. Upgrades never rewrite the
LaunchAgent arguments, password, certificate, configuration directory, or an
external SAM. A failed `launchctl kickstart` restores the old `current` and
`previous` links before attempting to restart the old release.

Ordinary uninstall unloads and removes the LaunchAgent and deletes all release
payloads. It deliberately retains the installation marker and state so a later
install can reuse the certificate and credentials. `uninstall --purge-state`
also removes the installation root and macrdp log directory. It therefore
removes passwords, certificates, or SAM files stored inside that root, but it
never deletes external paths passed through `--password-file`, `--config-dir`,
or `--sam-file`.

Generated NLA SAM files remain process-lifetime data and are securely removed
by the server on exit. Persistent FreeRDP certificates remain in the selected
configuration directory. Operators are responsible for provisioning and
rotating an explicit external SAM.

## Remaining release gates

1. Run the implemented Developer ID/notarization target with real Apple
   credentials, then verify installation and removal on a clean supported Mac.
2. Publish the binary, project source, FFmpeg corresponding source, checksums,
   and release notes together through an automated release workflow.
3. Complete the supported hardware and Windows `mstsc` acceptance rows tracked
   in the hardware matrix.
