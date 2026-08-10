#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    printf 'usage: %s <password-file> [--stdin] [--label <launch-agent-label>]\n' "$0" >&2
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

password_file_input=$1
shift

label='com.macrdp.cpp.server'
read_from_stdin=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --stdin)
            read_from_stdin=1
            shift
            ;;
        --label)
            if [[ $# -lt 2 || -z $2 ]]; then
                usage
                exit 2
            fi
            label=$2
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'invalid LaunchAgent label: %s\n' "$label" >&2
    exit 2
fi
if [[ ! -f $password_file_input || -L $password_file_input ]]; then
    printf 'password file must be an existing regular file, not a symbolic link: %s\n' \
        "$password_file_input" >&2
    exit 1
fi
if ! command -v stat >/dev/null 2>&1 || ! command -v launchctl >/dev/null 2>&1 \
    || [[ ! -x /usr/libexec/PlistBuddy ]]; then
    printf 'stat, launchctl, and PlistBuddy are required on macOS\n' >&2
    exit 1
fi

password_file=$(cd "$(dirname "$password_file_input")" && pwd -P)/$(
    basename "$password_file_input")
password_directory=$(dirname "$password_file")
file_uid=$(stat -f '%u' "$password_file")
file_mode=$(stat -f '%Lp' "$password_file")
current_uid=$(id -u)
directory_uid=$(stat -f '%u' "$password_directory")
directory_mode=$(stat -f '%Lp' "$password_directory")

if [[ $file_uid != "$current_uid" ]]; then
    printf 'password file must be owned by the current user: %s\n' "$password_file" >&2
    exit 1
fi
file_mode_value=$((8#$file_mode))
if (( (file_mode_value & 8#077) != 0 )); then
    printf 'password file must not grant group or other permissions: %s\n' \
        "$password_file" >&2
    exit 1
fi
directory_mode_value=$((8#$directory_mode))
if [[ $directory_uid != "$current_uid" ]] || (( (directory_mode_value & 8#022) != 0 )); then
    printf 'password directory must be owned by the current user and not writable by others: %s\n' \
        "$password_directory" >&2
    exit 1
fi

gui_domain="gui/$current_uid"
service="$gui_domain/$label"
launch_agents_dir=${MACRDP_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}
plist="$launch_agents_dir/$label.plist"
if [[ ! -f $plist || -L $plist ]]; then
    printf 'LaunchAgent plist is missing or is a symbolic link: %s\n' "$plist" >&2
    exit 1
fi

configured_password_file=''
password_file_argument_count=0
argument_index=0
previous_argument=''
while argument=$(/usr/libexec/PlistBuddy \
    -c "Print :ProgramArguments:$argument_index" "$plist" 2>/dev/null); do
    if [[ $previous_argument == '--password-file' ]]; then
        configured_password_file=$argument
        password_file_argument_count=$((password_file_argument_count + 1))
    fi
    previous_argument=$argument
    argument_index=$((argument_index + 1))
done
if [[ $password_file_argument_count -ne 1 || -z $configured_password_file ]]; then
    printf 'LaunchAgent must contain exactly one --password-file argument: %s\n' "$plist" >&2
    exit 1
fi
if [[ ! -f $configured_password_file || -L $configured_password_file ]]; then
    printf 'configured LaunchAgent password file is invalid: %s\n' \
        "$configured_password_file" >&2
    exit 1
fi
configured_password_file=$(cd "$(dirname "$configured_password_file")" && pwd -P)/$(
    basename "$configured_password_file")
if [[ $configured_password_file != "$password_file" ]]; then
    printf 'LaunchAgent %s reads a different password file: %s\n' \
        "$label" "$configured_password_file" >&2
    exit 1
fi

if ! service_description=$(launchctl print "$service" 2>/dev/null); then
    printf 'LaunchAgent is not loaded: %s\n' "$service" >&2
    exit 1
fi
if [[ $service_description != *"$password_file"* ]]; then
    printf 'loaded LaunchAgent does not report the configured password file: %s\n' \
        "$password_file" >&2
    exit 1
fi

new_password=''
confirmation=''
if [[ $read_from_stdin -eq 1 ]]; then
    if ! IFS= read -r new_password && [[ -z $new_password ]]; then
        printf 'unable to read the new password from stdin\n' >&2
        exit 1
    fi
    if IFS= read -r confirmation; then
        new_password=''
        confirmation=''
        printf 'stdin must contain exactly one password line\n' >&2
        exit 1
    fi
else
    if [[ ! -t 0 ]]; then
        printf 'interactive input requires a terminal; use --stdin for a pipeline\n' >&2
        exit 1
    fi
    printf 'New RDP password: ' >&2
    IFS= read -r -s new_password
    printf '\nConfirm new RDP password: ' >&2
    IFS= read -r -s confirmation
    printf '\n' >&2
    if [[ $new_password != "$confirmation" ]]; then
        new_password=''
        confirmation=''
        printf 'passwords do not match\n' >&2
        exit 1
    fi
fi
confirmation=''

if [[ -z $new_password ]]; then
    printf 'the new password must not be empty\n' >&2
    exit 1
fi
if (( ${#new_password} > 4096 )); then
    new_password=''
    printf 'the new password must not exceed 4096 bytes\n' >&2
    exit 1
fi
if [[ $new_password == *$'\r'* || $new_password == *$'\n'* ]]; then
    new_password=''
    printf 'the new password must contain exactly one line\n' >&2
    exit 1
fi

umask 077
temporary_password=$(mktemp "$password_directory/.macrdp-password.XXXXXX")
cleanup() {
    new_password=''
    confirmation=''
    if [[ -n ${temporary_password:-} ]]; then
        rm -f "$temporary_password"
    fi
}
trap cleanup EXIT

printf '%s\n' "$new_password" > "$temporary_password"
new_password=''
chmod 600 "$temporary_password"
mv -f "$temporary_password" "$password_file"
temporary_password=''

if ! launchctl kickstart -k "$service"; then
    printf 'password was replaced, but the LaunchAgent could not be restarted: %s\n' \
        "$service" >&2
    exit 1
fi

printf 'Rotated the RDP password and restarted %s\n' "$label"
printf 'Password file: %s\n' "$password_file"
printf 'Existing sessions were terminated; verify a new connection with the new password.\n'
