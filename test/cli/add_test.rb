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
end
