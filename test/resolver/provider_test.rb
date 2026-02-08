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

  def test_preferred_platform_for_does_not_select_foreign_arch_binary
    provider = provider_with({
      "nokogiri" => [
        ["nokogiri", "1.19.0", "ruby", {}, {}],
        ["nokogiri", "1.19.0", "aarch64-linux-gnu", {}, {}],
      ],
    }, platforms: ["ruby", "x86_64-linux"])

    platform = provider.preferred_platform_for("nokogiri", Gem::Version.new("1.19.0"))
    assert_equal "ruby", platform
  end

  def test_versions_for_respects_required_ruby_version
    provider = provider_with({
      "demo" => [
        ["demo", "1.0.0", "ruby", {}, { "ruby" => ">= 2.0" }],
        ["demo", "2.0.0", "ruby", {}, { "ruby" => ">= 99.0" }],
      ],
    })

    versions = provider.versions_for("demo")
    assert_equal [Gem::Version.new("1.0.0")], versions
  end

  def test_versions_for_ignores_required_ruby_upper_bounds_by_default
    provider = provider_with({
      "demo" => [
        ["demo", "1.0.0", "ruby", {}, { "ruby" => ">= 2.0, < 3.0" }],
      ],
    })

    versions = provider.versions_for("demo")
    assert_equal [Gem::Version.new("1.0.0")], versions
  end

  def test_versions_for_can_enforce_required_ruby_upper_bounds
    with_env("SCINT_IGNORE_RUBY_UPPER_BOUNDS", "0") do
      provider = provider_with({
        "demo" => [
          ["demo", "1.0.0", "ruby", {}, { "ruby" => ">= 2.0, < 3.0" }],
        ],
      })

      versions = provider.versions_for("demo")
      assert_equal [], versions
    end
  end

  def test_prefetch_populates_internal_info_cache
    client = FakeIndexClient.new("rack" => [["rack", "2.2.8", "ruby", {}, {}]])
    provider = Scint::Resolver::Provider.new(client)

    provider.prefetch(["rack"])
    versions = provider.versions_for("rack")

    assert_equal [Gem::Version.new("2.2.8")], versions
    assert_equal [["rack"]], client.prefetch_calls
  end

  def test_index_client_returns_default_client
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client)

    assert_equal client, provider.index_client
  end

  def test_source_uri_for_path_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.0.0", source: "/local/path" } })

    assert_equal "/local/path", provider.source_uri_for("mygem")
  end

  def test_source_uri_for_path_gem_without_source
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.0.0" } })

    assert_equal "path", provider.source_uri_for("mygem")
  end

  def test_source_uri_for_source_mapped_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      source_map: { "private" => "https://private.example.com" })

    assert_equal "https://private.example.com", provider.source_uri_for("private")
  end

  def test_source_uri_for_default_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client)

    assert_equal "https://example.test", provider.source_uri_for("rack")
  end

  def test_client_for_with_source_map
    default_client = FakeIndexClient.new({})
    private_client = FakeIndexClient.new({})

    provider = Scint::Resolver::Provider.new(default_client,
      clients: { "https://private.example.com" => private_client },
      source_map: { "mypkg" => "https://private.example.com" })

    assert_equal private_client, provider.client_for("mypkg")
    assert_equal default_client, provider.client_for("rack")
  end

  def test_versions_for_path_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.2.3" } })

    versions = provider.versions_for("mygem")
    assert_equal [Gem::Version.new("1.2.3")], versions
  end

  def test_versions_for_path_gem_without_version
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => {} })

    versions = provider.versions_for("mygem")
    assert_equal [Gem::Version.new("0")], versions
  end

  def test_dependencies_for_path_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.0.0", dependencies: [["rack", ">= 2.0"], ["puma", nil]] } })

    deps = provider.dependencies_for("mygem", Gem::Version.new("1.0.0"))
    assert_equal Gem::Requirement.new(">= 2.0"), deps["rack"]
    assert_equal Gem::Requirement.new(">= 0"), deps["puma"]
  end

  def test_dependencies_for_path_gem_with_multiple_requirement_parts
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.0.0", dependencies: [["rack", [">= 2.0", "< 3"]]] } })

    deps = provider.dependencies_for("mygem", Gem::Version.new("1.0.0"))
    assert_equal Gem::Requirement.new(">= 2.0", "< 3"), deps["rack"]
  end

  def test_path_or_git_gem
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "mygem" => { version: "1.0.0" } })

    assert_equal true, provider.path_or_git_gem?("mygem")
    assert_equal false, provider.path_or_git_gem?("rack")
  end

  def test_requirements_match_tolerates_malformed_reqs
    client = FakeIndexClient.new({
      "demo" => [
        ["demo", "1.0.0", "ruby", {}, { "ruby" => "garbage!@#" }],
      ],
    })
    provider = Scint::Resolver::Provider.new(client, platforms: ["ruby"])

    # Should not raise; tolerates malformed requirement
    versions = provider.versions_for("demo")
    assert_equal [Gem::Version.new("1.0.0")], versions
  end

  def test_normalize_requirement_with_pessimistic_upper_bound
    client = FakeIndexClient.new({
      "demo" => [
        ["demo", "1.0.0", "ruby", {}, { "ruby" => "~> 2.7" }],
      ],
    })
    provider = Scint::Resolver::Provider.new(client, platforms: ["ruby"])

    # Default: ignore upper bounds, so ~> 2.7 becomes >= 2.7
    versions = provider.versions_for("demo")
    assert_equal [Gem::Version.new("1.0.0")], versions
  end

  def test_prefetch_skips_path_gems
    client = FakeIndexClient.new({})
    provider = Scint::Resolver::Provider.new(client,
      path_gems: { "local" => { version: "1.0.0" } })

    provider.prefetch(["local", "nonexistent"])
    # Should not crash; local should be skipped
    assert_equal [], client.prefetch_calls.flatten.select { |n| n == "local" }
  end
end
