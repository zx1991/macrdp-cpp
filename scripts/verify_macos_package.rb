#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "pathname"

unless ARGV.length == 1
  warn "usage: #{$PROGRAM_NAME} <package-directory>"
  exit 2
end

package_input = Pathname.new(ARGV[0])
raise "package directory must not be a symbolic link: #{package_input}" if package_input.symlink?

package_dir = package_input.realpath
raise "package path is not a directory: #{package_dir}" unless package_dir.directory?

def safe_relative_path(value)
  path = Pathname.new(value)
  raise "package path must be relative: #{value}" if path.absolute?

  clean = path.cleanpath.to_s
  raise "package path escapes its root: #{value}" if clean == ".." || clean.start_with?("../")

  clean
end

sbom_relative = "share/macrdp/sbom.cdx.json"
sbom_path = package_dir.join(sbom_relative)
raise "CycloneDX SBOM is missing: #{sbom_path}" unless sbom_path.file? && !sbom_path.symlink?

sbom = JSON.parse(sbom_path.read)
raise "unexpected SBOM format" unless sbom["bomFormat"] == "CycloneDX"
raise "unexpected CycloneDX version" unless sbom["specVersion"] == "1.6"

root_component = sbom.dig("metadata", "component")
raise "SBOM metadata component is missing" unless root_component.is_a?(Hash)
raise "unexpected package component" unless root_component["name"] == "macrdp-cpp"

version = root_component["version"]
unless version.is_a?(String) && version.match?(/\A[0-9A-Za-z][0-9A-Za-z.+-]*\z/)
  raise "package version is missing or unsafe"
end

components = [root_component] + sbom.fetch("components")
expected_hashes = {}
components.each do |component|
  component.fetch("properties", []).each do |property|
    next unless ["macrdp:packaged-file-sha256", "macrdp:compliance-file-sha256"].include?(property["name"])

    path_value, expected_hash = property.fetch("value").split("=", 2)
    relative = safe_relative_path(path_value)
    unless expected_hash&.match?(/\A[0-9a-f]{64}\z/)
      raise "invalid SHA-256 for #{relative}"
    end
    if expected_hashes.key?(relative) && expected_hashes[relative] != expected_hash
      raise "conflicting SHA-256 values for #{relative}"
    end
    expected_hashes[relative] = expected_hash
  end
end

actual_files = []
Find.find(package_dir.to_s) do |entry|
  raise "package contains a symbolic link: #{entry}" if File.symlink?(entry)
  next unless File.file?(entry)

  relative = Pathname.new(entry).relative_path_from(package_dir).to_s
  actual_files << relative unless relative == sbom_relative
end

unless expected_hashes.keys.sort == actual_files.sort
  missing = actual_files - expected_hashes.keys
  extra = expected_hashes.keys - actual_files
  raise "package hash coverage mismatch (missing: #{missing.join(", ")}; extra: #{extra.join(", ")})"
end

expected_hashes.each do |relative, expected_hash|
  path = package_dir.join(relative)
  actual_hash = Digest::SHA256.file(path).hexdigest
  raise "package SHA-256 mismatch for #{relative}" unless actual_hash == expected_hash
end

required_files = %w[
  bin/macrdp-install-launch-agent
  bin/macrdp-manage
  bin/macrdp-rotate-password
  bin/macrdp-server
  bin/macrdp-verify-package
]
required_files.each do |relative|
  path = package_dir.join(relative)
  unless path.file? && !path.symlink? && path.executable?
    raise "required package file is missing or not executable: #{relative}"
  end
end

puts "version=#{version}"
puts "sbom_sha256=#{Digest::SHA256.file(sbom_path).hexdigest}"
puts "verified_files=#{actual_files.length}"
