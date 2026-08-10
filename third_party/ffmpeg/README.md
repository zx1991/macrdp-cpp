# macrdp FFmpeg build

The public macOS package uses a version-pinned, minimal FFmpeg build instead
of the ordinary Homebrew formula. The checked-in manifest is the authoritative
source URL, archive hash, license expression, component allowlist, and
configure-flag list.

Build the dependency inside the existing CMake build hierarchy:

```bash
scripts/build_macos_ffmpeg.sh build/third_party/ffmpeg arm64 15.0
```

The script downloads and verifies the pristine source archive, builds shared
libraries, probes the installed `libavutil` for its compiled configuration and
license, and writes `build/third_party/ffmpeg/provenance.json`. Generated
source, object, library, and provenance files do not belong in Git.

After configuring CMake with the generated prefix and provenance, create the
verified corresponding-source archive with:

```bash
cmake --build build --target macrdp-ffmpeg-source-package
```

The output is `build/macrdp-ffmpeg-sources-7.1.1.tar.gz`. An official binary
release must publish this archive and the matching macrdp project source next
to the binary artifact. The source archive does not need to be embedded inside
the application payload.

The release configuration must remain LGPL-compatible. Do not add
`--enable-gpl`, `--enable-version3`, x264, x265, or another GPL/nonfree codec
without also changing the project's binary-distribution policy and release
validation.
