# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/cli/exec"

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
    cli = Bundler2::CLI::Exec.new([])

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
      lock_path = File.join(lock_dir, Bundler2::CLI::Exec::RUNTIME_LOCK)

      FileUtils.mkdir_p(nested)
      FileUtils.mkdir_p(lock_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      called = nil
      Bundler2::Runtime::Exec.stub(:exec, lambda { |cmd, args, path|
        called = [cmd, args, path]
        0
      }) do
        with_cwd(nested) do
          status = Bundler2::CLI::Exec.new(["ruby", "-v"]).run
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
      Bundler2::Runtime::Exec.stub(:exec, lambda { |cmd, args, path|
        called = [cmd, args, path]
        0
      }) do
        with_cwd(nested) do
          status = Bundler2::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Bundler2::CLI::Exec::RUNTIME_LOCK)
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
        s.authors = ["bundler2-test"]
        s.files = []
        s.require_paths = ["lib/concurrent-ruby"]
      end
      File.write(spec_file, gemspec.to_ruby)

      Bundler2::Runtime::Exec.stub(:exec, ->(_cmd, _args, _path) { 0 }) do
        with_cwd(nested) do
          status = Bundler2::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Bundler2::CLI::Exec::RUNTIME_LOCK)
      data = Marshal.load(File.binread(rebuilt_path))
      assert_equal [File.realpath(custom_lib_dir)],
                   data.fetch("concurrent-ruby")[:load_paths].map { |p| File.realpath(p) }
    end
  end

  def test_run_rebuild_adds_nested_lib_dir_when_only_subdirs_exist
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
        s.authors = ["bundler2-test"]
        s.files = []
        s.require_paths = ["lib"]
      end
      File.write(spec_file, gemspec.to_ruby)

      Bundler2::Runtime::Exec.stub(:exec, ->(_cmd, _args, _path) { 0 }) do
        with_cwd(nested) do
          status = Bundler2::CLI::Exec.new(["ruby", "-v"]).run
          assert_equal 0, status
        end
      end

      rebuilt_path = File.join(root, ".bundle", Bundler2::CLI::Exec::RUNTIME_LOCK)
      data = Marshal.load(File.binread(rebuilt_path))
      load_paths = data.fetch("concurrent-ruby")[:load_paths].map { |p| File.realpath(p) }

      assert_includes load_paths, File.realpath(lib_dir)
      assert_includes load_paths, File.realpath(nested_lib_dir)
    end
  end
end
