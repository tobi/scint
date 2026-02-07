# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/resolver/resolver"
require "bundler2/gemfile/dependency"

class ResolverTest < Minitest::Test
  class FakeIndexClient
    attr_reader :source_uri

    def initialize(source_uri = "https://example.test")
      @source_uri = source_uri
    end

    def fetch_versions
      {}
    end
  end

  class FakeProvider
    attr_reader :index_client

    def initialize(versions:, dependencies:, has_extensions: {}, platforms: {})
      @versions = versions
      @dependencies = dependencies
      @has_extensions = has_extensions
      @platforms = platforms
      @index_client = FakeIndexClient.new
    end

    def versions_for(name)
      Array(@versions[name]).map { |v| Gem::Version.new(v) }
    end

    def dependencies_for(name, version)
      @dependencies.fetch([name, version.to_s], {})
    end

    def has_extensions?(name, version)
      !!@has_extensions[[name, version.to_s]]
    end

    def preferred_platform_for(name, version)
      @platforms.fetch([name, version.to_s], "ruby")
    end

    def prefetch(_names)
      nil
    end

    def source_uri_for(_name)
      @index_client.source_uri
    end

    def path_or_git_gem?(_name)
      false
    end

    def client_for(_name)
      @index_client
    end
  end

  def test_all_versions_for_prioritizes_locked_version
    provider = FakeProvider.new(
      versions: { "rack" => %w[1.0.0 2.0.0 3.0.0] },
      dependencies: {},
    )

    resolver = Bundler2::Resolver::Resolver.new(
      provider: provider,
      dependencies: [],
      locked_specs: { "rack" => "2.0.0" },
    )

    package = Bundler2::PubGrub::Package.new("rack")
    assert_equal(
      [Gem::Version.new("2.0.0"), Gem::Version.new("3.0.0"), Gem::Version.new("1.0.0")],
      resolver.all_versions_for(package),
    )
  end

  def test_requirement_to_range_for_pessimistic_constraint
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Bundler2::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("~> 2.3.4"))

    assert_equal Gem::Version.new("2.3.4"), range.min
    assert_equal true, range.include_min?
    assert_equal "2.4.A", range.max.to_s
  end

  def test_root_dependencies_merge_duplicate_package_constraints
    provider = FakeProvider.new(versions: {}, dependencies: {})
    deps = [
      Bundler2::Gemfile::Dependency.new("rack", version_reqs: [">= 2.0"]),
      Bundler2::Gemfile::Dependency.new("rack", version_reqs: ["< 3.0"]),
    ]

    resolver = Bundler2::Resolver::Resolver.new(provider: provider, dependencies: deps)
    root_deps = resolver.send(:root_dependencies)

    assert_equal 1, root_deps.size

    constraint = root_deps.values.first
    assert_equal Gem::Version.new("2.0"), constraint.range.min
    assert_equal true, constraint.range.include_min?
    assert_equal Gem::Version.new("3.0"), constraint.range.max
    assert_equal false, constraint.range.include_max?
  end

  def test_build_resolved_spec_maps_provider_data
    provider = FakeProvider.new(
      versions: { "rack" => ["2.2.8"] },
      dependencies: { ["rack", "2.2.8"] => { "dep" => Gem::Requirement.new(">= 1") } },
      has_extensions: { ["rack", "2.2.8"] => true },
      platforms: { ["rack", "2.2.8"] => "arm64-darwin" },
    )
    resolver = Bundler2::Resolver::Resolver.new(provider: provider, dependencies: [])

    package = Bundler2::PubGrub::Package.new("rack")
    spec = resolver.send(:build_resolved_spec, package, Gem::Version.new("2.2.8"))

    assert_equal "rack", spec.name
    assert_equal "2.2.8", spec.version
    assert_equal "arm64-darwin", spec.platform
    assert_equal [{ name: "dep", version_reqs: [">= 1"] }], spec.dependencies
    assert_equal false, spec.has_extensions
    assert_equal "https://example.test", spec.source
  end
end
