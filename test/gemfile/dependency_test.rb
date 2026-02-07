# frozen_string_literal: true

require_relative "../test_helper"
require "scint/gemfile/dependency"

class GemfileDependencyTest < Minitest::Test
  def test_default_version_reqs
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal [">= 0"], dep.version_reqs
  end

  def test_explicit_version_reqs
    dep = Scint::Gemfile::Dependency.new("rack", version_reqs: ["~> 3.0", ">= 3.0.1"])
    assert_equal ["~> 3.0", ">= 3.0.1"], dep.version_reqs
  end

  def test_default_groups
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal [:default], dep.groups
  end

  def test_custom_groups
    dep = Scint::Gemfile::Dependency.new("rspec", groups: [:test, :development])
    assert_equal [:test, :development], dep.groups
  end

  def test_groups_converted_to_symbols
    dep = Scint::Gemfile::Dependency.new("rspec", groups: ["test", "development"])
    assert_equal [:test, :development], dep.groups
  end

  def test_default_platforms
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal [], dep.platforms
  end

  def test_custom_platforms
    dep = Scint::Gemfile::Dependency.new("nokogiri", platforms: [:ruby, :jruby])
    assert_equal [:ruby, :jruby], dep.platforms
  end

  def test_platforms_converted_to_symbols
    dep = Scint::Gemfile::Dependency.new("nokogiri", platforms: ["ruby", "jruby"])
    assert_equal [:ruby, :jruby], dep.platforms
  end

  def test_require_paths_nil_by_default
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_nil dep.require_paths
  end

  def test_require_paths_explicit
    dep = Scint::Gemfile::Dependency.new("rack", require_paths: ["lib/rack"])
    assert_equal ["lib/rack"], dep.require_paths
  end

  def test_require_paths_false
    # require: false means empty array in the parser
    dep = Scint::Gemfile::Dependency.new("rake", require_paths: [])
    assert_equal [], dep.require_paths
  end

  def test_source_options_default_empty
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal({}, dep.source_options)
  end

  def test_source_options_with_git
    dep = Scint::Gemfile::Dependency.new("mygem", source_options: { git: "https://github.com/acme/mygem.git" })
    assert_equal({ git: "https://github.com/acme/mygem.git" }, dep.source_options)
  end

  def test_name_is_frozen_string
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal "rack", dep.name
    assert dep.name.frozen?
  end

  def test_to_s_with_default_version
    dep = Scint::Gemfile::Dependency.new("rack")
    assert_equal "rack", dep.to_s
  end

  def test_to_s_with_explicit_version
    dep = Scint::Gemfile::Dependency.new("rack", version_reqs: ["~> 3.0"])
    assert_equal "rack (~> 3.0)", dep.to_s
  end

  def test_to_s_with_multiple_versions
    dep = Scint::Gemfile::Dependency.new("rack", version_reqs: ["~> 3.0", ">= 3.0.1"])
    assert_equal "rack (~> 3.0, >= 3.0.1)", dep.to_s
  end

  def test_empty_version_reqs_defaults
    dep = Scint::Gemfile::Dependency.new("rack", version_reqs: [])
    assert_equal [">= 0"], dep.version_reqs
  end
end
