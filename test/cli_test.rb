# frozen_string_literal: true

require_relative "test_helper"
require "scint/cli"
require "scint/cli/add"
require "scint/cli/remove"

class CLITest < Minitest::Test
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

  def test_run_version_command
    out, err = with_captured_io do
      status = Scint::CLI.run(["version"])
      assert_equal 0, status
    end

    assert_match(/scint #{Regexp.escape(Scint::VERSION)}/, out)
    assert_equal "", err
  end

  def test_run_unknown_command
    out, err = with_captured_io do
      status = Scint::CLI.run(["unknown"])
      assert_equal 1, status
    end

    assert_equal "", out
    assert_includes err, "Unknown command"
  end

  def test_run_cache_command_dispatches
    with_tmpdir do |dir|
      with_env("XDG_CACHE_HOME", dir) do
        out, err = with_captured_io do
          status = Scint::CLI.run(["cache", "dir"])
          assert_equal 0, status
        end

        assert_equal "", err
        assert_equal File.join(dir, "scint") + "\n", out
      end
    end
  end

  def test_run_add_command_dispatches
    fake = Object.new
    fake.define_singleton_method(:run) { 0 }

    Scint::CLI::Add.stub(:new, ->(*) { fake }) do
      _out, _err = with_captured_io do
        status = Scint::CLI.run(["add", "rack", "--skip-install"])
        assert_equal 0, status
      end
    end
  end

  def test_run_remove_command_dispatches
    fake = Object.new
    fake.define_singleton_method(:run) { 0 }

    Scint::CLI::Remove.stub(:new, ->(*) { fake }) do
      _out, _err = with_captured_io do
        status = Scint::CLI.run(["remove", "rack", "--skip-install"])
        assert_equal 0, status
      end
    end
  end

  def test_run_help_command_returns_zero_and_outputs_help_text
    out, err = with_captured_io do
      status = Scint::CLI.run(["help"])
      assert_equal 0, status
    end

    assert_equal "", err
    assert_includes out, "Usage: scint COMMAND"
    assert_includes out, "Commands:"
    assert_includes out, "install"
    assert_includes out, "exec"
  end

  def test_run_help_flag_returns_zero_and_outputs_help_text
    out, err = with_captured_io do
      status = Scint::CLI.run(["--help"])
      assert_equal 0, status
    end

    assert_equal "", err
    assert_includes out, "Usage: scint COMMAND"
  end

  def test_run_exec_command_dispatches
    fake = Object.new
    fake.define_singleton_method(:run) { 0 }

    require "scint/cli/exec"
    Scint::CLI::Exec.stub(:new, ->(*) { fake }) do
      _out, _err = with_captured_io do
        status = Scint::CLI.run(["exec", "ruby", "-v"])
        assert_equal 0, status
      end
    end
  end

  def test_run_returns_130_on_interrupt
    require "scint/cli/exec"
    fake = Object.new
    fake.define_singleton_method(:run) { raise Interrupt }

    Scint::CLI::Exec.stub(:new, ->(*) { fake }) do
      _out, err = with_captured_io do
        status = Scint::CLI.run(["exec", "ruby"])
        assert_equal 130, status
      end

      assert_includes err, "Interrupted"
    end
  end

  def test_run_returns_1_on_generic_exception
    require "scint/cli/exec"
    fake = Object.new
    fake.define_singleton_method(:run) { raise RuntimeError, "something broke" }

    Scint::CLI::Exec.stub(:new, ->(*) { fake }) do
      _out, err = with_captured_io do
        status = Scint::CLI.run(["exec", "ruby"])
        assert_equal 1, status
      end

      assert_includes err, "Fatal: RuntimeError: something broke"
    end
  end

  def test_run_maps_bundler_error_to_status_code
    with_tmpdir do |dir|
      with_cwd(dir) do
        _out, err = with_captured_io do
          status = Scint::CLI.run(["install"])
          assert_equal 4, status
        end

        assert_includes err, "Error:"
      end
    end
  end
end
