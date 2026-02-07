# frozen_string_literal: true

require_relative "test_helper"
require "scint/commands/install"
require "scint/commands/exec"

class CommandsTest < Minitest::Test
  def test_commands_install_can_be_initialized
    install = Scint::Commands::Install.new([])
    assert_instance_of Scint::Commands::Install, install
  end

  def test_commands_install_with_args
    install = Scint::Commands::Install.new(["--jobs", "4"])
    assert_instance_of Scint::Commands::Install, install
  end

  def test_commands_exec_can_be_initialized
    exec_cmd = Scint::Commands::Exec.new([])
    assert_instance_of Scint::Commands::Exec, exec_cmd
  end

  def test_commands_exec_with_args
    exec_cmd = Scint::Commands::Exec.new(["ruby", "-v"])
    assert_instance_of Scint::Commands::Exec, exec_cmd
  end

  def test_commands_install_run_delegates_to_impl
    install = Scint::Commands::Install.new([])
    called = false
    install.instance_variable_get(:@impl).stub(:run, -> { called = true; nil }) do
      install.run
    end
    assert called
  end

  def test_commands_exec_run_delegates_to_impl
    exec_cmd = Scint::Commands::Exec.new([])
    called = false
    exec_cmd.instance_variable_get(:@impl).stub(:run, -> { called = true; nil }) do
      exec_cmd.run
    end
    assert called
  end
end
