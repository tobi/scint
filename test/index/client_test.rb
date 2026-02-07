# frozen_string_literal: true

require_relative "../test_helper"
require "scint/index/client"

class IndexClientTest < Minitest::Test
  def test_fetch_names_uses_etag_cache_and_memoizes_within_session
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)

      calls = 0
      response = http_response(Net::HTTPOK, body: "---\nrack\n", headers: { "ETag" => '"etag-1"' })
      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        calls += 1
        response
      }) do
        first = client.fetch_names
        second = client.fetch_names

        assert_equal ["rack"], first
        assert_equal ["rack"], second
      end

      assert_equal 1, calls
      assert_equal "etag-1", client.instance_variable_get(:@cache).names_etag
    ensure
      client.close
    end
  end

  def test_fetch_versions_range_append_path
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      cache.write_versions("abc", etag: "old")

      requests = []
      partial = http_response(Net::HTTPPartialContent, body: "cXYZ", headers: { "ETag" => '"new"' })

      client.stub(:http_get, lambda { |url, etag: nil, range_start: nil|
        requests << { url: url, etag: etag, range_start: range_start }
        partial
      }) do
        client.fetch_versions
      end

      assert_equal "abcXYZ", cache.versions
      assert_equal 2, requests.first[:range_start]
    ensure
      client.close
    end
  end

  def test_fetch_info_uses_binary_cache_when_checksum_matches
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      parser = client.instance_variable_get(:@parser)

      parser.instance_variable_set(:@info_checksums, { "rack" => "sum1" })
      parsed = [["rack", "2.2.8", "ruby", {}, {}]]
      cache.write_binary_info("rack", "sum1", parsed)

      client.stub(:http_get, ->(*_args, **_kwargs) { raise "should not fetch network" }) do
        assert_equal parsed, client.fetch_info("rack")
      end
    ensure
      client.close
    end
  end

  def test_prefetch_skips_binary_cached_and_fresh_info_files
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      parser = client.instance_variable_get(:@parser)

      parser.instance_variable_set(:@info_checksums, {
        "cached" => "sum-cached",
        "fresh" => Digest::MD5.hexdigest("fresh-body"),
      })

      cache.write_binary_info("cached", "sum-cached", [["cached", "1.0.0", "ruby", {}, {}]])
      cache.write_info("fresh", "fresh-body")

      fetched = []
      client.stub(:fetch_info_endpoint, lambda { |name|
        fetched << name
        "1.0.0 dep:>= 0\n"
      }) do
        results = client.prefetch(%w[cached fresh needs_fetch])
        assert_equal ["needs_fetch"], fetched
        assert_equal [["needs_fetch", "1.0.0", "ruby", { "dep" => ">= 0" }, {}]], results["needs_fetch"]
      end
    ensure
      client.close
    end
  end

  def test_decode_body_handles_gzip_encoded_responses
    client = Scint::Index::Client.new("https://example.test")
    body = gzip("rack\n")
    response = http_response(Net::HTTPOK, body: body, headers: { "Content-Encoding" => "gzip" })

    assert_equal "rack\n", client.send(:decode_body, response)
  ensure
    client.close if client
  end

  def test_extract_etag_handles_weak_and_quoted_values
    client = Scint::Index::Client.new("https://example.test")
    response = http_response(Net::HTTPOK, headers: { "ETag" => 'W/"abc123"' })

    assert_equal "abc123", client.send(:extract_etag, response)
  ensure
    client.close if client
  end
end
