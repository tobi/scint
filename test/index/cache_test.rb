# frozen_string_literal: true

require_relative "../test_helper"
require "uri"
require "bundler2/index/cache"

class IndexCacheTest < Minitest::Test
  def test_slug_for_uri
    slug = Bundler2::Index::Cache.slug_for("https://rubygems.org/api/v1/")
    assert_equal "rubygems.orgapi-v1-", slug
  end

  def test_names_and_versions_round_trip_with_etags
    with_tmpdir do |dir|
      cache = Bundler2::Index::Cache.new(dir)

      cache.write_names("rack\nrails\n", etag: "n1")
      cache.write_versions("rack 2.2.8\n", etag: "v1")
      cache.write_versions("rails 7.1.0\n", etag: "v2", append: true)

      assert_equal "rack\nrails\n", cache.names
      assert_equal "n1", cache.names_etag
      assert_equal "rack 2.2.8\nrails 7.1.0\n", cache.versions
      assert_equal "v2", cache.versions_etag
      assert_equal cache.versions.bytesize, cache.versions_size
    end
  end

  def test_info_and_freshness_checks
    with_tmpdir do |dir|
      cache = Bundler2::Index::Cache.new(dir)
      body = "2.2.8 deps"
      checksum = Digest::MD5.hexdigest(body)

      cache.write_info("rack", body, etag: "etag-rack")

      assert_equal body, cache.info("rack")
      assert_equal "etag-rack", cache.info_etag("rack")
      assert_equal true, cache.info_fresh?("rack", checksum)
      assert_equal false, cache.info_fresh?("rack", "different")
    end
  end

  def test_binary_info_cache_respects_checksum
    with_tmpdir do |dir|
      cache = Bundler2::Index::Cache.new(dir)
      parsed = [["rack", "2.2.8", "ruby", {}, {}]]

      cache.write_binary_info("rack", "sum1", parsed)

      assert_equal parsed, cache.read_binary_info("rack", "sum1")
      assert_nil cache.read_binary_info("rack", "sum2")
    end
  end

  def test_read_binary_info_returns_nil_for_corrupt_marshal
    with_tmpdir do |dir|
      cache = Bundler2::Index::Cache.new(dir)
      path = File.join(dir, "info-binary", "rack.bin")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "corrupt")

      assert_nil cache.read_binary_info("rack", "sum")
    end
  end

  def test_info_files_with_special_characters_are_supported
    with_tmpdir do |dir|
      cache = Bundler2::Index::Cache.new(dir)
      name = "weird/gem:name"

      cache.write_info(name, "body", etag: "etag")

      assert_equal "body", cache.info(name)
      assert_equal "etag", cache.info_etag(name)
    end
  end
end
