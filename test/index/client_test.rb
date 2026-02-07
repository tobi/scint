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

  def test_fetch_names_returns_cached_data_on_304_not_modified
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)

      # Pre-populate the cache with names data
      cache.write_names("---\nrack\njson\n", etag: "etag-cached")

      not_modified = http_response(Net::HTTPNotModified)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        not_modified
      }) do
        result = client.fetch_names
        assert_equal ["rack", "json"], result
      end
    ensure
      client.close
    end
  end

  def test_fetch_versions_range_not_satisfiable_falls_back_to_full_fetch
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)

      # Write existing versions data so range request is attempted
      cache.write_versions("old-data", etag: "old-etag")

      calls = []
      range_not_satisfiable = http_response(Net::HTTPRangeNotSatisfiable)
      full_response = http_response(Net::HTTPOK, body: "---\nrack 1.0.0 abc123\n", headers: { "ETag" => '"new-etag"' })

      client.stub(:http_get, lambda { |url, etag: nil, range_start: nil|
        calls << { url: url, range_start: range_start }
        if range_start
          range_not_satisfiable
        else
          full_response
        end
      }) do
        client.fetch_versions
      end

      # Should have made two requests: first a range request, then a full fetch
      assert_equal 2, calls.size
      assert calls.first[:range_start], "first request should be a range request"
      assert_nil calls.last[:range_start], "second request should be a full fetch"

      # Cache should have the new data
      assert_includes cache.versions, "rack 1.0.0 abc123"
    ensure
      client.close
    end
  end

  def test_fetch_info_with_empty_checksum_fetches_from_network
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      parser = client.instance_variable_get(:@parser)

      # Set empty checksum for the gem
      parser.instance_variable_set(:@info_checksums, { "rack" => "" })

      info_body = "2.2.8 json:>= 1.0\n"
      ok_response = http_response(Net::HTTPOK, body: info_body, headers: { "ETag" => '"info-etag"' })

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        ok_response
      }) do
        result = client.fetch_info("rack")
        assert_equal 1, result.size
        assert_equal "rack", result.first[0]
        assert_equal "2.2.8", result.first[1]
      end
    ensure
      client.close
    end
  end

  def test_prefetch_with_empty_names_returns_early
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)

      # Should not make any HTTP calls or raise errors
      client.stub(:http_get, ->(*_args, **_kwargs) { raise "should not fetch" }) do
        result = client.prefetch([])
        assert_nil result
      end
    ensure
      client.close
    end
  end

  def test_close_finishes_pooled_connections
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      connections = client.instance_variable_get(:@connections)

      # Create a fake connection object
      finished = false
      fake_conn = Object.new
      fake_conn.define_singleton_method(:started?) { true }
      fake_conn.define_singleton_method(:finish) { finished = true }

      connections.push(fake_conn)

      client.close

      assert finished, "close should call finish on started connections"
      assert connections.empty?, "connection pool should be empty after close"
    end
  end

  def test_close_handles_non_started_connections
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      connections = client.instance_variable_get(:@connections)

      # Create a fake connection that is not started
      fake_conn = Object.new
      fake_conn.define_singleton_method(:started?) { false }
      finish_called = false
      fake_conn.define_singleton_method(:finish) { finish_called = true }

      connections.push(fake_conn)

      client.close

      refute finish_called, "finish should not be called on non-started connections"
    end
  end

  def test_checkout_checkin_connection_reuse
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      connections = client.instance_variable_get(:@connections)

      # Create a fake started connection and push to pool
      fake_conn = Object.new
      fake_conn.define_singleton_method(:started?) { true }
      connections.push(fake_conn)

      uri = URI.parse("https://example.test/names")
      checked_out = client.send(:checkout_connection, uri)

      assert_same fake_conn, checked_out, "should reuse pooled started connection"

      # Checkin should return it to the pool
      client.send(:checkin_connection, checked_out)
      assert_equal 1, connections.size
    ensure
      client.close
    end
  end

  def test_fetch_versions_not_modified_with_no_local_data_returns_empty
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)

      # No local versions data, versions_size == 0, goes to full fetch path
      not_modified = http_response(Net::HTTPNotModified)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        not_modified
      }) do
        result = client.fetch_versions
        # cache.versions is nil, parse_versions(nil) returns empty hash
        assert_equal({}, result)
      end
    ensure
      client.close
    end
  end

  def test_fetch_versions_range_not_modified_returns_cached_parsed
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)

      # Write existing versions so range request is triggered
      cache.write_versions("---\nrack 1.0.0 abc\n", etag: "cached-etag")

      not_modified = http_response(Net::HTTPNotModified)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        not_modified
      }) do
        result = client.fetch_versions
        # Returns parsed versions hash from cached data
        assert_kind_of Hash, result
        assert result.key?("rack"), "expected rack in parsed versions"
      end
    ensure
      client.close
    end
  end

  def test_fetch_info_uses_local_file_when_fresh
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      parser = client.instance_variable_get(:@parser)

      info_body = "2.2.8 json:>= 1.0\n"
      checksum = Digest::MD5.hexdigest(info_body)
      parser.instance_variable_set(:@info_checksums, { "rack" => checksum })
      cache.write_info("rack", info_body)

      client.stub(:http_get, ->(*_args, **_kwargs) { raise "should not fetch" }) do
        result = client.fetch_info("rack")
        assert_equal 1, result.size
        assert_equal "rack", result.first[0]
      end
    ensure
      client.close
    end
  end

  def test_fetch_names_raises_on_network_error
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      error_response = http_response(Net::HTTPServiceUnavailable)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        error_response
      }) do
        assert_raises(Scint::NetworkError) { client.fetch_names }
      end
    ensure
      client.close
    end
  end

  def test_fetch_versions_raises_on_full_fetch_error
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      error_response = http_response(Net::HTTPServiceUnavailable)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        error_response
      }) do
        assert_raises(Scint::NetworkError) { client.fetch_versions }
      end
    ensure
      client.close
    end
  end

  def test_fetch_versions_range_raises_on_unexpected_error
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      cache.write_versions("old-data", etag: "old-etag")

      error_response = http_response(Net::HTTPServiceUnavailable)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        error_response
      }) do
        assert_raises(Scint::NetworkError) { client.fetch_versions }
      end
    ensure
      client.close
    end
  end

  def test_fetch_info_endpoint_not_modified_returns_cached
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      cache.write_info("rack", "2.2.8\n")

      not_modified = http_response(Net::HTTPNotModified)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        not_modified
      }) do
        data = client.send(:fetch_info_endpoint, "rack")
        assert_equal "2.2.8\n", data
      end
    ensure
      client.close
    end
  end

  def test_fetch_info_endpoint_not_found_returns_nil
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      not_found = http_response(Net::HTTPNotFound)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        not_found
      }) do
        result = client.send(:fetch_info_endpoint, "missing")
        assert_nil result
      end
    ensure
      client.close
    end
  end

  def test_fetch_info_endpoint_raises_on_error
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      error_response = http_response(Net::HTTPServiceUnavailable)

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        error_response
      }) do
        assert_raises(Scint::NetworkError) { client.send(:fetch_info_endpoint, "rack") }
      end
    ensure
      client.close
    end
  end

  def test_fetch_versions_range_ignored_by_server_uses_full_response
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)

      # Write existing versions so range request is triggered
      cache.write_versions("old-data", etag: "old-etag")

      # Server ignores range and returns full 200 with valid versions data
      full_response = http_response(Net::HTTPOK, body: "---\nmygem 2.0.0 def\n", headers: { "ETag" => '"new-etag"' })

      client.stub(:http_get, lambda { |_url, etag: nil, range_start: nil|
        full_response
      }) do
        result = client.fetch_versions
        assert_kind_of Hash, result
        assert result.key?("mygem"), "expected mygem in parsed versions"
      end
    ensure
      client.close
    end
  end

  def test_prefetch_writes_binary_info_cache
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      cache = client.instance_variable_get(:@cache)
      parser = client.instance_variable_get(:@parser)

      # Populate checksums so prefetch doesn't need to call fetch_versions
      parser.instance_variable_set(:@info_checksums, { "newgem" => "checksum123" })

      info_body = "1.0.0 dep:>= 0\n"
      client.stub(:fetch_info_endpoint, lambda { |name|
        info_body
      }) do
        results = client.prefetch(["newgem"], worker_count: 1)

        # Verify that binary info was written (line 116)
        binary_cached = cache.read_binary_info("newgem", "checksum123")
        refute_nil binary_cached, "binary info should have been written during prefetch"
        assert_equal "newgem", binary_cached.first[0]
      end
    ensure
      client.close
    end
  end

  def test_prefetch_prints_stderr_warning_on_error_with_debug
    with_tmpdir do |dir|
      client = Scint::Index::Client.new("https://example.test", cache_dir: dir)
      parser = client.instance_variable_get(:@parser)

      # Populate checksums so prefetch doesn't need to call fetch_versions
      parser.instance_variable_set(:@info_checksums, { "badgem" => "sum1" })

      client.stub(:fetch_info_endpoint, lambda { |name|
        raise StandardError, "connection refused"
      }) do
        old_stderr = $stderr
        captured = StringIO.new
        $stderr = captured
        with_env("SCINT_DEBUG", "1") do
          results = client.prefetch(["badgem"], worker_count: 1)
          # Should not raise -- error is caught inside the thread
          assert_kind_of Hash, results
        end
        $stderr = old_stderr

        # Line 121: $stderr.puts "prefetch warning: ..." when SCINT_DEBUG set
        assert_includes captured.string, "prefetch warning: badgem: connection refused"
      end
    ensure
      client.close
    end
  end
end
