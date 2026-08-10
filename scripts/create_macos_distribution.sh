#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 5 ]]; then
    printf 'usage: %s <package-directory> <output-dmg> <version> <architecture> <minimum-macos>\n' \
        "$0" >&2
    exit 2
fi

package_input=$1
output_input=$2
version=$3
architecture=$4
minimum_macos=$5
sign_identity=${MACRDP_DISTRIBUTION_SIGN_IDENTITY:--}
sign_identifier=${MACRDP_DISTRIBUTION_SIGN_IDENTIFIER:-io.github.zx1991.macrdp.distribution}
sign_timestamp=${MACRDP_DISTRIBUTION_TIMESTAMP:-OFF}
codesign_command=${MACRDP_DISTRIBUTION_CODESIGN_COMMAND:-codesign}

for command_name in "$codesign_command" ditto hdiutil lipo ruby shasum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required to create the macOS distribution\n' "$command_name" >&2
        exit 1
    fi
done
if [[ ! $version =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
    printf 'invalid distribution version: %s\n' "$version" >&2
    exit 2
fi
case $architecture in
    arm64|x86_64|universal2) ;;
    *)
        printf 'unsupported distribution architecture: %s\n' "$architecture" >&2
        exit 2
        ;;
esac
if [[ ! $minimum_macos =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
    printf 'invalid minimum macOS version: %s\n' "$minimum_macos" >&2
    exit 2
fi
if [[ -z $sign_identity || -z $sign_identifier \
      || ! $sign_identifier =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'distribution signing identity or identifier is invalid\n' >&2
    exit 2
fi

is_enabled() {
    case $1 in
        1|ON|on|TRUE|true|YES|yes) return 0 ;;
        0|OFF|off|FALSE|false|NO|no|'') return 1 ;;
        *)
            printf 'invalid boolean value: %s\n' "$1" >&2
            exit 2
            ;;
    esac
}
if [[ $sign_identity == - ]] && is_enabled "$sign_timestamp"; then
    printf 'ad-hoc DMG signing cannot request a trusted timestamp\n' >&2
    exit 1
fi
if [[ -L $package_input || ! -d $package_input ]]; then
    printf 'package must be a directory, not a symbolic link: %s\n' "$package_input" >&2
    exit 1
fi
package_dir=$(cd "$package_input" && pwd -P)
package_verifier="$package_dir/bin/macrdp-verify-package"
if [[ ! -x $package_verifier || -L $package_verifier ]]; then
    printf 'packaged verifier is missing or invalid: %s\n' "$package_verifier" >&2
    exit 1
fi

verification=$("$package_verifier" "$package_dir")
verified_version=$(printf '%s\n' "$verification" | awk -F= '$1 == "version" { print $2 }')
sbom_sha256=$(printf '%s\n' "$verification" | awk -F= '$1 == "sbom_sha256" { print $2 }')
if [[ $verified_version != "$version" || ! $sbom_sha256 =~ ^[0-9a-f]{64}$ ]]; then
    printf 'package metadata does not match distribution version %s\n' "$version" >&2
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
    case $architecture in
        universal2)
            sorted_architectures=$(printf '%s\n' $file_architectures | sort | tr '\n' ' ')
            [[ $sorted_architectures == 'arm64 x86_64 ' ]] || {
                printf 'unexpected universal payload architectures for %s: %s\n' \
                    "$file" "$file_architectures" >&2
                exit 1
            }
            ;;
        *)
            [[ $file_architectures == "$architecture" ]] || {
                printf 'unexpected payload architecture for %s: %s\n' \
                    "$file" "$file_architectures" >&2
                exit 1
            }
            ;;
    esac
done
server_details=$("$codesign_command" -d --verbose=4 \
    "$package_dir/bin/macrdp-server" 2>&1)
server_identifier=$(printf '%s\n' "$server_details" \
    | awk -F= '$1 == "Identifier" { print $2; exit }')
if [[ -z $server_identifier || ! $server_identifier =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'packaged server code-signing identifier is missing or invalid\n' >&2
    exit 1
fi

mkdir -p "$(dirname "$output_input")"
output_dir=$(cd "$(dirname "$output_input")" && pwd -P)
output_dmg="$output_dir/$(basename "$output_input")"
if [[ $output_dmg != *.dmg || -L $output_dmg || -d $output_dmg ]]; then
    printf 'output must be a regular .dmg path: %s\n' "$output_dmg" >&2
    exit 2
fi

package_name="macrdp-cpp-$version"
volume_name="macrdp-cpp $version"
if (( ${#volume_name} > 27 )); then
    printf 'distribution version is too long for the DMG volume name: %s\n' "$version" >&2
    exit 2
fi
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-distribution.XXXXXX")
temporary_dmg="$output_dmg.tmp.$$.dmg"
cleanup() {
    rm -rf "$staging_root"
    rm -f "$temporary_dmg"
}
trap cleanup EXIT

ditto --noextattr --noacl --noqtn "$package_dir" "$staging_root/$package_name"
copied_verification=$("$staging_root/$package_name/bin/macrdp-verify-package" \
    "$staging_root/$package_name")
if [[ $copied_verification != "$verification" ]]; then
    printf 'copied package verification metadata changed during DMG staging\n' >&2
    exit 1
fi

git_revision=$(ruby -rjson -e '
  component = JSON.parse(File.read(ARGV.fetch(0))).dig("metadata", "component")
  property = component.fetch("properties").find do |entry|
    entry["name"] == "macrdp:git-revision"
  end
  abort "SBOM git revision is missing" unless property
  puts property.fetch("value")
' "$package_dir/share/macrdp/sbom.cdx.json")
verifier_sha256=$(shasum -a 256 "$package_verifier" | awk '{ print $1 }')

ruby -rjson -e '
  output, version, architecture, minimum, package_name, sbom_hash,
    verifier_hash, revision, distribution_identifier, server_identifier = ARGV
  metadata = {
    "schemaVersion" => 1,
    "name" => "macrdp-cpp",
    "version" => version,
    "architecture" => architecture,
    "minimumMacOSVersion" => minimum,
    "packageDirectory" => package_name,
    "packageSbomSha256" => sbom_hash,
    "packageVerifierSha256" => verifier_hash,
    "gitRevision" => revision,
    "distributionIdentifier" => distribution_identifier,
    "serverIdentifier" => server_identifier
  }
  File.write(output, JSON.pretty_generate(metadata) + "\n")
' "$staging_root/distribution.json" "$version" "$architecture" \
    "$minimum_macos" "$package_name" "$sbom_sha256" "$verifier_sha256" \
    "$git_revision" "$sign_identifier" "$server_identifier"

cat > "$staging_root/INSTALL.txt" <<EOF
macrdp-cpp $version for macOS $minimum_macos or later ($architecture)

This image contains a command-line RDP server and per-user lifecycle manager.
Create an owner-only password file outside this read-only image, then run:

  ./$package_name/bin/macrdp-manage install \\
    --package ./$package_name \\
    --user <rdp-user> \\
    --password-file <password-file>

Use the installed current/bin/macrdp-manage command for status, rollback, and
uninstall. Screen Recording and Accessibility remain controlled by macOS.
EOF

hdiutil create \
    -srcfolder "$staging_root" \
    -volname "$volume_name" \
    -fs 'HFS+' \
    -format UDZO \
    -imagekey zlib-level=9 \
    -nospotlight \
    -ov \
    "$temporary_dmg" >/dev/null
hdiutil verify "$temporary_dmg" >/dev/null

signing_arguments=(--force --sign "$sign_identity" --identifier "$sign_identifier")
if is_enabled "$sign_timestamp"; then
    signing_arguments+=(--timestamp)
else
    signing_arguments+=(--timestamp=none)
fi
"$codesign_command" "${signing_arguments[@]}" "$temporary_dmg"
"$codesign_command" --verify --strict --verbose=2 "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null
mv -f "$temporary_dmg" "$output_dmg"

printf 'Created macOS distribution: %s\n' "$output_dmg"
printf 'DMG signing identity: %s\n' "$sign_identity"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$output_dmg" | awk '{ print $1 }')"
