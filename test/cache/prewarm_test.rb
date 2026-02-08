# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cache/prewarm"
require "scint/cache/layout"

class CachePrewarmTest < Minitest::Test
  class FakeDownloader
    attr_reader :items

    def initialize(result_proc)
      @result_proc = result_proc
      @items = nil
    end

    def download_batch(items)
      @items = items
      @result_proc.call(items)
    end

    def close; end
  end

  def test_run_downloads_and_extracts_rubygems_specs
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          create_fake_gem(item[:dest], name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "module Rack; end\n" })
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 2,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 1, result[:warmed]
      assert_equal 0, result[:failed]
      assert File.exist?(cache.inbound_path(spec))
      assert Dir.exist?(cache.cached_path(spec))
      assert File.exist?(cache.cached_spec_path(spec))
      assert File.exist?(cache.cached_manifest_path(spec))
      refute Dir.exist?(cache.extracted_path(spec))
      assert_equal 1, downloader.items.size
    end
  end

  def test_run_skips_when_artifacts_already_exist
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      cached_dir = cache.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached_dir, "lib"))
      File.write(File.join(cached_dir, "lib", "rack.rb"), "")

      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "rack"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.cached_spec_path(spec)))
      File.binwrite(cache.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached_dir,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "rubygems", "uri" => "https://rubygems.org/" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(cache.cached_manifest_path(spec), manifest)

      downloader = FakeDownloader.new(->(_items) { flunk("should not download") })
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:skipped]
      assert_equal 0, result[:failed]
    end
  end

  def test_run_reports_failed_downloads
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      downloader = FakeDownloader.new(lambda do |items|
        items.map do |item|
          { spec: item[:spec], path: nil, size: 0, error: Scint::NetworkError.new("nope") }
        end
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:failed]
      assert_includes result[:failures].first[:error].message, "nope"
    end
  end

  def test_run_ignores_non_http_sources
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "local", version: "1.0.0", source: "/tmp/local")

      downloader = FakeDownloader.new(->(_items) { flunk("should not download") })
      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 0, result[:warmed]
      assert_equal 1, result[:ignored]
      assert_equal 0, result[:failed]
    end
  end

  def test_run_force_purges_and_redownloads
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      # Pre-populate cache artifacts
      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      cached_dir = cache.cached_path(spec)
      FileUtils.mkdir_p(File.join(cached_dir, "lib"))
      File.write(File.join(cached_dir, "lib", "rack.rb"), "old")

      gemspec = Gem::Specification.new do |s|
        s.name = "rack"
        s.version = Gem::Version.new("2.2.8")
        s.summary = "rack"
        s.require_paths = ["lib"]
      end
      FileUtils.mkdir_p(File.dirname(cache.cached_spec_path(spec)))
      File.binwrite(cache.cached_spec_path(spec), Marshal.dump(gemspec))

      manifest = Scint::Cache::Manifest.build(
        spec: spec,
        gem_dir: cached_dir,
        abi_key: Scint::Platform.abi_key,
        source: { "type" => "rubygems", "uri" => "https://rubygems.org/" },
        extensions: false,
      )
      Scint::Cache::Manifest.write(cache.cached_manifest_path(spec), manifest)

      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          create_fake_gem(item[:dest], name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "new\n" })
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        force: true,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      assert_equal 1, result[:warmed]
      assert_equal 0, result[:skipped]
    end
  end

  def test_run_extract_failure_reports_error
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "broken", version: "1.0.0", source: "https://rubygems.org/")

      # Download succeeds but write a broken file so extraction will fail
      downloader = FakeDownloader.new(lambda do |items|
        items.each do |item|
          FileUtils.mkdir_p(File.dirname(item[:dest]))
          File.binwrite(item[:dest], "not-a-valid-gem")
        end
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 1, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])
      assert result[:failed] >= 1
      assert result[:failures].any? { |f| f[:spec] == spec }
    end
  end

  def test_default_downloader_factory_creates_pool
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      # Use default factory (no downloader_factory: arg) so line 24 is hit
      prewarm = Scint::Cache::Prewarm.new(cache_layout: cache, jobs: 1)

      # The default factory should create a Downloader::Pool.
      # We call the factory directly to verify it works.
      factory = prewarm.instance_variable_get(:@downloader_factory)
      pool = factory.call(1, nil)
      assert_kind_of Scint::Downloader::Pool, pool
      pool.close
    end
  end

  def test_extract_raises_cache_error_when_inbound_gem_missing
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "missing", version: "1.0.0", source: "https://rubygems.org/")

      # Download "succeeds" but the file doesn't actually exist on disk
      downloader = FakeDownloader.new(lambda do |items|
        # Do NOT write any file -- simulate missing inbound
        items.map { |item| { spec: item[:spec], path: item[:dest], size: 0, error: nil } }
      end)

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { downloader },
      )

      result = prewarm.run([spec])

      # The extract worker should have raised CacheError for missing inbound (line 130)
      assert_equal 1, result[:failed]
      assert result[:failures].any? { |f|
        f[:error].is_a?(Scint::CacheError) && f[:error].message.include?("Missing downloaded gem")
      }
    end
  end

  def test_extract_promotes_to_cached_with_manifest
    with_tmpdir do |dir|
      cache = Scint::Cache::Layout.new(root: File.join(dir, "cache"))
      spec = fake_spec(name: "rack", version: "2.2.8", source: "https://rubygems.org/")

      # Pre-populate inbound gem
      inbound = cache.inbound_path(spec)
      FileUtils.mkdir_p(File.dirname(inbound))
      create_fake_gem(inbound, name: "rack", version: "2.2.8", files: { "lib/rack.rb" => "" })

      prewarm = Scint::Cache::Prewarm.new(
        cache_layout: cache,
        jobs: 1,
        downloader_factory: ->(_size, _creds) { flunk("should not download") },
      )

      task = Scint::Cache::Prewarm::Task.new(spec: spec, download: false, extract: true)
      failures = prewarm.send(:extract_tasks, [task])

      assert_empty failures
      assert Dir.exist?(cache.cached_path(spec)), "cached dir should exist after promotion"
      assert File.exist?(cache.cached_spec_path(spec)), "cached spec should exist"
      assert File.exist?(cache.cached_manifest_path(spec)), "manifest should exist"
      refute Dir.exist?(cache.assembling_path(spec)), "assembling dir should be cleaned up"
    end
  end
end
