# Release Engineering

`macrdp-package-validate` produces a relocatable, ad-hoc-signed developer
payload. Its dependency closure and compliance metadata are release-oriented,
but it is not yet a Developer ID signed and notarized installer.

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

- `sbom.cdx.json`: a deterministic CycloneDX 1.6 inventory.
- `THIRD_PARTY_NOTICES.md`: versions, declared licenses, homepages, packaged
  files, and bundled license locations.
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

1. The signed and notarized macrdp binary package or installer.
2. The exact tagged macrdp project source archive.
3. `macrdp-ffmpeg-sources-7.1.1.tar.gz` and its published SHA-256.
4. Release notes identifying the SBOM and license files inside the binary
   package.

The final signing and packaging design must preserve the user's ability to
replace the dynamically linked FFmpeg libraries with interface-compatible
modified builds and locally re-sign the result. Do not enable library-validation
settings that prevent that workflow without a separately reviewed LGPL
compliance design.

## Installation lifecycle

`bin/macrdp-manage` implements the per-user lifecycle without modifying system
directories. Before installation or upgrade it rejects symbolic links and
unrecorded files, verifies every SHA-256 property in the packaged SBOM, and
checks the server and dylib signatures. It repeats those checks after copying.
These checks detect corruption and incomplete payloads; authenticity still
depends on the future Developer ID signed and notarized outer distribution.

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

1. Sign the final package with Developer ID, submit it for notarization, staple
   the ticket, and verify installation and removal on a clean supported Mac.
2. Publish the binary, project source, FFmpeg corresponding source, checksums,
   and release notes together through an automated release workflow.
3. Complete the supported hardware and Windows `mstsc` acceptance rows tracked
   in the hardware matrix.
