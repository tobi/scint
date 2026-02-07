# frozen_string_literal: true

require_relative "../test_helper"
require "scint/installer/preparer"
require "scint/cache/layout"

class PreparerTest < Minitest::Test
  FakeDownloadPool = Struct.new(:batch_results, :download_calls, :download_batch_items, :closed, keyword_init: true) do
    def initialize(**kwargs)
      super
      self.download_calls ||= []
      self.download_batch_items ||= []
      self.closed = false if closed.nil?
    end

    def download(uri, dest)
      download_calls << [uri, dest]
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, "gem")
      { path: dest, size: 3 }
    end

    def download_batch(items)
      self.download_batch_items = items
      return batch_results if batch_results

      items.map do |item|
        FileUtils.mkdir_p(File.dirname(item[:dest]))
        File.binwrite(item[:dest], "gem")
        { spec: item[:spec], path: item[:dest], size: 3, error: nil }
      end
    end

    def close
      self.closed = true
    end
  end

  class FakePackage
    attr_reader :extract_calls

    def initialize(gemspec:)
      @gemspec = gemspec
      @extract_calls = []
    end

    def extract(gem_path, dest)
      @extract_calls << [gem_path, dest]
      FileUtils.mkdir_p(dest)
      File.write(File.join(dest, "example.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "example"
          s.version = "1.0.0"
          s.summary = "x"
          s.authors = ["a"]
        end
      RUBY
      { gemspec: @gemspec, extracted_path: dest }
    end
  end

  def new_preparer(layout, pool:, package:)
    preparer = Scint::Installer::Preparer.new(layout: layout)
    preparer.instance_variable_set(:@download_pool, pool)
    preparer.instance_variable_set(:@package, package)
    preparer
  end

  def plan_entry(spec, cached_path: nil, gem_path: nil)
    Scint::Installer::PlanEntry.new(spec: spec, action: :download, cached_path: cached_path, gem_path: gem_path)
  end

  def test_prepare_uses_existing_extracted_cache_and_cached_spec
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8")

      extracted = layout.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      cached_spec = { "ok" => true }
      File.binwrite(layout.spec_cache_path(spec), Marshal.dump(cached_spec))

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: { "unused" => true })
      preparer = new_preparer(layout, pool: pool, package: package)

      result = preparer.prepare([plan_entry(spec)])

      assert_equal 1, result.size
      assert_equal true, result.first.from_cache
      assert_equal cached_spec, result.first.gemspec
      assert_equal [], pool.download_batch_items
      assert_equal [], package.extract_calls
      assert_equal true, pool.closed
    end
  end

  def test_prepare_uses_extracted_gemspec_when_cached_spec_missing
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8")

      extracted = layout.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "rack.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "rack"
          s.version = "2.2.8"
          s.summary = "rack"
          s.authors = ["a"]
        end
      RUBY

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: { "unused" => true })
      preparer = new_preparer(layout, pool: pool, package: package)

      result = preparer.prepare([plan_entry(spec)])
      gemspec = result.first.gemspec

      assert_equal true, result.first.from_cache
      assert_equal "rack", gemspec.name
      assert_equal Gem::Version.new("2.2.8"), gemspec.version
    end
  end

  def test_prepare_extracts_when_inbound_exists_but_not_extracted
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8")
      inbound = layout.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      File.binwrite(inbound, "gem-bytes")

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: { "name" => "rack" })
      preparer = new_preparer(layout, pool: pool, package: package)

      result = preparer.prepare([plan_entry(spec)])

      assert_equal false, result.first.from_cache
      assert_equal inbound, package.extract_calls.first.first
      assert File.directory?(layout.extracted_path(spec))
      assert File.exist?(layout.spec_cache_path(spec))
      assert_equal true, pool.closed
    end
  end

  def test_prepare_downloads_missing_gems_and_extracts
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      a = fake_spec(name: "a", version: "1.0.0")
      b = fake_spec(name: "b", version: "1.0.0")
      entries = [
        plan_entry(a, cached_path: "https://example.test/gems/a-1.0.0.gem"),
        plan_entry(b),
      ]

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: { "name" => "ok" })
      preparer = new_preparer(layout, pool: pool, package: package)

      result = preparer.prepare(entries)

      assert_equal 2, result.size
      assert_equal 2, pool.download_batch_items.size
      assert_equal "https://example.test/gems/a-1.0.0.gem", pool.download_batch_items.first[:uri]
      assert_equal 2, package.extract_calls.size
      assert_equal true, pool.closed
    end
  end

  def test_prepare_raises_install_error_when_download_batch_contains_error
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "broken", version: "1.0.0")

      pool = FakeDownloadPool.new(
        batch_results: [
          { spec: spec, path: nil, size: 0, error: StandardError.new("network down") },
        ],
      )
      package = FakePackage.new(gemspec: {})
      preparer = new_preparer(layout, pool: pool, package: package)

      error = assert_raises(Scint::InstallError) { preparer.prepare([plan_entry(spec)]) }
      assert_includes error.message, "Failed to download broken"
      assert_equal true, pool.closed
    end
  end

  def test_prepare_one_downloads_when_missing
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "solo", version: "1.0.0")
      entry = plan_entry(spec, cached_path: "https://example.test/gems/solo-1.0.0.gem")

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: { "name" => "solo" })
      preparer = new_preparer(layout, pool: pool, package: package)

      prepared = preparer.prepare_one(entry)

      assert_equal false, prepared.from_cache
      assert_equal 1, pool.download_calls.size
      assert_equal "https://example.test/gems/solo-1.0.0.gem", pool.download_calls.first.first
      assert_equal 1, package.extract_calls.size
    end
  end

  def test_gem_download_uri_falls_back_to_rubygems_filename
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    preparer = new_preparer(layout, pool: FakeDownloadPool.new, package: FakePackage.new(gemspec: {}))
    spec = fake_spec(name: "ffi", version: "1.17.0", platform: "x86_64-linux")
    entry = plan_entry(spec)

    uri = preparer.send(:gem_download_uri, entry)
    assert_equal "https://rubygems.org/gems/ffi-1.17.0-x86_64-linux.gem", uri
  end

  def test_gem_download_uri_prefers_cached_path_then_gem_path
    layout = Scint::Cache::Layout.new(root: "/tmp/cache")
    preparer = new_preparer(layout, pool: FakeDownloadPool.new, package: FakePackage.new(gemspec: {}))
    spec = fake_spec(name: "rack", version: "2.2.8")

    cached_entry = plan_entry(spec, cached_path: "https://cached/path.gem", gem_path: "https://ignored/path.gem")
    gem_path_entry = plan_entry(spec, gem_path: "https://gem/path.gem")

    assert_equal "https://cached/path.gem", preparer.send(:gem_download_uri, cached_entry)
    assert_equal "https://gem/path.gem", preparer.send(:gem_download_uri, gem_path_entry)
  end

  def test_load_cached_spec_returns_nil_for_corrupt_data
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      preparer = new_preparer(layout, pool: FakeDownloadPool.new, package: FakePackage.new(gemspec: {}))
      spec = fake_spec(name: "rack", version: "2.2.8")

      path = layout.spec_cache_path(spec)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "bad marshal")

      assert_nil preparer.send(:load_cached_spec, spec)
    end
  end

  def test_prepare_one_uses_cached_extracted_directory
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8")

      extracted = layout.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      cached_spec = { "cached" => true }
      File.binwrite(layout.spec_cache_path(spec), Marshal.dump(cached_spec))

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: {})
      preparer = new_preparer(layout, pool: pool, package: package)

      result = preparer.prepare_one(plan_entry(spec))

      assert_equal true, result.from_cache
      assert_equal cached_spec, result.gemspec
      assert_equal extracted, result.extracted_path
    end
  end

  def test_extract_gem_returns_cached_when_dest_already_exists
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8")

      # Pre-create extracted path to simulate race condition
      extracted = layout.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "rack.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "rack"
          s.version = "2.2.8"
          s.summary = "rack"
          s.authors = ["a"]
        end
      RUBY

      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: {})
      preparer = new_preparer(layout, pool: pool, package: package)

      # Call extract_gem directly with a dummy gem_path
      result = preparer.send(:extract_gem, spec, "/dummy.gem")

      assert_equal true, result.from_cache
      assert_equal extracted, result.extracted_path
    end
  end

  def test_read_gemspec_from_extracted_returns_nil_on_load_error
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: {})
      preparer = new_preparer(layout, pool: pool, package: package)
      spec = fake_spec(name: "broken", version: "1.0.0")

      extracted = File.join(dir, "extracted")
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "broken.gemspec"), "raise 'oops'")

      result = preparer.send(:read_gemspec_from_extracted, extracted, spec)
      assert_nil result
    end
  end

  def test_read_gemspec_from_extracted_rescues_standard_error
    with_tmpdir do |dir|
      layout = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      pool = FakeDownloadPool.new
      package = FakePackage.new(gemspec: {})
      preparer = new_preparer(layout, pool: pool, package: package)
      spec = fake_spec(name: "erroring", version: "1.0.0")

      extracted = File.join(dir, "extracted")
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "erroring.gemspec"), "# valid gemspec file")

      # Stub Gem::Specification.load to raise StandardError (line 177-178)
      Gem::Specification.stub(:load, ->(_path) { raise StandardError, "load failed" }) do
        result = preparer.send(:read_gemspec_from_extracted, extracted, spec)
        assert_nil result, "should return nil when Gem::Specification.load raises StandardError"
      end
    end
  end
end
