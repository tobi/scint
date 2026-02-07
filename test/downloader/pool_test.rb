# frozen_string_literal: true

require_relative "../test_helper"
require "scint/downloader/pool"

class DownloaderPoolTest < Minitest::Test
  def test_download_retries_and_resets_fetcher
    pool = Scint::Downloader::Pool.new(size: 1)

    attempts = 0
    reset_calls = 0
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |_uri, dest, checksum: nil|
      attempts += 1
      raise Scint::NetworkError, "temporary" if attempts < 3

      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, "ok")
      { path: dest, size: 2 }
    end

    pool.define_singleton_method(:thread_fetcher) { fetcher }
    pool.define_singleton_method(:reset_thread_fetcher) { reset_calls += 1 }

    with_tmpdir do |dir|
      dest = File.join(dir, "rack.gem")

      pool.stub(:sleep, nil) do
        result = pool.download("https://example.test/rack.gem", dest)
        assert_equal dest, result[:path]
        assert_equal 2, result[:size]
      end
    end

    assert_equal 3, attempts
    assert_equal 2, reset_calls
  end

  def test_download_raises_after_max_retries
    pool = Scint::Downloader::Pool.new(size: 1)

    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |_uri, _dest, checksum: nil|
      raise SocketError, "dns failure"
    end

    pool.define_singleton_method(:thread_fetcher) { fetcher }
    pool.define_singleton_method(:reset_thread_fetcher) { nil }

    with_tmpdir do |dir|
      error = nil
      pool.stub(:sleep, nil) do
        error = assert_raises(Scint::NetworkError) do
          pool.download("https://example.test/fail.gem", File.join(dir, "fail.gem"))
        end
      end

      assert_includes error.message, "after 3 retries"
    end
  end

  def test_download_batch_collects_success_and_failure_results
    pool = Scint::Downloader::Pool.new(size: 2)

    pool.stub(:download, lambda { |uri, dest, checksum: nil|
      raise Scint::NetworkError, "boom" if uri.include?("bad")

      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, "gem")
      { path: dest, size: 3 }
    }) do
      with_tmpdir do |dir|
        items = [
          { uri: "https://example.test/good.gem", dest: File.join(dir, "good.gem"), spec: "good", checksum: nil },
          { uri: "https://example.test/bad.gem", dest: File.join(dir, "bad.gem"), spec: "bad", checksum: nil },
        ]

        results = pool.download_batch(items)
        by_spec = results.each_with_object({}) { |r, h| h[r[:spec]] = r }

        assert_nil by_spec.fetch("good")[:error]
        assert_equal File.join(dir, "good.gem"), by_spec.fetch("good")[:path]

        refute_nil by_spec.fetch("bad")[:error]
        assert_equal 0, by_spec.fetch("bad")[:size]
      end
    end
  end

  def test_close_closes_all_fetchers
    pool = Scint::Downloader::Pool.new(size: 1)
    closed = []

    a = Object.new
    b = Object.new
    a.define_singleton_method(:close) { closed << :a }
    b.define_singleton_method(:close) { closed << :b }

    pool.instance_variable_set(:@fetchers, { 1 => a, 2 => b })
    pool.close

    assert_equal [:a, :b], closed.sort
    assert_equal({}, pool.instance_variable_get(:@fetchers))
  end
end
