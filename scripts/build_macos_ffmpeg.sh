#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    printf 'usage: %s <build-root> [architecture] [minimum-macos]\n' "$0" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
project_source=$(cd "$script_dir/.." && pwd -P)
manifest="$project_source/third_party/ffmpeg/manifest.json"
probe_source="$project_source/tools/ffmpeg_build_probe.c"
build_input=$1
architecture=${2:-arm64}
minimum_macos=${3:-15.0}

for command_name in clang curl make patch ruby shasum tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required to build FFmpeg\n' "$command_name" >&2
        exit 1
    fi
done
if [[ ! -f $manifest || ! -f $probe_source ]]; then
    printf 'FFmpeg manifest or build probe is missing\n' >&2
    exit 1
fi
case $architecture in
    arm64|x86_64) ;;
    *)
        printf 'unsupported FFmpeg architecture: %s\n' "$architecture" >&2
        exit 1
        ;;
esac
if [[ ! $minimum_macos =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    printf 'invalid minimum macOS version: %s\n' "$minimum_macos" >&2
    exit 1
fi

mkdir -p "$build_input"
build_root=$(cd "$build_input" && pwd -P)
if [[ $build_root == / || $build_root == "$project_source" ]]; then
    printf 'FFmpeg build root must be a dedicated subdirectory: %s\n' \
        "$build_root" >&2
    exit 1
fi
version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' "$manifest")
source_url=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source").fetch("url")' "$manifest")
source_sha256=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source").fetch("sha256")' "$manifest")
license_expression=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("licenseExpression")' "$manifest")

download_root="$build_root/downloads"
source_parent="$build_root/source"
source_root="$source_parent/ffmpeg-$version"
work_root="$build_root/work-$architecture-macos-$minimum_macos"
prefix_root="$build_root/prefix"
archive="$download_root/ffmpeg-$version.tar.xz"
configuration_file="$build_root/ffmpeg-build-configuration.txt"
provenance_file="$build_root/provenance.json"
stamp_file="$build_root/build.sha256"
probe="$work_root/macrdp-ffmpeg-build-probe"

patch_files=()
while IFS=$'\t' read -r patch_relative patch_sha256; do
    patch_path="$project_source/third_party/ffmpeg/$patch_relative"
    if [[ ! -f $patch_path ]]; then
        printf 'FFmpeg patch is missing: %s\n' "$patch_relative" >&2
        exit 1
    fi
    actual_patch_sha256=$(shasum -a 256 "$patch_path" | awk '{ print $1 }')
    if [[ $actual_patch_sha256 != "$patch_sha256" ]]; then
        printf 'FFmpeg patch SHA-256 mismatch: %s\n' "$patch_relative" >&2
        exit 1
    fi
    patch_files+=("$patch_path")
done < <(ruby -rjson -e '
  JSON.parse(File.read(ARGV.fetch(0))).fetch("patches", []).each do |entry|
    puts [entry.fetch("path"), entry.fetch("sha256")].join("\t")
  end
' "$manifest")

stamp_value=$(
    {
        shasum -a 256 "$manifest" "$probe_source" \
            "$script_dir/build_macos_ffmpeg.sh" "${patch_files[@]}"
        printf 'architecture=%s\nminimum_macos=%s\n' "$architecture" "$minimum_macos"
    } | shasum -a 256 | awk '{ print $1 }'
)

build_complete=true
for library_name in libavcodec libavutil libswresample libswscale; do
    if [[ ! -f $prefix_root/lib/$library_name.dylib ]]; then
        build_complete=false
    fi
done
if [[ -f $stamp_file && -f $provenance_file && -f $configuration_file \
      && $build_complete == true && $(<"$stamp_file") == "$stamp_value" ]]; then
    printf 'FFmpeg %s is already built at %s\n' "$version" "$prefix_root"
    exit 0
fi

mkdir -p "$download_root"
if [[ -f $archive ]]; then
    actual_sha256=$(shasum -a 256 "$archive" | awk '{ print $1 }')
    if [[ $actual_sha256 != "$source_sha256" ]]; then
        printf 'discarding FFmpeg archive with unexpected SHA-256\n' >&2
        rm -f "$archive"
    fi
fi
if [[ ! -f $archive ]]; then
    archive_tmp="$archive.tmp.$$"
    trap 'rm -f "$archive_tmp"' EXIT
    curl -fsSL -o "$archive_tmp" "$source_url"
    actual_sha256=$(shasum -a 256 "$archive_tmp" | awk '{ print $1 }')
    if [[ $actual_sha256 != "$source_sha256" ]]; then
        printf 'FFmpeg source SHA-256 mismatch: expected %s, got %s\n' \
            "$source_sha256" "$actual_sha256" >&2
        exit 1
    fi
    mv "$archive_tmp" "$archive"
    trap - EXIT
fi

rm -rf "$source_parent" "$work_root" "$prefix_root"
mkdir -p "$source_parent" "$work_root" "$prefix_root"
tar -xf "$archive" -C "$source_parent"
if [[ ! -x $source_root/configure ]]; then
    printf 'FFmpeg source archive did not produce the expected source tree\n' >&2
    exit 1
fi
while IFS=$'\t' read -r patch_relative patch_sha256; do
    patch_path="$project_source/third_party/ffmpeg/$patch_relative"
    if [[ ! -f $patch_path ]]; then
        printf 'FFmpeg patch is missing: %s\n' "$patch_relative" >&2
        exit 1
    fi
    actual_patch_sha256=$(shasum -a 256 "$patch_path" | awk '{ print $1 }')
    if [[ $actual_patch_sha256 != "$patch_sha256" ]]; then
        printf 'FFmpeg patch SHA-256 mismatch: %s\n' "$patch_relative" >&2
        exit 1
    fi
    patch -d "$source_root" -p1 < "$patch_path"
done < <(ruby -rjson -e '
  JSON.parse(File.read(ARGV.fetch(0))).fetch("patches", []).each do |entry|
    puts [entry.fetch("path"), entry.fetch("sha256")].join("\t")
  end
' "$manifest")

configure_flags=()
while IFS= read -r flag; do
    configure_flags+=("$flag")
done < <(ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0))).fetch("configureFlags").each { |flag| puts flag }' "$manifest")
configure_flags+=(
    "--prefix=$prefix_root"
    "--cc=clang"
    "--arch=$architecture"
    "--target-os=darwin"
    "--install-name-dir=@rpath"
    "--extra-cflags=-arch $architecture -mmacosx-version-min=$minimum_macos"
    "--extra-ldflags=-arch $architecture -mmacosx-version-min=$minimum_macos"
)

jobs=${MACRDP_FFMPEG_JOBS:-}
if [[ -z $jobs ]]; then
    jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')
fi
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    printf 'MACRDP_FFMPEG_JOBS must be a positive integer\n' >&2
    exit 1
fi

(
    cd "$work_root"
    MACOSX_DEPLOYMENT_TARGET="$minimum_macos" \
        "$source_root/configure" "${configure_flags[@]}"
    make -j"$jobs"
    make install
)

for library_name in libavcodec libavutil libswresample libswscale; do
    if [[ ! -f $prefix_root/lib/$library_name.dylib ]]; then
        printf 'expected FFmpeg library is missing: %s\n' "$library_name" >&2
        exit 1
    fi
done

clang -std=c11 \
    -I"$prefix_root/include" \
    -L"$prefix_root/lib" \
    -Wl,-rpath,"$prefix_root/lib" \
    "$probe_source" \
    -lavcodec \
    -lavutil \
    -lswresample \
    -lswscale \
    -o "$probe"
probe_output=$(
    DYLD_LIBRARY_PATH="$prefix_root/lib" \
        "$probe" "$version" "LGPL version 2.1 or later"
)
printf '%s\n' "$probe_output" | ruby -e '
  value = STDIN.read
  replacements = ARGV.each_slice(2).to_a
  replacements.each { |from, to| value = value.gsub(from, to) }
  print value
' \
    "$prefix_root" '<install-prefix>' \
    "$source_root" '<source-root>' \
    "$work_root" '<build-root>' \
    > "$configuration_file"

ruby -rjson -e '
  manifest_path, output_path, archive, source_root, work_root, prefix_root,
    configuration_file, architecture, minimum_macos = ARGV
  manifest = JSON.parse(File.read(manifest_path))
  manifest["build"] = {
    "architecture" => architecture,
    "minimumMacOS" => minimum_macos,
    "compiler" => "clang",
    "sourceArchive" => File.realpath(archive),
    "sourceRoot" => File.realpath(source_root),
    "workRoot" => File.realpath(work_root),
    "installPrefix" => File.realpath(prefix_root),
    "configurationFile" => File.realpath(configuration_file),
    "licenseFiles" => [
      File.realpath(File.join(source_root, "COPYING.LGPLv2.1")),
      File.realpath(File.join(source_root, "LICENSE.md"))
    ]
  }
  File.write(output_path, JSON.pretty_generate(manifest) + "\n")
' \
    "$manifest" "$provenance_file" "$archive" "$source_root" "$work_root" \
    "$prefix_root" "$configuration_file" "$architecture" "$minimum_macos"

printf '%s\n' "$stamp_value" > "$stamp_file"
printf 'Built FFmpeg %s (%s) at %s\n' "$version" "$license_expression" "$prefix_root"
printf 'Provenance: %s\n' "$provenance_file"
