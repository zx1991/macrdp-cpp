#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 || $# -gt 6 ]]; then
    printf 'usage: %s <macrdp-server> <output-directory> <project-source> <freerdp-source> <project-version> [ffmpeg-provenance]\n' \
        "$0" >&2
    exit 2
fi

server=$1
output=$2
project_source=$3
freerdp_source=$4
project_version=$5
ffmpeg_provenance=${6:-}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
compliance_generator="$script_dir/generate_macos_compliance.rb"
install_manager="$project_source/scripts/manage_macos_install.sh"
launch_agent_installer="$project_source/scripts/install_launch_agent.sh"
package_verifier="$project_source/scripts/verify_macos_package.rb"
password_rotator="$project_source/scripts/rotate_launch_agent_password.sh"

if [[ ! -x "$server" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server" >&2
    exit 1
fi
if [[ ! -f "$project_source/LICENSE" || ! -f "$project_source/NOTICE" ]]; then
    printf 'project LICENSE or NOTICE is missing: %s\n' "$project_source" >&2
    exit 1
fi
if [[ ! -f "$freerdp_source/LICENSE" ]]; then
    printf 'FreeRDP LICENSE is missing: %s\n' "$freerdp_source" >&2
    exit 1
fi
if [[ ! -f "$compliance_generator" ]]; then
    printf 'compliance generator is missing: %s\n' "$compliance_generator" >&2
    exit 1
fi
for project_script in "$install_manager" "$launch_agent_installer" \
    "$package_verifier" "$password_rotator"; do
    if [[ ! -x $project_script ]]; then
        printf 'package management script is missing or not executable: %s\n' \
            "$project_script" >&2
        exit 1
    fi
done
if [[ -n $ffmpeg_provenance && ! -f $ffmpeg_provenance ]]; then
    printf 'FFmpeg provenance is missing: %s\n' "$ffmpeg_provenance" >&2
    exit 1
fi
if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1 \
    || ! command -v codesign >/dev/null 2>&1 || ! command -v ruby >/dev/null 2>&1; then
    printf 'otool, install_name_tool, codesign, and ruby are required on macOS\n' >&2
    exit 1
fi

mkdir -p "$output/bin" "$output/lib"
output_dir=$(cd "$output" && pwd -P)
packaged_server="$output_dir/bin/macrdp-server"
executable_dir=$(dirname "$packaged_server")
dependency_origins=$(mktemp "${TMPDIR:-/tmp}/macrdp-dependencies.XXXXXX")
trap 'rm -f "$dependency_origins"' EXIT

# Rebuild the generated payload from the current binary and dependency set.
# Unexpected stale files are left in place so the exact-coverage verifier fails
# instead of silently deleting caller-owned data from an arbitrary output path.
rm -f "$packaged_server"
find "$output_dir/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' -delete
cp -f "$server" "$packaged_server"
chmod u+w "$packaged_server"
install -m 755 "$install_manager" "$output_dir/bin/macrdp-manage"
install -m 755 "$launch_agent_installer" \
    "$output_dir/bin/macrdp-install-launch-agent"
install -m 755 "$package_verifier" "$output_dir/bin/macrdp-verify-package"
install -m 755 "$password_rotator" "$output_dir/bin/macrdp-rotate-password"

is_system_dependency() {
    case "$1" in
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

    [[ -e "$candidate" ]] || return 1
    directory=$(cd "$(dirname "$candidate")" && pwd -P) || return 1
    printf '%s/%s\n' "$directory" "$(basename "$candidate")"
}

contains_path() {
    local candidate=$1
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

resolve_dependency() {
    local owner=$1
    local dependency=$2
    local candidate
    local name
    local rpath_base

    case "$dependency" in
        /*)
            [[ -f "$dependency" ]] || return 1
            printf '%s\n' "$dependency"
            return 0
            ;;
        @loader_path/*)
            candidate="$(dirname "$owner")/${dependency#@loader_path/}"
            [[ -f "$candidate" ]] || return 1
            printf '%s\n' "$candidate"
            return 0
            ;;
        @executable_path/*)
            candidate="$executable_dir/${dependency#@executable_path/}"
            [[ -f "$candidate" ]] || return 1
            printf '%s\n' "$candidate"
            return 0
            ;;
        @rpath/*)
            name=${dependency#@rpath/}
            while read -r candidate; do
                [[ -n "$candidate" ]] || continue
                case "$candidate" in
                    @loader_path/*)
                        rpath_base="$(dirname "$owner")/${candidate#@loader_path/}"
                        ;;
                    @executable_path/*)
                        rpath_base="$executable_dir/${candidate#@executable_path/}"
                        ;;
                    /*)
                        rpath_base="$candidate"
                        ;;
                    *)
                        continue
                        ;;
                esac
                candidate="$rpath_base/$name"
                if [[ -f "$candidate" ]]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done < <(otool -l "$owner" | awk '$1 == "path" { print $2 }')

            # Dependencies already copied into the package are authoritative.
            # This matters when a copied library has no LC_RPATH of its own:
            # falling through to Homebrew could resolve a same-named library
            # from a different FFmpeg build and corrupt dependency provenance.
            candidate="$output_dir/lib/$name"
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi

            for candidate in /opt/homebrew/lib /usr/local/lib; do
                if [[ -f "$candidate/$name" ]]; then
                    printf '%s\n' "$candidate/$name"
                    return 0
                fi
            done
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

queue=("$packaged_server")
processed=()

while [[ ${#queue[@]} -gt 0 ]]; do
    current=${queue[0]}
    queue=("${queue[@]:1}")
    if contains_path "$current" "${processed[@]-}"; then
        continue
    fi
    processed+=("$current")

    dependencies=()
    while read -r dependency; do
        [[ -n "$dependency" ]] || continue
        dependencies+=("$dependency")
    done < <(otool -L "$current" | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*(.*/\1/p')

    for dependency in "${dependencies[@]}"; do
        if is_system_dependency "$dependency"; then
            continue
        fi

        resolved=$(resolve_dependency "$current" "$dependency" || true)
        if [[ -z "$resolved" ]]; then
            printf 'unable to resolve non-system dependency %s of %s\n' \
                "$dependency" "$current" >&2
            exit 1
        fi

        # An @rpath reference can legitimately resolve to a macOS system
        # framework/runtime. Keep that reference and its system rpath; only
        # non-system dependencies belong in the package.
        if is_system_dependency "$resolved"; then
            continue
        fi
        canonical_resolved=$(canonical_existing_path "$resolved" || true)
        if [[ -z "$canonical_resolved" ]]; then
            printf 'unable to canonicalize dependency %s of %s\n' \
                "$dependency" "$current" >&2
            exit 1
        fi
        resolved=$canonical_resolved
        source_origin=$resolved
        if [[ $source_origin == "$output_dir"/lib/* ]]; then
            packaged_origin="lib/${source_origin##*/}"
            source_origin=$(awk -F '\t' -v packaged_path="$packaged_origin" \
                '$1 == packaged_path { print $2; exit }' "$dependency_origins")
            if [[ -z $source_origin ]]; then
                printf 'unable to recover original dependency source for %s\n' \
                    "$packaged_origin" >&2
                exit 1
            fi
        fi

        name=$(basename "$resolved")
        destination="$output_dir/lib/$name"
        if [[ ! -e "$destination" ]]; then
            cp -L "$resolved" "$destination"
            chmod u+w "$destination"
            install_name_tool -id "@loader_path/$name" "$destination" 2>/dev/null
        fi

        if [[ "$current" == "$packaged_server" ]]; then
            replacement="@loader_path/../lib/$name"
        else
            replacement="@loader_path/$name"
        fi
        install_name_tool -change "$dependency" "$replacement" "$current" 2>/dev/null || true
        printf 'lib/%s\t%s\t%s\n' "$name" "$source_origin" \
            "${current#"$output_dir"/}" >> "$dependency_origins"

        if ! contains_path "$destination" "${queue[@]-}" "${processed[@]-}"; then
            queue+=("$destination")
        fi
    done
done

delete_non_system_rpaths() {
    local file=$1
    local rpath

    while read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if ! is_system_dependency "$rpath"; then
            install_name_tool -delete_rpath "$rpath" "$file" 2>/dev/null
        fi
    done < <(otool -l "$file" | awk '$1 == "path" { print $2 }')
}

validate_dependency() {
    local owner=$1
    local dependency=$2
    local resolved
    local canonical

    if is_system_dependency "$dependency"; then
        return 0
    fi

    case "$dependency" in
        @loader_path/*|@executable_path/*)
            resolved=$(resolve_dependency "$owner" "$dependency" || true)
            canonical=$(canonical_existing_path "$resolved" || true)
            if [[ -z "$canonical" || "$canonical" != "$output_dir"/* ]]; then
                printf 'packaged dependency escapes output directory: %s of %s\n' \
                    "$dependency" "$owner" >&2
                return 1
            fi
            ;;
        @rpath/*)
            resolved=$(resolve_dependency "$owner" "$dependency" || true)
            if [[ -z "$resolved" || ! -f "$resolved" ]]; then
                printf 'unresolved @rpath dependency %s of %s\n' \
                    "$dependency" "$owner" >&2
                return 1
            fi
            if ! is_system_dependency "$resolved"; then
                printf 'non-system @rpath dependency remains: %s of %s\n' \
                    "$dependency" "$owner" >&2
                return 1
            fi
            ;;
        /*)
            printf 'non-system absolute dependency remains: %s of %s\n' \
                "$dependency" "$owner" >&2
            return 1
            ;;
        *)
            printf 'unsupported packaged dependency form: %s of %s\n' \
                "$dependency" "$owner" >&2
            return 1
            ;;
    esac
}

validate_packaged_file() {
    local current=$1
    local dependency
    local rpath

    while read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if ! is_system_dependency "$rpath"; then
            printf 'non-system LC_RPATH remains in %s: %s\n' "$current" "$rpath" >&2
            return 1
        fi
    done < <(otool -l "$current" | awk '$1 == "path" { print $2 }')

    while read -r dependency; do
        [[ -n "$dependency" ]] || continue
        validate_dependency "$current" "$dependency" || return 1
    done < <(otool -L "$current" | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*(.*/\1/p')
}

# Once every non-system dependency has been rewritten to a package-relative
# install name, non-system rpaths are unnecessary and make the package depend
# on the build machine. Remove them before signing and fail closed if any
# external reference remains.
while IFS= read -r current; do
    delete_non_system_rpaths "$current"
done < <(find "$output_dir" -type f \( -name 'macrdp-server' -o -name '*.dylib' \) -print)

while IFS= read -r current; do
    validate_packaged_file "$current"
done < <(find "$output_dir" -type f \( -name 'macrdp-server' -o -name '*.dylib' \) -print)

# install_name_tool invalidates an existing signature. Re-sign the modified
# payload ad hoc so macOS does not kill the packaged process at load time.
sign_ad_hoc() {
    local file=$1
    local signing_output

    if ! signing_output=$(codesign --force --sign - "$file" 2>&1); then
        printf 'unable to apply ad-hoc signature to %s\n' "$file" >&2
        printf '%s\n' "$signing_output" >&2
        return 1
    fi
}

for library in "$output_dir"/lib/*.dylib; do
    [[ -f "$library" ]] || continue
    sign_ad_hoc "$library"
done
sign_ad_hoc "$packaged_server"

ruby "$compliance_generator" \
    "$output_dir" \
    "$dependency_origins" \
    "$project_source" \
    "$freerdp_source" \
    "$project_version" \
    "$ffmpeg_provenance"

printf 'Packaged macrdp-server at %s\n' "$output_dir"
printf 'Non-system dylibs: %s\n' "$(find "$output_dir/lib" -type f | wc -l | tr -d ' ')"
