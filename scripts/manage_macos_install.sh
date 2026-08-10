#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

label='com.macrdp.cpp.server'
install_root_input=${MACRDP_INSTALL_ROOT:-"$HOME/Library/Application Support/macrdp-cpp"}
package_input=''
username=''
password_file=''
port=3389
port_set=0
config_dir_input=''
purge_state=0
server_options=()

usage() {
    cat >&2 <<EOF
usage:
  $0 install --package <directory> --user <name> --password-file <path> [options] [-- server-options...]
  $0 upgrade --package <directory> [--root <directory>] [--label <label>]
  $0 rollback [--root <directory>] [--label <label>]
  $0 status [--root <directory>] [--label <label>]
  $0 uninstall [--root <directory>] [--label <label>] [--purge-state]

install options:
  --port <number>       RDP port (default: 3389)
  --config-dir <path>   Persistent certificate/configuration directory
  --root <directory>    Versioned installation root
  --label <label>       Per-user LaunchAgent label
EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi
command_name=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --package)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            package_input=$2
            shift 2
            ;;
        --user)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            username=$2
            shift 2
            ;;
        --password-file)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            password_file=$2
            shift 2
            ;;
        --port)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            port=$2
            port_set=1
            shift 2
            ;;
        --config-dir)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            config_dir_input=$2
            shift 2
            ;;
        --root)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            install_root_input=$2
            shift 2
            ;;
        --label)
            [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
            label=$2
            shift 2
            ;;
        --purge-state)
            purge_state=1
            shift
            ;;
        --)
            shift
            server_options=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case $command_name in
    install|upgrade|rollback|status|uninstall) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'invalid LaunchAgent label: %s\n' "$label" >&2
    exit 2
fi
if [[ ! $port =~ ^[1-9][0-9]*$ ]] || (( port > 65535 )); then
    printf 'invalid RDP port: %s\n' "$port" >&2
    exit 2
fi
if [[ $command_name != install && ${#server_options[@]} -gt 0 ]]; then
    printf 'server options are valid only for install\n' >&2
    exit 2
fi
if [[ $command_name != uninstall && $purge_state -eq 1 ]]; then
    printf '%s does not accept --purge-state\n' "$command_name" >&2
    exit 2
fi
case $command_name in
    install)
        [[ -n $package_input && -n $username && -n $password_file ]] \
            || { usage; exit 2; }
        ;;
    upgrade)
        if [[ -z $package_input || -n $username || -n $password_file \
              || -n $config_dir_input || $port_set -eq 1 ]]; then
            usage
            exit 2
        fi
        ;;
    rollback|status|uninstall)
        if [[ -n $package_input || -n $username || -n $password_file \
              || -n $config_dir_input || $port_set -eq 1 ]]; then
            usage
            exit 2
        fi
        ;;
esac

for command in ruby shasum stat find mv ln launchctl codesign; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf '%s is required to manage the macrdp installation\n' "$command" >&2
        exit 1
    fi
done
if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    printf 'PlistBuddy is required to manage the macrdp LaunchAgent\n' >&2
    exit 1
fi

absolute_path() {
    ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$1"
}

install_root=$(absolute_path "$install_root_input")
home_root=$(absolute_path "$HOME")
case $install_root in
    /|"$home_root"|"$home_root/Library"|"$home_root/Library/Application Support")
        printf 'refusing unsafe installation root: %s\n' "$install_root" >&2
        exit 1
        ;;
esac
if [[ -L $install_root ]]; then
    printf 'installation root must not be a symbolic link: %s\n' "$install_root" >&2
    exit 1
fi

marker="$install_root/.macrdp-install-root"
releases_dir="$install_root/releases"
current_link="$install_root/current"
previous_link="$install_root/previous"
launch_agents_dir=${MACRDP_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}
default_log_dir="$HOME/Library/Logs/macrdp-cpp"
log_dir=${MACRDP_LOG_DIR:-"$default_log_dir"}
plist="$launch_agents_dir/$label.plist"
current_uid=$(id -u)
gui_domain="gui/$current_uid"
service="$gui_domain/$label"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

find_companion() {
    local packaged_name=$1
    local source_name=$2
    if [[ -x $script_dir/$packaged_name ]]; then
        printf '%s\n' "$script_dir/$packaged_name"
    elif [[ -x $script_dir/$source_name ]]; then
        printf '%s\n' "$script_dir/$source_name"
    else
        return 1
    fi
}

verifier=$(find_companion macrdp-verify-package verify_macos_package.rb || true)
launch_agent_installer=$(
    find_companion macrdp-install-launch-agent install_launch_agent.sh || true)

require_marker() {
    if [[ ! -f $marker || -L $marker || $(<"$marker") != 'schema=1' ]]; then
        printf 'macrdp installation marker is missing or invalid: %s\n' "$marker" >&2
        exit 1
    fi
    if [[ ! -d $install_root || $(stat -f '%u' "$install_root") != "$current_uid" ]]; then
        printf 'installation root must be a directory owned by the current user: %s\n' \
            "$install_root" >&2
        exit 1
    fi
    for managed_directory in "$releases_dir" "$install_root/state"; do
        if [[ -L $managed_directory ]]; then
            printf 'managed installation directory must not be a symbolic link: %s\n' \
                "$managed_directory" >&2
            exit 1
        fi
    done
}

ensure_install_root() {
    if [[ -L $install_root ]]; then
        printf 'installation root must not be a symbolic link: %s\n' "$install_root" >&2
        exit 1
    fi
    for managed_directory in "$releases_dir" "$install_root/state"; do
        if [[ -L $managed_directory ]]; then
            printf 'managed installation directory must not be a symbolic link: %s\n' \
                "$managed_directory" >&2
            exit 1
        fi
    done
    mkdir -p "$install_root" "$releases_dir" "$install_root/state"
    chmod 700 "$install_root" "$releases_dir" "$install_root/state"
    for managed_directory in "$install_root" "$releases_dir" "$install_root/state"; do
        if [[ $(stat -f '%u' "$managed_directory") != "$current_uid" ]]; then
            printf 'managed installation directory is not owned by the current user: %s\n' \
                "$managed_directory" >&2
            exit 1
        fi
    done
    if [[ -e $marker && ( ! -f $marker || -L $marker || $(<"$marker") != 'schema=1' ) ]]; then
        printf 'installation root marker is invalid: %s\n' "$marker" >&2
        exit 1
    fi
    if [[ ! -e $marker ]]; then
        if [[ -e $current_link || -L $current_link \
              || -e $previous_link || -L $previous_link \
              || -n $(find "$releases_dir" -mindepth 1 -print -quit) ]]; then
            printf 'installation root contains unmanaged release state: %s\n' "$install_root" >&2
            exit 1
        fi
        umask 077
        printf 'schema=1\n' > "$marker"
        chmod 600 "$marker"
    fi
}

validate_managed_plist() {
    local program
    if [[ ! -f $plist || -L $plist ]]; then
        printf 'LaunchAgent plist is missing or invalid: %s\n' "$plist" >&2
        return 1
    fi
    program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null || true)
    if [[ $program != "$current_link/bin/macrdp-server" ]]; then
        printf 'LaunchAgent does not belong to this installation: %s\n' "$plist" >&2
        return 1
    fi
}

link_release_id() {
    local link=$1
    local target
    [[ -L $link ]] || return 1
    target=$(readlink "$link")
    case $target in
        releases/*)
            target=${target#releases/}
            [[ -n $target && $target != */* && -d $releases_dir/$target \
                && ! -L $releases_dir/$target ]] || return 1
            printf '%s\n' "$target"
            ;;
        *) return 1 ;;
    esac
}

replace_release_link() {
    local name=$1
    local release_id=$2
    local link="$install_root/$name"
    local temporary="$install_root/.$name.$$.tmp"
    rm -f "$temporary"
    ln -s "releases/$release_id" "$temporary"
    ruby -e 'File.rename(ARGV.fetch(0), ARGV.fetch(1))' "$temporary" "$link"
}

restore_link() {
    local name=$1
    local release_id=$2
    local link="$install_root/$name"
    if [[ -n $release_id ]]; then
        replace_release_link "$name" "$release_id"
    else
        rm -f "$link"
    fi
}

remove_tree() {
    local path=$1
    [[ -e $path || -L $path ]] || return 0
    find "$path" -depth -delete
}

verify_signatures() {
    local package=$1
    local file
    # macOS Bash clears errexit inside command substitutions, so these
    # functions must propagate every failure explicitly.
    codesign --verify --strict "$package/bin/macrdp-server" || return 1
    for file in "$package"/lib/*.dylib; do
        [[ -f $file ]] || continue
        codesign --verify --strict "$file" || return 1
    done
}

verify_package() {
    local package=$1
    [[ -n $verifier ]] || {
        printf 'macrdp package verifier is unavailable next to %s\n' "$0" >&2
        return 1
    }
    "$verifier" "$package" || return 1
    verify_signatures "$package" || return 1
}

stage_release() {
    local package=$1
    local verification=$2
    local version sbom_hash release_id destination staging
    version=$(printf '%s\n' "$verification" | awk -F= '$1 == "version" { print $2 }')
    sbom_hash=$(printf '%s\n' "$verification" | awk -F= '$1 == "sbom_sha256" { print $2 }')
    if [[ -z $version || ! $sbom_hash =~ ^[0-9a-f]{64}$ ]]; then
        printf 'package verifier returned invalid release metadata\n' >&2
        return 1
    fi
    release_id="$version-${sbom_hash:0:16}"
    destination="$releases_dir/$release_id"
    if [[ -e $destination || -L $destination ]]; then
        verify_package "$destination" >/dev/null || return 1
        printf '%s\n' "$release_id"
        return 0
    fi

    staging="$releases_dir/.staging-$release_id-$$"
    remove_tree "$staging" || return 1
    mkdir -p "$staging" || return 1
    if command -v ditto >/dev/null 2>&1; then
        if ! ditto "$package" "$staging"; then
            remove_tree "$staging" || true
            return 1
        fi
    else
        if ! cp -R "$package"/. "$staging"/; then
            remove_tree "$staging" || true
            return 1
        fi
    fi
    if ! verify_package "$staging" >/dev/null; then
        remove_tree "$staging" || true
        return 1
    fi
    if ! find "$staging" -type f -exec chmod a-w {} +; then
        remove_tree "$staging" || true
        return 1
    fi
    if ! mv "$staging" "$destination"; then
        remove_tree "$staging" || true
        return 1
    fi
    printf '%s\n' "$release_id"
}

restart_after_switch() {
    local new_release=$1
    local old_current=$2
    local old_previous=$3
    replace_release_link previous "$old_current"
    replace_release_link current "$new_release"
    if launchctl kickstart -k "$service"; then
        return 0
    fi

    restore_link current "$old_current"
    restore_link previous "$old_previous"
    launchctl kickstart -k "$service" >/dev/null 2>&1 || true
    printf 'service restart failed; restored release %s\n' "$old_current" >&2
    return 1
}

case $command_name in
    install)
        if [[ -e $current_link || -L $current_link ]]; then
            printf 'macrdp is already installed; use upgrade\n' >&2
            exit 1
        fi
        ensure_install_root
        package=$(absolute_path "$package_input")
        verification=$(verify_package "$package")
        release_id=$(stage_release "$package" "$verification")
        replace_release_link current "$release_id"

        if [[ -z $config_dir_input ]]; then
            if [[ -d $install_root/shadow || -f $install_root/macrdp.sam ]]; then
                config_dir_input=$install_root
            else
                config_dir_input="$install_root/state/config"
            fi
        fi
        config_dir=$(absolute_path "$config_dir_input")
        mkdir -p "$config_dir"
        config_dir=$(cd "$config_dir" && pwd -P)
        chmod 700 "$config_dir"
        if [[ -z $launch_agent_installer ]]; then
            printf 'LaunchAgent installer is unavailable next to %s\n' "$0" >&2
            restore_link current ''
            exit 1
        fi
        launch_arguments=(
            "$current_link/bin/macrdp-server"
            "$username"
            "$password_file"
            "$port"
            "$config_dir"
        )
        if [[ ${#server_options[@]} -gt 0 ]]; then
            launch_arguments+=(-- "${server_options[@]}")
        fi
        plist_backup=''
        if [[ -L $plist || ( -e $plist && ! -f $plist ) ]]; then
            printf 'existing LaunchAgent plist is not a regular file: %s\n' "$plist" >&2
            restore_link current ''
            exit 1
        fi
        if [[ -f $plist ]]; then
            plist_backup=$(mktemp "${TMPDIR:-/tmp}/macrdp-plist-backup.XXXXXX")
            cp "$plist" "$plist_backup"
        fi
        if ! MACRDP_PRESERVE_SERVER_PATH=1 \
            MACRDP_LAUNCH_AGENT_LABEL="$label" \
            MACRDP_LAUNCH_AGENTS_DIR="$launch_agents_dir" \
            MACRDP_LOG_DIR="$log_dir" \
            "$launch_agent_installer" "${launch_arguments[@]}"; then
            restore_link current ''
            launchctl bootout "$service" >/dev/null 2>&1 || true
            if [[ -n $plist_backup ]]; then
                install -m 600 "$plist_backup" "$plist"
                launchctl bootstrap "$gui_domain" "$plist" >/dev/null 2>&1 || true
                launchctl kickstart -k "$service" >/dev/null 2>&1 || true
            else
                rm -f "$plist"
            fi
            rm -f "$plist_backup"
            printf 'installation failed while creating the LaunchAgent\n' >&2
            exit 1
        fi
        rm -f "$plist_backup"
        printf 'Installed macrdp release %s\n' "$release_id"
        printf 'Persistent state: %s\n' "$config_dir"
        ;;
    upgrade)
        require_marker
        old_current=$(link_release_id "$current_link" || true)
        old_previous=$(link_release_id "$previous_link" || true)
        if [[ -z $old_current ]]; then
            printf 'current macrdp release is missing or invalid\n' >&2
            exit 1
        fi
        if ! validate_managed_plist || ! launchctl print "$service" >/dev/null 2>&1; then
            printf 'LaunchAgent is not installed and loaded: %s\n' "$service" >&2
            exit 1
        fi
        verify_package "$releases_dir/$old_current" >/dev/null
        package=$(absolute_path "$package_input")
        verification=$(verify_package "$package")
        release_id=$(stage_release "$package" "$verification")
        if [[ $release_id == "$old_current" ]]; then
            printf 'Release %s is already current\n' "$release_id"
            exit 0
        fi
        restart_after_switch "$release_id" "$old_current" "$old_previous"
        printf 'Upgraded macrdp from %s to %s\n' "$old_current" "$release_id"
        printf 'Rollback release: %s\n' "$old_current"
        ;;
    rollback)
        require_marker
        old_current=$(link_release_id "$current_link" || true)
        rollback_release=$(link_release_id "$previous_link" || true)
        if [[ -z $old_current || -z $rollback_release || $old_current == "$rollback_release" ]]; then
            printf 'no valid previous release is available for rollback\n' >&2
            exit 1
        fi
        if ! validate_managed_plist || ! launchctl print "$service" >/dev/null 2>&1; then
            printf 'LaunchAgent is not installed and loaded: %s\n' "$service" >&2
            exit 1
        fi
        verify_package "$releases_dir/$rollback_release" >/dev/null
        restart_after_switch "$rollback_release" "$old_current" "$rollback_release"
        printf 'Rolled back macrdp from %s to %s\n' "$old_current" "$rollback_release"
        ;;
    status)
        require_marker
        current_release=$(link_release_id "$current_link" || true)
        previous_release=$(link_release_id "$previous_link" || true)
        [[ -n $current_release ]] || {
            printf 'current macrdp release is missing or invalid\n' >&2
            exit 1
        }
        printf 'install_root=%s\n' "$install_root"
        printf 'current_release=%s\n' "$current_release"
        printf 'previous_release=%s\n' "${previous_release:-none}"
        if [[ -e $plist || -L $plist ]]; then
            validate_managed_plist || exit 1
        fi
        if [[ -f $plist ]] && launchctl print "$service" >/dev/null 2>&1; then
            printf 'service=loaded\n'
        else
            printf 'service=not-loaded\n'
        fi
        ;;
    uninstall)
        require_marker
        if [[ -e $plist || -L $plist ]]; then
            validate_managed_plist || exit 1
        fi
        log_root=''
        if [[ $purge_state -eq 1 ]]; then
            log_root=$(absolute_path "$log_dir")
            default_log_root=$(absolute_path "$default_log_dir")
            if [[ $log_root != "$default_log_root" || -L $log_root ]]; then
                printf 'refusing non-default or symbolic log directory cleanup: %s\n' \
                    "$log_root" >&2
                exit 1
            fi
        fi
        launchctl bootout "$service" >/dev/null 2>&1 || true
        rm -f "$plist" "$current_link" "$previous_link"
        remove_tree "$releases_dir"
        if [[ $purge_state -eq 1 ]]; then
            remove_tree "$install_root"
            remove_tree "$log_root"
            printf 'Uninstalled macrdp and purged project-managed state\n'
        else
            printf 'Uninstalled macrdp; preserved state under %s\n' "$install_root"
        fi
        ;;
esac
