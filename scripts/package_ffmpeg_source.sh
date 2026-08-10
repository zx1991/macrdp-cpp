#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'usage: %s <ffmpeg-provenance> <project-source> <output-archive>\n' "$0" >&2
    exit 2
fi

provenance_input=$1
project_input=$2
output_input=$3

for command_name in find ruby shasum sort tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required to package FFmpeg source\n' "$command_name" >&2
        exit 1
    fi
done
if [[ ! -f $provenance_input ]]; then
    printf 'FFmpeg provenance is missing: %s\n' "$provenance_input" >&2
    exit 1
fi
if [[ ! -d $project_input ]]; then
    printf 'project source is missing: %s\n' "$project_input" >&2
    exit 1
fi

provenance=$(cd "$(dirname "$provenance_input")" && pwd -P)/$(basename "$provenance_input")
project_source=$(cd "$project_input" && pwd -P)
manifest="$project_source/third_party/ffmpeg/manifest.json"
distribution_readme="$project_source/third_party/ffmpeg/SOURCE_DISTRIBUTION.md"
if [[ ! -f $manifest || ! -f $distribution_readme ]]; then
    printf 'FFmpeg manifest or source-distribution instructions are missing\n' >&2
    exit 1
fi

ruby -rjson -e '
  manifest = JSON.parse(File.read(ARGV.fetch(0)))
  provenance = JSON.parse(File.read(ARGV.fetch(1)))
  %w[schemaVersion name version homepage licenseExpression source patches configureFlags expectedLibraries].each do |key|
    abort "FFmpeg provenance does not match manifest key #{key}" unless provenance[key] == manifest[key]
  end
  abort "managed FFmpeg is not LGPL-2.1-or-later" unless manifest["licenseExpression"] == "LGPL-2.1-or-later"
' "$manifest" "$provenance"

version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' "$manifest")
source_sha256=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).dig("source", "sha256")' "$manifest")
source_archive=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).dig("build", "sourceArchive")' "$provenance")
if [[ ! -f $source_archive ]]; then
    printf 'verified FFmpeg source archive is missing: %s\n' "$source_archive" >&2
    exit 1
fi
actual_source_sha256=$(shasum -a 256 "$source_archive" | awk '{ print $1 }')
if [[ $actual_source_sha256 != "$source_sha256" ]]; then
    printf 'FFmpeg source SHA-256 mismatch: expected %s, got %s\n' \
        "$source_sha256" "$actual_source_sha256" >&2
    exit 1
fi

mkdir -p "$(dirname "$output_input")"
output_archive=$(cd "$(dirname "$output_input")" && pwd -P)/$(basename "$output_input")
bundle_name="macrdp-ffmpeg-sources-$version"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-ffmpeg-sources.XXXXXX")
validation_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-ffmpeg-validate.XXXXXX")
temporary_archive="$output_archive.tmp.$$"
cleanup() {
    rm -rf "$staging_root" "$validation_root"
    rm -f "$temporary_archive"
}
trap cleanup EXIT

bundle_root="$staging_root/$bundle_name"
mkdir -p \
    "$bundle_root/upstream" \
    "$bundle_root/third_party/ffmpeg/patches" \
    "$bundle_root/scripts" \
    "$bundle_root/tools"
cp "$distribution_readme" "$bundle_root/README.md"
cp "$source_archive" "$bundle_root/upstream/ffmpeg-$version.tar.xz"
cp "$manifest" "$bundle_root/third_party/ffmpeg/manifest.json"
cp "$project_source/third_party/ffmpeg/README.md" \
    "$bundle_root/third_party/ffmpeg/README.md"
cp "$project_source/scripts/build_macos_ffmpeg.sh" "$bundle_root/scripts/"
cp "$project_source/tools/ffmpeg_build_probe.c" "$bundle_root/tools/"

while IFS=$'\t' read -r patch_relative expected_patch_sha256; do
    patch_source="$project_source/third_party/ffmpeg/$patch_relative"
    patch_destination="$bundle_root/third_party/ffmpeg/$patch_relative"
    if [[ ! -f $patch_source ]]; then
        printf 'FFmpeg patch is missing: %s\n' "$patch_relative" >&2
        exit 1
    fi
    actual_patch_sha256=$(shasum -a 256 "$patch_source" | awk '{ print $1 }')
    if [[ $actual_patch_sha256 != "$expected_patch_sha256" ]]; then
        printf 'FFmpeg patch SHA-256 mismatch: %s\n' "$patch_relative" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$patch_destination")"
    cp "$patch_source" "$patch_destination"
done < <(ruby -rjson -e '
  JSON.parse(File.read(ARGV.fetch(0))).fetch("patches", []).each do |entry|
    puts [entry.fetch("path"), entry.fetch("sha256")].join("\t")
  end
' "$manifest")

(
    cd "$bundle_root"
    find . -type f ! -name SHA256SUMS -print \
        | LC_ALL=C sort \
        | while IFS= read -r file; do shasum -a 256 "$file"; done \
        > SHA256SUMS
)

COPYFILE_DISABLE=1 tar -czf "$temporary_archive" -C "$staging_root" "$bundle_name"
tar -xzf "$temporary_archive" -C "$validation_root"
(
    cd "$validation_root/$bundle_name"
    shasum -a 256 -c SHA256SUMS >/dev/null
)
mv -f "$temporary_archive" "$output_archive"

printf 'Packaged FFmpeg corresponding source: %s\n' "$output_archive"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$output_archive" | awk '{ print $1 }')"
