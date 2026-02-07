# frozen_string_literal: true

require_relative "../test_helper"
require "scint/resolver/provider"

class ProviderTest < Minitest::Test
  class FakeIndexClient
    attr_reader :source_uri, :prefetch_calls

    def initialize(data)
      @data = data
      @source_uri = "https://example.test"
      @prefetch_calls = []
    end

    def fetch_info(name)
      @data.fetch(name, [])
    end

    def prefetch(names)
      @prefetch_calls << names
      names.each_with_object({}) { |n, h| h[n] = @data.fetch(n, []) }
    end
  end

  def provider_with(data, platforms: ["ruby", "x86_64-linux"])
    client = FakeIndexClient.new(data)
    Scint::Resolver::Provider.new(client, platforms: platforms)
  end

  def test_versions_for_filters_platforms_and_sorts
    provider = provider_with({
      "rack" => [
        ["rack", "2.0.0", "ruby", {}, {}],
        ["rack", "2.0.0", "x86_64-linux", {}, {}],
        ["rack", "3.0.0", "java", {}, {}],
        ["rack", "1.0.0", "ruby", {}, {}],
      ],
    })

    versions = provider.versions_for("rack")
    assert_equal [Gem::Version.new("1.0.0"), Gem::Version.new("2.0.0")], versions
  end

  def test_dependencies_for_merges_constraints_from_multiple_matching_entries
    provider = provider_with({
      "rack" => [
        ["rack", "2.0.0", "ruby", { "dep" => ">= 1" }, {}],
        ["rack", "2.0.0", "ruby", { "dep" => "< 3" }, {}],
      ],
    })

    deps = provider.dependencies_for("rack", Gem::Version.new("2.0.0"))
    dep_req = deps.fetch("dep")

    assert_includes dep_req.to_s, ">= 1"
    assert_includes dep_req.to_s, "< 3"
  end

  def test_has_extensions_detects_platform_specific_variants
    provider = provider_with({
      "ffi" => [
        ["ffi", "1.0.0", "ruby", {}, {}],
        ["ffi", "1.0.0", "x86_64-linux", {}, {}],
      ],
    })

    assert_equal true, provider.has_extensions?("ffi", Gem::Version.new("1.0.0"))
  end

  def test_locked_version_returns_gem_version
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client, locked_specs: { "rack" => "2.2.8" })

    assert_equal Gem::Version.new("2.2.8"), provider.locked_version("rack")
    assert_nil provider.locked_version("rails")
  end

  def test_preferred_platform_for_prefers_local_binary_variant
    provider = provider_with({
      "nokogiri" => [
        ["nokogiri", "1.19.0", "ruby", {}, {}],
        ["nokogiri", "1.19.0", "arm64-darwin", {}, {}],
      ],
    }, platforms: ["ruby", "arm64-darwin-25"])

    platform = provider.preferred_platform_for("nokogiri", Gem::Version.new("1.19.0"))
    assert_equal "arm64-darwin", platform
  end

  def test_prefetch_populates_internal_info_cache
    client = FakeIndexClient.new("rack" => [["rack", "2.2.8", "ruby", {}, {}]])
    provider = Scint::Resolver::Provider.new(client)

    provider.prefetch(["rack"])
    versions = provider.versions_for("rack")

    assert_equal [Gem::Version.new("2.2.8")], versions
    assert_equal [["rack"]], client.prefetch_calls
  end
end
