# frozen_string_literal: true

require_relative "test_helper"
require "scint"

class ScintTest < Minitest::Test
  def setup
    Scint.cache_root = nil
  end

  # --- VERSION ---

  def test_version_is_defined
    assert_kind_of String, Scint::VERSION
    refute_empty Scint::VERSION
    assert_match(/\A\d+\.\d+\.\d+/, Scint::VERSION)
  end

  # --- Color constants ---

  def test_color_constants_empty_when_no_color_set
    # COLOR is computed at load time, so we test the invariant:
    # when COLOR is false, all color constants are empty strings.
    # Since NO_COLOR or non-TTY may already be set in CI, we check
    # the constants are consistent with the COLOR flag.
    if Scint::COLOR
      assert_match(/\e\[/, Scint::GREEN)
      assert_match(/\e\[/, Scint::RED)
      assert_match(/\e\[/, Scint::YELLOW)
      assert_match(/\e\[/, Scint::BOLD)
      assert_match(/\e\[/, Scint::DIM)
      assert_match(/\e\[/, Scint::RESET)
    else
      assert_equal "", Scint::GREEN
      assert_equal "", Scint::RED
      assert_equal "", Scint::YELLOW
      assert_equal "", Scint::BOLD
      assert_equal "", Scint::DIM
      assert_equal "", Scint::RESET
    end
  end

  def test_color_constants_are_strings
    [Scint::GREEN, Scint::RED, Scint::YELLOW, Scint::BOLD, Scint::DIM, Scint::RESET].each do |c|
      assert_kind_of String, c
    end
  end

  # Since tests run in a non-TTY (piped) environment, COLOR should be false
  # and all color constants should be empty strings.
  def test_color_is_false_in_test_environment
    # In test/CI environments stderr is not a TTY, so COLOR should be false
    # unless explicitly overridden. This test documents the expected behavior.
    unless $stderr.tty?
      refute Scint::COLOR, "COLOR should be false when stderr is not a TTY"
      assert_equal "", Scint::GREEN
      assert_equal "", Scint::RED
      assert_equal "", Scint::YELLOW
      assert_equal "", Scint::BOLD
      assert_equal "", Scint::DIM
      assert_equal "", Scint::RESET
    end
  end

  # --- Cache root ---

  def test_cache_root_uses_xdg_cache_home
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        Scint.cache_root = nil
        assert_equal File.join(dir, "scint"), Scint.cache_root
      end
    end
  end

  def test_cache_root_setter_overrides_default
    Scint.cache_root = "/tmp/custom-scint-cache"
    assert_equal "/tmp/custom-scint-cache", Scint.cache_root
  end

  def test_cache_root_defaults_to_home_cache_when_xdg_unset
    with_env("XDG_CACHE_HOME", nil) do
      Scint.cache_root = nil
      expected = File.join(Dir.home, ".cache", "scint")
      assert_equal expected, Scint.cache_root
    end
  end

  # --- Structs ---

  def test_structs_are_keyword_initialized
    dep = Scint::Dependency.new(name: "rack", version_reqs: [">= 0"], source: "https://rubygems.org")
    assert_equal "rack", dep.name

    resolved = Scint::ResolvedSpec.new(name: "rack", version: "2.2.8", platform: "ruby")
    assert_equal "2.2.8", resolved.version
  end

  def test_dependency_struct_members
    dep = Scint::Dependency.new(
      name: "rails",
      version_reqs: [">= 7.0"],
      source: "https://rubygems.org",
      groups: [:default],
      platforms: [:ruby],
      require_paths: ["lib"]
    )
    assert_equal "rails", dep.name
    assert_equal [">= 7.0"], dep.version_reqs
    assert_equal "https://rubygems.org", dep.source
    assert_equal [:default], dep.groups
    assert_equal [:ruby], dep.platforms
    assert_equal ["lib"], dep.require_paths
  end

  def test_locked_spec_struct_members
    ls = Scint::LockedSpec.new(
      name: "rack",
      version: "3.0.0",
      platform: "ruby",
      dependencies: [{ name: "webrick" }],
      source: "https://rubygems.org",
      checksum: "abc123"
    )
    assert_equal "rack", ls.name
    assert_equal "3.0.0", ls.version
    assert_equal "ruby", ls.platform
    assert_equal [{ name: "webrick" }], ls.dependencies
    assert_equal "https://rubygems.org", ls.source
    assert_equal "abc123", ls.checksum
  end

  def test_resolved_spec_struct_members
    rs = Scint::ResolvedSpec.new(
      name: "puma",
      version: "6.0.0",
      platform: "x86_64-linux",
      dependencies: [],
      source: "https://rubygems.org",
      has_extensions: true,
      remote_uri: "https://rubygems.org/gems/puma-6.0.0.gem",
      checksum: "sha256:abc"
    )
    assert_equal "puma", rs.name
    assert_equal "6.0.0", rs.version
    assert_equal "x86_64-linux", rs.platform
    assert_equal [], rs.dependencies
    assert_equal "https://rubygems.org", rs.source
    assert_equal true, rs.has_extensions
    assert_equal "https://rubygems.org/gems/puma-6.0.0.gem", rs.remote_uri
    assert_equal "sha256:abc", rs.checksum
  end

  def test_plan_entry_struct_members
    spec = Scint::ResolvedSpec.new(name: "rack", version: "3.0.0")
    pe = Scint::PlanEntry.new(
      spec: spec,
      action: :download,
      cached_path: "/tmp/cache/rack-3.0.0",
      gem_path: "/tmp/gems/rack-3.0.0"
    )
    assert_equal spec, pe.spec
    assert_equal :download, pe.action
    assert_equal "/tmp/cache/rack-3.0.0", pe.cached_path
    assert_equal "/tmp/gems/rack-3.0.0", pe.gem_path
  end

  def test_prepared_gem_struct_members
    spec = Scint::ResolvedSpec.new(name: "rack", version: "3.0.0")
    pg = Scint::PreparedGem.new(
      spec: spec,
      extracted_path: "/tmp/extracted",
      gemspec: nil,
      from_cache: true
    )
    assert_equal spec, pg.spec
    assert_equal "/tmp/extracted", pg.extracted_path
    assert_nil pg.gemspec
    assert_equal true, pg.from_cache
  end

  # --- Autoloads ---

  def test_autoload_errors
    require "scint/errors"
    assert_kind_of Class, Scint::BundlerError
    assert_kind_of Class, Scint::GemfileError
  end

  def test_autoload_fs
    require "scint/fs"
    assert_kind_of Module, Scint::FS
  end

  def test_autoload_platform
    require "scint/platform"
    assert_kind_of Module, Scint::Platform
  end

  def test_submodule_namespaces_exist
    assert_kind_of Module, Scint::Gemfile
    assert_kind_of Module, Scint::Lockfile
    assert_kind_of Module, Scint::Resolver
    assert_kind_of Module, Scint::Index
    assert_kind_of Module, Scint::Downloader
    assert_kind_of Module, Scint::Cache
    assert_kind_of Module, Scint::Installer
    assert_kind_of Module, Scint::Source
    assert_kind_of Module, Scint::Runtime
  end
end
