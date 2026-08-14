#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "set"

unless (5..6).cover?(ARGV.length)
  warn "usage: #{$PROGRAM_NAME} <package> <dependency-origins> <project-source> <freerdp-source> <project-version> [ffmpeg-provenance]"
  exit 2
end

package_dir = Pathname.new(ARGV[0]).realpath
origins_path = Pathname.new(ARGV[1]).realpath
project_source = Pathname.new(ARGV[2]).realpath
freerdp_source = Pathname.new(ARGV[3]).realpath
project_version = ARGV[4]
ffmpeg_provenance_path = ARGV[5].to_s.empty? ? nil : Pathname.new(ARGV[5]).realpath
freerdp_manifest_path = project_source.join("third_party", "freerdp", "manifest.json")
raise "FreeRDP source manifest is missing" unless freerdp_manifest_path.file?

freerdp_manifest = JSON.parse(freerdp_manifest_path.read)
raise "unexpected FreeRDP manifest schema" unless freerdp_manifest["schemaVersion"] == 1
raise "unexpected FreeRDP dependency" unless freerdp_manifest["name"] == "FreeRDP"
freerdp_commit = freerdp_manifest.fetch("commit")
unless freerdp_commit.match?(/\A[0-9a-f]{40}\z/)
  raise "invalid FreeRDP commit"
end
freerdp_source_sha256 = freerdp_manifest.dig("source", "sha256")
unless freerdp_source_sha256&.match?(/\A[0-9a-f]{64}\z/)
  raise "invalid FreeRDP source SHA-256"
end
freerdp_source_url = freerdp_manifest.dig("source", "url")
unless freerdp_source_url&.end_with?("/#{freerdp_commit}")
  raise "FreeRDP source URL does not match its commit"
end

def relative_package_path(value)
  path = Pathname.new(value)
  raise "package path must be relative: #{value}" if path.absolute?

  clean = path.cleanpath.to_s
  raise "package path escapes its root: #{value}" if clean == ".." || clean.start_with?("../")

  clean
end

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def purl_escape(value)
  CGI.escape(value).gsub("+", "%20")
end

def descendant_of?(path, root)
  path == root || path.to_s.start_with?("#{root}/")
end

def license_files(root)
  matches = []
  Find.find(root.to_s) do |entry|
    relative = Pathname.new(entry).relative_path_from(root).each_filename.to_a
    if File.directory?(entry) && relative.length > 4
      Find.prune
      next
    end
    next unless File.file?(entry)
    next unless File.basename(entry).match?(/\A(?:LICENSE|COPYING|NOTICE)(?:[._-].*)?\z/i)

    matches << Pathname.new(entry)
  end
  matches.sort
end

def copy_licenses(component_name, source_root, licenses_root, candidates = nil)
  candidates ||= license_files(source_root)
  raise "no license files found for #{component_name} in #{source_root}" if candidates.empty?

  safe_name = component_name.gsub(/[^A-Za-z0-9_.@+-]/, "_")
  destination_dir = licenses_root.join(safe_name)
  FileUtils.mkdir_p(destination_dir)
  copied = []
  candidates.each do |source|
    relative = source.relative_path_from(source_root).to_s
    destination = destination_dir.join(relative.tr("/\\", "__"))
    if destination.exist? && sha256(destination) != sha256(source)
      raise "license filename collision for #{component_name}: #{destination.basename}"
    end
    FileUtils.cp(source, destination)
    copied << destination
  end
  copied.sort
end


managed_ffmpeg = nil
if ffmpeg_provenance_path
  provenance = JSON.parse(ffmpeg_provenance_path.read)
  raise "unexpected FFmpeg provenance schema" unless provenance["schemaVersion"] == 1
  raise "unexpected managed dependency" unless provenance["name"] == "ffmpeg"
  raise "managed FFmpeg version is missing" unless provenance["version"].is_a?(String) && !provenance["version"].empty?
  unless provenance["licenseExpression"] == "LGPL-2.1-or-later"
    raise "managed FFmpeg must be LGPL-2.1-or-later"
  end

  source = provenance.fetch("source")
  source_sha256 = source.fetch("sha256")
  raise "invalid FFmpeg source SHA-256" unless source_sha256.match?(/\A[0-9a-f]{64}\z/)
  build = provenance.fetch("build")
  install_prefix = Pathname.new(build.fetch("installPrefix")).realpath
  source_root = Pathname.new(build.fetch("sourceRoot")).realpath
  source_archive = Pathname.new(build.fetch("sourceArchive")).realpath
  configuration_file = Pathname.new(build.fetch("configurationFile")).realpath
  raise "FFmpeg source archive SHA-256 mismatch" unless sha256(source_archive) == source_sha256
  raise "FFmpeg build configuration is empty" unless configuration_file.file? && configuration_file.size.positive?

  forbidden_flags = %w[
    --enable-gpl
    --enable-version3
    --enable-libx264
    --enable-libx265
    --enable-nonfree
  ]
  configure_flags = provenance.fetch("configureFlags")
  raise "FFmpeg configure flags are missing" unless configure_flags.is_a?(Array) && !configure_flags.empty?
  forbidden_flags.each do |flag|
    raise "managed FFmpeg enables forbidden option #{flag}" if configure_flags.include?(flag)
  end
  expected_libraries = provenance.fetch("expectedLibraries")
  unless expected_libraries.sort == %w[libavcodec libavutil libswresample libswscale]
    raise "managed FFmpeg library allowlist is unexpected"
  end

  license_paths = build.fetch("licenseFiles").map { |path| Pathname.new(path).realpath }
  license_paths.each do |path|
    raise "FFmpeg license file escapes its source tree: #{path}" unless descendant_of?(path, source_root)
  end
  provenance.fetch("patches", []).each do |entry|
    relative = relative_package_path(entry.fetch("path"))
    patch_path = project_source.join("third_party", "ffmpeg", relative)
    expected_hash = entry.fetch("sha256")
    raise "invalid FFmpeg patch SHA-256: #{relative}" unless expected_hash.match?(/\A[0-9a-f]{64}\z/)
    raise "FFmpeg patch is missing: #{relative}" unless patch_path.file?
    raise "FFmpeg patch SHA-256 mismatch: #{relative}" unless sha256(patch_path) == expected_hash
  end

  managed_ffmpeg = {
    provenance: provenance,
    install_prefix: install_prefix,
    source_root: source_root,
    source_archive: source_archive,
    configuration_file: configuration_file,
    license_paths: license_paths,
    expected_libraries: expected_libraries
  }
end

records = origins_path.readlines(chomp: true).reject(&:empty?).map.with_index(1) do |line, line_number|
  fields = line.split("\t", -1)
  raise "invalid dependency origin row #{line_number}" unless fields.length == 3

  packaged_path = relative_package_path(fields[0])
  owner_path = relative_package_path(fields[2])
  source_path = Pathname.new(fields[1]).realpath
  unless package_dir.join(packaged_path).file?
    raise "recorded dependency is missing from package: #{packaged_path}"
  end

  if managed_ffmpeg && descendant_of?(source_path, managed_ffmpeg.fetch(:install_prefix))
    basename = source_path.basename.to_s
    allowed = managed_ffmpeg.fetch(:expected_libraries).any? do |library|
      basename.match?(/\A#{Regexp.escape(library)}(?:\.[0-9.]+)?\.dylib\z/)
    end
    raise "unexpected managed FFmpeg library: #{basename}" unless allowed

    {
      packaged_path: packaged_path,
      owner_path: owner_path,
      source_path: source_path,
      provider: :project,
      component_key: ["project", "ffmpeg", managed_ffmpeg.dig(:provenance, "version")]
    }
  else
    match = source_path.to_s.match(%r{\A(.*/Cellar)/([^/]+)/([^/]+)/})
    raise "dependency has no recognized provenance: #{source_path}" unless match

    {
      packaged_path: packaged_path,
      owner_path: owner_path,
      source_path: source_path,
      provider: :homebrew,
      component_key: ["homebrew", match[2], match[3]],
      formula_name: match[2],
      formula_version: match[3],
      formula_root: Pathname.new(match[1]).join(match[2], match[3]).realpath
    }
  end
end
raise "dependency origin manifest is empty" if records.empty?

origins_by_file = records.group_by { |record| record[:packaged_path] }
origins_by_file.each do |packaged_path, file_records|
  origins = file_records.map { |record| record[:source_path].to_s }.uniq
  raise "package file has multiple dependency origins: #{packaged_path}" if origins.length != 1
end

formula_groups = records.select { |record| record[:provider] == :homebrew }
                        .group_by { |record| [record[:formula_name], record[:formula_version]] }
formula_names = formula_groups.keys.map(&:first).uniq.sort
brew_formulae = {}
unless formula_names.empty?
  brew_stdout, brew_stderr, brew_status = Open3.capture3("brew", "info", "--json=v2", *formula_names)
  unless brew_status.success?
    raise "unable to query Homebrew metadata: #{brew_stderr.strip}"
  end
  brew_formulae = JSON.parse(brew_stdout).fetch("formulae").to_h do |formula|
    [formula.fetch("name"), formula]
  end
end

compliance_dir = package_dir.join("share", "macrdp")
FileUtils.rm_rf(compliance_dir)
licenses_root = compliance_dir.join("licenses")
FileUtils.mkdir_p(licenses_root)

license_sets = {}
license_sets["macrdp-cpp"] = copy_licenses(
  "macrdp-cpp",
  project_source,
  licenses_root,
  [project_source.join("LICENSE"), project_source.join("NOTICE")]
)
license_sets["FreeRDP"] = copy_licenses(
  "FreeRDP",
  freerdp_source,
  licenses_root,
  [freerdp_source.join("LICENSE")]
)
formula_groups.each do |(formula_name, _formula_version), group_records|
  license_sets[formula_name] = copy_licenses(
    formula_name,
    group_records.first.fetch(:formula_root),
    licenses_root
  )
end
if managed_ffmpeg
  license_sets["ffmpeg"] = copy_licenses(
    "ffmpeg",
    managed_ffmpeg.fetch(:source_root),
    licenses_root,
    managed_ffmpeg.fetch(:license_paths)
  )
end

ffmpeg_configuration = compliance_dir.join("ffmpeg-build-configuration.txt")
ffmpeg_source_provenance = compliance_dir.join("ffmpeg-source-provenance.json")
freerdp_source_provenance = compliance_dir.join("freerdp-source-provenance.json")
File.write(
  freerdp_source_provenance,
  JSON.pretty_generate(freerdp_manifest) + "\n"
)
if managed_ffmpeg
  FileUtils.cp(managed_ffmpeg.fetch(:configuration_file), ffmpeg_configuration)
  provenance = managed_ffmpeg.fetch(:provenance)
  public_provenance = {
    "schemaVersion" => provenance.fetch("schemaVersion"),
    "name" => provenance.fetch("name"),
    "version" => provenance.fetch("version"),
    "homepage" => provenance.fetch("homepage"),
    "licenseExpression" => provenance.fetch("licenseExpression"),
    "source" => provenance.fetch("source"),
    "patches" => provenance.fetch("patches", []),
    "configureFlags" => provenance.fetch("configureFlags"),
    "expectedLibraries" => provenance.fetch("expectedLibraries"),
    "build" => provenance.fetch("build").slice(
      "architecture", "minimumMacOS", "compiler"
    )
  }
  File.write(ffmpeg_source_provenance, JSON.pretty_generate(public_provenance) + "\n")
elsif (ffmpeg_group = formula_groups.find { |(name, _version), _records| name == "ffmpeg" })
  ffmpeg_binary = ffmpeg_group.last.first.fetch(:formula_root).join("bin", "ffmpeg")
  stdout, stderr, status = Open3.capture3(ffmpeg_binary.to_s, "-hide_banner", "-buildconf")
  raise "unable to record FFmpeg build configuration: #{stderr.strip}" unless status.success?

  File.write(ffmpeg_configuration, (stdout + stderr).lstrip)
end

notices_path = compliance_dir.join("THIRD_PARTY_NOTICES.md")
notice_lines = [
  "# Third-Party Notices",
  "",
  "This inventory is generated from the exact dynamic libraries copied into this package.",
  "The bundled license files remain authoritative.",
  "",
  "## FreeRDP #{freerdp_manifest.fetch("version")}",
  "",
  "- Upstream version: #{freerdp_manifest.fetch("upstreamVersion")}",
  "- License: #{freerdp_manifest.fetch("licenseExpression")}",
  "- Homepage: #{freerdp_manifest.fetch("homepage")}",
  "- Repository: #{freerdp_manifest.fetch("repository")}",
  "- Revision: #{freerdp_commit}",
  "- Source: #{freerdp_source_url}",
  "- Source SHA-256: #{freerdp_source_sha256}",
  "- Linkage: statically linked",
  "- License files: #{license_sets.fetch("FreeRDP").map { |path| path.relative_path_from(package_dir) }.join(", ")}",
  ""
]
if managed_ffmpeg
  provenance = managed_ffmpeg.fetch(:provenance)
  managed_files = records.select { |record| record[:provider] == :project }
                         .map { |record| record[:packaged_path] }.uniq.sort
  notice_lines.concat([
    "## FFmpeg #{provenance.fetch("version")}",
    "",
    "- License: #{provenance.fetch("licenseExpression")}",
    "- Homepage: #{provenance.fetch("homepage")}",
    "- Linkage: dynamically linked",
    "- Source: #{provenance.dig("source", "url")}",
    "- Source SHA-256: #{provenance.dig("source", "sha256")}",
    "- Packaged files: #{managed_files.join(", ")}",
    "- License files: #{license_sets.fetch("ffmpeg").map { |path| path.relative_path_from(package_dir) }.join(", ")}",
    ""
  ])
end
formula_groups.keys.sort.each do |formula_name, formula_version|
  metadata = brew_formulae.fetch(formula_name) do
    raise "Homebrew metadata is missing formula #{formula_name}"
  end
  license_expression = metadata["license"]
  raise "Homebrew metadata has no license for #{formula_name}" unless license_expression.is_a?(String) && !license_expression.empty?

  files = formula_groups.fetch([formula_name, formula_version])
                        .map { |record| record[:packaged_path] }.uniq.sort
  notice_lines.concat([
    "## #{formula_name} #{formula_version}",
    "",
    "- License: #{license_expression}",
    "- Homepage: #{metadata.fetch("homepage")}",
    "- Packaged files: #{files.join(", ")}",
    "- License files: #{license_sets.fetch(formula_name).map { |path| path.relative_path_from(package_dir) }.join(", ")}",
    ""
  ])
end
File.write(notices_path, notice_lines.join("\n"))

presets_documentation = compliance_dir.join("PRESETS.md")
presets_documentation_source = project_source.join("docs", "presets.md")
raise "preset documentation is missing: #{presets_documentation_source}" unless presets_documentation_source.file?

FileUtils.cp(presets_documentation_source, presets_documentation)

def compliance_properties(paths, package_dir)
  paths.sort.map do |path|
    relative = path.relative_path_from(package_dir).to_s
    { "name" => "macrdp:compliance-file-sha256", "value" => "#{relative}=#{sha256(path)}" }
  end
end

root_ref = "pkg:github/zx1991/macrdp-cpp@#{purl_escape(project_version)}"
server_relative = "bin/macrdp-server"
project_payload_relatives = %w[
  bin/macrdp-install-launch-agent
  bin/macrdp-manage
  bin/macrdp-rotate-password
  bin/macrdp-server
  bin/macrdp-verify-package
]
project_payload_relatives.each do |relative|
  path = package_dir.join(relative)
  raise "project payload file is missing: #{relative}" unless path.file? && !path.symlink?
end

git_stdout, _git_stderr, git_status = Open3.capture3(
  "git", "-C", project_source.to_s, "rev-parse", "HEAD"
)
if git_status.success?
  source_revision = git_stdout.strip
  status_stdout, _status_stderr, status_result = Open3.capture3(
    "git", "-C", project_source.to_s, "status", "--porcelain", "--untracked-files=normal"
  )
  source_revision += "-dirty" if status_result.success? && !status_stdout.empty?
else
  source_revision = "source-archive"
end
root_component = {
  "type" => "application",
  "bom-ref" => root_ref,
  "group" => "zx1991",
  "name" => "macrdp-cpp",
  "version" => project_version,
  "purl" => root_ref,
  "licenses" => [{ "expression" => "Apache-2.0" }],
  "evidence" => {
    "occurrences" => project_payload_relatives.map { |relative| { "location" => relative } }
  },
  "properties" => [
    { "name" => "macrdp:git-revision", "value" => source_revision },
    { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/macrdp-cpp" }
  ] + project_payload_relatives.map do |relative|
    { "name" => "macrdp:packaged-file-sha256", "value" => "#{relative}=#{sha256(package_dir.join(relative))}" }
  end + compliance_properties(
    license_sets.fetch("macrdp-cpp") + [notices_path, presets_documentation],
    package_dir
  )
}

freerdp_ref = "pkg:github/zx1991/FreeRDP@#{freerdp_commit}"
freerdp_component = {
  "type" => "library",
  "bom-ref" => freerdp_ref,
  "group" => "zx1991",
  "name" => "FreeRDP",
  "version" => freerdp_manifest.fetch("version"),
  "purl" => freerdp_ref,
  "licenses" => [{ "expression" => freerdp_manifest.fetch("licenseExpression") }],
  "externalReferences" => [
    { "type" => "website", "url" => freerdp_manifest.fetch("homepage") },
    { "type" => "vcs", "url" => "#{freerdp_manifest.fetch("repository")}##{freerdp_commit}" },
    { "type" => "distribution", "url" => freerdp_source_url }
  ],
  "properties" => [
    { "name" => "macrdp:linkage", "value" => "static" },
    { "name" => "macrdp:upstream-version", "value" => freerdp_manifest.fetch("upstreamVersion") },
    { "name" => "macrdp:git-revision", "value" => freerdp_commit },
    { "name" => "macrdp:source-archive-sha256", "value" => freerdp_source_sha256 },
    { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/FreeRDP" }
  ] + compliance_properties(
    license_sets.fetch("FreeRDP") + [freerdp_source_provenance],
    package_dir
  )
}

formula_refs = {}
formula_components = formula_groups.keys.sort.map do |formula_name, formula_version|
  metadata = brew_formulae.fetch(formula_name)
  group_records = formula_groups.fetch([formula_name, formula_version])
  packaged_files = group_records.map { |record| record[:packaged_path] }.uniq.sort
  ref = "pkg:generic/homebrew/#{purl_escape(formula_name)}@#{purl_escape(formula_version)}"
  formula_refs[[formula_name, formula_version]] = ref
  extra_compliance = license_sets.fetch(formula_name)
  if formula_name == "ffmpeg" && ffmpeg_configuration.file?
    extra_compliance += [ffmpeg_configuration]
  end

  {
    "type" => "library",
    "bom-ref" => ref,
    "group" => "Homebrew",
    "name" => formula_name,
    "version" => formula_version,
    "purl" => ref,
    "licenses" => [{ "expression" => metadata.fetch("license") }],
    "externalReferences" => [{ "type" => "website", "url" => metadata.fetch("homepage") }],
    "evidence" => { "occurrences" => packaged_files.map { |path| { "location" => path } } },
    "properties" => [
      { "name" => "macrdp:homebrew-formula", "value" => formula_name },
      { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/#{formula_name}" }
    ] + packaged_files.map do |path|
      { "name" => "macrdp:packaged-file-sha256", "value" => "#{path}=#{sha256(package_dir.join(path))}" }
    end + compliance_properties(extra_compliance, package_dir)
  }
end

managed_ffmpeg_ref = nil
managed_ffmpeg_component = nil
if managed_ffmpeg
  provenance = managed_ffmpeg.fetch(:provenance)
  managed_ffmpeg_ref = "pkg:generic/ffmpeg@#{purl_escape(provenance.fetch("version"))}"
  packaged_files = records.select { |record| record[:provider] == :project }
                          .map { |record| record[:packaged_path] }.uniq.sort
  managed_compliance = license_sets.fetch("ffmpeg") +
                       [ffmpeg_configuration, ffmpeg_source_provenance]
  managed_ffmpeg_component = {
    "type" => "library",
    "bom-ref" => managed_ffmpeg_ref,
    "group" => "FFmpeg",
    "name" => "ffmpeg",
    "version" => provenance.fetch("version"),
    "purl" => managed_ffmpeg_ref,
    "licenses" => [{ "expression" => provenance.fetch("licenseExpression") }],
    "externalReferences" => [
      { "type" => "website", "url" => provenance.fetch("homepage") },
      { "type" => "distribution", "url" => provenance.dig("source", "url") }
    ],
    "evidence" => { "occurrences" => packaged_files.map { |path| { "location" => path } } },
    "properties" => [
      { "name" => "macrdp:dependency-provider", "value" => "project-build" },
      { "name" => "macrdp:linkage", "value" => "dynamic" },
      { "name" => "macrdp:source-archive-sha256", "value" => provenance.dig("source", "sha256") },
      { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/ffmpeg" }
    ] + packaged_files.map do |path|
      { "name" => "macrdp:packaged-file-sha256", "value" => "#{path}=#{sha256(package_dir.join(path))}" }
    end + compliance_properties(managed_compliance, package_dir)
  }
end

file_refs = origins_by_file.to_h do |packaged_path, file_records|
  record = file_records.first
  ref = if record[:provider] == :project
          managed_ffmpeg_ref
        else
          formula_refs.fetch([record[:formula_name], record[:formula_version]])
        end
  [packaged_path, ref]
end
dependency_map = Hash.new { |hash, key| hash[key] = Set.new }
dependency_map[root_ref] << freerdp_ref
records.each do |record|
  owner_ref = record[:owner_path] == server_relative ? root_ref : file_refs.fetch(record[:owner_path])
  dependency_ref = file_refs.fetch(record[:packaged_path])
  dependency_map[owner_ref] << dependency_ref unless owner_ref == dependency_ref
end
all_components = [freerdp_component] + formula_components + [managed_ffmpeg_component].compact
all_refs = [root_ref] + all_components.map { |component| component.fetch("bom-ref") }
dependencies = all_refs.sort.map do |ref|
  { "ref" => ref, "dependsOn" => dependency_map[ref].to_a.sort }
end

sbom = {
  "$schema" => "https://cyclonedx.org/schema/bom-1.6.schema.json",
  "bomFormat" => "CycloneDX",
  "specVersion" => "1.6",
  "version" => 1,
  "metadata" => {
    "tools" => {
      "components" => [{ "type" => "application", "name" => "macrdp compliance generator", "version" => "1" }]
    },
    "component" => root_component
  },
  "components" => all_components,
  "dependencies" => dependencies
}
File.write(compliance_dir.join("sbom.cdx.json"), JSON.pretty_generate(sbom) + "\n")

puts "Generated compliance bundle: #{all_components.length} third-party components"
