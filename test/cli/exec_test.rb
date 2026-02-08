# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cli/exec"

class CLIExecTest < Minitest::Test
  def with_captured_stderr
    old_err = $stderr
    err = StringIO.new
    $stderr = err
    yield err
  ensure
    $stderr = old_err
  end

  def test_run_requires_command
    cli = Scint::CLI::Exec.new([])

    with_captured_stderr do |err|
      assert_equal 1, cli.run
      assert_includes err.string, "requires a command"
    end
  end

  def test_run_finds_lockfile_in_parent_and_executes
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      nested = File.join(root, "a", "b")
      lock_dir = File.join(root, ".bundle")
      lock_path = File.join(lock_dir, Scint::CLI::Exec::RUNTIME_LOCK)

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(lock_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      called = nil
      Scint::Runtime::Exec.stub(:exec, lambda { |cmd, args, path|
        called = [cmd, args, path]
        0
      }) do
        with_cwd(nested) do
          status = Scint::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      assert_equal "ruby", called[0]
      assert_equal ["-v"], called[1]
      assert_equal File.realpath(lock_path), File.realpath(called[2])
    end
  end

  def test_run_rebuilds_runtime_lock_from_gemfile_lock_when_missing
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      nested = File.join(root, "a", "b")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      specs_dir = File.join(ruby_dir, "specifications")
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "rack-2.2.8")
      lib_dir = File.join(gem_dir, "lib")

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(specs_dir)
      FileUtils.mkdir_p(lib_dir)
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.8)

        DEPENDENCIES
          rack
      LOCK

      called = nil
      Scint::Runtime::Exec.stub(:exec, lambda { |cmd, args, path|
        called = [cmd, args, path]
        0
      }) do
        with_cwd(nested) do
          status = Scint::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Scint::CLI::Exec::RUNTIME_LOCK)
      assert_equal File.realpath(rebuilt_path), File.realpath(called[2])
      assert File.exist?(rebuilt_path)

      data = Marshal.load(File.binread(rebuilt_path))
      assert_equal "2.2.8", data.fetch("rack")[:version]
      assert_equal [File.realpath(lib_dir)], data.fetch("rack")[:load_paths].map { |p| File.realpath(p) }
    end
  end

  def test_run_rebuild_uses_require_paths_from_installed_gemspec
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      nested = File.join(root, "a", "b")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      specs_dir = File.join(ruby_dir, "specifications")
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "concurrent-ruby-1.3.6")
      custom_lib_dir = File.join(gem_dir, "lib", "concurrent-ruby")
      spec_file = File.join(specs_dir, "concurrent-ruby-1.3.6.gemspec")

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(custom_lib_dir)
      FileUtils.mkdir_p(specs_dir)
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            concurrent-ruby (1.3.6)

        DEPENDENCIES
          concurrent-ruby
      LOCK

      gemspec = Gem::Specification.new do |s|
        s.name = "concurrent-ruby"
        s.version = Gem::Version.new("1.3.6")
        s.summary = "test"
        s.authors = ["scint-test"]
        s.files = []
        s.require_paths = ["lib/concurrent-ruby"]
      end
      File.write(spec_file, gemspec.to_ruby)

      Scint::Runtime::Exec.stub(:exec, ->(_cmd, _args, _path) { 0 }) do
        with_cwd(nested) do
          status = Scint::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Scint::CLI::Exec::RUNTIME_LOCK)
      data = Marshal.load(File.binread(rebuilt_path))
      assert_equal [File.realpath(custom_lib_dir)],
                   data.fetch("concurrent-ruby")[:load_paths].map { |p| File.realpath(p) }
    end
  end

  def test_run_rebuild_keeps_absolute_require_paths_from_installed_gemspec
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      nested = File.join(root, "a", "b")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      specs_dir = File.join(ruby_dir, "specifications")
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "pg-1.5.3")
      lib_dir = File.join(gem_dir, "lib")
      ext_dir = File.join(ruby_dir, "extensions", Scint::Platform.gem_arch, Scint::Platform.extension_api_version, "pg-1.5.3")
      spec_file = File.join(specs_dir, "pg-1.5.3.gemspec")

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(lib_dir)
      FileUtils.mkdir_p(ext_dir)
      FileUtils.mkdir_p(specs_dir)
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            pg (1.5.3)

        DEPENDENCIES
          pg
      LOCK

      gemspec = Gem::Specification.new do |s|
        s.name = "pg"
        s.version = Gem::Version.new("1.5.3")
        s.summary = "test"
        s.authors = ["scint-test"]
        s.files = []
        s.require_paths = [ext_dir, "lib"]
      end
      File.write(spec_file, gemspec.to_ruby)

      Scint::Runtime::Exec.stub(:exec, ->(_cmd, _args, _path) { 0 }) do
        with_cwd(nested) do
          status = Scint::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Scint::CLI::Exec::RUNTIME_LOCK)
      data = Marshal.load(File.binread(rebuilt_path))
      load_paths = data.fetch("pg")[:load_paths]
      assert_includes load_paths, ext_dir
      assert_includes load_paths, lib_dir
    end
  end

  def test_run_returns_error_when_no_lockfile_found
    with_tmpdir do |dir|
      with_cwd(dir) do
        old_err = $stderr
        err = StringIO.new
        $stderr = err

        status = Scint::CLI::Exec.new(["ruby", "-v"]).run
        assert_equal 1, status
        assert_includes err.string, "No runtime lock found"
      ensure
        $stderr = old_err
      end
    end
  end

  def test_rebuild_runtime_lock_returns_nil_on_standard_error
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      specs_dir = File.join(ruby_dir, "specifications")
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "rack-2.2.8")
      lib_dir = File.join(gem_dir, "lib")

      FileUtils.mkdir_p(specs_dir)
      FileUtils.mkdir_p(lib_dir)
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.8)

        DEPENDENCIES
          rack
      LOCK

      lock_path = File.join(bundle_dir, Scint::CLI::Exec::RUNTIME_LOCK)
      exec_instance = Scint::CLI::Exec.new(["ruby"])

      # Stub FS.atomic_write to raise, simulating an error during rebuild
      Scint::FS.stub(:atomic_write, ->(*) { raise StandardError, "disk error" }) do
        result = exec_instance.send(:rebuild_runtime_lock, root, bundle_dir, lock_path)
        assert_nil result
      end
    end
  end

  def test_read_require_paths_returns_lib_on_exception
    with_tmpdir do |dir|
      spec_file = File.join(dir, "bad.gemspec")
      File.write(spec_file, "this is not valid ruby gemspec syntax }{")

      exec_instance = Scint::CLI::Exec.new(["ruby"])
      result = exec_instance.send(:read_require_paths, spec_file)
      assert_equal ["lib"], result
    end
  end

  def test_read_require_paths_rescues_standard_error_from_load
    with_tmpdir do |dir|
      spec_file = File.join(dir, "error.gemspec")
      File.write(spec_file, "# dummy gemspec")

      exec_instance = Scint::CLI::Exec.new(["ruby"])

      # Stub Gem::Specification.load to raise StandardError (line 129-130)
      Gem::Specification.stub(:load, ->(_path) { raise StandardError, "load kaboom" }) do
        result = exec_instance.send(:read_require_paths, spec_file)
        assert_equal ["lib"], result, "should return ['lib'] when Gem::Specification.load raises"
      end
    end
  end

  def test_detect_ruby_dir_fallback_to_any_directory
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = File.join(bundle_dir, "ruby", "2.7.0")
      FileUtils.mkdir_p(ruby_dir)

      exec_instance = Scint::CLI::Exec.new(["ruby"])
      result = exec_instance.send(:detect_ruby_dir, bundle_dir)

      # Should fall back to the only available directory
      assert_equal ruby_dir, result
    end
  end

  def test_spec_full_name_with_platform
    exec_instance = Scint::CLI::Exec.new(["ruby"])
    spec = { name: "ffi", version: "1.17.0", platform: "x86_64-linux" }
    result = exec_instance.send(:spec_full_name, spec)
    assert_equal "ffi-1.17.0-x86_64-linux", result
  end

  def test_run_rebuild_keeps_only_declared_lib_dir_when_only_subdirs_exist
    with_tmpdir do |dir|
      root = File.join(dir, "project")
      nested = File.join(root, "a", "b")
      bundle_dir = File.join(root, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      specs_dir = File.join(ruby_dir, "specifications")
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "concurrent-ruby-1.3.6")
      lib_dir = File.join(gem_dir, "lib")
      nested_lib_dir = File.join(lib_dir, "concurrent-ruby")
      spec_file = File.join(specs_dir, "concurrent-ruby-1.3.6.gemspec")

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(nested_lib_dir)
      FileUtils.mkdir_p(specs_dir)
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            concurrent-ruby (1.3.6)

        DEPENDENCIES
          concurrent-ruby
      LOCK

      gemspec = Gem::Specification.new do |s|
        s.name = "concurrent-ruby"
        s.version = Gem::Version.new("1.3.6")
        s.summary = "test"
        s.authors = ["scint-test"]
        s.files = []
        s.require_paths = ["lib"]
      end
      File.write(spec_file, gemspec.to_ruby)

      Scint::Runtime::Exec.stub(:exec, ->(_cmd, _args, _path) { 0 }) do
        with_cwd(nested) do
          status = Scint::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Scint::CLI::Exec::RUNTIME_LOCK)
      data = Marshal.load(File.binread(rebuilt_path))
      load_paths = data.fetch("concurrent-ruby")[:load_paths].map { |p| File.realpath(p) }

      assert_includes load_paths, File.realpath(lib_dir)
      refute_includes load_paths, File.realpath(nested_lib_dir)
    end
  end
end
