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

actual_payload = %w[
  bin/macrdp-install-launch-agent
  bin/macrdp-manage
  bin/macrdp-rotate-password
  bin/macrdp-server
  bin/macrdp-verify-package
] + Dir.glob(package_dir.join("lib", "*.dylib").to_s)
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
presets_documentation = compliance_dir.join("PRESETS.md")
unless presets_documentation.file? && presets_documentation.size.positive?
  raise "preset documentation is missing"
end
freerdp_component = components.find { |component| component["name"] == "FreeRDP" }
raise "FreeRDP component is missing" unless freerdp_component
freerdp_provenance_path = compliance_dir.join("freerdp-source-provenance.json")
unless freerdp_provenance_path.file? && freerdp_provenance_path.size.positive?
  raise "FreeRDP source provenance is missing"
end
freerdp_provenance = JSON.parse(freerdp_provenance_path.read)
unless freerdp_provenance["schemaVersion"] == 1
  raise "unexpected FreeRDP source provenance schema"
end
unless freerdp_provenance["version"] == freerdp_component["version"]
  raise "FreeRDP provenance version mismatch"
end
freerdp_source_hash = freerdp_provenance.dig("source", "sha256")
unless freerdp_source_hash&.match?(/\A[0-9a-f]{64}\z/)
  raise "invalid FreeRDP source provenance hash"
end
freerdp_component_hash = freerdp_component.fetch("properties").find do |property|
  property["name"] == "macrdp:source-archive-sha256"
end
unless freerdp_component_hash&.fetch("value") == freerdp_source_hash
  raise "FreeRDP component source hash mismatch"
end
ffmpeg_component = components.find { |component| component["name"] == "ffmpeg" }
if ffmpeg_component
  configuration = compliance_dir.join("ffmpeg-build-configuration.txt")
  raise "FFmpeg build configuration is missing" unless configuration.file? && configuration.size.positive?

  provider = ffmpeg_component.fetch("properties", []).find do |property|
    property["name"] == "macrdp:dependency-provider"
  end
  if provider&.fetch("value") == "project-build"
    licenses = ffmpeg_component.fetch("licenses")
    unless licenses == [{ "expression" => "LGPL-2.1-or-later" }]
      raise "project-built FFmpeg must be LGPL-2.1-or-later"
    end
    forbidden_options = %w[
      --enable-gpl
      --enable-version3
      --enable-libx264
      --enable-libx265
      --enable-nonfree
    ]
    forbidden_options.each do |option|
      raise "project-built FFmpeg enables #{option}" if configuration.read.include?(option)
    end

    provenance_path = compliance_dir.join("ffmpeg-source-provenance.json")
    raise "FFmpeg source provenance is missing" unless provenance_path.file? && provenance_path.size.positive?
    provenance = JSON.parse(provenance_path.read)
    raise "unexpected FFmpeg source provenance schema" unless provenance["schemaVersion"] == 1
    raise "FFmpeg provenance version mismatch" unless provenance["version"] == ffmpeg_component["version"]
    raise "FFmpeg provenance license mismatch" unless provenance["licenseExpression"] == "LGPL-2.1-or-later"
    source_hash = provenance.dig("source", "sha256")
    raise "invalid FFmpeg source provenance hash" unless source_hash&.match?(/\A[0-9a-f]{64}\z/)
    component_hash = ffmpeg_component.fetch("properties").find do |property|
      property["name"] == "macrdp:source-archive-sha256"
    end
    raise "FFmpeg component source hash mismatch" unless component_hash&.fetch("value") == source_hash
    unless provenance.fetch("expectedLibraries").sort == %w[libavcodec libavutil libswresample libswscale]
      raise "unexpected FFmpeg library allowlist"
    end
    required_flags = [
      "--enable-shared",
      "--disable-static",
      "--disable-programs",
      "--disable-network",
      "--disable-autodetect",
      "--disable-everything",
      "--enable-avcodec",
      "--enable-avutil",
      "--enable-swresample",
      "--enable-swscale",
      "--enable-decoder=h264,aac,pcm_s16le,pcm_u8",
      "--enable-encoder=h264_videotoolbox,aac,pcm_s16le,pcm_u8",
      "--enable-parser=h264",
      "--enable-hwaccel=h264_videotoolbox",
      "--enable-videotoolbox"
    ]
    configure_flags = provenance.fetch("configureFlags")
    missing_flags = required_flags - configure_flags
    unless missing_flags.empty?
      raise "project-built FFmpeg is missing required flags: #{missing_flags.join(", ")}"
    end

    occurrences = ffmpeg_component.dig("evidence", "occurrences") || []
    stems = occurrences.map do |occurrence|
      basename = File.basename(safe_relative_path(occurrence.fetch("location")))
      match = basename.match(/\A(libavcodec|libavutil|libswresample|libswscale)(?:\.[0-9.]+)?\.dylib\z/)
      raise "unexpected project-built FFmpeg payload: #{basename}" unless match

      match[1]
    end
    unless stems.sort == %w[libavcodec libavutil libswresample libswscale]
      raise "project-built FFmpeg payload does not match its allowlist"
    end
  end
end

puts "Validated compliance bundle: #{components.length - 1} third-party components, #{actual_payload.length} payload files"
