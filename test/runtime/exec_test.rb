# frozen_string_literal: true

require_relative "../test_helper"
require "scint/runtime/exec"
require "base64"

class RuntimeExecTest < Minitest::Test
  def test_exec_sets_environment_and_invokes_kernel_exec
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)

      existing = File.join(project, "vendor", "rack", "lib")
      missing = File.join(project, "vendor", "missing", "lib")
      FileUtils.mkdir_p(existing)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")

      lock_data = {
        "rack" => { load_paths: [existing, missing] },
      }
      File.binwrite(lock_path, Marshal.dump(lock_data))

      old_env = ENV.to_hash
      called = nil

      with_env("RUBYOPT", nil) do
      with_env("RUBYLIB", "already") do
        Kernel.stub(:exec, lambda { |*args|
          called = args
          :exec_stubbed
        }) do
          result = Scint::Runtime::Exec.exec("ruby", ["-v"], lock_path)
          assert_equal :exec_stubbed, result
        end

        assert_equal ["ruby", "-v"], called
        scint_lib_dir = File.expand_path("../../lib", __dir__)
        assert_equal true, ENV["RUBYLIB"].start_with?(scint_lib_dir)
        assert_includes ENV["RUBYLIB"], "already"
        assert_equal "-rbundler/setup", ENV["RUBYOPT"]
        assert_equal lock_path, ENV["SCINT_RUNTIME_LOCK"]

        ruby_dir = ruby_bundle_dir(bundle_dir)
        assert_equal ruby_dir, ENV["GEM_HOME"]
        gem_path_parts = ENV["GEM_PATH"].split(File::PATH_SEPARATOR)
        assert_equal ruby_dir, gem_path_parts.first
        assert_includes gem_path_parts, ruby_dir
        assert_equal bundle_dir, ENV["BUNDLE_PATH"]
        assert_equal bundle_dir, ENV["BUNDLE_APP_CONFIG"]
        path_parts = ENV["PATH"].split(File::PATH_SEPARATOR)
        assert_equal File.dirname(RbConfig.ruby), path_parts[0]
        assert_equal File.join(ruby_dir, "bin"), path_parts[1]
        assert_equal File.join(bundle_dir, "bin"), path_parts[2]
        assert_equal File.join(project, "Gemfile"), ENV["BUNDLE_GEMFILE"]

        original_env = Marshal.load(Base64.decode64(ENV["SCINT_ORIGINAL_ENV"]))
        assert_equal old_env["PATH"], original_env["PATH"]
      end
      end
    ensure
      ENV.replace(old_env)
    end
  end

  def test_resolve_command_returns_original_when_no_gem_executable_found
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      FileUtils.mkdir_p(File.join(bundle_dir, "bin"))
      FileUtils.mkdir_p(File.join(ruby_dir, "bin"))
      FileUtils.mkdir_p(File.join(ruby_dir, "gems"))

      result = Scint::Runtime::Exec.send(:resolve_command, "nonexistent", bundle_dir, ruby_dir)
      assert_equal "nonexistent", result
    end
  end

  def test_find_gem_executable_searches_gems_directories
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby", "3.3.0")
      gem_dir = File.join(ruby_dir, "gems", "rake-13.0.0")
      exe_dir = File.join(gem_dir, "exe")
      FileUtils.mkdir_p(exe_dir)
      File.write(File.join(exe_dir, "rake"), "#!/usr/bin/env ruby\nputs 'hello'")

      result = Scint::Runtime::Exec.send(:find_gem_executable, ruby_dir, "rake")
      assert_equal File.join(exe_dir, "rake"), result
    end
  end

  def test_find_gem_executable_returns_nil_when_gems_dir_missing
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby", "3.3.0")
      # Don't create gems dir
      result = Scint::Runtime::Exec.send(:find_gem_executable, ruby_dir, "rake")
      assert_nil result
    end
  end

  def test_find_gem_executable_checks_bin_subdirectory_too
    with_tmpdir do |dir|
      ruby_dir = File.join(dir, "ruby", "3.3.0")
      gem_dir = File.join(ruby_dir, "gems", "rspec-3.12.0")
      bin_dir = File.join(gem_dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      File.write(File.join(bin_dir, "rspec"), "#!/usr/bin/env ruby\nputs 'test'")

      result = Scint::Runtime::Exec.send(:find_gem_executable, ruby_dir, "rspec")
      assert_equal File.join(bin_dir, "rspec"), result
    end
  end

  def test_write_bundle_exec_wrapper_creates_wrapper_script
    with_tmpdir do |dir|
      bundle_bin = File.join(dir, "bundle_bin")
      FileUtils.mkdir_p(bundle_bin)

      wrapper_path = File.join(bundle_bin, "rails")
      target_path = File.join(dir, "gems", "railties-7.0.0", "exe", "rails")

      Scint::Runtime::Exec.send(:write_bundle_exec_wrapper, wrapper_path, target_path, bundle_bin)

      assert File.exist?(wrapper_path), "wrapper file should exist"
      content = File.read(wrapper_path)
      assert_includes content, "#!/usr/bin/env ruby"
      assert_includes content, "load"
      assert_equal 0o755, File.stat(wrapper_path).mode & 0o777
    end
  end

  def test_resolve_command_with_absolute_path_returns_command_unchanged
    result = Scint::Runtime::Exec.send(:resolve_command, "/usr/bin/ruby", "/some/bundle", "/some/ruby")
    assert_equal "/usr/bin/ruby", result
  end

  def test_resolve_command_creates_wrapper_for_gem_executable
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      gems_dir = File.join(ruby_dir, "gems")
      gem_dir = File.join(gems_dir, "rspec-3.12.0")
      exe_dir = File.join(gem_dir, "exe")
      FileUtils.mkdir_p(exe_dir)
      FileUtils.mkdir_p(File.join(bundle_dir, "bin"))
      FileUtils.mkdir_p(File.join(ruby_dir, "bin"))
      File.write(File.join(exe_dir, "rspec"), "#!/usr/bin/env ruby\nputs 'test'")

      result = Scint::Runtime::Exec.send(:resolve_command, "rspec", bundle_dir, ruby_dir)

      # Should have created a wrapper in .bundle/bin
      expected_wrapper = File.join(bundle_dir, "bin", "rspec")
      assert_equal expected_wrapper, result
      assert File.exist?(expected_wrapper)
    end
  end

  def test_exec_sets_bundle_gemfile_to_nil_when_project_has_no_gemfile
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      old_env = ENV.to_hash
      Kernel.stub(:exec, ->(*_args) { :ok }) do
        Scint::Runtime::Exec.exec("ruby", [], lock_path)
      end

      assert_nil ENV["BUNDLE_GEMFILE"]
    ensure
      ENV.replace(old_env)
    end
  end

  def test_exec_does_not_preload_shim_for_bundle_command
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gem_lib = File.join(project, "vendor", "rack", "lib")
      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(gem_lib)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")
      File.binwrite(lock_path, Marshal.dump({ "rack" => { load_paths: [gem_lib] } }))

      old_env = ENV.to_hash
      called = nil
      rubylib_after = nil
      rubyopt_after = nil
      with_env("RUBYOPT", nil) do
        with_env("RUBYLIB", nil) do
          Kernel.stub(:exec, lambda { |*args|
            called = args
            rubylib_after = ENV["RUBYLIB"]
            rubyopt_after = ENV["RUBYOPT"]
            :exec_stubbed
          }) do
            result = Scint::Runtime::Exec.exec("bundle", ["-v"], lock_path)
            assert_equal :exec_stubbed, result
          end
        end
      end

      assert_equal ["bundle", "-v"], called
      scint_lib_dir = File.expand_path("../../lib", __dir__)
      refute_includes rubylib_after.to_s, scint_lib_dir
      assert_equal "", rubylib_after.to_s
      refute_includes rubyopt_after.to_s, "-rbundler/setup"
    ensure
      ENV.replace(old_env)
    end
  end

  def test_exec_rewrites_bundle_exec_to_direct_command
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gem_lib = File.join(project, "vendor", "rack", "lib")
      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(gem_lib)
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")
      File.binwrite(lock_path, Marshal.dump({ "rack" => { load_paths: [gem_lib] } }))

      old_env = ENV.to_hash
      called = nil
      rubylib_after = nil
      rubyopt_after = nil
      with_env("RUBYOPT", nil) do
        with_env("RUBYLIB", nil) do
          Kernel.stub(:exec, lambda { |*args|
            called = args
            rubylib_after = ENV["RUBYLIB"]
            rubyopt_after = ENV["RUBYOPT"]
            :exec_stubbed
          }) do
            result = Scint::Runtime::Exec.exec("bundle", ["exec", "rake", "-T"], lock_path)
            assert_equal :exec_stubbed, result
          end
        end
      end

      assert_equal ["rake", "-T"], called
      scint_lib_dir = File.expand_path("../../lib", __dir__)
      assert_includes rubylib_after.to_s, scint_lib_dir
      assert_includes rubyopt_after.to_s, "-rbundler/setup"
    ensure
      ENV.replace(old_env)
    end
  end

  def test_exec_keeps_ruby_bin_before_bundle_bin_for_env_ruby_scripts
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      ruby_dir = ruby_bundle_dir(bundle_dir)
      FileUtils.mkdir_p(File.join(bundle_dir, "bin"))
      FileUtils.mkdir_p(File.join(ruby_dir, "bin"))
      FileUtils.mkdir_p(File.join(project, "bin"))
      File.write(File.join(project, "Gemfile"), "source 'https://rubygems.org'\n")
      File.binwrite(lock_path, Marshal.dump({}))

      # Simulate a gem-provided executable named "ruby" in .bundle/bin.
      File.write(File.join(bundle_dir, "bin", "ruby"), "#!/usr/bin/env ruby\n")
      FileUtils.chmod(0o755, File.join(bundle_dir, "bin", "ruby"))
      File.write(File.join(project, "bin", "rails"), "#!/usr/bin/env ruby\nputs 'ok'\n")
      FileUtils.chmod(0o755, File.join(project, "bin", "rails"))

      old_env = ENV.to_hash
      path_after = nil
      called = nil
      Dir.chdir(project) do
        Kernel.stub(:exec, lambda { |*args|
          called = args
          path_after = ENV["PATH"]
          :exec_stubbed
        }) do
          result = Scint::Runtime::Exec.exec("bin/rails", ["--help"], lock_path)
          assert_equal :exec_stubbed, result
        end
      end

      assert_equal ["bin/rails", "--help"], called
      path_parts = path_after.split(File::PATH_SEPARATOR)
      assert_equal File.dirname(RbConfig.ruby), path_parts[0]
      assert_equal File.join(ruby_dir, "bin"), path_parts[1]
      assert_equal File.join(bundle_dir, "bin"), path_parts[2]
    ensure
      ENV.replace(old_env)
    end
  end
end
