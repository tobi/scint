# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/layout"
require "scint/cache/manifest"
require "scint/cache/validity"

class CacheValidityTest < Minitest::Test
  def test_cached_valid_requires_matching_manifest_abi
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "demo", version: "1.0.0", platform: "ruby", source: "https://rubygems.org")

      cached = layout.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached, "lib"))
      File.write(File.join(cached, "lib", "demo.rb"), "module Demo; end\n")

      gemspec = Gem::Specification.new do |s|
        s.name = "demo"
        s.version = Gem::Version.new("1.0.0")
        s.summary = "demo"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(layout.cached_spec_path(spec)))
      File.binwrite(layout.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached,
        abi_key: "ruby-bad",
        source: { "type" => "rubygems", "uri" => "https://rubygems.org" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(layout.cached_manifest_path(spec), manifest)

      refute Scint::Cache::Validity.cached_valid?(spec, layout)
    end
  end

  def test_cached_valid_accepts_matching_manifest_and_spec
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "demo", version: "1.0.0", platform: "ruby", source: "https://rubygems.org")

      cached = layout.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached, "lib"))
      File.write(File.join(cached, "lib", "demo.rb"), "module Demo; end\n")

      gemspec = Gem::Specification.new do |s|
        s.name = "demo"
        s.version = Gem::Version.new("1.0.0")
        s.summary = "demo"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(layout.cached_spec_path(spec)))
      File.binwrite(layout.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "rubygems", "uri" => "https://rubygems.org" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(layout.cached_manifest_path(spec), manifest)

      assert Scint::Cache::Validity.cached_valid?(spec, layout)
    end
  end

  def test_source_path_for_uses_legacy_extracted_with_telemetry
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "demo", version: "1.0.0", platform: "ruby", source: "https://rubygems.org")
      legacy = layout.extracted_path(spec)
      FileUtils.mkdir_p(legacy)
      File.write(File.join(legacy, "demo.gemspec"), "Gem::Specification.new")

      telemetry = Scint::Cache::Telemetry.new
      path = Scint::Cache::Validity.source_path_for(spec, layout, telemetry: telemetry)
      assert_equal legacy, path
      assert_equal 1, telemetry.counts["cache.legacy.extracted"]
    end
  end
end
