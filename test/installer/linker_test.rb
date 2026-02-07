# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/installer/linker"

class LinkerTest < Minitest::Test
  Prepared = Struct.new(:spec, :extracted_path, :gemspec, :from_cache, keyword_init: true)

  def test_link_hardlinks_files_writes_gemspec_and_binstub
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      extracted = File.join(dir, "cache", "rack-2.2.8")
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rack.rb"), "module Rack; end\n")

      spec = fake_spec(name: "rack", version: "2.2.8")
      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.authors = ["a"]
        s.summary = "rack"
        s.executables = ["rackup"]
      end

      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: gemspec, from_cache: true)
      Bundler2::Installer::Linker.link(prepared, bundle_path)

      ruby_dir = ruby_bundle_dir(bundle_path)
      gem_dir = File.join(ruby_dir, "gems", "rack-2.2.8")
      linked_file = File.join(gem_dir, "lib", "rack.rb")

      assert File.exist?(linked_file)
      assert_hardlinked(File.join(extracted, "lib", "rack.rb"), linked_file)

      spec_path = File.join(ruby_dir, "specifications", "rack-2.2.8.gemspec")
      assert File.exist?(spec_path)
      assert_includes File.read(spec_path), "rack"

      binstub = File.join(ruby_dir, "bin", "rackup")
      assert File.exist?(binstub)
      assert_equal true, File.executable?(binstub)
      assert_includes File.read(binstub), "Gem.bin_path"
    end
  end

  def test_link_does_not_overwrite_existing_spec_or_binstub
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      extracted = File.join(dir, "cache", "rack-2.2.8")
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rack.rb"), "module Rack; end\n")

      ruby_dir = ruby_bundle_dir(bundle_path)
      spec_dir = File.join(ruby_dir, "specifications")
      bin_dir = File.join(ruby_dir, "bin")
      FileUtils.mkdir_p(spec_dir)
      FileUtils.mkdir_p(bin_dir)
      spec_path = File.join(spec_dir, "rack-2.2.8.gemspec")
      bin_path = File.join(bin_dir, "rackup")
      File.write(spec_path, "existing spec")
      File.write(bin_path, "existing bin")

      spec = fake_spec(name: "rack", version: "2.2.8")
      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.authors = ["a"]
        s.summary = "rack"
        s.executables = ["rackup"]
      end

      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: gemspec, from_cache: true)
      Bundler2::Installer::Linker.link(prepared, bundle_path)

      assert_equal "existing spec", File.read(spec_path)
      assert_equal "existing bin", File.read(bin_path)
    end
  end

  def test_link_uses_minimal_gemspec_when_none_available
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      extracted = File.join(dir, "cache", "rack-2.2.8")
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "rack.rb"), "module Rack; end\n")

      spec = fake_spec(name: "rack", version: "2.2.8")
      prepared = Prepared.new(spec: spec, extracted_path: extracted, gemspec: nil, from_cache: true)

      Bundler2::Installer::Linker.link(prepared, bundle_path)

      spec_path = File.join(ruby_bundle_dir(bundle_path), "specifications", "rack-2.2.8.gemspec")
      assert_includes File.read(spec_path), "Installed by bundler2"
    end
  end

  def test_link_batch_links_multiple_gems
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")

      a_src = File.join(dir, "cache", "a-1.0.0")
      b_src = File.join(dir, "cache", "b-1.0.0")
      FileUtils.mkdir_p(File.join(a_src, "lib"))
      FileUtils.mkdir_p(File.join(b_src, "lib"))
      File.write(File.join(a_src, "lib", "a.rb"), "A")
      File.write(File.join(b_src, "lib", "b.rb"), "B")

      prepared = [
        Prepared.new(spec: fake_spec(name: "a", version: "1.0.0"), extracted_path: a_src, gemspec: nil, from_cache: true),
        Prepared.new(spec: fake_spec(name: "b", version: "1.0.0"), extracted_path: b_src, gemspec: nil, from_cache: true),
      ]

      Bundler2::Installer::Linker.link_batch(prepared, bundle_path)

      ruby_dir = ruby_bundle_dir(bundle_path)
      assert File.exist?(File.join(ruby_dir, "gems", "a-1.0.0", "lib", "a.rb"))
      assert File.exist?(File.join(ruby_dir, "gems", "b-1.0.0", "lib", "b.rb"))
    end
  end

  def test_link_extracts_executables_from_hash_gemspec
    with_tmpdir do |dir|
      bundle_path = File.join(dir, ".bundle")
      extracted = File.join(dir, "cache", "demo-1.0.0")
      FileUtils.mkdir_p(File.join(extracted, "lib"))
      File.write(File.join(extracted, "lib", "demo.rb"), "module Demo; end\n")

      spec = fake_spec(name: "demo", version: "1.0.0")
      prepared = Prepared.new(
        spec: spec,
        extracted_path: extracted,
        gemspec: { executables: ["demo-exe"] },
        from_cache: true,
      )

      Bundler2::Installer::Linker.link(prepared, bundle_path)

      binstub = File.join(ruby_bundle_dir(bundle_path), "bin", "demo-exe")
      assert File.exist?(binstub)
      assert_equal true, File.executable?(binstub)
    end
  end
end
