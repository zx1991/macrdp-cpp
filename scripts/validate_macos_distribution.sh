#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 5 || $# -gt 6 ]]; then
    printf 'usage: %s <dmg> <version> <architecture> <minimum-macos> <development|developer-id> [--require-notarized]\n' \
        "$0" >&2
    exit 2
fi

dmg_input=$1
expected_version=$2
expected_architecture=$3
expected_minimum=$4
sign_mode=$5
notarized_option=${6:-}
hdiutil_command=${MACRDP_HDIUTIL_COMMAND:-hdiutil}
codesign_command=${MACRDP_CODESIGN_COMMAND:-codesign}
xcrun_command=${MACRDP_XCRUN_COMMAND:-xcrun}
spctl_command=${MACRDP_SPCTL_COMMAND:-spctl}

case $sign_mode in
    development|developer-id) ;;
    *)
        printf 'invalid distribution signing mode: %s\n' "$sign_mode" >&2
        exit 2
        ;;
esac
if [[ -n $notarized_option && $notarized_option != --require-notarized ]]; then
    printf 'invalid distribution validation option: %s\n' "$notarized_option" >&2
    exit 2
fi
if [[ $notarized_option == --require-notarized && $sign_mode != developer-id ]]; then
    printf 'notarization validation requires Developer ID mode\n' >&2
    exit 2
fi
for command_name in "$hdiutil_command" "$codesign_command" lipo ruby shasum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required to validate the macOS distribution\n' "$command_name" >&2
        exit 1
    fi
done
if [[ -L $dmg_input || ! -f $dmg_input ]]; then
    printf 'distribution must be a regular DMG, not a symbolic link: %s\n' "$dmg_input" >&2
    exit 1
fi
dmg=$(cd "$(dirname "$dmg_input")" && pwd -P)/$(basename "$dmg_input")

"$hdiutil_command" verify "$dmg" >/dev/null
"$codesign_command" --verify --strict --verbose=2 "$dmg"
dmg_details=$("$codesign_command" -d --verbose=4 "$dmg" 2>&1)
dmg_identifier=$(printf '%s\n' "$dmg_details" \
    | awk -F= '$1 == "Identifier" { print $2; exit }')
if [[ -z $dmg_identifier ]]; then
    printf 'DMG code-signing identifier is missing\n' >&2
    exit 1
fi

developer_team=''
validate_developer_id_signature() {
    local file=$1
    local require_runtime=$2
    local details team
    details=$("$codesign_command" -d --verbose=4 "$file" 2>&1)
    if [[ $details != *$'Authority=Developer ID Application:'* \
          || $details == *$'Signature=adhoc'* \
          || $details != *$'Timestamp='* ]]; then
        printf 'Developer ID signature or trusted timestamp is missing: %s\n' "$file" >&2
        return 1
    fi
    if [[ $require_runtime == 1 && $details != *'(runtime)'* ]]; then
        printf 'hardened runtime is missing: %s\n' "$file" >&2
        return 1
    fi
    team=$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')
    if [[ -z $team ]]; then
        printf 'Developer ID TeamIdentifier is missing: %s\n' "$file" >&2
        return 1
    fi
    if [[ -z $developer_team ]]; then
        developer_team=$team
    elif [[ $developer_team != "$team" ]]; then
        printf 'Developer ID TeamIdentifier mismatch: %s\n' "$file" >&2
        return 1
    fi
}

if [[ $sign_mode == developer-id ]]; then
    validate_developer_id_signature "$dmg" 0
fi
if [[ $notarized_option == --require-notarized ]]; then
    command -v "$xcrun_command" >/dev/null 2>&1
    command -v "$spctl_command" >/dev/null 2>&1
    "$xcrun_command" stapler validate "$dmg"
    "$spctl_command" --assess --type open \
        --context context:primary-signature --verbose=4 "$dmg"
fi

mount_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-distribution-mount.XXXXXX")
mounted=0
cleanup() {
    if [[ $mounted -eq 1 ]]; then
        "$hdiutil_command" detach "$mount_root" >/dev/null 2>&1 || true
    fi
    rmdir "$mount_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$hdiutil_command" attach -readonly -nobrowse -noautoopen \
    -mountpoint "$mount_root" "$dmg" >/dev/null
mounted=1

metadata="$mount_root/distribution.json"
instructions="$mount_root/INSTALL.txt"
if [[ ! -f $metadata || -L $metadata || ! -s $instructions || -L $instructions ]]; then
    printf 'distribution metadata or installation instructions are missing\n' >&2
    exit 1
fi
package_name=$(ruby -rjson -e '
  metadata = JSON.parse(File.read(ARGV.fetch(0)))
  expected_version, expected_architecture, expected_minimum = ARGV.drop(1)
  abort "unexpected distribution schema" unless metadata["schemaVersion"] == 1
  abort "unexpected distribution name" unless metadata["name"] == "macrdp-cpp"
  abort "distribution version mismatch" unless metadata["version"] == expected_version
  abort "distribution architecture mismatch" unless metadata["architecture"] == expected_architecture
  abort "distribution minimum macOS mismatch" unless metadata["minimumMacOSVersion"] == expected_minimum
  package_name = metadata.fetch("packageDirectory")
  abort "unsafe package directory" unless package_name == "macrdp-cpp-#{expected_version}"
  %w[packageSbomSha256 packageVerifierSha256].each do |key|
    abort "invalid #{key}" unless metadata[key]&.match?(/\A[0-9a-f]{64}\z/)
  end
  revision = metadata.fetch("gitRevision")
  abort "invalid git revision" unless revision.match?(/\A[0-9a-f]{40}(-dirty)?\z/)
  identifier = metadata.fetch("distributionIdentifier")
  abort "invalid distribution identifier" unless identifier.match?(/\A[A-Za-z0-9._-]+\z/)
  server_identifier = metadata.fetch("serverIdentifier")
  abort "invalid server identifier" unless server_identifier.match?(/\A[A-Za-z0-9._-]+\z/)
  puts package_name
' "$metadata" "$expected_version" "$expected_architecture" "$expected_minimum")
package_dir="$mount_root/$package_name"
if [[ ! -d $package_dir || -L $package_dir ]]; then
    printf 'distribution package directory is missing or symbolic: %s\n' "$package_dir" >&2
    exit 1
fi
metadata_distribution_identifier=$(ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("distributionIdentifier")' "$metadata")
metadata_server_identifier=$(ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("serverIdentifier")' "$metadata")
if [[ $dmg_identifier != "$metadata_distribution_identifier" ]]; then
    printf 'DMG identifier does not match distribution metadata\n' >&2
    exit 1
fi

package_verifier="$package_dir/bin/macrdp-verify-package"
verification=$("$package_verifier" "$package_dir")
verified_version=$(printf '%s\n' "$verification" | awk -F= '$1 == "version" { print $2 }')
verified_sbom=$(printf '%s\n' "$verification" | awk -F= '$1 == "sbom_sha256" { print $2 }')
metadata_sbom=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("packageSbomSha256")' "$metadata")
metadata_verifier=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("packageVerifierSha256")' "$metadata")
actual_verifier=$(shasum -a 256 "$package_verifier" | awk '{ print $1 }')
if [[ $verified_version != "$expected_version" \
      || $verified_sbom != "$metadata_sbom" \
      || $actual_verifier != "$metadata_verifier" ]]; then
    printf 'mounted package metadata or verifier hash does not match the DMG manifest\n' >&2
    exit 1
fi

payload=("$package_dir/bin/macrdp-server")
for library in "$package_dir"/lib/*.dylib; do
    [[ -f $library ]] || continue
    payload+=("$library")
done
for file in "${payload[@]}"; do
    "$codesign_command" --verify --strict --verbose=2 "$file"
    file_architectures=$(lipo -archs "$file")
    case $expected_architecture in
        universal2)
            sorted_architectures=$(printf '%s\n' $file_architectures | sort | tr '\n' ' ')
            [[ $sorted_architectures == 'arm64 x86_64 ' ]] || {
                printf 'unexpected universal payload architectures for %s: %s\n' \
                    "$file" "$file_architectures" >&2
                exit 1
            }
            ;;
        *)
            [[ $file_architectures == "$expected_architecture" ]] || {
                printf 'unexpected payload architecture for %s: %s\n' \
                    "$file" "$file_architectures" >&2
                exit 1
            }
            ;;
    esac
    if [[ $sign_mode == developer-id ]]; then
        validate_developer_id_signature "$file" 1
    fi
done
server_details=$("$codesign_command" -d --verbose=4 \
    "$package_dir/bin/macrdp-server" 2>&1)
server_identifier=$(printf '%s\n' "$server_details" \
    | awk -F= '$1 == "Identifier" { print $2; exit }')
if [[ $server_identifier != "$metadata_server_identifier" ]]; then
    printf 'packaged server identifier does not match distribution metadata\n' >&2
    exit 1
fi
if [[ $sign_mode == developer-id ]]; then
    git_revision=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("gitRevision")' "$metadata")
    if [[ ! $git_revision =~ ^[0-9a-f]{40}$ ]]; then
        printf 'Developer ID distribution was produced from a dirty source revision\n' >&2
        exit 1
    fi
fi

help_output=$("$package_dir/bin/macrdp-server" --help)
if [[ $help_output != *'Usage:'* || $help_output != *'default: 127.0.0.1'* ]]; then
    printf 'mounted server did not complete its loader/help smoke check\n' >&2
    exit 1
fi

printf 'Validated macOS distribution: %s\n' "$dmg"
printf 'Version: %s\n' "$expected_version"
printf 'Architecture: %s\n' "$expected_architecture"
printf 'Signing mode: %s\n' "$sign_mode"
if [[ -n $developer_team ]]; then
    printf 'Developer Team: %s\n' "$developer_team"
fi
