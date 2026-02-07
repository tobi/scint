# frozen_string_literal: true

require_relative "test_helper"
require "scint"

class ScintTest < Minitest::Test
  def setup
    Scint.cache_root = nil
  end

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

  def test_structs_are_keyword_initialized
    dep = Scint::Dependency.new(name: "rack", version_reqs: [">= 0"], source: "https://rubygems.org")
    assert_equal "rack", dep.name

    resolved = Scint::ResolvedSpec.new(name: "rack", version: "2.2.8", platform: "ruby")
    assert_equal "2.2.8", resolved.version
  end
end
