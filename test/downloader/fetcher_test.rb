# frozen_string_literal: true

require_relative "../test_helper"
require "scint/downloader/fetcher"

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
      fetcher = Scint::Downloader::Fetcher.new
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
      fetcher = Scint::Downloader::Fetcher.new
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
    fetcher = Scint::Downloader::Fetcher.new

    redirects = Array.new(Scint::Downloader::Fetcher::MAX_REDIRECTS + 1) do
      http_response(Net::HTTPFound, headers: { "location" => "https://example.test/loop" })
    end
    conn = FakeHTTP.new(redirects)

    fetcher.stub(:connection_for, ->(_uri) { conn }) do
      error = assert_raises(Scint::NetworkError) do
        fetcher.fetch("https://example.test/start", "/tmp/unused")
      end
      assert_includes error.message, "Too many redirects"
    end
  end

  def test_fetch_checksum_mismatch_removes_temp_file
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "abc")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        assert_raises(Scint::NetworkError) do
          fetcher.fetch("https://example.test/rack.gem", dest, checksum: "deadbeef")
        end
      end

      refute File.exist?(dest)
      assert_equal [], Dir.glob("#{dest}.*.tmp")
    end
  end

  def test_close_finishes_and_clears_connections
    fetcher = Scint::Downloader::Fetcher.new
    a = FakeHTTP.new([])
    b = FakeHTTP.new([])
    fetcher.instance_variable_set(:@connections, { "a" => a, "b" => b })

    fetcher.close

    assert a.finished?
    assert b.finished?
    assert_equal({}, fetcher.instance_variable_get(:@connections))
  end

  def test_fetch_with_string_uri_parses_automatically
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "string-uri")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        result = fetcher.fetch("https://example.test/gems/rack.gem", dest)

        assert_equal dest, result[:path]
        assert_equal 10, result[:size]
      end

      assert_equal "string-uri", File.binread(dest)
    end
  end

  def test_fetch_with_uri_object
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "rack.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "uri-obj")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        result = fetcher.fetch(URI.parse("https://example.test/gems/rack.gem"), dest)

        assert_equal dest, result[:path]
        assert_equal 7, result[:size]
      end

      assert_equal "uri-obj", File.binread(dest)
    end
  end

  def test_fetch_applies_credentials_to_request
    with_tmpdir do |dir|
      fetcher_creds = Object.new
      applied_uri = nil
      fetcher_creds.define_singleton_method(:apply!) do |request, uri|
        applied_uri = uri
        request.basic_auth("user", "pass")
      end

      fetcher = Scint::Downloader::Fetcher.new(credentials: fetcher_creds)
      dest = File.join(dir, "private.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: "secret")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        fetcher.fetch("https://private.example.test/gems/private.gem", dest)
      end

      refute_nil applied_uri
      assert_equal "private.example.test", applied_uri.host
      assert_equal "secret", File.binread(dest)
    end
  end

  def test_connection_for_reuses_started_connection
    fetcher = Scint::Downloader::Fetcher.new
    conn = FakeHTTP.new([])
    fetcher.instance_variable_set(:@connections, { "example.test:443:https" => conn })

    result = fetcher.send(:connection_for, URI.parse("https://example.test/path"))
    assert_same conn, result
  end

  def test_connection_for_creates_new_connection_when_not_started
    fetcher = Scint::Downloader::Fetcher.new

    fake_http = FakeHTTP.new([])
    started = false
    original_new = Net::HTTP.method(:new)

    Net::HTTP.stub(:new, lambda { |host, port|
      http = Object.new
      http.define_singleton_method(:use_ssl=) { |_v| }
      http.define_singleton_method(:open_timeout=) { |_v| }
      http.define_singleton_method(:read_timeout=) { |_v| }
      http.define_singleton_method(:keep_alive_timeout=) { |_v| }
      http.define_singleton_method(:start) { started = true }
      http.define_singleton_method(:started?) { started }
      http
    }) do
      result = fetcher.send(:connection_for, URI.parse("https://new.example.test/path"))
      assert started
      assert result.started?
    end
  end

  def test_connection_for_replaces_dead_connection
    fetcher = Scint::Downloader::Fetcher.new

    dead_conn = Object.new
    dead_conn.define_singleton_method(:started?) { false }

    fetcher.instance_variable_set(:@connections, { "dead.example.test:443:https" => dead_conn })

    started = false
    Net::HTTP.stub(:new, lambda { |host, port|
      http = Object.new
      http.define_singleton_method(:use_ssl=) { |_v| }
      http.define_singleton_method(:open_timeout=) { |_v| }
      http.define_singleton_method(:read_timeout=) { |_v| }
      http.define_singleton_method(:keep_alive_timeout=) { |_v| }
      http.define_singleton_method(:start) { started = true }
      http.define_singleton_method(:started?) { started }
      http
    }) do
      result = fetcher.send(:connection_for, URI.parse("https://dead.example.test/path"))
      assert started
      assert result.started?
      refute_same dead_conn, result
    end
  end

  def test_fetch_cleans_up_temp_file_on_exception
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "fail.gem")

      conn = Object.new
      conn.define_singleton_method(:request) { |_req| raise RuntimeError, "network fail" }
      conn.define_singleton_method(:started?) { true }

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        assert_raises(RuntimeError) do
          fetcher.fetch("https://example.test/fail.gem", dest)
        end
      end

      refute File.exist?(dest)
      assert_equal [], Dir.glob("#{dest}.*.tmp")
    end
  end

  def test_fetch_checksum_success
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "checked.gem")
      body = "verified content"
      expected_checksum = Digest::SHA256.hexdigest(body)
      conn = FakeHTTP.new([http_response(Net::HTTPOK, body: body)])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        result = fetcher.fetch("https://example.test/checked.gem", dest, checksum: expected_checksum)

        assert_equal dest, result[:path]
        assert_equal body.bytesize, result[:size]
      end

      assert_equal body, File.binread(dest)
    end
  end

  def test_fetch_raises_network_error_for_http_error_response
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "notfound.gem")
      conn = FakeHTTP.new([http_response(Net::HTTPNotFound, body: "not found")])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        error = assert_raises(Scint::NetworkError) do
          fetcher.fetch("https://example.test/notfound.gem", dest)
        end
        assert_includes error.message, "HTTP 404"
        assert_includes error.message, "not found"
      end

      assert_equal [], Dir.glob("#{dest}.*.tmp")
    end
  end

  def test_fetch_raises_network_error_with_body_excerpt_for_http_error
    with_tmpdir do |dir|
      fetcher = Scint::Downloader::Fetcher.new
      dest = File.join(dir, "restricted.gem")
      conn = FakeHTTP.new([
                            http_response(
                              Net::HTTPNotFound,
                              body: "<h1>Download Restricted: TOKEN_DELETED</h1>\n<p>Token removed.</p>",
                            ),
                          ])

      fetcher.stub(:connection_for, ->(_uri) { conn }) do
        error = assert_raises(Scint::NetworkError) do
          fetcher.fetch("https://example.test/restricted.gem", dest)
        end
        assert_includes error.message, "HTTP 404"
        assert_includes error.message, "TOKEN_DELETED"
      end
    end
  end
end
