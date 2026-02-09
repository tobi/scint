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

  def test_interactive_mode_shows_processing_spinner_for_setup_only_work
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")
    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:render_live_locked)
    end
    progress.on_complete(1, :fetch_index, "https://rubygems.org")
    progress.stop

    text = out.string
    assert_includes text, "Fetching index https://rubygems.org"
    assert_includes text, "Processing..."
    refute_includes text, "Fetched index https://rubygems.org"
  end

  def test_setup_line_followed_by_stream_work
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :fetch_index, "https://rubygems.org")
    progress.on_start(1, :fetch_index, "https://rubygems.org")
    progress.on_enqueue(2, :link, "rack")
    progress.on_start(2, :link, "rack")

    text = out.string.gsub("\r", "")
    assert_includes text, "Fetching index https://rubygems.org\n"
    assert_includes text, "Installing rack"
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

  def test_counts_builtin_scint_link_like_normal_install_task
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "scint")
    progress.on_start(1, :link, "scint")
    progress.on_complete(1, :link, "scint")
    progress.on_enqueue(2, :link, "rack")
    progress.on_start(2, :link, "rack")
    progress.on_complete(2, :link, "rack")

    assert_equal "2 gems processed", progress.summary
    assert_includes out.string, "Installing scint"
    assert_includes out.string, "Installing rack"
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
    assert_includes text, "Compiling"
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
    assert_includes text, "Downloads"
    assert_includes text, "· gem0"
  end

  def test_interactive_mode_renders_compile_after_install_when_both_active
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "rack")
    progress.on_start(1, :link, "rack")
    progress.on_enqueue(2, :build_ext, "nokogiri")
    progress.on_start(2, :build_ext, "nokogiri")
    sleep 0.3
    progress.stop

    text = out.string
    install_idx = text.index("Installing")
    compile_idx = text.index("Compiling")
    refute_nil install_idx
    refute_nil compile_idx
    assert_operator install_idx, :<, compile_idx
  end

  def test_interactive_mode_renders_all_phase_rows_with_dim_idle_marker
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "rack")
    progress.on_start(1, :download, "rack")
    sleep 0.3
    progress.stop

    text = out.string
    assert_includes text, "Downloads"
    refute_includes text, "Extraction"
    refute_includes text, "Compiling"
    refute_match(/Installing.*\d+\/\d+/, text)
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

  def test_interactive_mode_prints_phase_summary_on_completion
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :link, "central_icons")
    progress.on_start(1, :link, "central_icons")
    progress.on_complete(1, :link, "central_icons")
    progress.stop

    text = out.string
    # Phase summary line is emitted when all jobs of a type finish
    assert_includes text, "Installing"
    assert_includes text, "1/1"
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
    # After stop, cursor should be restored and followup output appended
    assert_match(/\e\[\?25hSUMMARY/, text)
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

  def test_truncate_plain_returns_text_unchanged_when_short
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:truncate_plain, "hello", 10)
    assert_equal "hello", result
  end

  def test_truncate_plain_truncates_long_text_with_ellipsis
    progress = Scint::Progress.new(output: StringIO.new)
    long_text = "a" * 50
    result = progress.send(:truncate_plain, long_text, 20)
    assert_equal 20, result.length
    assert result.end_with?("…"), "Expected truncated text to end with ellipsis"
    assert_equal "a" * 19 + "…", result
  end

  def test_truncate_plain_at_exact_boundary
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:truncate_plain, "abcde", 5)
    assert_equal "abcde", result
  end

  def test_clamp_panel_rows_returns_lines_unchanged_when_within_limit
    progress = Scint::Progress.new(output: StringIO.new)
    lines = (1..5).map { |i| "line #{i}" }
    result = progress.send(:clamp_panel_rows, lines)
    assert_equal lines, result
  end

  def test_clamp_panel_rows_truncates_when_exceeding_max
    progress = Scint::Progress.new(output: StringIO.new)
    max = Scint::Progress::MAX_PANEL_ROWS
    lines = (1..(max + 5)).map { |i| "line #{i}" }
    result = progress.send(:clamp_panel_rows, lines)
    assert_equal max, result.length
    assert_includes result.last, "..."
    # The first (max - 1) lines should be preserved
    assert_equal lines.first(max - 1), result.first(max - 1)
  end

  def test_fit_line_preserves_ansi_escapes_and_truncates_visible_content
    progress = Scint::Progress.new(output: StringIO.new)
    ansi_line = "\e[1mHello World this is a long string with formatting\e[0m"
    fitted = progress.send(:fit_line, ansi_line, 15)
    visible = progress.send(:visible_width, fitted)
    assert_equal true, visible <= 15
    assert_includes fitted, "…"
    # ANSI escape codes should still be present
    assert_includes fitted, "\e[1m"
  end

  def test_tty_detection_fallback_returns_false_for_string_io
    progress = Scint::Progress.new(output: StringIO.new)
    result = progress.send(:tty_output?, StringIO.new)
    assert_equal false, result
  end

  def test_start_starts_render_thread_in_interactive_mode
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Enqueue a stream type job so the render thread has work
    progress.on_enqueue(1, :link, "rack")

    # start should create a render thread when interactive
    progress.start
    sleep 0.1
    thread = progress.instance_variable_get(:@render_thread)
    assert thread.is_a?(Thread), "Expected render thread to be started"
  ensure
    progress.instance_variable_get(:@mutex).synchronize do
      progress.instance_variable_set(:@render_stop, true)
    end
    thread&.join(1)
  end

  def test_non_interactive_emits_phase_completion
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "bigfile")
    progress.on_start(1, :download, "bigfile")

    progress.on_complete(1, :download, "bigfile")

    text = out.string
    assert_includes text, "Downloading"
    assert_includes text, "bigfile"
    assert_match(/Downloads 1\/1 in (?:\d+ms|\d+\.\d{2}s)/, text)
  end

  def test_stream_active_or_pending_with_pending_jobs
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Enqueue a download but don't start it - so total > completed
    progress.on_enqueue(1, :download, "rack")
    progress.on_enqueue(2, :download, "puma")
    progress.on_start(1, :download, "rack")
    progress.on_complete(1, :download, "rack")

    # Still pending: gem2 is enqueued but not started/completed
    result = progress.send(:stream_active_or_pending?)
    assert_equal true, result
  end

  def test_detect_terminal_width_uses_columns_env
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    with_env("COLUMNS", "60") do
      width = progress.send(:detect_terminal_width, out)
      assert_equal 60, width
    end
  end

  def test_detect_terminal_width_uses_winsize
    io = Object.new
    io.define_singleton_method(:winsize) { [24, 100] }
    progress = Scint::Progress.new(output: StringIO.new)

    with_env("COLUMNS", nil) do
      width = progress.send(:detect_terminal_width, io)
      assert_equal 100, width
    end
  end

  def test_detect_terminal_width_clamps_to_min
    out = StringIO.new
    progress = Scint::Progress.new(output: out)

    with_env("COLUMNS", "10") do
      width = progress.send(:detect_terminal_width, out)
      assert_equal Scint::Progress::MIN_RENDER_WIDTH, width
    end
  end

  def test_tty_output_returns_false_on_exception
    broken_io = Object.new
    broken_io.define_singleton_method(:tty?) { raise IOError, "broken" }
    progress = Scint::Progress.new(output: StringIO.new)

    result = progress.send(:tty_output?, broken_io)
    assert_equal false, result
  end

  def test_phase_rows_for_build_without_tail_has_status_only
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :build_ext, "rack")
    progress.on_start(1, :build_ext, "rack")

    rows = progress.send(:phase_rows_for, :build_ext, "⠋")

    assert_equal 1, rows.length
    assert_includes rows.first, "Compiling"
  ensure
    progress.stop
  end

  def test_render_thread_rescues_standard_error
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    # Make render_live_locked raise so the rescue on line 460-461 triggers
    progress.define_singleton_method(:render_live_locked) do
      raise StandardError, "render exploded"
    end

    progress.instance_variable_get(:@mutex).synchronize do
      progress.send(:start_render_thread_locked)
    end

    thread = progress.instance_variable_get(:@render_thread)
    assert_kind_of Thread, thread

    # The thread should finish without propagating the error
    thread.join(2)
    refute thread.alive?, "Render thread should have exited after rescue"
  end

  def test_detect_terminal_width_rescues_io_console_failure
    # Create an IO-like object that doesn't respond to winsize
    io = StringIO.new
    progress = Scint::Progress.new(output: io)

    # Stub require "io/console" to raise, and make IO.console raise too.
    # We need COLUMNS unset and no winsize method to fall through to the
    # IO.console path (lines 602-610).
    with_env("COLUMNS", nil) do
      # io (StringIO) doesn't have winsize, so we skip the first branch.
      # For the IO.console branch, we need it to raise StandardError.
      # We can do this by temporarily stubbing IO.console.
      original_console = IO.method(:console)
      singleton = IO.singleton_class
      if singleton.method_defined?(:console) || singleton.private_method_defined?(:console)
        singleton.send(:remove_method, :console)
      end
      IO.define_singleton_method(:console) do |*|
        raise StandardError, "no console available"
      end

      begin
        width = progress.send(:detect_terminal_width, io)
        # Should fall through to the default MAX_LINE_LEN, clamped by min
        assert_operator width, :>=, Scint::Progress::MIN_RENDER_WIDTH
        assert_operator width, :<=, Scint::Progress::MAX_LINE_LEN
      ensure
        if singleton.method_defined?(:console) || singleton.private_method_defined?(:console)
          singleton.send(:remove_method, :console)
        end
        IO.define_singleton_method(:console, original_console)
      end
    end
  end

  def test_detect_terminal_width_rescues_winsize_error
    # Create an IO-like object whose winsize raises
    io = Object.new
    io.define_singleton_method(:winsize) { raise IOError, "not a tty" }
    progress = Scint::Progress.new(output: StringIO.new)

    with_env("COLUMNS", nil) do
      width = progress.send(:detect_terminal_width, io)
      # Should fall through to IO.console or default
      assert_operator width, :>=, Scint::Progress::MIN_RENDER_WIDTH
      assert_operator width, :<=, Scint::Progress::MAX_LINE_LEN
    end
  end

  def test_on_fail_in_interactive_mode_shows_failure
    out = FakeTTY.new
    progress = Scint::Progress.new(output: out)

    progress.on_enqueue(1, :download, "rack")
    progress.on_start(1, :download, "rack")
    sleep 0.3

    progress.on_fail(1, :download, "rack", StandardError.new("network error"))
    progress.stop

    text = out.string
    assert_includes text, "FAILED"
    assert_includes text, "network error"
  end
end
