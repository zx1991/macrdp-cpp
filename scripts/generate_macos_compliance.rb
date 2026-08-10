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

unless ARGV.length == 5
  warn "usage: #{$PROGRAM_NAME} <package> <dependency-origins> <project-source> <freerdp-source> <project-version>"
  exit 2
end

package_dir = Pathname.new(ARGV[0]).realpath
origins_path = Pathname.new(ARGV[1]).realpath
project_source = Pathname.new(ARGV[2]).realpath
freerdp_source = Pathname.new(ARGV[3]).realpath
project_version = ARGV[4]

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

records = origins_path.readlines(chomp: true).reject(&:empty?).map.with_index(1) do |line, line_number|
  fields = line.split("\t", -1)
  raise "invalid dependency origin row #{line_number}" unless fields.length == 3

  packaged_path = relative_package_path(fields[0])
  owner_path = relative_package_path(fields[2])
  source_path = Pathname.new(fields[1]).realpath
  unless package_dir.join(packaged_path).file?
    raise "recorded dependency is missing from package: #{packaged_path}"
  end

  match = source_path.to_s.match(%r{\A(.*/Cellar)/([^/]+)/([^/]+)/})
  raise "dependency is not traceable to a Homebrew Cellar: #{source_path}" unless match

  {
    packaged_path: packaged_path,
    owner_path: owner_path,
    source_path: source_path,
    formula_name: match[2],
    formula_version: match[3],
    formula_root: Pathname.new(match[1]).join(match[2], match[3]).realpath
  }
end
raise "dependency origin manifest is empty" if records.empty?

origins_by_file = records.group_by { |record| record[:packaged_path] }
origins_by_file.each do |packaged_path, file_records|
  origins = file_records.map { |record| record[:source_path].to_s }.uniq
  raise "package file has multiple dependency origins: #{packaged_path}" if origins.length != 1
end

formula_groups = records.group_by { |record| [record[:formula_name], record[:formula_version]] }
formula_names = formula_groups.keys.map(&:first).uniq.sort
brew_stdout, brew_stderr, brew_status = Open3.capture3("brew", "info", "--json=v2", *formula_names)
unless brew_status.success?
  raise "unable to query Homebrew metadata: #{brew_stderr.strip}"
end
brew_formulae = JSON.parse(brew_stdout).fetch("formulae").to_h do |formula|
  [formula.fetch("name"), formula]
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

ffmpeg_configuration = compliance_dir.join("ffmpeg-build-configuration.txt")
if (ffmpeg_group = formula_groups.find { |(name, _version), _records| name == "ffmpeg" })
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
  "## FreeRDP 3.30.0",
  "",
  "- License: Apache-2.0",
  "- Homepage: https://www.freerdp.com/",
  "- Linkage: statically linked",
  "- License files: #{license_sets.fetch("FreeRDP").map { |path| path.relative_path_from(package_dir) }.join(", ")}",
  ""
]
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

def compliance_properties(paths, package_dir)
  paths.sort.map do |path|
    relative = path.relative_path_from(package_dir).to_s
    { "name" => "macrdp:compliance-file-sha256", "value" => "#{relative}=#{sha256(path)}" }
  end
end

root_ref = "pkg:github/zx1991/macrdp-cpp@#{purl_escape(project_version)}"
server_relative = "bin/macrdp-server"
server_path = package_dir.join(server_relative)
raise "packaged server is missing" unless server_path.file?

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
  "evidence" => { "occurrences" => [{ "location" => server_relative }] },
  "properties" => [
    { "name" => "macrdp:git-revision", "value" => source_revision },
    { "name" => "macrdp:packaged-file-sha256", "value" => "#{server_relative}=#{sha256(server_path)}" },
    { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/macrdp-cpp" }
  ] + compliance_properties(license_sets.fetch("macrdp-cpp") + [notices_path], package_dir)
}

freerdp_ref = "pkg:github/FreeRDP/FreeRDP@3.30.0"
freerdp_component = {
  "type" => "library",
  "bom-ref" => freerdp_ref,
  "group" => "FreeRDP",
  "name" => "FreeRDP",
  "version" => "3.30.0",
  "purl" => freerdp_ref,
  "licenses" => [{ "expression" => "Apache-2.0" }],
  "externalReferences" => [{ "type" => "website", "url" => "https://www.freerdp.com/" }],
  "properties" => [
    { "name" => "macrdp:linkage", "value" => "static" },
    { "name" => "macrdp:license-directory", "value" => "share/macrdp/licenses/FreeRDP" }
  ] + compliance_properties(license_sets.fetch("FreeRDP"), package_dir)
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

file_refs = origins_by_file.to_h do |packaged_path, file_records|
  record = file_records.first
  [packaged_path, formula_refs.fetch([record[:formula_name], record[:formula_version]])]
end
dependency_map = Hash.new { |hash, key| hash[key] = Set.new }
dependency_map[root_ref] << freerdp_ref
records.each do |record|
  owner_ref = record[:owner_path] == server_relative ? root_ref : file_refs.fetch(record[:owner_path])
  dependency_ref = file_refs.fetch(record[:packaged_path])
  dependency_map[owner_ref] << dependency_ref unless owner_ref == dependency_ref
end
all_refs = [root_ref, freerdp_ref] + formula_components.map { |component| component.fetch("bom-ref") }
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
  "components" => [freerdp_component] + formula_components,
  "dependencies" => dependencies
}
File.write(compliance_dir.join("sbom.cdx.json"), JSON.pretty_generate(sbom) + "\n")

puts "Generated compliance bundle: #{formula_components.length + 1} third-party components"
