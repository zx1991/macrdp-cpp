#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "pathname"

unless ARGV.length == 1
  warn "usage: #{$PROGRAM_NAME} <package>"
  exit 2
end

package_dir = Pathname.new(ARGV[0]).realpath
compliance_dir = package_dir.join("share", "macrdp")
sbom_path = compliance_dir.join("sbom.cdx.json")
raise "CycloneDX SBOM is missing: #{sbom_path}" unless sbom_path.file?

sbom = JSON.parse(sbom_path.read)
raise "unexpected SBOM format" unless sbom["bomFormat"] == "CycloneDX"
raise "unexpected CycloneDX version" unless sbom["specVersion"] == "1.6"
raise "unexpected SBOM document version" unless sbom["version"] == 1

root_component = sbom.dig("metadata", "component")
raise "SBOM metadata component is missing" unless root_component.is_a?(Hash)
components = [root_component] + sbom.fetch("components")
refs = components.map { |component| component.fetch("bom-ref") }
raise "SBOM contains duplicate component references" unless refs.uniq.length == refs.length

def safe_relative_path(value)
  path = Pathname.new(value)
  raise "SBOM path must be relative: #{value}" if path.absolute?

  clean = path.cleanpath.to_s
  raise "SBOM path escapes the package: #{value}" if clean == ".." || clean.start_with?("../")

  clean
end

packaged_hashes = {}
compliance_hashes = {}
components.each do |component|
  licenses = component["licenses"]
  raise "component has no declared license: #{component.fetch("name")}" unless licenses.is_a?(Array) && !licenses.empty?

  properties = component.fetch("properties", [])
  license_directory = properties.find { |property| property["name"] == "macrdp:license-directory" }
  raise "component has no license directory: #{component.fetch("name")}" unless license_directory
  license_path = package_dir.join(safe_relative_path(license_directory.fetch("value")))
  raise "component license directory is missing: #{license_path}" unless license_path.directory?
  raise "component license directory is empty: #{license_path}" if license_path.children.empty?

  properties.each do |property|
    case property["name"]
    when "macrdp:packaged-file-sha256", "macrdp:compliance-file-sha256"
      path_value, expected_hash = property.fetch("value").split("=", 2)
      raise "invalid SHA-256 property for #{component.fetch("name")}" unless expected_hash&.match?(/\A[0-9a-f]{64}\z/)
      relative = safe_relative_path(path_value)
      target = property["name"] == "macrdp:packaged-file-sha256" ? packaged_hashes : compliance_hashes
      if target.key?(relative) && target[relative] != expected_hash
        raise "conflicting hashes for #{relative}"
      end
      target[relative] = expected_hash
    end
  end
end

actual_payload = ["bin/macrdp-server"] + Dir.glob(package_dir.join("lib", "*.dylib").to_s)
                                               .map { |path| Pathname.new(path).relative_path_from(package_dir).to_s }
                                               .sort
unless packaged_hashes.keys.sort == actual_payload.sort
  missing = actual_payload - packaged_hashes.keys
  extra = packaged_hashes.keys - actual_payload
  raise "SBOM payload coverage mismatch (missing: #{missing.join(", ")}; extra: #{extra.join(", ")})"
end

packaged_hashes.merge(compliance_hashes).each do |relative, expected_hash|
  path = package_dir.join(relative)
  raise "SBOM-recorded file is missing: #{relative}" unless path.file?
  actual_hash = Digest::SHA256.file(path).hexdigest
  raise "SBOM hash mismatch for #{relative}" unless actual_hash == expected_hash
end

actual_compliance = []
Find.find(compliance_dir.to_s) do |entry|
  raise "compliance bundle contains a symbolic link: #{entry}" if File.symlink?(entry)
  next unless File.file?(entry)

  relative = Pathname.new(entry).relative_path_from(package_dir).to_s
  actual_compliance << relative unless relative == "share/macrdp/sbom.cdx.json"
end
unless compliance_hashes.keys.sort == actual_compliance.sort
  missing = actual_compliance - compliance_hashes.keys
  extra = compliance_hashes.keys - actual_compliance
  raise "SBOM compliance-file coverage mismatch (missing: #{missing.join(", ")}; extra: #{extra.join(", ")})"
end

dependency_rows = sbom.fetch("dependencies")
dependency_refs = dependency_rows.map { |row| row.fetch("ref") }
raise "SBOM dependency rows do not cover every component" unless dependency_refs.sort == refs.sort
dependency_rows.each do |row|
  row.fetch("dependsOn").each do |dependency_ref|
    raise "SBOM dependency references an unknown component: #{dependency_ref}" unless refs.include?(dependency_ref)
  end
end

notices = compliance_dir.join("THIRD_PARTY_NOTICES.md")
raise "third-party notices are missing" unless notices.file? && notices.size.positive?
ffmpeg_component = components.find { |component| component["name"] == "ffmpeg" }
if ffmpeg_component
  configuration = compliance_dir.join("ffmpeg-build-configuration.txt")
  raise "FFmpeg build configuration is missing" unless configuration.file? && configuration.size.positive?
end

puts "Validated compliance bundle: #{components.length - 1} third-party components, #{actual_payload.length} payload files"
