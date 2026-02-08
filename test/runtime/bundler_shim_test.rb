# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "base64"

class BundlerShimTest < Minitest::Test
  def test_bundler_setup_and_require_use_scint_runtime_lock
    with_tmpdir do |dir|
      project_dir = File.join(dir, "app")
      bundle_dir = File.join(project_dir, ".bundle")
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
          "RUBYLIB" => lib_dir,
          "RUBYOPT" => "",
          "BUNDLER_SETUP" => nil,
        },
        RbConfig.ruby,
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
      bundle_dir = File.join(project_dir, ".bundle")
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
          "RUBYOPT" => "",
          "RUBYLIB" => lib_dir,
          "BUNDLER_SETUP" => nil,
        },
        RbConfig.ruby,
        "-e",
        script,
      )

      assert status.success?, err
      assert_equal "/usr/bin:/bin|/usr/bin:/bin|-W:no-deprecated|/usr/bin:/bin|-W:no-deprecated", out
    end
  end

  def test_bundler_require_falls_back_to_matching_underscored_file
    with_tmpdir do |dir|
      project_dir = File.join(dir, "app")
      bundle_dir = File.join(project_dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gem_lib = File.join(project_dir, "vendor", "actionmailer", "lib")
      gemfile_path = File.join(project_dir, "Gemfile")

      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(gem_lib)
      File.write(File.join(gem_lib, "action_mailer.rb"), "ACTION_MAILER_LOADED = true\n")
      File.write(gemfile_path, "source 'https://rubygems.org'\ngem 'actionmailer'\n")
      File.binwrite(lock_path, Marshal.dump({ "actionmailer" => { load_paths: [gem_lib] } }))

      lib_dir = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        require "bundler/setup"
        Bundler.require
        print defined?(ACTION_MAILER_LOADED)
      RUBY

      out, err, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => gemfile_path,
          "SCINT_RUNTIME_LOCK" => lock_path,
          "RUBYLIB" => lib_dir,
          "RUBYOPT" => "",
          "BUNDLER_SETUP" => nil,
        },
        RbConfig.ruby,
        "-e",
        script,
      )

      assert status.success?, err
      assert_equal "constant", out
    end
  end

  def test_bundler_require_falls_back_to_compatible_prefix_basename
    with_tmpdir do |dir|
      project_dir = File.join(dir, "app")
      bundle_dir = File.join(project_dir, ".bundle")
      lock_path = File.join(bundle_dir, "scint.lock.marshal")
      gem_lib = File.join(project_dir, "vendor", "railties", "lib")
      gemfile_path = File.join(project_dir, "Gemfile")

      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(gem_lib)
      File.write(File.join(gem_lib, "rails.rb"), "RAILS_FROM_RAILTIES = true\n")
      File.write(gemfile_path, "source 'https://rubygems.org'\ngem 'railties'\n")
      File.binwrite(lock_path, Marshal.dump({ "railties" => { load_paths: [gem_lib] } }))

      lib_dir = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        require "bundler/setup"
        Bundler.require
        print defined?(RAILS_FROM_RAILTIES)
      RUBY

      out, err, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => gemfile_path,
          "SCINT_RUNTIME_LOCK" => lock_path,
          "RUBYLIB" => lib_dir,
          "RUBYOPT" => "",
          "BUNDLER_SETUP" => nil,
        },
        RbConfig.ruby,
        "-e",
        script,
      )

      assert status.success?, err
      assert_equal "constant", out
    end
  end
end
