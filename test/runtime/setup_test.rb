# frozen_string_literal: true

require_relative "../test_helper"
require "scint/runtime/setup"

class RuntimeSetupTest < Minitest::Test
  def test_load_lock_raises_when_missing
    error = assert_raises(LoadError) { Scint::Runtime::Setup.load_lock("/no/such/file") }
    assert_includes error.message, "Runtime lock not found"
  end

  def test_setup_adds_existing_load_paths_and_sets_bundle_gemfile
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
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
        result = Scint::Runtime::Setup.setup(lock_path)

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
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      with_env("BUNDLE_GEMFILE", "/already/set") do
        Scint::Runtime::Setup.setup(lock_path)
        assert_equal "/already/set", ENV["BUNDLE_GEMFILE"]
      end
    end
  end

  def test_setup_leaves_bundle_gemfile_nil_when_gemfile_missing
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      with_env("BUNDLE_GEMFILE", nil) do
        Scint::Runtime::Setup.setup(lock_path)
        assert_nil ENV["BUNDLE_GEMFILE"]
      end
    end
  end

  def test_setup_hydrates_loaded_specs_from_runtime_lock
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({ "mini_racer" => { version: "0.19.1", load_paths: [] } }))

      fake_spec = Struct.new(:version, :full_name).new(Gem::Version.new("0.19.1"), "mini_racer-0.19.1")
      old_loaded_specs = Gem.loaded_specs.dup
      Gem.loaded_specs.delete("mini_racer")

      finder = lambda do |name, *args|
        if name == "mini_racer" && (args.empty? || args.first == "0.19.1")
          [fake_spec]
        else
          []
        end
      end

      Gem::Specification.stub(:find_all_by_name, finder) do
        Scint::Runtime::Setup.setup(lock_path)
      end

      assert_equal fake_spec, Gem.loaded_specs["mini_racer"]
    ensure
      Gem.loaded_specs.replace(old_loaded_specs) if old_loaded_specs
    end
  end

  def test_setup_skips_loaded_specs_when_spec_lookup_fails
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({ "ghost" => { version: "1.0.0", load_paths: [] } }))

      old_loaded_specs = Gem.loaded_specs.dup
      Gem.loaded_specs.delete("ghost")

      Gem::Specification.stub(:find_all_by_name, []) do
        Scint::Runtime::Setup.setup(lock_path)
      end

      assert_nil Gem.loaded_specs["ghost"]
    ensure
      Gem.loaded_specs.replace(old_loaded_specs) if old_loaded_specs
    end
  end
end
