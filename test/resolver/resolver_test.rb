# frozen_string_literal: true

require_relative "../test_helper"
require "scint/resolver/resolver"
require "scint/gemfile/dependency"

class ResolverTest < Minitest::Test
  class FakeIndexClient
    attr_reader :source_uri

    def initialize(source_uri = "https://example.test", data: {})
      @source_uri = source_uri
      @data = data
    end

    def fetch_versions
      {}
    end

    def prefetch(_names)
      nil
    end

    def fetch_info(name)
      @data.fetch(name, [])
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

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: [],
      locked_specs: { "rack" => "2.0.0" },
    )

    package = Scint::PubGrub::Package.new("rack")
    assert_equal(
      [Gem::Version.new("2.0.0"), Gem::Version.new("3.0.0"), Gem::Version.new("1.0.0")],
      resolver.all_versions_for(package),
    )
  end

  def test_requirement_to_range_for_pessimistic_constraint
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("~> 2.3.4"))

    assert_equal Gem::Version.new("2.3.4"), range.min
    assert_equal true, range.include_min?
    assert_equal "2.4.A", range.max.to_s
  end

  def test_root_dependencies_merge_duplicate_package_constraints
    provider = FakeProvider.new(versions: {}, dependencies: {})
    deps = [
      Scint::Gemfile::Dependency.new("rack", version_reqs: [">= 2.0"]),
      Scint::Gemfile::Dependency.new("rack", version_reqs: ["< 3.0"]),
    ]

    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: deps)
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
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    package = Scint::PubGrub::Package.new("rack")
    spec = resolver.send(:build_resolved_spec, package, Gem::Version.new("2.2.8"))

    assert_equal "rack", spec.name
    assert_equal "2.2.8", spec.version
    assert_equal "arm64-darwin", spec.platform
    assert_equal [{ name: "dep", version_reqs: [">= 1"] }], spec.dependencies
    assert_equal false, spec.has_extensions
    assert_equal "https://example.test", spec.source
  end

  # --- requirement_to_range operator tests ---

  def test_requirement_to_range_for_greater_than
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("> 1.0"))

    assert_equal Gem::Version.new("1.0"), range.min
    assert_equal false, range.include_min?
    assert_nil range.max
  end

  def test_requirement_to_range_for_greater_than_or_equal
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new(">= 2.0"))

    assert_equal Gem::Version.new("2.0"), range.min
    assert_equal true, range.include_min?
    assert_nil range.max
  end

  def test_requirement_to_range_for_less_than
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("< 3.0"))

    assert_nil range.min
    assert_equal Gem::Version.new("3.0"), range.max
    assert_equal false, range.include_max?
  end

  def test_requirement_to_range_for_less_than_or_equal
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("<= 4.0"))

    assert_nil range.min
    assert_equal Gem::Version.new("4.0"), range.max
    assert_equal true, range.include_max?
  end

  def test_requirement_to_range_for_equal
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("= 1.5.0"))

    assert_equal Gem::Version.new("1.5.0"), range.min
    assert_equal Gem::Version.new("1.5.0"), range.max
    assert_equal true, range.include_min?
    assert_equal true, range.include_max?
  end

  def test_requirement_to_range_for_not_equal
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    range = resolver.send(:requirement_to_range, Gem::Requirement.new("!= 1.5.0"))

    # != returns the inversion of the equal range, which is a VersionUnion
    # It should include versions other than 1.5.0
    v1_4 = Gem::Version.new("1.4.0")
    v1_5 = Gem::Version.new("1.5.0")
    v1_6 = Gem::Version.new("1.6.0")

    assert range.include?(v1_4), "!= 1.5.0 should include 1.4.0"
    refute range.include?(v1_5), "!= 1.5.0 should not include 1.5.0"
    assert range.include?(v1_6), "!= 1.5.0 should include 1.6.0"
  end

  # --- Full resolve test ---

  # Transitive deps of a source-pinned gem must resolve from that same source.
  def test_resolve_with_inline_source_propagates_to_transitive_deps
    default_client = FakeIndexClient.new("https://rubygems.org", data: {
      "rack" => [["rack", "2.0.0", "ruby", {}, {}]],
    })
    private_client = FakeIndexClient.new("https://private.example.com", data: {
      "database_documentation" => [
        ["database_documentation", "2.0.0", "ruby", { "services_db-client" => "~> 0.24.2" }, {}],
      ],
      "services_db-client" => [["services_db-client", "0.24.3", "ruby", {}, {}]],
    })

    provider = Scint::Resolver::Provider.new(
      default_client,
      clients: {
        "https://rubygems.org" => default_client,
        "https://private.example.com" => private_client,
      },
      source_map: { "database_documentation" => "https://private.example.com" },
      platforms: ["ruby"],
    )

    deps = [
      Scint::Gemfile::Dependency.new("rack", version_reqs: [">= 1.0"]),
      Scint::Gemfile::Dependency.new("database_documentation", version_reqs: ["~> 2.0"]),
    ]

    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: deps)
    result = resolver.resolve
    resolved = result.each_with_object({}) { |spec, h| h[spec.name] = spec }

    assert_includes resolved.keys, "services_db-client"
    assert_equal "0.24.3", resolved["services_db-client"].version
    assert_equal "https://private.example.com", resolved["services_db-client"].source
    assert_equal "2.0.0", resolved["rack"].version
    assert_equal "https://rubygems.org", resolved["rack"].source
  end

  def test_resolve_with_simple_dependency_graph
    # Set up a small dependency graph:
    #   app depends on rack >= 2.0, < 3.0
    #   app depends on json >= 1.0
    #   rack 2.2.8 depends on json >= 1.0
    provider = FakeProvider.new(
      versions: {
        "rack" => %w[1.0.0 2.0.0 2.2.8],
        "json" => %w[1.0.0 2.0.0 2.7.0],
      },
      dependencies: {
        ["rack", "1.0.0"] => {},
        ["rack", "2.0.0"] => { "json" => Gem::Requirement.new(">= 1.0") },
        ["rack", "2.2.8"] => { "json" => Gem::Requirement.new(">= 1.0") },
        ["json", "1.0.0"] => {},
        ["json", "2.0.0"] => {},
        ["json", "2.7.0"] => {},
      },
    )

    deps = [
      Scint::Gemfile::Dependency.new("rack", version_reqs: [">= 2.0", "< 3.0"]),
      Scint::Gemfile::Dependency.new("json", version_reqs: [">= 1.0"]),
    ]

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: deps,
    )

    result = resolver.resolve
    resolved = result.each_with_object({}) { |spec, h| h[spec.name] = spec }

    assert_includes resolved.keys, "rack"
    assert_includes resolved.keys, "json"

    rack_ver = Gem::Version.new(resolved["rack"].version)
    assert rack_ver >= Gem::Version.new("2.0.0"), "rack should be >= 2.0.0"
    assert rack_ver < Gem::Version.new("3.0.0"), "rack should be < 3.0.0"

    json_ver = Gem::Version.new(resolved["json"].version)
    assert json_ver >= Gem::Version.new("1.0.0"), "json should be >= 1.0.0"
  end

  def test_resolve_with_single_gem_no_deps
    provider = FakeProvider.new(
      versions: { "rake" => %w[13.0.0 13.1.0] },
      dependencies: {
        ["rake", "13.0.0"] => {},
        ["rake", "13.1.0"] => {},
      },
    )

    deps = [Scint::Gemfile::Dependency.new("rake", version_reqs: [">= 13.0"])]

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: deps,
    )

    result = resolver.resolve

    assert_equal 1, result.size
    assert_equal "rake", result.first.name
    assert Gem::Version.new(result.first.version) >= Gem::Version.new("13.0.0")
  end

  # --- prefetch_all tests ---

  def test_prefetch_all_calls_provider_prefetch_with_all_names
    prefetched_names = nil
    provider = FakeProvider.new(
      versions: { "rack" => %w[2.0.0] },
      dependencies: {},
    )
    provider.define_singleton_method(:prefetch) do |names|
      prefetched_names = names
      nil
    end

    deps = [
      Scint::Gemfile::Dependency.new("rack", version_reqs: [">= 1.0"]),
    ]

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: deps,
      locked_specs: { "json" => "2.0.0" },
    )

    resolver.send(:prefetch_all)

    assert_includes prefetched_names, "rack"
    assert_includes prefetched_names, "json"
  end

  def test_prefetch_all_skips_path_or_git_gems_for_fetch_versions
    fetch_versions_called = false
    provider = FakeProvider.new(
      versions: { "mygem" => %w[1.0.0] },
      dependencies: {},
    )
    provider.define_singleton_method(:path_or_git_gem?) do |name|
      name == "mygem"
    end
    provider.index_client.define_singleton_method(:fetch_versions) do
      fetch_versions_called = true
      {}
    end

    deps = [Scint::Gemfile::Dependency.new("mygem", version_reqs: [">= 0"])]

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: deps,
    )

    resolver.send(:prefetch_all)

    refute fetch_versions_called, "fetch_versions should not be called for path/git gems"
  end

  # --- versions_for tests ---

  def test_versions_for_selects_versions_in_range
    provider = FakeProvider.new(
      versions: { "rack" => %w[1.0.0 2.0.0 3.0.0] },
      dependencies: {},
    )

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: [],
    )

    package = Scint::PubGrub::Package.new("rack")
    range = Scint::PubGrub::VersionRange.new(
      min: Gem::Version.new("1.5"),
      max: Gem::Version.new("2.5"),
      include_min: true,
    )

    versions = resolver.versions_for(package, range)

    assert_equal [Gem::Version.new("2.0.0")], versions
  end

  def test_versions_for_returns_all_when_any_range
    provider = FakeProvider.new(
      versions: { "rack" => %w[1.0.0 2.0.0] },
      dependencies: {},
    )

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: [],
    )

    package = Scint::PubGrub::Package.new("rack")
    versions = resolver.versions_for(package)

    assert_equal 2, versions.size
    assert_includes versions, Gem::Version.new("1.0.0")
    assert_includes versions, Gem::Version.new("2.0.0")
  end

  # --- incompatibilities_for test ---

  def test_incompatibilities_for_returns_dependency_incompatibilities
    provider = FakeProvider.new(
      versions: { "rack" => %w[1.0.0 2.0.0], "json" => %w[1.0.0] },
      dependencies: {
        ["rack", "1.0.0"] => { "json" => Gem::Requirement.new(">= 1.0") },
        ["rack", "2.0.0"] => { "json" => Gem::Requirement.new(">= 1.0") },
      },
    )

    deps = [Scint::Gemfile::Dependency.new("rack", version_reqs: [">= 1.0"])]

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: deps,
    )

    package = Scint::PubGrub::Package.new("rack")
    version = Gem::Version.new("1.0.0")

    incompats = resolver.incompatibilities_for(package, version)

    assert_equal 1, incompats.size
    incompat = incompats.first
    assert_instance_of Scint::PubGrub::Incompatibility, incompat
    assert_equal :dependency, incompat.cause
  end

  # --- no_versions_incompatibility_for test ---

  def test_no_versions_incompatibility_for_creates_incompatibility
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    package = Scint::PubGrub::Package.new("missing")
    range = Scint::PubGrub::VersionRange.any
    constraint = Scint::PubGrub::VersionConstraint.new(package, range: range)
    term = Scint::PubGrub::Term.new(constraint, true)

    incompat = resolver.no_versions_incompatibility_for(package, term)

    assert_instance_of Scint::PubGrub::Incompatibility, incompat
    assert_instance_of Scint::PubGrub::Incompatibility::NoVersions, incompat.cause
  end

  # --- requirement_to_range bad operator test ---

  def test_requirement_to_range_raises_for_unknown_operator
    provider = FakeProvider.new(versions: {}, dependencies: {})
    resolver = Scint::Resolver::Resolver.new(provider: provider, dependencies: [])

    # Create a requirement with a bad operator by manipulating internals
    bad_req = Gem::Requirement.new(">= 0")
    bad_req.instance_variable_set(:@requirements, [["<>", Gem::Version.new("1.0")]])

    assert_raises(Scint::ResolveError) do
      resolver.send(:requirement_to_range, bad_req)
    end
  end

  # --- dependencies_for test ---

  def test_dependencies_for_maps_provider_deps_to_pubgrub_constraints
    provider = FakeProvider.new(
      versions: { "rack" => %w[2.0.0] },
      dependencies: {
        ["rack", "2.0.0"] => { "json" => Gem::Requirement.new(">= 1.0") },
      },
    )

    resolver = Scint::Resolver::Resolver.new(
      provider: provider,
      dependencies: [],
    )

    package = Scint::PubGrub::Package.new("rack")
    version = Gem::Version.new("2.0.0")

    result = resolver.send(:dependencies_for, package, version)

    assert_equal 1, result.size
    dep_package = result.keys.first
    assert_equal "json", dep_package.name
    constraint = result.values.first
    assert_instance_of Scint::PubGrub::VersionConstraint, constraint
  end
end
