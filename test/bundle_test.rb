# frozen_string_literal: true

require_relative "test_helper"
require "scint/bundle"
require "scint/cache/layout"

class BundleTest < Minitest::Test
  def test_gemfile_parses_from_root_directory
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY

      bundle = Scint::Bundle.new(dir)
      gf = bundle.gemfile
      assert_instance_of Scint::Gemfile::ParseResult, gf
      assert_equal 1, gf.dependencies.size
      assert_equal "rack", gf.dependencies.first.name
    end
  end

  def test_gemfile_is_memoized
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY

      bundle = Scint::Bundle.new(dir)
      first = bundle.gemfile
      second = bundle.gemfile
      assert_same first, second
    end
  end

  def test_lockfile_returns_nil_when_missing
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY

      bundle = Scint::Bundle.new(dir)
      assert_nil bundle.lockfile
    end
  end

  def test_lockfile_parses_when_present
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.8)

        PLATFORMS
          ruby

        DEPENDENCIES
          rack

        BUNDLED WITH
          2.5.0
      LOCK

      bundle = Scint::Bundle.new(dir)
      lf = bundle.lockfile
      refute_nil lf
      assert_instance_of Scint::Lockfile::LockfileData, lf
      spec_names = lf.specs.map { |s| s[:name] }
      assert_includes spec_names, "rack"
    end
  end

  def test_lockfile_is_memoized
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.8)

        PLATFORMS
          ruby

        DEPENDENCIES
          rack

        BUNDLED WITH
          2.5.0
      LOCK

      bundle = Scint::Bundle.new(dir)
      first = bundle.lockfile
      second = bundle.lockfile
      assert_same first, second
    end
  end

  def test_cache_returns_layout
    bundle = Scint::Bundle.new(".")
    cache = bundle.cache
    assert_instance_of Scint::Cache::Layout, cache
  end

  def test_cache_is_memoized
    bundle = Scint::Bundle.new(".")
    first = bundle.cache
    second = bundle.cache
    assert_same first, second
  end

  def test_resolve_with_matching_lockfile_uses_fast_path
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
      RUBY
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.8)

        PLATFORMS
          ruby

        DEPENDENCIES
          rack

        BUNDLED WITH
          2.5.0
      LOCK

      bundle = Scint::Bundle.new(dir)
      resolved = bundle.resolve(fetch_indexes: false)
      assert_kind_of Array, resolved

      names = resolved.map(&:name)
      assert_includes names, "rack"
      assert_includes names, "scint"
    end
  end

  def test_group_filtering_with_without
    with_tmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack"
        group :development do
          gem "minitest"
        end
      RUBY
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            minitest (5.20.0)
            rack (2.2.8)

        PLATFORMS
          ruby

        DEPENDENCIES
          minitest
          rack

        BUNDLED WITH
          2.5.0
      LOCK

      bundle = Scint::Bundle.new(dir, without: [:development])
      resolved = bundle.resolve(fetch_indexes: false)
      names = resolved.map(&:name)
      assert_includes names, "rack"
      refute_includes names, "minitest"
    end
  end

  def test_root_is_expanded
    bundle = Scint::Bundle.new(".")
    assert_equal File.expand_path("."), bundle.root
  end
end
