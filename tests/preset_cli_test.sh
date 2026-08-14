#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <macrdp-server>\n' "$0" >&2
    exit 2
fi

server=$1
test_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-preset-cli.XXXXXX")
trap 'chmod -R u+rwX "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT
chmod 700 "$test_root"
mkdir "$test_root/presets"
chmod 700 "$test_root/presets"

expect_line() {
    local output=$1
    local expected=$2
    if ! grep -Fqx -- "$expected" <<<"$output"; then
        printf 'missing expected line: %s\n%s\n' "$expected" "$output" >&2
        exit 1
    fi
}

expect_text() {
    local output=$1
    local expected=$2
    if [[ $output != *"$expected"* ]]; then
        printf 'missing expected text: %s\n%s\n' "$expected" "$output" >&2
        exit 1
    fi
}

expect_failure() {
    local expected=$1
    shift
    local output
    local status
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        printf 'command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
    expect_text "$output" "$expected"
}

output=$("$server" --config-dir "$test_root" --list-presets)
expect_text "$output" $'local\tbuilt-in\t'
expect_text "$output" $'standard\tbuilt-in\t'
expect_text "$output" $'high-quality\tbuilt-in\t'
expect_text "$output" $'resource-saving\tbuilt-in\t'
expect_text "$output" $'view-only\tbuilt-in\t'

output=$("$server" --max-fps 12 --preset standard --bind-address 127.0.0.1 \
    --audio --print-effective-config --config-dir "$test_root")
expect_line "$output" "preset=standard"
expect_line "$output" "bind-address=127.0.0.1"
expect_line "$output" "max-fps=12"
expect_line "$output" "max-bitrate=16000000"
expect_line "$output" "h264-encoder=openh264"
expect_line "$output" "h264-keyint=10"
expect_line "$output" "audio=true"
expect_line "$output" "credential-source=interactive-prompt"

password_path="$test_root/password"
printf 'not-read-by-this-test\n' > "$password_path"
chmod 600 "$password_path"
cat > "$test_root/presets/home.conf" <<EOF
extends = standard
description = Home office
display-id = 5
fps = 10
password-file = $password_path
EOF
chmod 600 "$test_root/presets/home.conf"

output=$("$server" --preset home --print-effective-config --config-dir "$test_root")
expect_line "$output" "preset=home"
expect_line "$output" "description=Home office"
expect_line "$output" "bind-address=0.0.0.0"
expect_line "$output" "display-id=5"
expect_line "$output" "max-fps=10"
expect_line "$output" "credential-source=password-file"

output=$("$server" --preset trusted-lan --print-effective-config --config-dir "$test_root")
expect_line "$output" "preset=trusted-lan"
expect_text "$output" "Compatibility alias for 'standard'"

output=$("$server" --preset home --password-stdin --print-effective-config \
    --config-dir "$test_root")
expect_line "$output" "credential-source=stdin"

output=$("$server" --preset home --sam-file /tmp/example.sam \
    --print-effective-config --config-dir "$test_root")
expect_line "$output" "credential-source=sam-file"

expect_failure "Use only one of --password" \
    "$server" --password test --sam-file /tmp/example.sam \
    --print-effective-config --config-dir "$test_root"

output=$("$server" --config-dir "$test_root" --list-presets)
expect_text "$output" $'home\tuser\t'

printf 'password = plaintext\n' > "$test_root/presets/plaintext.conf"
printf 'password-stdin = true\n' > "$test_root/presets/stdin.conf"
printf 'password-file = relative-password\n' > "$test_root/presets/relative.conf"
printf 'unknown-key = value\n' > "$test_root/presets/unknown.conf"
printf 'extends = cycle-b\n' > "$test_root/presets/cycle-a.conf"
printf 'extends = cycle-a\n' > "$test_root/presets/cycle-b.conf"
printf 'password-file = %s\nsam-file = /tmp/test.sam\n' "$password_path" \
    > "$test_root/presets/two-credentials.conf"
printf 'fps = 5\n' > "$test_root/presets/insecure.conf"
chmod 600 "$test_root/presets/"{plaintext,stdin,relative,unknown,cycle-a,cycle-b,two-credentials}.conf
chmod 666 "$test_root/presets/insecure.conf"

expect_failure "'password' is forbidden in presets" \
    "$server" --preset plaintext --print-effective-config --config-dir "$test_root"
expect_failure "'password-stdin' is forbidden in presets" \
    "$server" --preset stdin --print-effective-config --config-dir "$test_root"
expect_failure "'password-file' must be an absolute path" \
    "$server" --preset relative --print-effective-config --config-dir "$test_root"
expect_failure "'unknown-key' is not a supported preset key" \
    "$server" --preset unknown --print-effective-config --config-dir "$test_root"
expect_failure "Preset inheritance cycle" \
    "$server" --preset cycle-a --print-effective-config --config-dir "$test_root"
expect_failure "specify only one of 'password-file' and 'sam-file'" \
    "$server" --preset two-credentials --print-effective-config --config-dir "$test_root"
expect_failure "not writable by others" \
    "$server" --preset insecure --print-effective-config --config-dir "$test_root"
expect_failure "Unable to open preset" \
    "$server" --preset missing --print-effective-config --config-dir "$test_root"

chmod 0777 "$test_root/presets"
expect_failure "not writable by others" \
    "$server" --preset home --print-effective-config --config-dir "$test_root"
