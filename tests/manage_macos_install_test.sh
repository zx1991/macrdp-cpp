#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    printf 'usage: %s <manager> <launch-agent-installer> <package-verifier> <password-rotator>\n' "$0" >&2
    exit 2
fi

manager=$1
launch_agent_installer=$2
package_verifier=$3
password_rotator=$4
test_root=$(mktemp -d "${TMPDIR:-/tmp}/macrdp-install-test.XXXXXX")
test_root=$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$test_root")
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

export HOME="$test_root/home"
export MACRDP_INSTALL_ROOT="$test_root/install"
export MACRDP_LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
export MACRDP_LOG_DIR="$HOME/Library/Logs/macrdp-cpp"
export MACRDP_TEST_LAUNCHCTL_LOG="$test_root/launchctl.log"
export MACRDP_TEST_FAIL_NEXT_KICKSTART="$test_root/fail-next-kickstart"
mkdir -p "$HOME" "$test_root/bin" "$test_root/secrets"
chmod 700 "$HOME" "$test_root/secrets"

cat > "$test_root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MACRDP_TEST_LAUNCHCTL_LOG"
case ${1:-} in
    print)
        label=${2##*/}
        [[ -f $MACRDP_LAUNCH_AGENTS_DIR/$label.plist ]]
        ;;
    kickstart)
        if [[ -e $MACRDP_TEST_FAIL_NEXT_KICKSTART ]]; then
            rm -f "$MACRDP_TEST_FAIL_NEXT_KICKSTART"
            exit 1
        fi
        ;;
    bootout|bootstrap|enable) ;;
    *) exit 1 ;;
esac
EOF

cat > "$test_root/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == '--verify' ]]
EOF
chmod 700 "$test_root/bin/launchctl" "$test_root/bin/codesign"
export PATH="$test_root/bin:$PATH"

password_file="$test_root/secrets/password"
printf 'installation-test-password\n' > "$password_file"
chmod 600 "$password_file"

make_package() {
    local package=$1
    local version=$2
    mkdir -p "$package/bin" "$package/share/macrdp/licenses/macrdp-cpp"
    cp "$manager" "$package/bin/macrdp-manage"
    cp "$launch_agent_installer" "$package/bin/macrdp-install-launch-agent"
    cp "$package_verifier" "$package/bin/macrdp-verify-package"
    cp "$password_rotator" "$package/bin/macrdp-rotate-password"
    chmod 755 "$package/bin/macrdp-manage" \
        "$package/bin/macrdp-install-launch-agent" \
        "$package/bin/macrdp-rotate-password" \
        "$package/bin/macrdp-verify-package"
    cat > "$package/bin/macrdp-server" <<EOF
#!/usr/bin/env bash
printf 'macrdp test server %s\\n' '$version'
EOF
    chmod 755 "$package/bin/macrdp-server"
    printf 'test license\n' > "$package/share/macrdp/licenses/macrdp-cpp/LICENSE"

    ruby -rdigest -rjson -e '
      package, version = ARGV
      sbom_relative = "share/macrdp/sbom.cdx.json"
      properties = [
        { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/macrdp-cpp" }
      ]
      Dir.glob(File.join(package, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
        next unless File.file?(path)
        relative = path.delete_prefix("#{package}/")
        next if relative == sbom_relative
        property = relative.start_with?("share/macrdp/") ?
          "macrdp:compliance-file-sha256" : "macrdp:packaged-file-sha256"
        properties << {
          "name" => property,
          "value" => "#{relative}=#{Digest::SHA256.file(path).hexdigest}"
        }
      end
      sbom = {
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.6",
        "version" => 1,
        "metadata" => {
          "component" => {
            "type" => "application",
            "bom-ref" => "pkg:generic/macrdp-test@#{version}",
            "name" => "macrdp-cpp",
            "version" => version,
            "licenses" => [{ "expression" => "Apache-2.0" }],
            "properties" => properties
          }
        },
        "components" => []
      }
      path = File.join(package, sbom_relative)
      File.write(path, JSON.pretty_generate(sbom) + "\n")
    ' "$package" "$version"
}

package_v1="$test_root/package-v1"
package_v2="$test_root/package-v2"
package_v3="$test_root/package-v3"
package_bad="$test_root/package-bad"
package_noexec="$test_root/package-noexec"
make_package "$package_v1" 1.0.0
make_package "$package_v2" 1.1.0
make_package "$package_v3" 1.2.0
make_package "$package_bad" 2.0.0
make_package "$package_noexec" 2.1.0
printf 'tampered\n' >> "$package_bad/bin/macrdp-server"
chmod 600 "$package_noexec/bin/macrdp-server"

empty_password_file="$test_root/secrets/empty-password"
: > "$empty_password_file"
chmod 600 "$empty_password_file"
if "$manager" install \
    --package "$package_v1" \
    --user install-test \
    --password-file "$empty_password_file" >/dev/null 2>&1; then
    printf 'empty initial password was accepted\n' >&2
    exit 1
fi
if [[ -e $MACRDP_INSTALL_ROOT/current \
      || -e $MACRDP_LAUNCH_AGENTS_DIR/com.macrdp.cpp.server.plist ]]; then
    printf 'failed initial installation left active state\n' >&2
    exit 1
fi

"$manager" install \
    --package "$package_v1" \
    --user install-test \
    --password-file "$password_file" \
    --view-only >/dev/null 2>&1 && {
        printf 'server options without -- were accepted\n' >&2
        exit 1
    }

"$manager" install \
    --package "$package_v1" \
    --user install-test \
    --password-file "$password_file" \
    -- --view-only --no-clipboard --no-audio

if [[ ! -L $MACRDP_INSTALL_ROOT/current \
      || -e $MACRDP_INSTALL_ROOT/previous \
      || $(<"$MACRDP_INSTALL_ROOT/.macrdp-install-root") != 'schema=1' ]]; then
    printf 'initial versioned installation layout is invalid\n' >&2
    exit 1
fi
release_v1=${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current")
plist="$MACRDP_LAUNCH_AGENTS_DIR/com.macrdp.cpp.server.plist"
program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")
config_dir=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:8' "$plist")
expected_config_dir=$(cd "$MACRDP_INSTALL_ROOT/state/config" && pwd -P)
if [[ $program != "$MACRDP_INSTALL_ROOT/current/bin/macrdp-server" \
      || $config_dir != "$expected_config_dir" ]]; then
    printf 'LaunchAgent does not use stable executable and state paths\n' >&2
    exit 1
fi

mkdir -p "$config_dir/shadow"
printf 'persistent certificate\n' > "$config_dir/shadow/shadow.crt"
certificate_hash=$(shasum -a 256 "$config_dir/shadow/shadow.crt" | awk '{ print $1 }')

status_output=$("$manager" status)
if [[ $status_output != *'service=loaded'* \
      || $status_output != *'previous_release=none'* ]]; then
    printf 'installed status is incomplete\n' >&2
    exit 1
fi

"$manager" upgrade --package "$package_v2"
release_v2=${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current")
if [[ $release_v1 == "$release_v2" \
      || ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/previous") != "$release_v1" ]]; then
    printf 'upgrade did not retain the previous release\n' >&2
    exit 1
fi
if [[ $(shasum -a 256 "$config_dir/shadow/shadow.crt" | awk '{ print $1 }') != "$certificate_hash" ]]; then
    printf 'upgrade changed persistent certificate state\n' >&2
    exit 1
fi

if "$manager" upgrade --package "$package_bad" >/dev/null 2>&1; then
    printf 'tampered package was accepted\n' >&2
    exit 1
fi
if [[ ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current") != "$release_v2" ]]; then
    printf 'rejected package changed the current release\n' >&2
    exit 1
fi
if "$manager" upgrade --package "$package_noexec" >/dev/null 2>&1; then
    printf 'package with a non-executable server was accepted\n' >&2
    exit 1
fi

verification_v3=$("$package_verifier" "$package_v3")
version_v3=$(printf '%s\n' "$verification_v3" | awk -F= '$1 == "version" { print $2 }')
sbom_hash_v3=$(printf '%s\n' "$verification_v3" | awk -F= '$1 == "sbom_sha256" { print $2 }')
release_id_v3="$version_v3-${sbom_hash_v3:0:16}"
ln -s "$test_root/outside-release" "$MACRDP_INSTALL_ROOT/releases/$release_id_v3"
if "$manager" upgrade --package "$package_v3" >/dev/null 2>&1; then
    printf 'upgrade accepted a symbolic release destination\n' >&2
    exit 1
fi
rm "$MACRDP_INSTALL_ROOT/releases/$release_id_v3"

touch "$MACRDP_TEST_FAIL_NEXT_KICKSTART"
if "$manager" upgrade --package "$package_v3" >/dev/null 2>&1; then
    printf 'failed service restart was reported as a successful upgrade\n' >&2
    exit 1
fi
if [[ ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current") != "$release_v2" \
      || ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/previous") != "$release_v1" ]]; then
    printf 'failed upgrade did not restore current and previous releases\n' >&2
    exit 1
fi

"$manager" rollback
if [[ ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current") != "$release_v1" \
      || ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/previous") != "$release_v2" ]]; then
    printf 'rollback did not exchange current and previous releases\n' >&2
    exit 1
fi
if [[ $(shasum -a 256 "$config_dir/shadow/shadow.crt" | awk '{ print $1 }') != "$certificate_hash" ]]; then
    printf 'rollback changed persistent certificate state\n' >&2
    exit 1
fi

rollback_candidate=${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/previous")
chmod u+w "$rollback_candidate/bin/macrdp-server"
printf 'tampered installed release\n' >> "$rollback_candidate/bin/macrdp-server"
if "$manager" rollback >/dev/null 2>&1; then
    printf 'rollback accepted a modified installed release\n' >&2
    exit 1
fi
if [[ ${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current") != "$release_v1" ]]; then
    printf 'rejected rollback changed the current release\n' >&2
    exit 1
fi

current_candidate=${MACRDP_INSTALL_ROOT}/$(readlink "$MACRDP_INSTALL_ROOT/current")
chmod u+w "$current_candidate/bin/macrdp-server"
printf 'tampered current release\n' >> "$current_candidate/bin/macrdp-server"
if "$manager" upgrade --package "$package_v3" >/dev/null 2>&1; then
    printf 'upgrade retained a modified current release as its rollback target\n' >&2
    exit 1
fi
cp "$package_v1/bin/macrdp-server" "$current_candidate/bin/macrdp-server"
chmod a-w "$current_candidate/bin/macrdp-server"

unsafe_log_dir="$HOME/unsafe-logs/macrdp-cpp"
mkdir -p "$unsafe_log_dir"
printf 'keep\n' > "$unsafe_log_dir/unrelated.log"
if MACRDP_LOG_DIR="$unsafe_log_dir" \
    "$manager" uninstall --purge-state >/dev/null 2>&1; then
    printf 'purge accepted a non-default log directory\n' >&2
    exit 1
fi
if [[ ! -L $MACRDP_INSTALL_ROOT/current || ! -f $plist \
      || ! -f $unsafe_log_dir/unrelated.log ]]; then
    printf 'rejected purge partially changed installation state\n' >&2
    exit 1
fi

"$manager" uninstall
if [[ -e $MACRDP_INSTALL_ROOT/current || -e $MACRDP_INSTALL_ROOT/releases \
      || -e $plist || ! -f $config_dir/shadow/shadow.crt || ! -f $password_file ]]; then
    printf 'ordinary uninstall removed state or retained program files\n' >&2
    exit 1
fi

"$manager" install \
    --package "$package_v2" \
    --user install-test \
    --password-file "$password_file"
"$manager" uninstall --purge-state
if [[ -e $MACRDP_INSTALL_ROOT || -e $MACRDP_LOG_DIR || ! -f $password_file ]]; then
    printf 'purge did not remove managed state or removed an external password\n' >&2
    exit 1
fi

if ! grep -Eq '^kickstart -k gui/[0-9]+/com\.macrdp\.cpp\.server$' \
    "$MACRDP_TEST_LAUNCHCTL_LOG"; then
    printf 'lifecycle operations did not restart the LaunchAgent\n' >&2
    exit 1
fi

printf 'macOS installation lifecycle tests passed\n'
