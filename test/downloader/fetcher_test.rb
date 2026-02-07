# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/downloader/fetcher"

class FetcherTest < Minitest::Test
  class FakeHTTP
    def initialize(responses)
      @responses = responses.dup
      @finished = false
    end

    def request(_request)
      raise "no more responses" if @responses.empty?

      @responses.shift
    end

    def started?
      true
    end

    def finish
      @finished = true
    end

    def finished?
      @finished
    end
  end

  def test_fetch_success_writes_file
    with_tmpdir do |dir|
      fetcher = Bundler2::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "abc")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        result = fetcher.fetch("https://example.test/gems/rack.gem", dest)

        assert_equal dest, result[:path]
        assert_equal 3, result[:size]
      end

      assert_equal "abc", File.binread(dest)
    end
  end

  def test_fetch_follows_redirects
    with_tmpdir do |dir|
      fetcher = Bundler2::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      responses = [
        http_response(Net::HTTPFound, headers: { "location" => "https://example.test/next" }),
        http_response(Net::HTTPOK, body: "ok"),
      ]
      conn = FakeHTTP.new(responses)

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        fetcher.fetch("https://example.test/start", dest)
      end

      assert_equal "ok", File.binread(dest)
    end
  end

  def test_fetch_raises_after_too_many_redirects
    fetcher = Bundler2::Downloader::Fetcher.new

    redirects = Array.new(Bundler2::Downloader::Fetcher::MAX_REDIRECTS + 1) do
      http_response(Net::HTTPFound, headers: { "location" => "https://example.test/loop" })
    end
    conn = FakeHTTP.new(redirects)

    fetcher.stub(:connection_for, ->(_uri) { conn }) do
      error = assert_raises(Bundler2::NetworkError) do
        fetcher.fetch("https://example.test/start", "/tmp/unused")
      end
      assert_includes error.message, "Too many redirects"
    end
  end

  def test_fetch_checksum_mismatch_removes_temp_file
    with_tmpdir do |dir|
      fetcher = Bundler2::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "abc")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        assert_raises(Bundler2::NetworkError) do
          fetcher.fetch("https://example.test/rack.gem", dest, checksum: "deadbeef")
        end
      end

      refute File.exist?(dest)
      assert_equal [], Dir.glob("#{dest}.*.tmp")
    end
  end

  def test_close_finishes_and_clears_connections
    fetcher = Bundler2::Downloader::Fetcher.new
    a = FakeHTTP.new([])
    b = FakeHTTP.new([])
    fetcher.instance_variable_set(:@connections, { "a" => a, "b" => b })

    fetcher.close

    assert a.finished?
    assert b.finished?
    assert_equal({}, fetcher.instance_variable_get(:@connections))
  end
end
