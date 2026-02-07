# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "base64"

class BundlerShimTest < Minitest::Test
  def test_bundler_setup_and_require_use_scint_runtime_lock
    with_tmpdir do |dir|
      project_dir = File.join(dir, "app")
      bundle_dir = File.join(project_dir, ".scint")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gem_lib = File.join(project_dir, "vendor", "my_gem", "lib")
      gemfile_path = File.join(project_dir, "Gemfile")

      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(File.join(gem_lib, "my"))
      File.write(File.join(gem_lib, "my", "gem.rb"), "MY_GEM_LOADED = true\n")
      File.write(gemfile_path, "source 'https://rubygems.org'\ngem 'my-gem'\n")
      File.binwrite(lock_path, Marshal.dump({ "my-gem" => { load_paths: [gem_lib] } }))

      lib_dir = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        require "bundler/setup"
        Bundler.require
        print [defined?(Scint), defined?(Bundler), defined?(MY_GEM_LOADED)].join("|")
      RUBY

      out, err, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => gemfile_path,
          "SCINT_RUNTIME_LOCK" => lock_path,
        },
        RbConfig.ruby,
        "-I#{lib_dir}",
        "-e",
        script,
      )

      assert status.success?, err
      assert_equal "constant|constant|constant", out
      assert_equal "", err
    end
  end

  def test_bundler_original_env_and_unbundled_env_are_available
    with_tmpdir do |dir|
      project_dir = File.join(dir, "app")
      bundle_dir = File.join(project_dir, ".scint")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gemfile_path = File.join(project_dir, "Gemfile")

      FileUtils.mkdir_p(bundle_dir)
      File.write(gemfile_path, "source 'https://rubygems.org'\n")
      File.binwrite(lock_path, Marshal.dump({}))

      original = {
        "PATH" => "/usr/bin:/bin",
        "BUNDLE_GEMFILE" => gemfile_path,
        "RUBYOPT" => "-rbundler/setup -W:no-deprecated",
      }
      encoded = Base64.strict_encode64(Marshal.dump(original))

      lib_dir = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        require "bundler/setup"
        inside = nil
        Bundler.with_unbundled_env do
          inside = [ENV["PATH"], ENV["RUBYOPT"]]
        end
        print [
          Bundler::ORIGINAL_ENV["PATH"],
          Bundler.original_env["PATH"],
          Bundler.unbundled_env["RUBYOPT"],
          inside[0],
          inside[1],
        ].join("|")
      RUBY

      out, err, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => gemfile_path,
          "SCINT_RUNTIME_LOCK" => lock_path,
          "SCINT_ORIGINAL_ENV" => encoded,
          "PATH" => "/tmp/custom-path",
          "RUBYOPT" => "-rbundler/setup",
        },
        RbConfig.ruby,
        "-I#{lib_dir}",
        "-e",
        script,
      )

      assert status.success?, err
      assert_equal "/usr/bin:/bin|/usr/bin:/bin|-W:no-deprecated|/usr/bin:/bin|-W:no-deprecated", out
    end
  end
end
