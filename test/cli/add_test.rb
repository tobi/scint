# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cli/add"

class CLIAddTest < Minitest::Test
  def with_captured_io
    old_out = $stdout
    old_err = $stderr
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    yield
    [out.string, err.string]
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  def test_run_adds_gem_and_skips_install_when_requested
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, err = with_captured_io do
            status = Scint::CLI::Add.new(["rack", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_equal "", err
          assert_includes out, "Added rack"
          assert_includes File.read("Gemfile"), "gem \"rack\""
        end
      end
    end
  end

  def test_run_updates_existing_gem_line
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"
          gem "rack", "~> 2.0"
        RUBY

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          _out, _err = with_captured_io do
            status = Scint::CLI::Add.new(["rack", "--version", "~> 3.0", "--skip-install"]).run
            assert_equal 0, status
          end
        end

        assert_includes File.read("Gemfile"), "~> 3.0"
      end
    end
  end

  def test_run_invokes_install_by_default
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        install_called = false
        fake_install = Object.new
        fake_install.define_singleton_method(:run) do
          install_called = true
          0
        end

        Scint::CLI::Install.stub(:new, ->(*) { fake_install }) do
          out, err = with_captured_io do
            status = Scint::CLI::Add.new(["rack"]).run
            assert_equal 0, status
          end

          assert_equal "", err
          assert_includes out, "Added rack"
        end

        assert_equal true, install_called
      end
    end
  end

  def test_run_requires_gem_name
    out, err = with_captured_io do
      status = Scint::CLI::Add.new([]).run
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Usage: scint add"
  end

  def test_group_option_passes_group_to_editor
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, _err = with_captured_io do
            status = Scint::CLI::Add.new(["rspec", "--group", "test", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_includes out, "Added rspec"
        end

        contents = File.read("Gemfile")
        assert_includes contents, "rspec"
        assert_includes contents, "test"
      end
    end
  end

  def test_source_option_passes_source_to_editor
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, _err = with_captured_io do
            status = Scint::CLI::Add.new(["my_gem", "--source", "https://private.gems.org", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_includes out, "Added my_gem"
        end

        contents = File.read("Gemfile")
        assert_includes contents, "my_gem"
        assert_includes contents, "https://private.gems.org"
      end
    end
  end

  def test_git_option_passes_git_to_editor
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, _err = with_captured_io do
            status = Scint::CLI::Add.new(["my_gem", "--git", "https://github.com/foo/bar.git", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_includes out, "Added my_gem"
        end

        contents = File.read("Gemfile")
        assert_includes contents, "my_gem"
        assert_includes contents, "https://github.com/foo/bar.git"
      end
    end
  end

  def test_path_option_passes_path_to_editor
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, _err = with_captured_io do
            status = Scint::CLI::Add.new(["my_gem", "--path", "../vendor/my_gem", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_includes out, "Added my_gem"
        end

        contents = File.read("Gemfile")
        assert_includes contents, "my_gem"
        assert_includes contents, "../vendor/my_gem"
      end
    end
  end

  def test_unknown_option_raises_gemfile_error
    assert_raises(Scint::GemfileError) do
      Scint::CLI::Add.new(["rack", "--unknown-flag"])
    end
  end
end
