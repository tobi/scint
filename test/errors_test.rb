# frozen_string_literal: true

require_relative "test_helper"
require "scint/errors"

class ErrorsTest < Minitest::Test
  def test_bundler_error_status_code
    assert_equal 1, Scint::BundlerError.new.status_code
  end

  def test_gemfile_error_status_code
    assert_equal 4, Scint::GemfileError.new.status_code
  end

  def test_lockfile_error_status_code
    assert_equal 5, Scint::LockfileError.new.status_code
  end

  def test_resolve_error_status_code
    assert_equal 6, Scint::ResolveError.new.status_code
  end

  def test_network_error_status_code
    assert_equal 7, Scint::NetworkError.new.status_code
  end

  def test_install_error_status_code
    assert_equal 8, Scint::InstallError.new.status_code
  end

  def test_extension_build_error_status_code
    assert_equal 9, Scint::ExtensionBuildError.new.status_code
  end

  def test_permission_error_status_code
    assert_equal 10, Scint::PermissionError.new.status_code
  end

  def test_platform_error_status_code
    assert_equal 11, Scint::PlatformError.new.status_code
  end

  def test_cache_error_status_code
    assert_equal 12, Scint::CacheError.new.status_code
  end

  # Inheritance tests

  def test_extension_build_error_inherits_from_install_error
    assert Scint::ExtensionBuildError < Scint::InstallError,
      "ExtensionBuildError should inherit from InstallError"
  end

  def test_all_errors_inherit_from_bundler_error
    [
      Scint::GemfileError,
      Scint::LockfileError,
      Scint::ResolveError,
      Scint::NetworkError,
      Scint::InstallError,
      Scint::ExtensionBuildError,
      Scint::PermissionError,
      Scint::PlatformError,
      Scint::CacheError,
    ].each do |klass|
      assert klass < Scint::BundlerError,
        "#{klass} should inherit from BundlerError"
    end
  end

  def test_all_errors_inherit_from_standard_error
    [
      Scint::BundlerError,
      Scint::GemfileError,
      Scint::LockfileError,
      Scint::ResolveError,
      Scint::NetworkError,
      Scint::InstallError,
      Scint::ExtensionBuildError,
      Scint::PermissionError,
      Scint::PlatformError,
      Scint::CacheError,
    ].each do |klass|
      assert klass < StandardError,
        "#{klass} should inherit from StandardError"
    end
  end

  def test_errors_can_be_raised_with_message
    err = assert_raises(Scint::GemfileError) { raise Scint::GemfileError, "bad gemfile" }
    assert_equal "bad gemfile", err.message
    assert_equal 4, err.status_code
  end
end
