# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/manifest"

class CacheManifestTest < Minitest::Test
  def test_collect_files_sorts_entries_by_path
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "b.rb"), "b")
      File.write(File.join(dir, "a.rb"), "a")
      File.write(File.join(dir, "lib", "z.rb"), "z")

      entries = Scint::Cache::Manifest.collect_files(dir)
      paths = entries.map { |entry| entry["path"] }
      assert_equal paths.sort, paths
    end
  end

  def test_write_orders_manifest_keys
    with_tmpdir do |dir|
      manifest = {
        "version" => 1,
        "source" => { "uri" => "https://rubygems.org" },
        "full_name" => "demo-1.0.0",
        "files" => [],
        "build" => { "extensions" => false },
        "abi" => "ruby-test",
      }
      path = File.join(dir, "manifest.json")
      Scint::Cache::Manifest.write(path, manifest)

      content = File.read(path)
      abi_index = content.index("\"abi\"")
      build_index = content.index("\"build\"")
      files_index = content.index("\"files\"")
      full_index = content.index("\"full_name\"")
      source_index = content.index("\"source\"")
      version_index = content.index("\"version\"")

      assert abi_index < build_index
      assert build_index < files_index
      assert files_index < full_index
      assert full_index < source_index
      assert source_index < version_index
    end
  end
end
