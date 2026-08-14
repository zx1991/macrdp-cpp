# FreeRDP source

`manifest.json` pins the macrdp FreeRDP fork used by configure, packaging, and
SBOM generation. The `macrdp-3.30` branch is based on upstream FreeRDP 3.30.0,
and release points use `3.30.0-macrdp.N` tags. Product-specific codec,
transport, and shadow-server changes remain focused commits.

To update the dependency:

1. Commit and push the FreeRDP changes to `zx1991/FreeRDP`.
2. Set `commit` and `source.url` in `manifest.json` to the full commit hash.
3. Download that codeload URL and update `source.sha256`.
4. Run a clean configure, build, test, and package validation.

Do not edit `build/_deps/freerdp-src`; use
`FETCHCONTENT_SOURCE_DIR_FREERDP` to point CMake at a local fork checkout while
developing both repositories.
