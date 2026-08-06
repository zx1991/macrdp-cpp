#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
    printf 'usage: %s <macrdp-server> <user> <password-file> [port] [config-dir]\n' "$0" >&2
    exit 2
fi

server_input=$1
username=$2
password_file_input=$3
port=${4:-3389}
config_dir_input=${5:-"$HOME/Library/Application Support/macrdp-cpp"}
label='com.macrdp.cpp.server'

if [[ ! -x "$server_input" ]]; then
    printf 'server executable is missing or not executable: %s\n' "$server_input" >&2
    exit 1
fi
if [[ ! -f "$password_file_input" ]]; then
    printf 'password file is missing: %s\n' "$password_file_input" >&2
    exit 1
fi
if ! command -v plutil >/dev/null 2>&1 || ! command -v launchctl >/dev/null 2>&1; then
    printf 'plutil and launchctl are required on macOS\n' >&2
    exit 1
fi

server=$(cd "$(dirname "$server_input")" && pwd -P)/$(basename "$server_input")
password_file=$(cd "$(dirname "$password_file_input")" && pwd -P)/$(basename "$password_file_input")
config_dir=$(cd "$(dirname "$config_dir_input")" && pwd -P)/$(basename "$config_dir_input")
launch_agents_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/macrdp-cpp"
plist="$launch_agents_dir/$label.plist"

mkdir -p "$launch_agents_dir" "$log_dir"
chmod 700 "$log_dir"

temporary_plist=$(mktemp "${TMPDIR:-/tmp}/macrdp-launch-agent.XXXXXX")
cleanup() {
    rm -f "$temporary_plist"
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
plutil -insert RunAtLoad -bool true "$temporary_plist"
plutil -insert KeepAlive -bool true "$temporary_plist"
plutil -insert ProcessType -string Interactive "$temporary_plist"
plutil -insert ThrottleInterval -integer 5 "$temporary_plist"
plutil -insert LimitLoadToSessionType -string Aqua "$temporary_plist"
plutil -insert StandardOutPath -string "$log_dir/server.log" "$temporary_plist"
plutil -insert StandardErrorPath -string "$log_dir/server.error.log" "$temporary_plist"
plutil -lint "$temporary_plist" >/dev/null

install -m 600 "$temporary_plist" "$plist"

gui_domain="gui/$(id -u)"
launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
launchctl bootstrap "$gui_domain" "$plist"
launchctl enable "$gui_domain/$label"
launchctl kickstart -k "$gui_domain/$label"

printf 'Installed and started %s\n' "$label"
printf 'Plist: %s\n' "$plist"
printf 'Logs: %s\n' "$log_dir"
printf 'Grant Screen Recording and Accessibility to this exact server executable before connecting.\n'
