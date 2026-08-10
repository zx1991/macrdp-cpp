#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    printf 'usage: %s <macrdp-server> <user> <password-file> [port] [config-dir] [-- server-options...]\n' "$0" >&2
    exit 2
fi

server_input=$1
username=$2
password_file_input=$3
shift 3

port=3389
config_dir_input="$HOME/Library/Application Support/macrdp-cpp"
if [[ $# -gt 0 && $1 != '--' ]]; then
    port=$1
    shift
fi
if [[ $# -gt 0 && $1 != '--' ]]; then
    config_dir_input=$1
    shift
fi
if [[ $# -gt 0 ]]; then
    if [[ $1 != '--' ]]; then
        printf 'server options must follow --\n' >&2
        exit 2
    fi
    shift
fi
label=${MACRDP_LAUNCH_AGENT_LABEL:-com.macrdp.cpp.server}

if [[ ! -x "$server_input" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server_input" >&2
    exit 1
fi
if [[ -z $username ]]; then
    printf 'user must not be empty\n' >&2
    exit 2
fi
if [[ ! $port =~ ^[1-9][0-9]*$ ]] || (( port > 65535 )); then
    printf 'invalid RDP port: %s\n' "$port" >&2
    exit 2
fi
if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'invalid LaunchAgent label: %s\n' "$label" >&2
    exit 2
fi
if [[ ! -f "$password_file_input" || -L "$password_file_input" ]]; then
    printf 'password file must be a regular file, not a symbolic link: %s\n' \
        "$password_file_input" >&2
    exit 1
fi
if ! command -v plutil >/dev/null 2>&1 || ! command -v launchctl >/dev/null 2>&1 \
    || ! command -v ruby >/dev/null 2>&1 || ! command -v stat >/dev/null 2>&1; then
    printf 'plutil, launchctl, Ruby, and stat are required on macOS\n' >&2
    exit 1
fi

if [[ ${MACRDP_PRESERVE_SERVER_PATH:-0} == 1 ]]; then
    server=$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$server_input")
else
    server=$(cd "$(dirname "$server_input")" && pwd -P)/$(basename "$server_input")
fi
password_file=$(cd "$(dirname "$password_file_input")" && pwd -P)/$(basename "$password_file_input")
if [[ -L $config_dir_input ]]; then
    printf 'config directory must not be a symbolic link: %s\n' "$config_dir_input" >&2
    exit 1
fi
mkdir -p "$config_dir_input"
config_dir=$(cd "$(dirname "$config_dir_input")" && pwd -P)/$(basename "$config_dir_input")
current_uid=$(id -u)
password_uid=$(stat -f '%u' "$password_file")
password_mode=$(stat -f '%Lp' "$password_file")
password_mode_value=$((8#$password_mode))
password_directory=$(dirname "$password_file")
password_directory_uid=$(stat -f '%u' "$password_directory")
password_directory_mode=$(stat -f '%Lp' "$password_directory")
password_directory_mode_value=$((8#$password_directory_mode))
if [[ $password_uid != "$current_uid" ]] || (( (password_mode_value & 8#077) != 0 )); then
    printf 'password file must be owned by the current user and private: %s\n' \
        "$password_file" >&2
    exit 1
fi
if [[ $password_directory_uid != "$current_uid" ]] \
    || (( (password_directory_mode_value & 8#022) != 0 )); then
    printf 'password directory must be owned by the current user and not writable by others: %s\n' \
        "$password_directory" >&2
    exit 1
fi
if ! ruby -e '
  value = File.binread(ARGV.fetch(0))
  exit 1 if value.bytesize > 4096
  if value.end_with?("\n")
    value = value.byteslice(0, value.bytesize - 1)
    value = value.byteslice(0, value.bytesize - 1) if value.end_with?("\r")
  end
  exit 1 if value.empty? || value.include?("\r") || value.include?("\n") || value.include?("\0")
' "$password_file"; then
    printf 'password file must contain one non-empty password line of at most 4096 bytes: %s\n' \
        "$password_file" >&2
    exit 1
fi
chmod 700 "$config_dir"

launch_agents_dir=${MACRDP_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}
log_dir=${MACRDP_LOG_DIR:-"$HOME/Library/Logs/macrdp-cpp"}
plist="$launch_agents_dir/$label.plist"

mkdir -p "$launch_agents_dir" "$log_dir"
chmod 700 "$launch_agents_dir" "$log_dir"

temporary_plist=$(mktemp "${TMPDIR:-/tmp}/macrdp-launch-agent.XXXXXX")
temporary_destination=''
cleanup() {
    rm -f "$temporary_plist"
    if [[ -n $temporary_destination ]]; then
        rm -f "$temporary_destination"
    fi
}
trap cleanup EXIT

plutil -create xml1 "$temporary_plist"
plutil -insert Label -string "$label" "$temporary_plist"
plutil -insert ProgramArguments -array "$temporary_plist"
plutil -insert ProgramArguments.0 -string "$server" "$temporary_plist"
plutil -insert ProgramArguments.1 -string '--port' "$temporary_plist"
plutil -insert ProgramArguments.2 -string "$port" "$temporary_plist"
plutil -insert ProgramArguments.3 -string '--user' "$temporary_plist"
plutil -insert ProgramArguments.4 -string "$username" "$temporary_plist"
plutil -insert ProgramArguments.5 -string '--password-file' "$temporary_plist"
plutil -insert ProgramArguments.6 -string "$password_file" "$temporary_plist"
plutil -insert ProgramArguments.7 -string '--config-dir' "$temporary_plist"
plutil -insert ProgramArguments.8 -string "$config_dir" "$temporary_plist"
argument_index=9
view_only=0
if [[ $# -gt 0 ]]; then
    for server_option in "$@"; do
        plutil -insert "ProgramArguments.$argument_index" -string "$server_option" "$temporary_plist"
        if [[ $server_option == '--view-only' ]]; then
            view_only=1
        fi
        argument_index=$((argument_index + 1))
    done
fi
plutil -insert RunAtLoad -bool true "$temporary_plist"
plutil -insert KeepAlive -bool true "$temporary_plist"
plutil -insert ProcessType -string Interactive "$temporary_plist"
plutil -insert ThrottleInterval -integer 5 "$temporary_plist"
plutil -insert LimitLoadToSessionType -string Aqua "$temporary_plist"
plutil -insert StandardOutPath -string "$log_dir/server.log" "$temporary_plist"
plutil -insert StandardErrorPath -string "$log_dir/server.error.log" "$temporary_plist"
plutil -lint "$temporary_plist" >/dev/null

temporary_destination="$launch_agents_dir/.$label.plist.$$"
install -m 600 "$temporary_plist" "$temporary_destination"
mv -f "$temporary_destination" "$plist"
temporary_destination=''

gui_domain="gui/$current_uid"
launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
launchctl bootstrap "$gui_domain" "$plist"
launchctl enable "$gui_domain/$label"
launchctl kickstart -k "$gui_domain/$label"

printf 'Installed and started %s\n' "$label"
printf 'Plist: %s\n' "$plist"
printf 'Logs: %s\n' "$log_dir"
if [[ $view_only -eq 1 ]]; then
    printf 'Grant Screen Recording to this exact server executable before connecting.\n'
else
    printf 'Grant Screen Recording and Accessibility to this exact server executable before connecting.\n'
fi
