# frozen_string_literal: true

require_relative "test_helper"
require "bundler2"

class Bundler2Test < Minitest::Test
  def setup
    Bundler2.cache_root = nil
  end

  def test_cache_root_uses_xdg_cache_home
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        Bundler2.cache_root = nil
        assert_equal File.join(dir, "bundler2"), Bundler2.cache_root
      end
    end
  end

  def test_cache_root_setter_overrides_default
    Bundler2.cache_root = "/tmp/custom-bundler2-cache"
    assert_equal "/tmp/custom-bundler2-cache", Bundler2.cache_root
  end

  def test_structs_are_keyword_initialized
    dep = Bundler2::Dependency.new(name: "rack", version_reqs: [">= 0"], source: "https://rubygems.org")
    assert_equal "rack", dep.name

    resolved = Bundler2::ResolvedSpec.new(name: "rack", version: "2.2.8", platform: "ruby")
    assert_equal "2.2.8", resolved.version
  end
end
