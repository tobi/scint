# frozen_string_literal: true

require_relative "test_helper"
require "bundler2/platform"

class PlatformTest < Minitest::Test
  def test_abi_key_contains_engine_version_and_arch
    key = Bundler2::Platform.abi_key
    assert_includes key, RUBY_ENGINE
    assert_includes key, RUBY_VERSION
    assert_includes key, Bundler2::Platform.arch
  end

  def test_match_platform_for_ruby_and_local
    assert_equal true, Bundler2::Platform.match_platform?("ruby")
    assert_equal true, Bundler2::Platform.match_platform?(Bundler2::Platform.local_platform.to_s)
  end

  def test_gem_arch_matches_rubygems_platform_string
    assert_equal Bundler2::Platform.local_platform.to_s, Bundler2::Platform.gem_arch
  end

  def test_os_predicates_are_boolean
    assert_includes [true, false], Bundler2::Platform.windows?
    assert_includes [true, false], Bundler2::Platform.macos?
    assert_includes [true, false], Bundler2::Platform.linux?
  end
end
