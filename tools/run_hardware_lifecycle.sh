#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
server="$repo_dir/build/macrdp-server"
cycles=20
port=3395
startup_timeout=20
shutdown_timeout=10
output_dir=''
aqua_mode=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --server PATH              Exact macrdp-server executable to exercise.
  --cycles NUMBER            Start/stop cycles (default: 20).
  --port NUMBER              Dedicated loopback port (default: 3395).
  --startup-timeout SECONDS  Per-cycle listener timeout (default: 20).
  --shutdown-timeout SECONDS Per-cycle SIGTERM timeout (default: 10).
  --output DIR               Create evidence at this new directory.
  --aqua                     Run through a temporary per-user Aqua LaunchAgent.
  -h, --help                 Show this help.

The server runs view-only with clipboard and audio disabled. A random test
password is generated in memory for each harness run and is passed only through
MACRDP_PASSWORD. The owner-only evidence contains logs and modifier probes, but
not the password or generated server configuration.
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
        --cycles)
            [[ $# -ge 2 ]] || { printf '%s\n' '--cycles requires a number' >&2; exit 2; }
            cycles=$2
            shift 2
            ;;
        --cycles=*)
            cycles=${1#--cycles=}
            shift
            ;;
        --port)
            [[ $# -ge 2 ]] || { printf '%s\n' '--port requires a number' >&2; exit 2; }
            port=$2
            shift 2
            ;;
        --port=*)
            port=${1#--port=}
            shift
            ;;
        --startup-timeout)
            [[ $# -ge 2 ]] || { printf '%s\n' '--startup-timeout requires seconds' >&2; exit 2; }
            startup_timeout=$2
            shift 2
            ;;
        --startup-timeout=*)
            startup_timeout=${1#--startup-timeout=}
            shift
            ;;
        --shutdown-timeout)
            [[ $# -ge 2 ]] || { printf '%s\n' '--shutdown-timeout requires seconds' >&2; exit 2; }
            shutdown_timeout=$2
            shift 2
            ;;
        --shutdown-timeout=*)
            shutdown_timeout=${1#--shutdown-timeout=}
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
        --aqua)
            aqua_mode=1
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

require_positive_integer() {
    local name=$1
    local value=$2
    if [[ $value == *[!0-9]* || $value -lt 1 ]]; then
        printf '%s must be a positive integer: %s\n' "$name" "$value" >&2
        exit 2
    fi
}

require_positive_integer cycles "$cycles"
require_positive_integer port "$port"
require_positive_integer startup-timeout "$startup_timeout"
require_positive_integer shutdown-timeout "$shutdown_timeout"
if [[ $port -gt 65535 ]]; then
    printf 'port must be between 1 and 65535: %s\n' "$port" >&2
    exit 2
fi
if [[ $(uname -s) != Darwin ]]; then
    printf '%s\n' 'hardware lifecycle validation requires macOS' >&2
    exit 1
fi
if [[ ! -x "$server" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server" >&2
    exit 1
fi

server=$(cd "$(dirname "$server")" && pwd -P)/$(basename "$server")
probe="$script_dir/macrdp_system_probe.swift"
if [[ ! -x "$probe" ]]; then
    printf 'modifier probe is missing or not executable: %s\n' "$probe" >&2
    exit 1
fi
if ! codesign --verify --strict --verbose=2 "$server" >/dev/null 2>&1; then
    printf 'server signature verification failed: %s\n' "$server" >&2
    exit 1
fi
if [[ -n $(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true) ]]; then
    printf 'TCP port %s already has a listener:\n' "$port" >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    exit 1
fi
if [[ -n "$output_dir" && $output_dir != /* ]]; then
    output_dir="$(pwd -P)/$output_dir"
fi
if [[ -n "$output_dir" && -e "$output_dir" ]]; then
    printf 'output directory already exists: %s\n' "$output_dir" >&2
    exit 1
fi

run_through_aqua() {
    local launcher_root
    local label
    local plist
    local stdout_log
    local stderr_log
    local domain="gui/$(id -u)"
    local launch_state=''
    local lifecycle_exit=timeout
    local maximum_attempts
    local argument_index
    local argument
    local -a arguments

    umask 077
    launcher_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-lifecycle-launch.XXXXXX")
    if [[ -z "$output_dir" ]]; then
        output_dir="$launcher_root/evidence"
    fi
    label="io.github.macrdp.lifecycle.$PPID.$$"
    plist="$launcher_root/$label.plist"
    stdout_log="$launcher_root/launch-agent.stdout.log"
    stderr_log="$launcher_root/launch-agent.stderr.log"

    cleanup_aqua_launcher() {
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
        rm -f "$plist"
    }
    trap cleanup_aqua_launcher EXIT
    trap 'exit 130' INT TERM HUP

    plutil -create xml1 "$plist"
    plutil -insert Label -string "$label" "$plist"
    plutil -insert ProgramArguments -array "$plist"
    arguments=(
        /bin/bash
        "$script_dir/run_hardware_lifecycle.sh"
        --server "$server"
        --cycles "$cycles"
        --port "$port"
        --startup-timeout "$startup_timeout"
        --shutdown-timeout "$shutdown_timeout"
        --output "$output_dir"
    )
    argument_index=0
    for argument in "${arguments[@]}"; do
        plutil -insert "ProgramArguments.$argument_index" -string "$argument" "$plist"
        argument_index=$((argument_index + 1))
    done
    plutil -insert WorkingDirectory -string "$repo_dir" "$plist"
    plutil -insert RunAtLoad -bool true "$plist"
    plutil -insert ProcessType -string Interactive "$plist"
    plutil -insert LimitLoadToSessionType -string Aqua "$plist"
    plutil -insert StandardOutPath -string "$stdout_log" "$plist"
    plutil -insert StandardErrorPath -string "$stderr_log" "$plist"
    plutil -lint "$plist" >/dev/null

    if launchctl bootstrap "$domain" "$plist"; then
        maximum_attempts=$((cycles * (startup_timeout + shutdown_timeout + 10) * 2 + 120))
        for ((argument_index = 0; argument_index < maximum_attempts; ++argument_index)); do
            launch_state=$(launchctl print "$domain/$label" 2>&1 || true)
            if [[ $launch_state == *'state = not running'* ]]; then
                if [[ $launch_state == *'last exit code ='* ]]; then
                    lifecycle_exit=$(awk '/last exit code =/ { print $5; exit }' \
                        <<<"$launch_state")
                    break
                fi
                if [[ $launch_state == *'last terminating signal ='* ]]; then
                    lifecycle_exit=signal-$(awk \
                        '/last terminating signal =/ { print $5; exit }' \
                        <<<"$launch_state")
                    break
                fi
            fi
            sleep 0.5
        done
    else
        lifecycle_exit=launch-error
    fi

    cleanup_aqua_launcher
    trap - EXIT INT TERM HUP
    if [[ -d "$output_dir" ]]; then
        [[ ! -f "$stdout_log" ]] || mv "$stdout_log" "$output_dir/launch-agent.stdout.log"
        [[ ! -f "$stderr_log" ]] || mv "$stderr_log" "$output_dir/launch-agent.stderr.log"
        chmod 600 "$output_dir"/launch-agent.*.log 2>/dev/null || true
        [[ ! -f "$output_dir/launch-agent.stdout.log" ]] \
            || cat "$output_dir/launch-agent.stdout.log"
        if [[ -s "$output_dir/launch-agent.stderr.log" ]]; then
            printf '%s\n' '== lifecycle LaunchAgent stderr ==' >&2
            cat "$output_dir/launch-agent.stderr.log" >&2
        fi
        printf 'Lifecycle evidence: %s\n' "$output_dir"
    else
        printf 'lifecycle LaunchAgent did not create evidence; launcher logs: %s\n' \
            "$launcher_root" >&2
    fi
    rmdir "$launcher_root" >/dev/null 2>&1 || true
    printf 'Aqua lifecycle exit: %s\n' "$lifecycle_exit"

    case "$lifecycle_exit" in
        timeout) return 124 ;;
        launch-error|signal-*) return 1 ;;
        *) return "$lifecycle_exit" ;;
    esac
}

if [[ $aqua_mode -eq 1 ]]; then
    run_through_aqua
    exit $?
fi

umask 077
if [[ -z "$output_dir" ]]; then
    output_dir=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-hardware-lifecycle.XXXXXX")
else
    mkdir -m 700 "$output_dir"
fi
output_dir=$(cd "$output_dir" && pwd -P)
summary="$output_dir/summary.txt"
config_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-lifecycle-config.XXXXXX")
server_hash=$(shasum -a 256 "$server" | awk '{ print $1 }')
lifecycle_password=$(LC_ALL=C od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
active_pid=''
cycles_completed=0
maximum_startup_seconds=0
maximum_shutdown_seconds=0
result=FAIL
failure_reason=aborted

if [[ -z "$lifecycle_password" ]]; then
    printf '%s\n' 'unable to generate the ephemeral lifecycle password' >&2
    exit 1
fi

listener_owned_by() {
    local expected_pid=$1
    lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null \
        | awk -v expected="$expected_pid" \
            '$1 == expected { found = 1 } END { exit found ? 0 : 1 }'
}

stop_active_server() {
    local attempt
    if [[ -z "$active_pid" ]]; then
        return
    fi
    if kill -0 "$active_pid" >/dev/null 2>&1; then
        kill -TERM "$active_pid" >/dev/null 2>&1 || true
        for ((attempt = 0; attempt < shutdown_timeout * 10; ++attempt)); do
            if ! kill -0 "$active_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi
    if kill -0 "$active_pid" >/dev/null 2>&1; then
        printf 'forcing cleanup of lifecycle server pid %s\n' "$active_pid" \
            >>"$output_dir/cleanup.log"
        kill -KILL "$active_pid" >/dev/null 2>&1 || true
    fi
    wait "$active_pid" >/dev/null 2>&1 || true
    active_pid=''
}

finalize() {
    local exit_status=$?
    local final_hash=missing
    trap - EXIT INT TERM HUP
    stop_active_server
    lifecycle_password=''
    unset lifecycle_password
    rm -rf -- "$config_root"
    if [[ -f "$server" ]]; then
        final_hash=$(shasum -a 256 "$server" | awk '{ print $1 }')
    fi
    if [[ $exit_status -ne 0 || $result != PASS ]]; then
        result=FAIL
    fi
    {
        printf 'cycles_completed=%s\n' "$cycles_completed"
        printf 'maximum_startup_seconds=%s\n' "$maximum_startup_seconds"
        printf 'maximum_shutdown_seconds=%s\n' "$maximum_shutdown_seconds"
        printf 'server_sha256_after=%s\n' "$final_hash"
        printf 'server_unchanged=%s\n' "$([[ $final_hash == "$server_hash" ]] && printf true || printf false)"
        printf 'finished_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'result=%s\n' "$result"
        printf 'failure_reason=%s\n' "$failure_reason"
    } >>"$summary"
    chmod 600 "$summary"
    printf 'Lifecycle result: %s (%s/%s cycles)\n' \
        "$result" "$cycles_completed" "$cycles"
    printf 'Lifecycle evidence: %s\n' "$output_dir"
}
trap finalize EXIT
trap 'failure_reason=interrupted; exit 130' INT TERM HUP

fail() {
    failure_reason=$1
    printf 'lifecycle validation failed: %s\n' "$1" >&2
    exit 1
}

check_modifier_probe() {
    local output_path=$1
    local modifier_flags
    local modifier_key_count
    local invalid_modifier_keys
    if ! "$probe" >"$output_path" 2>"$output_path.stderr"; then
        fail modifier-probe-execution
    fi
    modifier_flags=$(awk -F= '$1 == "modifier_flags" { print $2; exit }' "$output_path")
    modifier_key_count=$(awk -F= '$1 ~ /^key_.*_down$/ { count++ } END { print count + 0 }' \
        "$output_path")
    invalid_modifier_keys=$(awk -F= \
        '$1 ~ /^key_.*_down$/ && $2 != "false" { print $1 "=" $2 }' \
        "$output_path")
    printf 'modifier probe: flags=%s keys=%s\n' \
        "${modifier_flags:-missing}" "$modifier_key_count"
    if [[ $modifier_flags != 0x0000000000000000 \
        || $modifier_key_count -lt 1 || -n "$invalid_modifier_keys" ]]; then
        cat "$output_path" >&2
        fail active-modifier-state
    fi
}

wait_for_ready() {
    local pid=$1
    local log_path=$2
    local attempt
    for ((attempt = 0; attempt < startup_timeout * 10; ++attempt)); do
        if grep -q 'macrdp-server listening on port' "$log_path"; then
            if listener_owned_by "$pid"; then
                return 0
            fi
        fi
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            return 1
        fi
        sleep 0.1
    done
    return 1
}

{
    printf 'schema_version=1\n'
    printf 'started_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'server_path=%s\n' "$server"
    printf 'server_sha256_before=%s\n' "$server_hash"
    printf 'cycles_requested=%s\n' "$cycles"
    printf 'port=%s\n' "$port"
    printf 'startup_timeout_seconds=%s\n' "$startup_timeout"
    printf 'shutdown_timeout_seconds=%s\n' "$shutdown_timeout"
    printf 'access_policy=view-only,no-clipboard,no-audio\n'
} >"$summary"

check_modifier_probe "$output_dir/pre-run-system-probe.txt"

for ((cycle = 1; cycle <= cycles; ++cycle)); do
    cycle_name=$(printf '%02d' "$cycle")
    cycle_config="$config_root/cycle-$cycle_name"
    cycle_log="$output_dir/cycle-$cycle_name-server.log"
    cycle_probe="$output_dir/cycle-$cycle_name-system-probe.txt"
    mkdir -m 700 "$cycle_config"
    startup_started=$(date '+%s')
    MACRDP_PASSWORD="$lifecycle_password" "$server" \
        --port "$port" \
        --bind-address 127.0.0.1 \
        --user macrdp-lifecycle \
        --config-dir "$cycle_config" \
        --log-level INFO \
        --view-only \
        --no-clipboard \
        --no-audio \
        >"$cycle_log" 2>&1 &
    active_pid=$!

    if ! wait_for_ready "$active_pid" "$cycle_log"; then
        tail -n 40 "$cycle_log" >&2 || true
        fail "cycle-$cycle_name-startup"
    fi
    startup_elapsed=$(($(date '+%s') - startup_started))
    if [[ $startup_elapsed -gt $maximum_startup_seconds ]]; then
        maximum_startup_seconds=$startup_elapsed
    fi

    shutdown_started=$(date '+%s')
    if ! kill -TERM "$active_pid" >/dev/null 2>&1; then
        fail "cycle-$cycle_name-sigterm"
    fi
    stopped=0
    for ((attempt = 0; attempt < shutdown_timeout * 10; ++attempt)); do
        if ! kill -0 "$active_pid" >/dev/null 2>&1; then
            stopped=1
            break
        fi
        sleep 0.1
    done
    if [[ $stopped -ne 1 ]]; then
        fail "cycle-$cycle_name-shutdown-timeout"
    fi
    if wait "$active_pid"; then
        server_exit=0
    else
        server_exit=$?
    fi
    active_pid=''
    shutdown_elapsed=$(($(date '+%s') - shutdown_started))
    if [[ $shutdown_elapsed -gt $maximum_shutdown_seconds ]]; then
        maximum_shutdown_seconds=$shutdown_elapsed
    fi
    if [[ $server_exit -ne 0 ]]; then
        fail "cycle-$cycle_name-exit-$server_exit"
    fi
    if [[ -n $(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true) ]]; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
        fail "cycle-$cycle_name-listener-remained"
    fi

    check_modifier_probe "$cycle_probe"
    cycles_completed=$cycle
    {
        printf 'cycle_%s_startup_seconds=%s\n' "$cycle_name" "$startup_elapsed"
        printf 'cycle_%s_shutdown_seconds=%s\n' "$cycle_name" "$shutdown_elapsed"
        printf 'cycle_%s_exit=%s\n' "$cycle_name" "$server_exit"
        printf 'cycle_%s_modifier_state=clear\n' "$cycle_name"
    } >>"$summary"
    printf 'cycle %s/%s: PASS (startup=%ss shutdown=%ss)\n' \
        "$cycle" "$cycles" "$startup_elapsed" "$shutdown_elapsed"
done

cp "$output_dir/cycle-$(printf '%02d' "$cycles")-system-probe.txt" \
    "$output_dir/post-run-system-probe.txt"
final_server_hash=$(shasum -a 256 "$server" | awk '{ print $1 }')
if [[ $final_server_hash != "$server_hash" ]]; then
    fail server-binary-changed
fi
result=PASS
failure_reason=none
