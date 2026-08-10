#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
server="$repo_dir/build/macrdp-server"
output_dir=''
view_only=0
run_preflight=1
preflight_mode=direct
server_logs=()
server_log_count=0
aqua_label=''
aqua_plist=''

cleanup() {
    if [[ -n "$aqua_label" ]]; then
        launchctl bootout "gui/$(id -u)/$aqua_label" >/dev/null 2>&1 || true
    fi
    if [[ -n "$aqua_plist" ]]; then
        rm -f "$aqua_plist"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --server PATH       Exact macrdp-server executable to inspect.
  --output DIR        Create the diagnostic bundle at this new directory.
  --server-log PATH   Copy a server/client log into the bundle (repeatable).
  --view-only         Preflight Screen Recording without requiring Accessibility.
  --aqua-preflight    Run preflight through a temporary per-user Aqua LaunchAgent.
  --skip-preflight    Collect metadata without starting the capture preflight.
  -h, --help          Show this help.

The default output is a new owner-only directory under TMPDIR. Built-in probes
do not query hardware serial numbers, network addresses, credentials, or
keychain contents. Supplied logs are copied verbatim and can contain sensitive
data. Review the bundle before sharing it because logs, paths, and code-signing
metadata can contain local identifiers.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            [[ $# -ge 2 ]] || { printf '%s\n' '--server requires a path' >&2; exit 2; }
            server=$2
            shift 2
            ;;
        --server=*)
            server=${1#--server=}
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || { printf '%s\n' '--output requires a directory' >&2; exit 2; }
            output_dir=$2
            shift 2
            ;;
        --output=*)
            output_dir=${1#--output=}
            shift
            ;;
        --server-log)
            [[ $# -ge 2 ]] || { printf '%s\n' '--server-log requires a path' >&2; exit 2; }
            server_logs+=("$2")
            server_log_count=$((server_log_count + 1))
            shift 2
            ;;
        --server-log=*)
            server_logs+=("${1#--server-log=}")
            server_log_count=$((server_log_count + 1))
            shift
            ;;
        --view-only)
            view_only=1
            shift
            ;;
        --aqua-preflight)
            preflight_mode=aqua
            shift
            ;;
        --skip-preflight)
            run_preflight=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ $(uname -s) != Darwin ]]; then
    printf 'hardware diagnostics require macOS\n' >&2
    exit 1
fi
if [[ ! -x "$server" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server" >&2
    exit 1
fi
if [[ $server_log_count -gt 0 ]]; then
    for log_path in "${server_logs[@]}"; do
        if [[ ! -f "$log_path" ]]; then
            printf 'log file does not exist: %s\n' "$log_path" >&2
            exit 1
        fi
    done
fi

server=$(cd "$(dirname "$server")" && pwd -P)/$(basename "$server")
umask 077
if [[ -z "$output_dir" ]]; then
    output_dir=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-hardware-diagnostics.XXXXXX")
else
    mkdir -m 700 "$output_dir"
    output_dir=$(cd "$output_dir" && pwd -P)
fi

git_revision=unknown
git_dirty=unknown
if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_revision=$(git -C "$repo_dir" rev-parse HEAD)
    if [[ -n $(git -C "$repo_dir" status --porcelain) ]]; then
        git_dirty=true
    else
        git_dirty=false
    fi
fi

signature_verify_exit=127
{
    printf '%s\n' '== codesign verification =='
    set +e
    codesign --verify --deep --strict --verbose=2 "$server"
    signature_verify_exit=$?
    set -e
    printf '\n%s\n' '== code-signing details and designated requirement =='
    codesign -d --verbose=4 -r- "$server" || true
} >"$output_dir/signature.txt" 2>&1

preflight_exit=not-run
preflight_duration_seconds=not-run
if [[ $run_preflight -eq 1 ]]; then
    preflight_started_seconds=$(date '+%s')
    preflight_arguments=(--preflight --no-audio)
    if [[ $view_only -eq 1 ]]; then
        preflight_arguments+=(--view-only)
    fi
    if [[ $preflight_mode == direct ]]; then
        set +e
        "$server" "${preflight_arguments[@]}" \
            >"$output_dir/preflight.stdout.txt" \
            2>"$output_dir/preflight.stderr.txt"
        preflight_status=$?
        set -e
        preflight_exit=$preflight_status
    else
        aqua_label="io.github.macrdp.hardware-preflight.$PPID.$$"
        aqua_plist="${TMPDIR:-/tmp}/$aqua_label.plist"
        if [[ -e "$aqua_plist" ]]; then
            printf 'temporary Aqua plist already exists: %s\n' "$aqua_plist" \
                >"$output_dir/preflight.launchctl.txt"
            preflight_exit=launch-error
            aqua_label=''
            aqua_plist=''
        else
            plutil -create xml1 "$aqua_plist"
            plutil -insert Label -string "$aqua_label" "$aqua_plist"
            plutil -insert ProgramArguments -array "$aqua_plist"
            plutil -insert ProgramArguments.0 -string "$server" "$aqua_plist"
            argument_index=1
            for preflight_argument in "${preflight_arguments[@]}"; do
                plutil -insert "ProgramArguments.$argument_index" \
                    -string "$preflight_argument" "$aqua_plist"
                argument_index=$((argument_index + 1))
            done
            plutil -insert WorkingDirectory -string "$repo_dir" "$aqua_plist"
            plutil -insert RunAtLoad -bool true "$aqua_plist"
            plutil -insert ProcessType -string Interactive "$aqua_plist"
            plutil -insert LimitLoadToSessionType -string Aqua "$aqua_plist"
            plutil -insert StandardOutPath -string \
                "$output_dir/preflight.stdout.txt" "$aqua_plist"
            plutil -insert StandardErrorPath -string \
                "$output_dir/preflight.stderr.txt" "$aqua_plist"
            plutil -lint "$aqua_plist" >/dev/null

            gui_domain="gui/$(id -u)"
            if launchctl bootstrap "$gui_domain" "$aqua_plist" \
                2>"$output_dir/preflight.launchctl.txt"; then
                preflight_exit=timeout
                for ((attempt = 0; attempt < 60; ++attempt)); do
                    launch_state=$(launchctl print "$gui_domain/$aqua_label" 2>&1 || true)
                    if [[ $launch_state == *'state = not running'* ]]; then
                        if [[ $launch_state == *'last exit code ='* ]]; then
                            preflight_exit=$(awk '/last exit code =/ { print $5; exit }' \
                                <<<"$launch_state")
                            break
                        fi
                        if [[ $launch_state == *'last terminating signal ='* ]]; then
                            preflight_exit=signal-$(awk \
                                '/last terminating signal =/ { print $5; exit }' \
                                <<<"$launch_state")
                            break
                        fi
                    fi
                    sleep 0.5
                done
                if [[ $preflight_exit == timeout || $preflight_exit == signal-* ]]; then
                    printf '\n%s\n%s\n' '== final launch state ==' "$launch_state" \
                        >>"$output_dir/preflight.launchctl.txt"
                fi
            else
                preflight_exit=launch-error
            fi
            launchctl bootout "$gui_domain/$aqua_label" >/dev/null 2>&1 || true
            aqua_label=''
            rm -f "$aqua_plist"
            aqua_plist=''
        fi
    fi
    preflight_duration_seconds=$(($(date '+%s') - preflight_started_seconds))
fi

system_probe_exit=127
if command -v xcrun >/dev/null 2>&1; then
    set +e
    xcrun swift "$script_dir/macrdp_system_probe.swift" \
        >"$output_dir/system-probe.txt" \
        2>"$output_dir/system-probe.stderr.txt"
    system_probe_status=$?
    set -e
    system_probe_exit=$system_probe_status
else
    printf '%s\n' 'xcrun is unavailable' >"$output_dir/system-probe.stderr.txt"
fi

{
    printf '%s\n' '== executable =='
    file "$server" || true
    printf '\n%s\n' '== architectures =='
    lipo -info "$server" || true
    printf '\n%s\n' '== load commands =='
    otool -L "$server" || true
    printf '\n%s\n' '== minimum platform =='
    xcrun vtool -show-build "$server" || true
} >"$output_dir/binary.txt" 2>&1

{
    printf '%s\n' '== power configuration =='
    pmset -g || true
    printf '\n%s\n' '== assertions =='
    pmset -g assertions || true
} >"$output_dir/power.txt" 2>&1

log_index=0
if [[ $server_log_count -gt 0 ]]; then
    for log_path in "${server_logs[@]}"; do
        log_index=$((log_index + 1))
        cp "$log_path" "$output_dir/log-$log_index.txt"
        chmod 600 "$output_dir/log-$log_index.txt"
    done
fi

console_user_matches=false
console_user=$(stat -f '%Su' /dev/console 2>/dev/null || true)
if [[ -n "$console_user" && "$console_user" == "$(id -un)" ]]; then
    console_user_matches=true
fi

{
    printf 'schema_version=1\n'
    printf 'collected_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'git_revision=%s\n' "$git_revision"
    printf 'git_dirty=%s\n' "$git_dirty"
    printf 'macos_product_version=%s\n' "$(sw_vers -productVersion)"
    printf 'macos_build_version=%s\n' "$(sw_vers -buildVersion)"
    printf 'kernel_arch=%s\n' "$(uname -m)"
    printf 'hardware_model=%s\n' "$(sysctl -n hw.model 2>/dev/null || printf unknown)"
    printf 'cpu_brand=%s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)"
    printf 'memory_bytes=%s\n' "$(sysctl -n hw.memsize 2>/dev/null || printf unknown)"
    printf 'console_user_matches_collector=%s\n' "$console_user_matches"
    printf 'server_path=%s\n' "$server"
    printf 'server_sha256=%s\n' "$(shasum -a 256 "$server" | awk '{print $1}')"
    printf 'server_size_bytes=%s\n' "$(stat -f '%z' "$server")"
    printf 'signature_verify_exit=%s\n' "$signature_verify_exit"
    printf 'preflight_exit=%s\n' "$preflight_exit"
    printf 'preflight_duration_seconds=%s\n' "$preflight_duration_seconds"
    printf 'preflight_mode=%s\n' "$([[ $run_preflight -eq 1 ]] && printf %s "$preflight_mode" || printf skipped)"
    printf 'preflight_view_only=%s\n' "$([[ $view_only -eq 1 ]] && printf true || printf false)"
    printf 'system_probe_exit=%s\n' "$system_probe_exit"
    printf 'copied_log_count=%s\n' "$log_index"
} >"$output_dir/summary.txt"

(
    cd "$output_dir"
    manifest_files=()
    for file_path in *; do
        if [[ -f "$file_path" && "$file_path" != manifest.sha256 ]]; then
            manifest_files+=("$file_path")
        fi
    done
    shasum -a 256 "${manifest_files[@]}"
) >"$output_dir/manifest.sha256"

printf 'Hardware diagnostic bundle: %s\n' "$output_dir"
printf 'Exact-server preflight exit: %s\n' "$preflight_exit"
printf '%s\n' 'Review the owner-only bundle before sharing it.'
