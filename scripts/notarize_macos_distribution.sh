#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <signed-dmg> <notarytool-keychain-profile>\n' "$0" >&2
    exit 2
fi

dmg_input=$1
keychain_profile=$2
notary_timeout=${MACRDP_NOTARY_TIMEOUT:-30m}
codesign_command=${MACRDP_CODESIGN_COMMAND:-codesign}
xcrun_command=${MACRDP_XCRUN_COMMAND:-xcrun}
spctl_command=${MACRDP_SPCTL_COMMAND:-spctl}

if [[ -z $keychain_profile || ! $notary_timeout =~ ^[1-9][0-9]*[smh]?$ ]]; then
    printf 'notarytool profile or timeout is invalid\n' >&2
    exit 2
fi
for command_name in "$codesign_command" "$xcrun_command" "$spctl_command" ruby; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required to notarize the macOS distribution\n' "$command_name" >&2
        exit 1
    fi
done
if [[ -L $dmg_input || ! -f $dmg_input ]]; then
    printf 'distribution must be a regular DMG, not a symbolic link: %s\n' "$dmg_input" >&2
    exit 1
fi
dmg=$(cd "$(dirname "$dmg_input")" && pwd -P)/$(basename "$dmg_input")

"$codesign_command" --verify --strict --verbose=2 "$dmg"
signature_details=$("$codesign_command" -d --verbose=4 "$dmg" 2>&1)
if [[ $signature_details != *$'Authority=Developer ID Application:'* \
      || $signature_details == *$'Signature=adhoc'* \
      || $signature_details != *$'Timestamp='* ]]; then
    printf 'DMG must have a timestamped Developer ID Application signature before notarization\n' >&2
    exit 1
fi

notary_json=$("$xcrun_command" notarytool submit "$dmg" \
    --keychain-profile "$keychain_profile" \
    --wait \
    --timeout "$notary_timeout" \
    --output-format json)
notary_status=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("status")' \
    <<< "$notary_json")
submission_id=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")' \
    <<< "$notary_json")
if [[ $notary_status != Accepted ]]; then
    printf 'Apple notarization did not accept submission %s (status: %s)\n' \
        "$submission_id" "$notary_status" >&2
    printf '%s\n' "$notary_json" >&2
    exit 1
fi

"$xcrun_command" stapler staple "$dmg"
"$xcrun_command" stapler validate "$dmg"
"$codesign_command" --verify --strict --verbose=2 "$dmg"
"$spctl_command" --assess --type open \
    --context context:primary-signature --verbose=4 "$dmg"

printf 'Notarized and stapled macOS distribution: %s\n' "$dmg"
printf 'Notary submission: %s\n' "$submission_id"
