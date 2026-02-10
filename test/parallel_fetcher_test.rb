# frozen_string_literal: true

require "test_helper"
require "scint/parallel_fetcher"

class ParallelFetcherTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("parallel-fetcher-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- initialization ---

  def test_initializes_with_defaults
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    assert_instance_of Scint::ParallelFetcher, fetcher
    fetcher.close
  end

  def test_initializes_with_custom_concurrency
    fetcher = Scint::ParallelFetcher.new(concurrency: 5, dest_dir: @tmpdir)
    assert_instance_of Scint::ParallelFetcher, fetcher
    fetcher.close
  end

  # --- fetch_gems: cached ---

  def test_fetch_gems_returns_cached_when_file_exists
    # Pre-create a cached gem file
    gem_path = File.join(@tmpdir, "rack-3.2.4.gem")
    File.write(gem_path, "fake gem content")

    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    results = fetcher.fetch_gems([
      { name: "rack", version: "3.2.4", source_uri: "https://rubygems.org/" }
    ])
    fetcher.close

    assert_equal 1, results.size
    r = results.first
    assert_equal "rack", r[:name]
    assert_equal "3.2.4", r[:version]
    assert_equal gem_path, r[:path]
    assert_nil r[:error]
    assert r[:cached], "should report as cached"
  end

  def test_fetch_gems_skips_zero_byte_cached_files
    # Zero-byte file should not count as cached
    gem_path = File.join(@tmpdir, "rack-3.2.4.gem")
    File.write(gem_path, "")

    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    results = fetcher.fetch_gems([
      { name: "rack", version: "3.2.4", source_uri: "https://rubygems.org/" }
    ])
    fetcher.close

    r = results.first
    # Either downloaded or errored — not cached
    refute r[:cached], "zero-byte file should not be cached"
  end

  # --- fetch_gems: callback ---

  def test_fetch_gems_yields_each_result
    gem_path = File.join(@tmpdir, "rack-3.2.4.gem")
    File.write(gem_path, "fake gem content")

    yielded = []
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    fetcher.fetch_gems([
      { name: "rack", version: "3.2.4", source_uri: "https://rubygems.org/" }
    ]) { |r| yielded << r }
    fetcher.close

    assert_equal 1, yielded.size
    assert_equal "rack", yielded.first[:name]
  end

  # --- fetch_gems: multiple ---

  def test_fetch_gems_handles_multiple_cached_gems
    %w[rack-3.2.4 json-2.10.1 puma-7.1.0].each do |name|
      File.write(File.join(@tmpdir, "#{name}.gem"), "content")
    end

    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir, concurrency: 2)
    results = fetcher.fetch_gems([
      { name: "rack", version: "3.2.4", source_uri: "https://rubygems.org/" },
      { name: "json", version: "2.10.1", source_uri: "https://rubygems.org/" },
      { name: "puma", version: "7.1.0", source_uri: "https://rubygems.org/" },
    ])
    fetcher.close

    assert_equal 3, results.size
    assert results.all? { |r| r[:cached] }
  end

  # --- fetch_gems: empty ---

  def test_fetch_gems_empty_list
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    results = fetcher.fetch_gems([])
    fetcher.close
    assert_empty results
  end

  # --- gem_uri construction ---

  def test_gem_uri_strips_trailing_slash
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    # Access private method for unit testing
    uri = fetcher.send(:gem_uri, "https://rubygems.org/", "rack", "3.2.4")
    assert_equal "https://rubygems.org/gems/rack-3.2.4.gem", uri
    fetcher.close
  end

  def test_gem_uri_handles_no_trailing_slash
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    uri = fetcher.send(:gem_uri, "https://rubygems.org", "rack", "3.2.4")
    assert_equal "https://rubygems.org/gems/rack-3.2.4.gem", uri
    fetcher.close
  end

  def test_gem_uri_custom_source
    fetcher = Scint::ParallelFetcher.new(dest_dir: @tmpdir)
    uri = fetcher.send(:gem_uri, "https://gems.example.com/", "my-gem", "1.0.0")
    assert_equal "https://gems.example.com/gems/my-gem-1.0.0.gem", uri
    fetcher.close
  end
end
