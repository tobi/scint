# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/metadata_store"

class MetadataStoreTest < Minitest::Test
  def test_load_missing_file_returns_empty_hash
    with_tmpdir do |dir|
      store = Scint::Cache::MetadataStore.new(File.join(dir, "meta.bin"))
      assert_equal({}, store.load)
    end
  end

  def test_load_corrupt_file_returns_empty_hash
    with_tmpdir do |dir|
      path = File.join(dir, "meta.bin")
      File.binwrite(path, "not marshal")
      store = Scint::Cache::MetadataStore.new(path)

      assert_equal({}, store.load)
    end
  end

  def test_save_and_installed_checks
    with_tmpdir do |dir|
      store = Scint::Cache::MetadataStore.new(File.join(dir, "meta.bin"))
      store.save("rack-2.2.8" => true, "ffi-1.16.0-x86_64-linux" => true)

      assert store.installed?("rack", "2.2.8")
      assert store.installed?("ffi", "1.16.0", "x86_64-linux")
      refute store.installed?("rack", "9.9.9")
    end
  end

  def test_add_and_remove_entries
    with_tmpdir do |dir|
      store = Scint::Cache::MetadataStore.new(File.join(dir, "meta.bin"))

      store.add("rack", "2.2.8")
      store.add("nokogiri", "1.17.0", "arm64-darwin")

      assert store.installed?("rack", "2.2.8")
      assert store.installed?("nokogiri", "1.17.0", "arm64-darwin")

      store.remove("rack", "2.2.8")
      refute store.installed?("rack", "2.2.8")
      assert store.installed?("nokogiri", "1.17.0", "arm64-darwin")
    end
  end
end
