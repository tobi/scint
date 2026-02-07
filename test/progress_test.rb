# frozen_string_literal: true

require_relative "test_helper"
require "scint/progress"

class ProgressTest < Minitest::Test
  class FakeTTY < StringIO
    def tty? = true
  end

  def test_logs_tasks_sequentially_and_summarizes_failures
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_complete(1, :link, "rack")

    progress.on_enqueue(2, :download, "bad")
    progress.on_start(2, :download, "bad")
    progress.on_fail(2, :download, "bad", StandardError.new("boom"))

    assert_equal "1 gems installed, 1 failed", progress.summary
    assert_includes out.string, "[1/1] Installing rack"
    assert_includes out.string, "[2/2] Downloading bad"
    assert_includes out.string, "FAILED Downloading bad: boom"
  end

  def test_setup_tasks_do_not_use_ratio_prefix
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")

    assert_includes out.string, "Fetching index https://rubygems.org"
    refute_includes out.string, "[1/1]"
  end

  def test_prints_blank_line_after_setup_before_install_work
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")
    progress.on_enqueue(2, :link, "rack")
    progress.on_start(2, :link, "rack")

    assert_includes out.string, "Fetching index https://rubygems.org\n\n[2/2] Installing rack"
  end

  def test_hides_binstub_task_output
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :binstub, "rack")
    progress.on_start(1, :binstub, "rack")
    progress.on_complete(1, :binstub, "rack")
    progress.on_fail(1, :binstub, "rack", StandardError.new("boom"))

    assert_equal "", out.string
  end

  def test_prints_dim_build_tail_lines
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_build_tail("ffi", ["$ ruby extconf.rb", "checking for foo... yes"])

    assert_includes out.string, "build tail"
    assert_includes out.string, "ffi: $ ruby extconf.rb"
    assert_includes out.string, "ffi: checking for foo... yes"
  end

  def test_interactive_mode_renders_compact_phase_panel
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :build_ext, "rack")
    progress.on_start(1, :build_ext, "rack")
    progress.on_build_tail("rack", ["$ ruby extconf.rb", "checking... yes"])
    sleep 0.3
    progress.on_build_tail("rack", ["done"])
    sleep 0.3
    progress.on_complete(1, :build_ext, "rack")
    progress.stop

    text = out.string
    assert_includes text, "Compiling... (0/1)"
    assert_includes text, "Compiling... (1/1)"
    assert_includes text, "· rack"
    assert_includes text, "    done"
    refute_includes text, "Installing gems..."
    refute_includes text, "[1/1] Linking rack"
  end

  def test_interactive_mode_shows_four_recent_compile_tail_lines
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :build_ext, "nokogiri")
    progress.on_start(1, :build_ext, "nokogiri")
    sleep 0.3
    progress.on_build_tail("nokogiri", ["l1", "l2", "l3", "l4", "l5"])
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "· nokogiri"
    assert_includes text, "    l2"
    assert_includes text, "    l3"
    assert_includes text, "    l4"
    assert_includes text, "    l5"
    refute_includes text, "    l1"
  end

  def test_interactive_mode_shows_only_first_active_job_for_phase
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    5.times do |i|
      progress.on_enqueue(i + 1, :download, "gem#{i}")
      progress.on_start(i + 1, :download, "gem#{i}")
    end
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "Downloads... (0/5)"
    assert_includes text, "· gem0"
  end

  def test_interactive_mode_renders_all_phase_rows_with_dim_idle_marker
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "rack")
    progress.on_start(1, :download, "rack")
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "Downloads... (0/1)"
    assert_includes text, "Extraction... (0/0)"
    assert_includes text, "Compiling... (0/0)"
    assert_includes text, "Installing... (0/0)"
    assert_includes text, "○"
  end

  def test_interactive_mode_hides_and_restores_cursor
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    sleep 0.3
    progress.stop

    assert_includes out.string, "\e[?25l"
    assert_includes out.string, "\e[?25h"
  end

  def test_stop_positions_cursor_below_final_panel_for_followup_output
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    sleep 0.3
    progress.on_complete(1, :link, "rack")
    progress.stop
    out.print "SUMMARY\n"

    text = out.string
    assert_includes text, "Installing... (1/1)"
    assert_match(/\e\[\d+B\r\n\e\[\?25hSUMMARY/, text)
  end

  def test_prints_phase_completion_line_with_timing
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_complete(1, :link, "rack")

    assert_match(/Installing 1\/1 in .*ms|Installing 1\/1 in .*s/, out.string)
  end

  def test_fit_line_truncates_to_terminal_width
    progress = Scint::Progress.new(output: StringIO.new)
    fitted = progress.send(:fit_line, "x" * 200, 20)

    assert_equal true, progress.send(:visible_width, fitted) <= 20
    assert_includes fitted, "…"
  end
end
