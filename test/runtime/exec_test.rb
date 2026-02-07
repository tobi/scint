# frozen_string_literal: true

require_relative "../test_helper"
require "bundler2/runtime/exec"

class RuntimeExecTest < Minitest::Test
  def test_exec_sets_environment_and_invokes_kernel_exec
    with_tmpdir do |dir|
      project = File.join(dir, "app")
      bundle_dir = File.join(project, ".bundle")
      lock_path = File.join(bundle_dir, "bundler2.lock.marshal")
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

      with_env("RUBYLIB", "already") do
        Kernel.stub(:exec, lambda { |*args|
          called = args
          :exec_stubbed
        }) do
          result = Bundler2::Runtime::Exec.exec("ruby", ["-v"], lock_path)
          assert_equal :exec_stubbed, result
        end

        assert_equal ["ruby", "-v"], called
        assert_equal true, ENV["RUBYLIB"].start_with?(existing)
        assert_includes ENV["RUBYLIB"], "already"

        ruby_dir = ruby_bundle_dir(bundle_dir)
        assert_equal ruby_dir, ENV["GEM_HOME"]
        assert_equal ruby_dir, ENV["GEM_PATH"]
        assert_equal File.join(project, "Gemfile"), ENV["BUNDLE_GEMFILE"]
      end
    ensure
      ENV.replace(old_env)
    end
  end

  def test_exec_sets_bundle_gemfile_to_nil_when_project_has_no_gemfile
    with_tmpdir do |dir|
      bundle_dir = File.join(dir, ".bundle")
      lock_path = File.join(bundle_dir, "bundler2.lock.marshal")
      FileUtils.mkdir_p(bundle_dir)
      File.binwrite(lock_path, Marshal.dump({}))

      old_env = ENV.to_hash
      Kernel.stub(:exec, ->(*_args) { :ok }) do
        Bundler2::Runtime::Exec.exec("ruby", [], lock_path)
      end

      assert_nil ENV["BUNDLE_GEMFILE"]
    ensure
      ENV.replace(old_env)
    end
  end
end
