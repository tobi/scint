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
      assert Dir.exist?(cache.extracted_path(spec))
      assert File.exist?(cache.spec_cache_path(spec))
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
      extracted = cache.extracted_path(spec)
      FileUtils.mkdir_p(extracted)
      File.write(File.join(extracted, "x"), "x")
      FileUtils.mkdir_p(File.dirname(cache.spec_cache_path(spec)))
      File.write(cache.spec_cache_path(spec), "---\n")

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
end
