# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "rbconfig"

class CacheAuditTest < Minitest::Test
  def test_reports_misplaced_extensions_and_require_failure
    with_tmpdir do |dir|
      abi = "ruby-test-abi"
      cache_root = File.join(dir, "cache")
      gem_dir = File.join(cache_root, "cached", abi, "msgpack-1.7.5")
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "lib", "msgpack"))
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "msgpack"))

      write_spec(cache_root: cache_root, abi: abi, name: "msgpack", version: "1.7.5")
      File.write(File.join(gem_dir, "lib", "msgpack.rb"), "require 'msgpack/msgpack'\n")
      File.binwrite(File.join(gem_dir, "lib", "lib", "msgpack", "msgpack.bundle"), "")

      out, err, status = run_audit(cache_root: cache_root, abi: abi)
      text = "#{out}\n#{err}"

      assert_equal false, status.success?, text
      assert_includes text, "[FAIL] msgpack-1.7.5"
    end
  end

  def test_skips_gem_with_no_entry_feature
    with_tmpdir do |dir|
      abi = "ruby-test-abi"
      cache_root = File.join(dir, "cache")
      gem_dir = File.join(cache_root, "cached", abi, "debug-1.7.2")
      FileUtils.mkdir_p(File.join(gem_dir, "lib", "askify"))

      write_spec(cache_root: cache_root, abi: abi, name: "debug", version: "1.7.2")
      File.write(File.join(gem_dir, "lib", "askify", "version.rb"), "module Askify; VERSION = '0.1.0'; end\n")

      out, err, status = run_audit(cache_root: cache_root, abi: abi)
      text = "#{out}\n#{err}"

      # No entry feature discovered, so the gem is skipped (not failed)
      assert_equal true, status.success?, text
      assert_includes text, "1 skipped (no entry feature)"
    end
  end

  def test_passes_for_simple_well_formed_gem
    with_tmpdir do |dir|
      abi = "ruby-test-abi"
      cache_root = File.join(dir, "cache")
      gem_dir = File.join(cache_root, "cached", abi, "sample-1.0.0")
      FileUtils.mkdir_p(File.join(gem_dir, "lib"))

      write_spec(cache_root: cache_root, abi: abi, name: "sample", version: "1.0.0")
      File.write(File.join(gem_dir, "lib", "sample.rb"), "module Sample; end\n")

      out, err, status = run_audit(cache_root: cache_root, abi: abi)
      text = "#{out}\n#{err}"

      assert_equal true, status.success?, text
      assert_includes text, "Summary: 1 ok, 0 failed"
    end
  end

  private

  def run_audit(cache_root:, abi:)
    Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../../bin/scint-cache-audit", __dir__),
      "--cache-root",
      cache_root,
      "--abi",
      abi,
    )
  end

  def write_spec(cache_root:, abi:, name:, version:)
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.require_paths = ["lib"]
    end

    spec_path = File.join(cache_root, "cached", abi, "#{name}-#{version}.spec.marshal")
    FileUtils.mkdir_p(File.dirname(spec_path))
    File.binwrite(spec_path, Marshal.dump(spec))
  end
end
