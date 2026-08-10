#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <rotate-password-script>\n' "$0" >&2
    exit 2
fi

rotate_script=$1
test_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-password-test.XXXXXX")
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/config"
export MACRDP_LAUNCH_AGENTS_DIR="$test_root/LaunchAgents"
mkdir -p "$MACRDP_LAUNCH_AGENTS_DIR"
launchctl_log="$test_root/launchctl.log"
export MACRDP_TEST_LAUNCHCTL_LOG="$launchctl_log"

cat > "$test_root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MACRDP_TEST_LAUNCHCTL_LOG"
case ${1:-} in
    print)
        printf 'password-file=%s\n' "$MACRDP_TEST_CONFIGURED_PASSWORD_FILE"
        exit 0
        ;;
    kickstart)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 700 "$test_root/bin/launchctl"
export PATH="$test_root/bin:$PATH"

password_file=$(cd "$test_root/config" && pwd -P)/password
export MACRDP_TEST_CONFIGURED_PASSWORD_FILE="$password_file"
printf 'old-password\n' > "$password_file"
chmod 600 "$password_file"

plist="$MACRDP_LAUNCH_AGENTS_DIR/com.macrdp.cpp.server.plist"
plutil -create xml1 "$plist"
plutil -insert ProgramArguments -array "$plist"
plutil -insert ProgramArguments.0 -string '/tmp/macrdp-server' "$plist"
plutil -insert ProgramArguments.1 -string '--password-file' "$plist"
plutil -insert ProgramArguments.2 -string "$password_file" "$plist"

printf 'new-password\n' | "$rotate_script" "$password_file" --stdin

if [[ $(<"$password_file") != 'new-password' ]]; then
    printf 'password file was not replaced\n' >&2
    exit 1
fi
if [[ $(stat -f '%Lp' "$password_file") != '600' ]]; then
    printf 'password file permissions changed unexpectedly\n' >&2
    exit 1
fi
if ! grep -Eq '^print gui/[0-9]+/com\.macrdp\.cpp\.server$' "$launchctl_log" \
    || ! grep -Eq '^kickstart -k gui/[0-9]+/com\.macrdp\.cpp\.server$' "$launchctl_log"; then
    printf 'LaunchAgent was not checked and restarted as expected\n' >&2
    exit 1
fi

other_password_file="$test_root/config/other-password"
printf 'other-password\n' > "$other_password_file"
chmod 600 "$other_password_file"
plutil -replace ProgramArguments.2 -string "$other_password_file" "$plist"
if printf 'wrong-file-update\n' \
    | "$rotate_script" "$password_file" --stdin >/dev/null 2>&1; then
    printf 'LaunchAgent password-file mismatch was accepted\n' >&2
    exit 1
fi
if [[ $(<"$password_file") != 'new-password' ]]; then
    printf 'path mismatch changed the requested password file\n' >&2
    exit 1
fi
plutil -replace ProgramArguments.2 -string "$password_file" "$plist"

printf 'stable-password\n' > "$password_file"
chmod 600 "$password_file"
if printf '\n' | "$rotate_script" "$password_file" --stdin >/dev/null 2>&1; then
    printf 'empty password was accepted\n' >&2
    exit 1
fi
if [[ $(<"$password_file") != 'stable-password' ]]; then
    printf 'rejected input changed the password file\n' >&2
    exit 1
fi

if printf 'first-line\nsecond-line\n' \
    | "$rotate_script" "$password_file" --stdin >/dev/null 2>&1; then
    printf 'multiple password lines were accepted\n' >&2
    exit 1
fi
if [[ $(<"$password_file") != 'stable-password' ]]; then
    printf 'multiple-line input changed the password file\n' >&2
    exit 1
fi

chmod 644 "$password_file"
if printf 'replacement\n' | "$rotate_script" "$password_file" --stdin >/dev/null 2>&1; then
    printf 'non-private password file was accepted\n' >&2
    exit 1
fi
if [[ $(<"$password_file") != 'stable-password' ]]; then
    printf 'permission failure changed the password file\n' >&2
    exit 1
fi

printf 'password rotation tests passed\n'
