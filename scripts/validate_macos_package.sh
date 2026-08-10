#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    printf 'usage: %s <package-directory> [expected-architectures] [advertised-minimum-macos]\n' \
        "$0" >&2
    exit 2
fi

package_input=$1
expected_architectures=${2:-}
advertised_minimum=${3:-}

if [[ ! -d $package_input ]]; then
    printf 'package directory is missing: %s\n' "$package_input" >&2
    exit 1
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
compliance_validator="$script_dir/validate_macos_compliance.rb"

for command_name in otool lipo codesign awk ruby; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required on macOS\n' "$command_name" >&2
        exit 1
    fi
done

package_dir=$(cd "$package_input" && pwd -P)
packaged_server="$package_dir/bin/macrdp-server"
executable_dir=$(dirname "$packaged_server")
if [[ ! -x $packaged_server || -L $packaged_server ]]; then
    printf 'packaged server must be an executable regular file: %s\n' "$packaged_server" >&2
    exit 1
fi

is_system_path() {
    case $1 in
        /System/*|/usr/lib/*|/usr/lib)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

canonical_existing_path() {
    local candidate=$1
    local directory

    [[ -e $candidate ]] || return 1
    directory=$(cd "$(dirname "$candidate")" && pwd -P) || return 1
    printf '%s/%s\n' "$directory" "$(basename "$candidate")"
}

contains_word() {
    local expected=$1
    shift
    local word
    for word in "$@"; do
        if [[ $word == "$expected" ]]; then
            return 0
        fi
    done
    return 1
}

version_at_most() {
    local actual=$1
    local maximum=$2
    awk -v actual="$actual" -v maximum="$maximum" 'BEGIN {
        actual_count = split(actual, actual_parts, ".")
        maximum_count = split(maximum, maximum_parts, ".")
        count = actual_count > maximum_count ? actual_count : maximum_count
        for (part_index = 1; part_index <= count; ++part_index) {
            actual_value = actual_parts[part_index] + 0
            maximum_value = maximum_parts[part_index] + 0
            if (actual_value < maximum_value) exit 0
            if (actual_value > maximum_value) exit 1
        }
        exit 0
    }'
}

minimum_macos_for_architecture() {
    local file=$1
    local architecture=$2
    otool -arch "$architecture" -l "$file" | awk '
        $1 == "cmd" {
            build_version = ($2 == "LC_BUILD_VERSION")
            legacy_version = ($2 == "LC_VERSION_MIN_MACOSX")
        }
        build_version && $1 == "platform" { platform = $2 }
        build_version && $1 == "minos" {
            if (platform != 1) exit 2
            print $2
            exit 0
        }
        legacy_version && $1 == "version" {
            print $2
            exit 0
        }
        END {
            if (!build_version && !legacy_version) exit 3
        }
    '
}

resolve_packaged_dependency() {
    local owner=$1
    local dependency=$2
    local candidate
    local dependency_name
    local rpath

    case $dependency in
        @loader_path/*)
            candidate="$(dirname "$owner")/${dependency#@loader_path/}"
            ;;
        @executable_path/*)
            candidate="$executable_dir/${dependency#@executable_path/}"
            ;;
        @rpath/*)
            dependency_name=${dependency#@rpath/}
            while read -r rpath; do
                [[ -n $rpath ]] || continue
                if is_system_path "$rpath" && [[ -f $rpath/$dependency_name ]]; then
                    printf '%s\n' "$rpath/$dependency_name"
                    return 0
                fi
            done < <(otool -l "$owner" | awk '$1 == "path" { print $2 }')
            return 1
            ;;
        *)
            return 1
            ;;
    esac

    canonical_existing_path "$candidate"
}

validate_load_paths() {
    local file=$1
    local dependency
    local resolved
    local rpath

    while read -r rpath; do
        [[ -n $rpath ]] || continue
        if ! is_system_path "$rpath"; then
            printf 'non-system LC_RPATH remains in %s: %s\n' "$file" "$rpath" >&2
            return 1
        fi
    done < <(otool -l "$file" | awk '$1 == "path" { print $2 }')

    while read -r dependency; do
        [[ -n $dependency ]] || continue
        if is_system_path "$dependency"; then
            continue
        fi
        case $dependency in
            @loader_path/*|@executable_path/*|@rpath/*)
                resolved=$(resolve_packaged_dependency "$file" "$dependency" || true)
                if [[ -z $resolved ]]; then
                    printf 'unresolved packaged dependency %s of %s\n' "$dependency" "$file" >&2
                    return 1
                fi
                if ! is_system_path "$resolved" \
                    && [[ $resolved != "$package_dir"/* ]]; then
                    printf 'packaged dependency escapes package: %s of %s\n' \
                        "$dependency" "$file" >&2
                    return 1
                fi
                ;;
            *)
                printf 'non-system absolute or relative dependency remains: %s of %s\n' \
                    "$dependency" "$file" >&2
                return 1
                ;;
        esac
    done < <(otool -L "$file" | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*(.*/\1/p')
}

server_architecture_list=$(lipo -archs "$packaged_server")
read -r -a server_architectures <<< "$server_architecture_list"
if [[ ${#server_architectures[@]} -eq 0 ]]; then
    printf 'unable to determine packaged server architectures\n' >&2
    exit 1
fi

if [[ -n $expected_architectures ]]; then
    expected_architectures=${expected_architectures//,/ }
    expected_architectures=${expected_architectures//;/ }
    read -r -a expected_architecture_list <<< "$expected_architectures"
    for architecture in "${expected_architecture_list[@]}"; do
        if ! contains_word "$architecture" "${server_architectures[@]}"; then
            printf 'packaged server is missing expected architecture: %s\n' "$architecture" >&2
            exit 1
        fi
    done
fi

payload_files=("$packaged_server")
for library in "$package_dir"/lib/*.dylib; do
    [[ -e $library ]] || continue
    if [[ -L $library || ! -f $library ]]; then
        printf 'packaged library must be a regular file, not a symbolic link: %s\n' \
            "$library" >&2
        exit 1
    fi
    case $(basename "$library") in
        libavdevice*.dylib|libavfilter*.dylib|libavformat*.dylib|libpostproc*.dylib)
            printf 'unused FFmpeg component is present in the package: %s\n' \
                "$library" >&2
            exit 1
            ;;
    esac
    payload_files+=("$library")
done

for file in "${payload_files[@]}"; do
    file_architecture_list=$(lipo -archs "$file")
    read -r -a file_architectures <<< "$file_architecture_list"
    for architecture in "${server_architectures[@]}"; do
        if ! contains_word "$architecture" "${file_architectures[@]}"; then
            printf '%s is missing server architecture %s\n' "$file" "$architecture" >&2
            exit 1
        fi
        minimum_version=$(minimum_macos_for_architecture "$file" "$architecture")
        if [[ -z $minimum_version ]]; then
            printf 'unable to determine minimum macOS version for %s (%s)\n' \
                "$file" "$architecture" >&2
            exit 1
        fi
        if [[ -n $advertised_minimum ]] \
            && ! version_at_most "$minimum_version" "$advertised_minimum"; then
            printf '%s (%s) requires macOS %s, newer than advertised macOS %s\n' \
                "$file" "$architecture" "$minimum_version" "$advertised_minimum" >&2
            exit 1
        fi
    done
    validate_load_paths "$file"
    if ! signature_output=$(codesign --verify --strict --verbose=2 "$file" 2>&1); then
        printf 'invalid packaged signature: %s\n' "$file" >&2
        printf '%s\n' "$signature_output" >&2
        exit 1
    fi
done

help_output=$("$packaged_server" --help)
if [[ $help_output != *'Usage:'* \
    || $help_output != *'default: 127.0.0.1'* \
    || $help_output != *'--allow-insecure-security'* ]]; then
    printf 'packaged server did not complete the expected loader/help smoke check\n' >&2
    exit 1
fi

if [[ ! -f $compliance_validator ]]; then
    printf 'compliance validator is missing: %s\n' "$compliance_validator" >&2
    exit 1
fi
ruby "$compliance_validator" "$package_dir"

printf 'Validated macOS package: %s\n' "$package_dir"
printf 'Architectures: %s\n' "$server_architecture_list"
printf 'Mach-O payload files: %s\n' "${#payload_files[@]}"
if [[ -n $advertised_minimum ]]; then
    printf 'No payload requires newer than macOS %s\n' "$advertised_minimum"
fi
