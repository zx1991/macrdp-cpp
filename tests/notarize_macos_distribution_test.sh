#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <notarization-script>\n' "$0" >&2
    exit 2
fi

notarization_script=$1
test_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-notarization-test.XXXXXX")
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/bin"
test_dmg="$test_root/macrdp-test.dmg"
command_log="$test_root/commands.log"
printf 'synthetic signed DMG\n' > "$test_dmg"

cat > "$test_root/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$MACRDP_TEST_COMMAND_LOG"
if [[ ${1:-} == -d ]]; then
    if [[ ${MACRDP_TEST_BAD_AUTHORITY:-0} == 1 ]]; then
        printf 'Signature=adhoc\n'
    else
        printf '%s\n' \
            'Authority=Developer ID Application: Test Developer (TEAM123456)' \
            'Timestamp=Aug 10, 2026 at 20:00:00' \
            'TeamIdentifier=TEAM123456'
    fi
fi
EOF

cat > "$test_root/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$MACRDP_TEST_COMMAND_LOG"
case ${1:-} in
    notarytool)
        printf '{"id":"11111111-2222-3333-4444-555555555555","status":"%s"}\n' \
            "${MACRDP_TEST_NOTARY_STATUS:-Accepted}"
        ;;
    stapler) ;;
    *) exit 1 ;;
esac
EOF

cat > "$test_root/bin/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >> "$MACRDP_TEST_COMMAND_LOG"
EOF
chmod 700 "$test_root/bin/codesign" "$test_root/bin/xcrun" "$test_root/bin/spctl"

export MACRDP_CODESIGN_COMMAND="$test_root/bin/codesign"
export MACRDP_XCRUN_COMMAND="$test_root/bin/xcrun"
export MACRDP_SPCTL_COMMAND="$test_root/bin/spctl"
export MACRDP_TEST_COMMAND_LOG="$command_log"

"$notarization_script" "$test_dmg" macrdp-test-profile >/dev/null
if ! grep -Fq \
    'xcrun notarytool submit' "$command_log" \
    || ! grep -Fq -- '--keychain-profile macrdp-test-profile' "$command_log" \
    || ! grep -Fq -- '--wait --timeout 30m --output-format json' "$command_log" \
    || ! grep -Fq 'xcrun stapler staple' "$command_log" \
    || ! grep -Fq 'xcrun stapler validate' "$command_log" \
    || ! grep -Fq 'spctl --assess --type open' "$command_log"; then
    printf 'successful notarization did not execute the required validation sequence\n' >&2
    exit 1
fi
if grep -Eq -- '--password|--apple-id|--key-id|--issuer' "$command_log"; then
    printf 'notarization command exposed direct credential arguments\n' >&2
    exit 1
fi

: > "$command_log"
if MACRDP_TEST_NOTARY_STATUS=Invalid \
    "$notarization_script" "$test_dmg" macrdp-test-profile >/dev/null 2>&1; then
    printf 'invalid Apple notarization result was accepted\n' >&2
    exit 1
fi
if grep -Fq 'xcrun stapler' "$command_log"; then
    printf 'rejected notarization attempted to staple the DMG\n' >&2
    exit 1
fi

: > "$command_log"
if MACRDP_TEST_BAD_AUTHORITY=1 \
    "$notarization_script" "$test_dmg" macrdp-test-profile >/dev/null 2>&1; then
    printf 'ad-hoc DMG was accepted for notarization\n' >&2
    exit 1
fi
if grep -Fq 'xcrun ' "$command_log"; then
    printf 'invalid signing authority reached the Apple notary service\n' >&2
    exit 1
fi

printf 'macOS distribution notarization tests passed\n'
