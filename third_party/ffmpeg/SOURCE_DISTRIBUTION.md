# macrdp FFmpeg corresponding source

This archive contains the complete source inputs used for the FFmpeg shared
libraries distributed with the matching macrdp macOS binary package:

- the pristine, hash-verified FFmpeg source archive under `upstream/`;
- the authoritative manifest and every applied patch under
  `third_party/ffmpeg/`;
- the exact build driver and runtime capability probe under `scripts/` and
  `tools/`; and
- `SHA256SUMS`, covering every other file in this source archive.

The FFmpeg libraries are licensed under LGPL-2.1-or-later. See the upstream
source archive for its license texts and individual source-file notices. The
macrdp project source remains licensed under Apache-2.0.

To rebuild from this archive without downloading FFmpeg again, extract it,
place the included upstream archive where the build driver expects it, and run
the pinned build:

```bash
mkdir -p build/third_party/ffmpeg/downloads
cp upstream/ffmpeg-7.1.1.tar.xz build/third_party/ffmpeg/downloads/
scripts/build_macos_ffmpeg.sh build/third_party/ffmpeg arm64 15.0
```

The corresponding macrdp project source is required to build the complete
server. Official binary releases must publish that project source and this
FFmpeg source archive alongside the binary artifact.
