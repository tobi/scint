# frozen_string_literal: true

require_relative "../test_helper"
require "scint/cli/remove"

class CLIRemoveTest < Minitest::Test
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

  def test_run_removes_gem_and_skips_install_when_requested
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"
          gem "rack"
          gem "rake"
        RUBY

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, err = with_captured_io do
            status = Scint::CLI::Remove.new(["rack", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_equal "", err
          assert_includes out, "Removed rack"
        end

        contents = File.read("Gemfile")
        refute_includes contents, "gem \"rack\""
        assert_includes contents, "gem \"rake\""
      end
    end
  end

  def test_run_reports_missing_gem
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\n")

        Scint::CLI::Install.stub(:new, ->(*) { flunk("install should not run") }) do
          out, err = with_captured_io do
            status = Scint::CLI::Remove.new(["rack", "--skip-install"]).run
            assert_equal 0, status
          end

          assert_equal "", err
          assert_includes out, "No Gemfile entry found for rack"
        end
      end
    end
  end

  def test_run_invokes_install_by_default
    with_tmpdir do |dir|
      with_cwd(dir) do
        File.write("Gemfile", "source \"https://rubygems.org\"\ngem \"rack\"\n")

        install_called = false
        fake_install = Object.new
        fake_install.define_singleton_method(:run) do
          install_called = true
          0
        end

        Scint::CLI::Install.stub(:new, ->(*) { fake_install }) do
          _out, _err = with_captured_io do
            status = Scint::CLI::Remove.new(["rack"]).run
            assert_equal 0, status
          end
        end

        assert_equal true, install_called
      end
    end
  end

  def test_run_requires_gem_name
    out, err = with_captured_io do
      status = Scint::CLI::Remove.new([]).run
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Usage: scint remove"
  end
end
