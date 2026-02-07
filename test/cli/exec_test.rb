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
end
