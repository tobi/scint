# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/runtime/setup"

class RuntimeSetupTest < Minitest::Test
  def test_load_lock_raises_when_missing
    error = assert_raises(LoadError) { Bundler2::Runtime::Setup.load_lock("/no/such/file") }
    assert_includes error.message, "Runtime lock not found"
  end

  def test_setup_adds_existing_load_paths_and_sets_bundle_gemfile
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "bundler2.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)

      existing = File.join(project, "vendor", "rack", "lib")
      missing = File.join(project, "vendor", "missing", "lib")
      FileUtils.mkdir_p(existing)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")

      data = {
        "rack" => { load_paths: [existing, missing] },
      }
      File.binwrite(lock_path, Marshal.dump(data))

      old_load_path = $LOAD_PATH.dup
      with_env("BUNDLE_GEMFILE", nil) do
        result = Bundler2::Runtime::Setup.setup(lock_path)

        assert_equal data, result
        assert_equal existing, $LOAD_PATH.first
        refute_includes $LOAD_PATH, missing
        assert_equal File.join(project, "Gemfile"), ENV["BUNDLE_GEMFILE"]
      end
    ensure
      $LOAD_PATH.replace(old_load_path)
    end
  end

  def test_setup_does_not_override_existing_bundle_gemfile
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "bundler2.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      with_env("BUNDLE_GEMFILE", "/already/set") do
        Bundler2::Runtime::Setup.setup(lock_path)
        assert_equal "/already/set", ENV["BUNDLE_GEMFILE"]
      end
    end
  end

  def test_setup_leaves_bundle_gemfile_nil_when_gemfile_missing
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "bundler2.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      with_env("BUNDLE_GEMFILE", nil) do
        Bundler2::Runtime::Setup.setup(lock_path)
        assert_nil ENV["BUNDLE_GEMFILE"]
      end
    end
  end
end
