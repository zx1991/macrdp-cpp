#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <macrdp-server> <output-directory>\n' "$0" >&2
    exit 2
fi

server=$1
output=$2

if [[ ! -x "$server" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server" >&2
    exit 1
fi
if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1 \
    || ! command -v codesign >/dev/null 2>&1; then
    printf 'otool, install_name_tool, and codesign are required on macOS\n' >&2
    exit 1
fi

mkdir -p "$output/bin" "$output/lib"
output_dir=$(cd "$output" && pwd -P)
packaged_server="$output_dir/bin/macrdp-server"

# Rebuild the generated payload from the current binary and dependency set.
# Keep unrelated files in the caller's output directory untouched.
rm -f "$packaged_server"
find "$output_dir/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' -delete
cp -f "$server" "$packaged_server"
chmod u+w "$packaged_server"

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
            candidate="$output_dir/${dependency#@executable_path/}"
            [[ -f "$candidate" ]] || return 1
            printf '%s\n' "$candidate"
            return 0
            ;;
        @rpath/*)
            name=${dependency#@rpath/}
            while read -r candidate; do
                [[ -n "$candidate" ]] || continue
                candidate="$candidate/$name"
                if [[ -f "$candidate" ]]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done < <(otool -l "$owner" | awk '$1 == "path" { print $2 }')

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

        name=$(basename "$resolved")
        destination="$output_dir/lib/$name"
        if [[ ! -e "$destination" ]]; then
            cp -L "$resolved" "$destination"
            chmod u+w "$destination"
            install_name_tool -id "@loader_path/$name" "$destination"
        fi

        if [[ "$current" == "$packaged_server" ]]; then
            replacement="@loader_path/../lib/$name"
        else
            replacement="@loader_path/$name"
        fi
        install_name_tool -change "$dependency" "$replacement" "$current" 2>/dev/null || true

        if ! contains_path "$destination" "${queue[@]-}" "${processed[@]-}"; then
            queue+=("$destination")
        fi
    done
done

# install_name_tool invalidates an existing signature. Re-sign the modified
# payload ad hoc so macOS does not kill the packaged process at load time.
for library in "$output_dir"/lib/*.dylib; do
    [[ -f "$library" ]] || continue
    codesign --force --sign - "$library" >/dev/null
done
codesign --force --sign - "$packaged_server" >/dev/null

printf 'Packaged macrdp-server at %s\n' "$output_dir"
printf 'Non-system dylibs: %s\n' "$(find "$output_dir/lib" -type f | wc -l | tr -d ' ')"
